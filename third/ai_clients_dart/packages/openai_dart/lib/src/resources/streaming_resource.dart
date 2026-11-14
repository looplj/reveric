import 'dart:async'
    show Completer, StreamController, StreamSubscription, unawaited;
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../errors/exceptions.dart';
import '../utils/streaming_parser.dart';
import 'base_resource.dart';

/// Mixin that adds streaming capabilities to a [ResourceBase].
///
/// Provides [sendStream] for making SSE streaming requests with
/// proper abort support, dedicated HTTP client per stream, and cleanup
/// on completion, error, and subscription cancellation.
mixin StreamingResource on ResourceBase {
  /// Sends a streaming POST request and yields parsed SSE JSON events.
  ///
  /// Creates a dedicated HTTP client per stream for abort support.
  /// The [abortTrigger] parameter allows canceling the request. When the
  /// future completes, the underlying HTTP connection is closed, which
  /// terminates the stream.
  ///
  /// Returns the raw [http.StreamedResponse] for resources that need
  /// custom SSE parsing (e.g., typed event deserialization).
  ///
  /// Note: Streaming requests are NOT retried (non-idempotent, body consumed).
  /// The interceptor chain is bypassed since streaming requires low-level
  /// access to the response stream.
  Future<http.StreamedResponse> sendStream({
    required http.BaseRequest request,
    String? jsonBody,
    Map<String, String>? additionalHeaders,
    Future<void>? abortTrigger,
  }) async {
    ensureNotClosed?.call();

    // Add streaming-specific headers
    final streamHeaders = requestBuilder.buildStreamingHeaders(
      additionalHeaders: additionalHeaders,
    );
    request.headers.addAll(streamHeaders);

    // Multipart requests set their own Content-Type (with a boundary) at
    // finalize time. Drop the JSON content-type added by buildStreamingHeaders
    // so the multipart header isn't shadowed on the wire.
    if (request is http.MultipartRequest) {
      request.headers.removeWhere((k, _) => k.toLowerCase() == 'content-type');
    }

    // Set body AFTER headers so body setter adds charset to Content-Type
    // (e.g., application/json → application/json; charset=utf-8).
    // `jsonBody` only applies to `http.Request`; multipart/stream callers
    // configure their body on the request before calling sendStream.
    if (jsonBody != null) {
      if (request is! http.Request) {
        throw ArgumentError(
          'jsonBody is only supported for http.Request, '
          'got ${request.runtimeType}',
        );
      }
      request.body = jsonBody;
    }

    // Log request if logging is enabled
    Logger('OpenAIClient').fine('Streaming ${request.method} ${request.url}');

    // For abort support, create a dedicated HTTP client for this stream.
    // When abortTrigger completes, we close the client which cancels
    // the in-flight request and terminates the stream.
    if (abortTrigger != null) {
      final dedicatedClient = streamClientFactory?.call() ?? http.Client();
      var aborted = false;
      var clientClosed = false;
      final abortedResponse = Completer<http.StreamedResponse?>();
      void Function()? stopBody;

      void closeClientOnce() {
        if (!clientClosed) {
          clientClosed = true;
          dedicatedClient.close();
        }
      }

      void cancelSubscription(StreamSubscription<List<int>> subscription) {
        // 清理可能依赖失去响应的 transport，不能挡住调用方退出。
        unawaited(
          subscription.cancel().catchError((Object error, StackTrace stack) {
            Logger(
              'StreamingResource',
            ).warning('Stream cleanup failed', error, stack);
          }),
        );
      }

      void abort() {
        aborted = true;
        closeClientOnce();
        stopBody?.call();
        if (!abortedResponse.isCompleted) {
          abortedResponse.complete(null);
        }
      }

      unawaited(
        abortTrigger.then((_) => abort(), onError: (Object _) => abort()),
      );

      try {
        // close() 不保证挂起的 send() 马上完成。取消必须独立解除等待；
        // Future.any 同时接住迟到的错误，迟到的响应则立即取消订阅。
        final response = await Future.any<http.StreamedResponse?>([
          dedicatedClient.send(request).then((response) {
            if (aborted) {
              cancelSubscription(
                response.stream.listen((_) {}, onError: (Object _) {}),
              );
              return null;
            }
            return response;
          }),
          abortedResponse.future,
        ]);
        if (response == null) {
          return http.StreamedResponse(
            const Stream<List<int>>.empty(),
            200,
            request: request,
          );
        }

        final controller = StreamController<List<int>>();
        late final StreamSubscription<List<int>> subscription;
        var controllerClosed = false;
        var subscriptionCancelled = false;

        void closeController() {
          if (!controllerClosed) {
            controllerClosed = true;
            unawaited(controller.close());
          }
        }

        void stop() {
          stopBody = null;
          closeClientOnce();
          if (!subscriptionCancelled) {
            subscriptionCancelled = true;
            cancelSubscription(subscription);
          }
          closeController();
        }

        subscription = response.stream.listen(
          (data) {
            if (!controllerClosed && !aborted) {
              controller.add(data);
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!aborted && !controllerClosed) {
              controller.addError(error, stack);
            }
            stop();
          },
          onDone: () {
            stopBody = null;
            closeClientOnce();
            closeController();
          },
          cancelOnError: false,
        );
        controller.onCancel = stop;
        stopBody = stop;
        if (aborted) {
          stop();
        }

        return http.StreamedResponse(
          controller.stream,
          response.statusCode,
          contentLength: response.contentLength,
          request: response.request,
          headers: response.headers,
          isRedirect: response.isRedirect,
          persistentConnection: response.persistentConnection,
          reasonPhrase: response.reasonPhrase,
        );
      } catch (e) {
        // Close client on send() error too
        closeClientOnce();
        // 消费方主动 abort（2 分钟无事件超时 / 用户取消）时，关闭 dedicated
        // client 会使 send() 失败。此刻消费方正在拆除订阅：若抛 AbortedException
        // 会落入已取消的 async* 生成器，变成 zone 级 unhandled（匿名库误报为
        // uncaught_async）。返回空 200 响应让生成器正常结束，abort 由消费方的
        // 超时/取消流程处理。
        if (aborted) {
          return http.StreamedResponse(
            const Stream<List<int>>.empty(),
            200,
            request: request,
          );
        }
        rethrow;
      }
    }

    // No abort trigger - use the shared HTTP client
    return httpClient.send(request);
  }

  /// Parses an error response from a streaming request.
  ApiException parseStreamError(int statusCode, String body, String requestId) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final error = json['error'] as Map<String, dynamic>?;
      return createApiException(
        statusCode: statusCode,
        message: error?['message'] as String? ?? 'Unknown error',
        type: error?['type'] as String?,
        code: error?['code'] as String?,
        param: error?['param'] as String?,
        requestId: requestId,
        body: json,
      );
    } catch (_) {
      return ApiException(
        message: body.isNotEmpty ? body : 'HTTP $statusCode error',
        statusCode: statusCode,
        requestId: requestId,
      );
    }
  }

  /// Helper to create a streaming POST request with a JSON body.
  ///
  /// Returns the [http.StreamedResponse] with proper error checking.
  Future<http.StreamedResponse> sendStreamRequest({
    required String endpoint,
    required Map<String, dynamic> body,
    Map<String, String>? queryParams,
    Map<String, String>? additionalHeaders,
    Future<void>? abortTrigger,
  }) {
    final url = requestBuilder.buildUrl(endpoint, queryParams: queryParams);
    final request = http.Request('POST', url);

    return sendStream(
      request: request,
      jsonBody: jsonEncode(body),
      additionalHeaders: additionalHeaders,
      abortTrigger: abortTrigger,
    );
  }

  /// Streams SSE events from a streaming POST request.
  ///
  /// Yields parsed JSON maps from Server-Sent Events. Handles error
  /// responses (status >= 400) by throwing appropriate [ApiException]s.
  Stream<Map<String, dynamic>> streamSseEvents({
    required String endpoint,
    required Map<String, dynamic> body,
    Map<String, String>? queryParams,
    Map<String, String>? additionalHeaders,
    Future<void>? abortTrigger,
  }) async* {
    final response = await sendStreamRequest(
      endpoint: endpoint,
      body: body,
      queryParams: queryParams,
      additionalHeaders: additionalHeaders,
      abortTrigger: abortTrigger,
    );

    // Extract request ID from response headers for error reporting
    final requestId =
        response.headers['x-request-id'] ??
        response.request?.headers['X-Request-ID'] ??
        'unknown';

    try {
      if (response.statusCode >= 400) {
        final responseBody = await response.stream.bytesToString();
        throw parseStreamError(response.statusCode, responseBody, requestId);
      }

      const parser = SseParser();
      await for (final json in parser.parse(response.stream)) {
        yield json;
      }
    } on AbortedException {
      rethrow;
    }
  }

  /// Checks for inline errors in SSE stream data and throws
  /// [StreamException] if found.
  ///
  /// Detects two error patterns:
  /// 1. SSE `event: error` — parser sets `_event: "error"` in the JSON map
  /// 2. Error objects in data — from providers like AWS Bedrock that embed
  ///    errors in HTTP 200 SSE responses
  ///
  /// Supports multiple error formats:
  /// - Standard OpenAI: `{"error": {"message": "...", "type": "..."}}`
  /// - AWS Bedrock: `{"error": {"error": "...", "error_code": 4001}}`
  /// - Plain string: `{"error": "Something went wrong"}`
  ///
  /// This is intentionally NOT called from [streamSseEvents] because some
  /// resources (e.g., Responses API) handle `ErrorEvent` as a normal stream
  /// event rather than as an exception.
  Never throwInlineStreamError(
    Map<String, dynamic> json,
    String? sseEvent,
    Object? error,
  ) {
    String message;
    if (error is Map<String, dynamic>) {
      message = (error['message'] ?? error['error'] ?? 'Unknown stream error')
          .toString();
    } else if (error is String) {
      message = error;
    } else if (sseEvent == 'error') {
      message = (json['_rawData'] as String?) ?? 'Stream error event received';
    } else {
      message = 'Unknown stream error';
    }

    Logger('OpenAIClient').warning('Inline stream error: $message');

    // Strip internal `_event` field and encode as JSON for partialData
    final cleanJson = Map<String, dynamic>.from(json)
      ..remove('_event')
      ..remove('_rawData');
    throw StreamException(message: message, partialData: jsonEncode(cleanJson));
  }
}
