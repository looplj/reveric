// 职责: 启动、迁移与桌面生命周期失败时绕过本地数据库，向配置的地址上报匿名诊断。
// 关联文件:
//   lib/main.dart
//   lib/shared/database/app_database.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/services/device_id_service.dart
//   lib/shared/services/anonymous_reporting_consent_service.dart
// 遵循的 Rules:
//   .agents/rules/error-handling.md

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../app_config.dart';
import '../services/anonymous_reporting_consent_service.dart';
import '../services/device_id_service.dart';
import 'app_logger.dart';

final _log = AppLogger.forModule('StartupFailureReporter');

enum StartupFailureReportOutcome { reported, skipped, retryableFailure }

/// 直连上报启动期间的关键失败。
///
/// 该 reporter 不依赖 Drift、Riverpod 或 Outbox，因此数据库升级失败时仍可用。
class StartupFailureReporter {
  StartupFailureReporter({
    http.Client? httpClient,
    Future<String> Function()? getDeviceId,
    String Function()? getBaseUrl,
    Future<bool> Function()? getEnabled,
    DateTime Function()? now,
  }) : _httpClient = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null,
       _getDeviceId = getDeviceId ?? _defaultDeviceId,
       _getBaseUrl = getBaseUrl ?? _defaultBaseUrl,
       _getEnabled = getEnabled ?? _defaultEnabled,
       _now = now ?? DateTime.now;

  static const _timeout = Duration(seconds: 3);
  static const _maxMessageLength = 500;

  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final Future<String> Function() _getDeviceId;
  final String Function() _getBaseUrl;
  final Future<bool> Function() _getEnabled;
  final DateTime Function() _now;

  /// 生命周期故障只上传分类，不上传可能包含安装路径、端口或凭证的原始异常。
  Future<void> reportLifecycleFailure({
    required String phase,
    required String reason,
    required Object error,
    required StackTrace stackTrace,
  }) async {
    try {
      await report(
        phase: phase,
        error: LifecycleFailure(reason: reason, cause: error),
        stackTrace: stackTrace,
      ).timeout(const Duration(seconds: 4));
    } catch (reportError, reportStack) {
      _log.warning(
        'Lifecycle report failed phase=$phase error=$reportError\n$reportStack',
      );
    }
  }

  /// 上报失败本身不会覆盖原始启动/迁移异常。
  Future<void> report({
    required String phase,
    required Object error,
    required StackTrace stackTrace,
  }) async {
    await reportWithOutcome(phase: phase, error: error, stackTrace: stackTrace);
  }

