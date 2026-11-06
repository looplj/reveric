// 职责: 执行可中止的音频提交与查询 HTTP 请求并统一错误分类和诊断。
// 关联文件:
//   lib/shared/models/audio/request.dart
//   lib/shared/models/audio/exception.dart
//   lib/shared/providers/production_audio.dart
//   lib/shared/services/ai/media_diagnostics.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../../../utils/ai_error.dart';
import '../../../localization/ai_run_failure_localization.dart';
import '../../../logger/app_logger.dart';
import '../../../models/ai_run_failure.dart';
import '../../../models/ai_provider.dart';
import '../../../models/audio/exception.dart';
import '../../../models/audio/request.dart';
import '../../../models/audio/channels.dart';
import '../../../models/audio/result.dart';
import '../media_diagnostics.dart';
import 'retry.dart';
export '../../../models/audio/result.dart';

final _log = AppLogger.forModule('AudioClient');

abstract class AudioClient {
  AudioClient(
    this.client,
    this.apiKey, {
    required this.providerType,
    this.timeout = const Duration(seconds: 150),
    this.readRetryDelay = const Duration(seconds: 1),
  });
  final http.Client client;
  final String apiKey;

  /// 用于查找渠道登记的型号能力和请求默认值。
  final String providerType;
  final Duration timeout;
  final Duration readRetryDelay;

  /// 渠道未登记的型号没有型号默认值，按协议能解码的输出格式发送。
  AudioRequestDefaults get unlistedModelDefaults;

  Uri get requestUrl;
  Uri submissionUrl(AudioRequest request) => requestUrl;
  Map<String, String> get headers;
  Map<String, dynamic> encode(
    AudioRequest request, {
    List<Uint8List> references = const [],
  });
  AudioGenerationResult decodeResult(Map<String, dynamic> json);
  AudioGenerationResult? decodeBinaryResult(
    Uint8List bytes,
    Map<String, String> headers,
    AudioRequest request,
  ) => null;
  String? providerMessage(Map<String, dynamic> json) =>
      tryReadProviderMessage((message: json));

  Future<AudioGenerationResult> generate(
    AudioRequest request, {
    List<Uint8List> references = const [],
    Future<void>? abortTrigger,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw const AudioException('invalid_config');
    }
    // 未登记型号不校验能力，是否允许使用由业务层决定。
    request = lookupAudioChannelModel(providerType, request.modelId) == null
        ? request.withDefaults(unlistedModelDefaults)
        : resolveAudioRequest(providerType, request);
    final endpoint = submissionUrl(request);
    final body = encode(request, references: references);
    return executeRequest(
      'POST',
      endpoint,
      body: body,
      audioRequest: request,
      abortTrigger: abortTrigger,
    );
  }

  Future<AudioGenerationResult> executeRequest(
    String method,
    Uri endpoint, {
    Map<String, dynamic>? body,
    AudioRequest? audioRequest,
    Future<void>? abortTrigger,
  }) async {
    Future<AudioGenerationResult> attempt(int number) => _executeOnce(
      method,
      endpoint,
      body: body,
      audioRequest: audioRequest,
      abortTrigger: abortTrigger,
      attempt: number,
    );
    if (method != 'GET') {
      return attempt(1);
    }
    try {
      return await retryAudioRead(
        attempt,
        context:
            'phase=query provider=$providerType host=${endpoint.host} path=${endpoint.path}',
        apiKey: apiKey,
        abortTrigger: abortTrigger,
        delay: readRetryDelay,
      );
    } catch (error) {
      if (error is AudioException || error is Error) {
        rethrow;
      }
      throw AudioException(
        'unavailable',
        detail: safeMediaDiagnostic(error, apiKey),
      );
    }
  }

