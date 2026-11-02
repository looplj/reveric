// 职责: 收集当前日志和最近崩溃转储，经匿名上传接口提交一次诊断资料。
// 关联文件:
//   lib/shared/services/anonymous_file_service.dart
//   lib/shared/services/crash_reporting/native_crash_reporting.dart
//   lib/shared/widgets/settings/about_settings_section.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/file-access.md
//   .agents/rules/error-handling.md

import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../logger/app_logger.dart';
import 'anonymous_file_service.dart';
import 'crash_reporting/native_crash_reporting.dart';

final _log = AppLogger.forModule('DiagnosticsUpload');

class DiagnosticsUploadOrchestrator {
  Future<UploadResult> upload({
    required String logPath,
    required AnonymousFileService uploadService,
  }) async {
    var stage = 'collect';
    try {
      final logFile = File(logPath);
      final logBytes = await logFile.readAsBytes();
      final dump = await NativeCrashReporting.prepareLatestDump(
        p.join(logFile.parent.parent.path, 'crashes'),
      );
      final hasDump = dump != null;
      final List<int> bytes;
      if (dump != null) {
        stage = 'bundle';
        final dumpBytes = await dump.readAsBytes();
        bytes = await Isolate.run(() {
          final archive = Archive()
            ..addFile(ArchiveFile.bytes('latest.log', logBytes))
            ..addFile(ArchiveFile.bytes('latest.dump', dumpBytes));
          return ZipEncoder().encodeBytes(archive);
        });
      } else {
        bytes = logBytes;
      }
      // 后端 diagnostics namespace 的单文件上限为 50 MB。
      if (bytes.isEmpty || bytes.length > 50 * 1024 * 1024) {
        throw StateError('Diagnostic upload size is outside the allowed range');
      }
      stage = 'upload';
      _log.info('Uploading diagnostics dump=$hasDump bytes=${bytes.length}');
      final result = await uploadService.upload(
        namespace: 'diagnostics',
        fileBytes: bytes,
        contentType: hasDump ? 'application/zip' : 'text/plain',
      );
      if (!result.success || result.error != null) {
        _log.warning(
          'Diagnostic upload failed stage=$stage error=${result.error}',
        );
        return UploadResult(
          uploadId: result.uploadId,
          success: false,
          error: result.error,
        );
      }
      return result;
    } catch (error, stackTrace) {
      _log.error(
        'Diagnostic upload failed stage=$stage',
        error: error,
        stackTrace: stackTrace,
      );
      return const UploadResult(
        success: false,
        error: 'Diagnostic upload failed',
      );
    }
  }
}