  /// 上报并返回可供持久化队列判断是否应重试的结果。
  Future<StartupFailureReportOutcome> reportWithOutcome({
    required String phase,
    required Object error,
    required StackTrace stackTrace,
  }) async {
    if (!await _getEnabled()) {
      if (_log.isDebugEnabled) {
        _log.debug('skipped: reporting disabled phase=$phase');
      }
      return StartupFailureReportOutcome.skipped;
    }

    try {
      final baseUrl = _getBaseUrl().trim();
      if (baseUrl.isEmpty) {
        _log.warning('failed: empty base URL phase=$phase');
        return StartupFailureReportOutcome.retryableFailure;
      }

      final occurredAt = _now().toUtc();
      final deviceId = await _getStableDeviceId().timeout(_timeout);
      final payload = {
        'events': [
          {
            'device_id': deviceId,
            'session_id':
                'startup_${occurredAt.microsecondsSinceEpoch}_${phase.hashCode}',
            'session_mode': 'startup',
            'model': 'app',
            'error_type': 'request_error',
            'error_code': _errorCodeFor(phase),
            'exception_type': _safeErrorTypeName(error),
            'exception_message': _diagnosticMessage(
              phase: phase,
              error: error,
              stackTrace: stackTrace,
            ),
            'app_version': appVersion,
            'platform': Platform.operatingSystem,
            'occurred_at': occurredAt.toIso8601String(),
          },
        ],
      };
      final url = baseUrl.replaceFirst(RegExp(r'/$'), '');
      final response = await _httpClient
          .post(
            Uri.parse(url),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(_timeout);
      if (response.statusCode != 204) {
        _log.warning(
          'rejected phase=$phase status=${response.statusCode} '
          'body=${response.body}',
        );
        return StartupFailureReportOutcome.retryableFailure;
      }
      _log.info('reported phase=$phase');
      return StartupFailureReportOutcome.reported;
    } catch (reportError, reportStackTrace) {
      _log.warning('failed phase=$phase error=$reportError\n$reportStackTrace');
      return StartupFailureReportOutcome.retryableFailure;
    } finally {
      if (_ownsHttpClient) {
        _httpClient.close();
      }
    }
  }

  Future<String> _getStableDeviceId() async {
    try {
      return await _getDeviceId();
    } catch (error, stackTrace) {
      _log.warning(
        'device ID unavailable; using ephemeral ID error=$error\n$stackTrace',
      );
      return const Uuid().v4();
    }
  }

  static Future<String> _defaultDeviceId() {
    return DeviceIdService().getOrCreate();
  }

  static String _defaultBaseUrl() => startupFailureReportingUrl;

  /// 配置了启动诊断地址且设置开启时才上报。
  static Future<bool> _defaultEnabled() async {
    if (startupFailureReportingUrl.isEmpty) {
      return false;
    }
    try {
      return await const AnonymousReportingConsentService().isGranted();
    } catch (error) {
      _log.warning('consent unavailable; skip reporting error=$error');
      return false;
    }
  }

  String _errorCodeFor(String phase) {
    final normalized = phase
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return normalized.isEmpty ? 'startup_failure' : normalized;
  }

  String _safeErrorTypeName(Object error) {
    final cleaned = error.runtimeType.toString().replaceAll(
      RegExp(r'[^A-Za-z0-9_]'),
      '',
    );
    return cleaned.isEmpty ? 'Object' : cleaned;
  }

  String _diagnosticMessage({
    required String phase,
    required Object error,
    required StackTrace stackTrace,
  }) {
    final stackTop = _sanitizeStackTop(stackTrace);
    final raw =
        'phase=$phase error=$error'
        '${stackTop.isEmpty ? '' : '\nstack=$stackTop'}';
    if (raw.length <= _maxMessageLength) {
      return raw;
    }
    // stack 排障价值高于 error 正文，但它拼在末尾，整体截断会先把它切掉：
    // Riverpod 的 UnmountedRefException 自带数百字符说明，线上因此连一帧都拿不到。
    // 超长时给 stack 留出预算，压缩中间的 error 文本。
    if (stackTop.isNotEmpty) {
      final prefix = 'phase=$phase error=';
      final suffix = '\nstack=$stackTop';
      const ellipsis = '...[truncated]';
      final errorBudget =
          _maxMessageLength - prefix.length - suffix.length - ellipsis.length;
      if (errorBudget > 0) {
        final errorText = error.toString();
        final clipped = errorText.length <= errorBudget
            ? errorText
            : '${errorText.substring(0, errorBudget)}$ellipsis';
        return '$prefix$clipped$suffix';
      }
    }
    return '${raw.substring(0, _maxMessageLength)}...[truncated]';
  }

  String _sanitizeStackTop(StackTrace stackTrace) {
    final frames = <String>[];
    final projectFrames = <String>[];
    final pattern = RegExp(r'\((.*?):(\d+)(?::(\d+))?\)');
    for (final rawLine in stackTrace.toString().split('\n')) {
      final match = pattern.firstMatch(rawLine);
      if (match == null) {
        continue;
      }
      final fileName = match.group(1)!.split('/').last;
      final line = match.group(2)!;
      final column = match.group(3);
      final frame = column == null
          ? '$fileName:$line'
          : '$fileName:$line:$column';
      if (frames.length < 5) {
        frames.add(frame);
      }
      // 框架或网络帧可能占满前五帧；保留栈中最先出现的两个项目调用点。
      // 仅使用 package URI 识别项目，输出仍只有 basename 与行列号。
      if (match.group(1)!.startsWith('package:reveric/') &&
          projectFrames.length < 2 &&
          !projectFrames.contains(frame)) {
        projectFrames.add(frame);
      }
    }
    final missing = projectFrames
        .where((frame) => !frames.contains(frame))
        .toList();
    if (missing.isEmpty) {
      return frames.join(', ');
    }
    // 不移除已经位于顶部的项目帧。
    final selected = [...frames];
    for (final frame in missing) {
      if (selected.length >= 5) {
        final index = selected.lastIndexWhere(
          (f) => !projectFrames.contains(f),
        );
        selected.removeAt(index);
      }
      selected.add(frame);
    }
    return selected.join(', ');
  }
}

/// 有界、脱敏的生命周期诊断；具体 error code 由 reporter 的 phase 提供。
class LifecycleFailure implements Exception {
  LifecycleFailure({required String reason, required Object cause})
    : reason = reason
          .replaceAll(RegExp(r'[^a-z0-9_]'), '_')
          .substring(0, reason.length.clamp(0, 80)),
      causeType = cause.runtimeType.toString().replaceAll(
        RegExp(r'[^A-Za-z0-9_]'),
        '',
      ),
      osCode = switch (cause) {
        FileSystemException(:final osError) => osError?.errorCode,
        SocketException(:final osError) => osError?.errorCode,
        _ => null,
      },
      processExitCode = cause is ProcessException ? cause.errorCode : null;

  final String reason;
  final String causeType;
  final int? osCode;
  final int? processExitCode;

  @override
  String toString() =>
      'reason=$reason cause=$causeType'
      '${osCode == null ? '' : ' os_code=$osCode'}'
      '${processExitCode == null ? '' : ' exit_code=$processExitCode'}';
}