  Future<AudioGenerationResult> _executeOnce(
    String method,
    Uri endpoint, {
    Map<String, dynamic>? body,
    AudioRequest? audioRequest,
    Future<void>? abortTrigger,
    required int attempt,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw const AudioException('invalid_config');
    }
    if (!{'http', 'https'}.contains(endpoint.scheme) ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment) {
      throw const AudioException('invalid_config');
    }
    final abort = Completer<void>();
    var cancelled = false;
    void stop() {
      if (!abort.isCompleted) {
        abort.complete();
      }
    }

    if (abortTrigger != null) {
      unawaited(
        abortTrigger.then((_) {
          cancelled = true;
          stop();
        }),
      );
    }
    int? status;
    String? responseMessage;
    String? diagnosticBody;
    AudioException? httpFailure;
    try {
      // Observe a cancellation that arrived before the transport was created.
      await Future<void>.value();
      if (cancelled) {
        throw const AudioException('cancelled');
      }
      if (_log.isDebugEnabled) {
        _log.debug(
          'event=request provider=$providerType phase=${method == "POST" ? "submit" : "query"} '
          'host=${endpoint.host} path=${endpoint.path} attempt=$attempt/${method == "POST" ? 1 : 3} '
          'model=${audioRequest?.modelId ?? ""}',
        );
      }
      return await (() async {
        final post =
            http.AbortableRequest(method, endpoint, abortTrigger: abort.future)
              ..followRedirects = false
              ..headers.addAll({
                ...headers,
                'Content-Type': 'application/json',
              });
        if (body != null) {
          post.body = jsonEncode(body);
        }
        final response = await client.send(post);
        status = response.statusCode;
        if (status != 200) {
          // The received status survives an invalid, oversized or stalled body.
          httpFailure = _httpFailure(status!);
        }
        final bytes = <int>[];
        final limit = httpFailure == null ? 32 * 1024 * 1024 : 64 * 1024;
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > limit) {
            throw const FormatException('Audio response too large');
          }
          bytes.addAll(chunk);
        }
        if (httpFailure != null) {
          diagnosticBody = utf8.decode(bytes, allowMalformed: true);
          responseMessage = tryReadProviderMessage((message: diagnosticBody));
          httpFailure = _httpFailure(
            status!,
            responseMessage,
            tryReadProviderErrorCode((message: diagnosticBody)),
          );
          throw httpFailure!;
        }
        final binary = audioRequest == null
            ? null
            : decodeBinaryResult(
                Uint8List.fromList(bytes),
                response.headers,
                audioRequest,
              );
        if (binary != null) {
          if (_log.isDebugEnabled) {
            _log.debug(
              'event=response provider=$providerType phase=submit status=$status bytes=${binary.bytes.length}',
            );
          }
          return binary;
        }
        final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        responseMessage = providerMessage(json);
        return decodeResult(json);
      })().timeout(
        timeout,
        onTimeout: () {
          stop();
          throw TimeoutException('Audio request timed out', timeout);
        },
      );
    } catch (error) {
      if (cancelled || error is AudioException && error.code == 'cancelled') {
        throw const AudioException('cancelled');
      }
      _log.warning(
        'provider=$providerType $method ${endpoint.origin}${endpoint.path} '
        'status=${status ?? "unknown"} type=${error.runtimeType} '
        'error=${safeMediaDiagnostic(error, apiKey)} '
        'message=${safeMediaDiagnostic(responseMessage ?? diagnosticBody ?? error, apiKey)}',
      );
      // Unknown program errors retain their original stack at the task boundary.
      if (error is Error && error is! TypeError) {
        rethrow;
      }
      if (method == 'GET' && httpFailure == null && retryableAudioRead(error)) {
        rethrow;
      }
      // No automatic POST retry: a missing receipt cannot prove non-acceptance.
      throw httpFailure ??
          (error is AudioException
              ? error
              : AudioException(
                  method == 'POST' ? 'audio_submission_unknown' : 'unavailable',
                ));
    } finally {
      stop();
    }
  }

  AudioException _httpFailure(
    int status, [
    String? message,
    String? providerCode,
  ]) {
    final failure = AiRunFailure.http(
      statusCode: status,
      providerMessage: message,
      providerCode: providerCode,
    );
    return AudioException(
      switch (status) {
        401 || 403 => 'authentication',
        429 => 'rate_limited',
        >= 500 => 'unavailable',
        >= 400 && < 500 => 'rejected',
        _ => 'audio_submission_unknown',
      },
      statusCode: status,
      messageKey: localizeAiRunFailure(
        failure,
        (key) => key,
        preferProviderMessage: false,
      ),
      // 已识别出专用文案时不再展示原文，原文仍保留在 detail 中。
      providerMessage: recognizedAiRunFailureKey(failure) == null
          ? message
          : null,
      detail: providerErrorDetail(providerCode, message, apiKey),
    );
  }
}

/// Temporary outputs are fetched without provider credentials; only GETs retry.
Future<Uint8List> downloadAudioOutput(
  Uri url, {
  AiProvider? provider,
  http.Client? httpClient,
  Future<void>? abortTrigger,
  Duration timeout = const Duration(seconds: 60),
  Duration retryDelay = const Duration(seconds: 1),
}) async {
  if (url.scheme != 'https' ||
      url.host.isEmpty ||
      url.userInfo.isNotEmpty ||
      url.hasFragment) {
    throw const AudioException('audio_output_unavailable');
  }
  final client = httpClient ?? provider?.createProxyClient() ?? http.Client();
  try {
    return await retryAudioRead(
      (attempt) async {
        final abort = Completer<void>();
        void stop() {
          if (!abort.isCompleted) {
            abort.complete();
          }
        }

        if (abortTrigger != null) {
          unawaited(abortTrigger.then((_) => stop()));
        }
        int? status;
        final clock = Stopwatch()..start();
        if (_log.isDebugEnabled) {
          _log.debug(
            'event=download phase=download host=${url.host} attempt=$attempt/3 started',
          );
        }
        try {
          return await (() async {
            final request = http.AbortableRequest(
              'GET',
              url,
              abortTrigger: abort.future,
            )..followRedirects = false;
            final response = await client.send(request);
            status = response.statusCode;
            final bytes = <int>[];
            final limit = status == 200 ? 32 * 1024 * 1024 : 64 * 1024;
            await for (final chunk in response.stream) {
              if (bytes.length + chunk.length > limit) {
                throw AudioException(
                  'audio_output_unavailable',
                  statusCode: status,
                  detail: 'Audio download exceeded response size limit',
                );
              }
              bytes.addAll(chunk);
            }
            if (status != 200) {
              throw AudioException(
                'audio_output_unavailable',
                statusCode: status,
                detail: safeMediaDiagnostic(
                  utf8.decode(bytes, allowMalformed: true),
                  '',
                ),
              );
            }
            if (bytes.isEmpty) {
              throw const AudioException(
                'audio_output_unavailable',
                detail: 'Empty audio response',
              );
            }
            if (_log.isDebugEnabled) {
              _log.debug(
                'event=download phase=download host=${url.host} attempt=$attempt/3 '
                'status=$status bytes=${bytes.length} elapsed_ms=${clock.elapsedMilliseconds} completed',
              );
            }
            return Uint8List.fromList(bytes);
          })().timeout(
            timeout,
            onTimeout: () {
              stop();
              throw TimeoutException('Audio download timed out', timeout);
            },
          );
        } catch (error) {
          // A known HTTP failure retains its status even when the error body breaks.
          if (status != null &&
              status != 200 &&
              error is! AudioException &&
              error is! Error) {
            throw AudioException(
              'audio_output_unavailable',
              statusCode: status,
              detail: safeMediaDiagnostic(error, ''),
            );
          }
          rethrow;
        } finally {
          stop();
        }
      },
      context: 'phase=download host=${url.host}',
      abortTrigger: abortTrigger,
      delay: retryDelay,
    );
  } catch (error) {
    if (error is AudioException || error is Error) {
      rethrow;
    }
    throw AudioException(
      'audio_output_unavailable',
      detail: safeMediaDiagnostic(error, ''),
    );
  } finally {
    if (httpClient == null) {
      client.close();
    }
  }
}
