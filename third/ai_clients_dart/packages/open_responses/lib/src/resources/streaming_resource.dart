import 'dart:async'
    show Completer, StreamController, StreamSubscription, unawaited;
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../auth/auth_provider.dart';
import '../errors/exceptions.dart';
import 'base_resource.dart';

/// Mixin providing streaming HTTP request capabilities.
///
/// Provides methods for preparing and sending streaming requests
/// that bypass the interceptor chain for unbuffered response handling.
mixin StreamingResource on ResourceBase {
  /// Prepares a streaming request by applying authentication.
  Future<http.Request> prepareStreamingRequest(http.Request request) async {
    await _applyAuthentication(request);
    return request;
  }

  /// Sends a streaming request and returns the streamed response.
  ///
  /// Throws appropriate exceptions for HTTP error responses.
  Future<http.StreamedResponse> sendStreamingRequest(
    http.Request request, {
    Future<void>? abortTrigger,
  }) async {
    final streamedResponse = await _sendRequest(request, abortTrigger);
    if (streamedResponse.statusCode >= 400) {
      final body = await streamedResponse.stream.bytesToString();
      throw mapHttpErrorForStreaming(streamedResponse.statusCode, body);
    }
    return streamedResponse;
  }

  Future<http.StreamedResponse> _sendRequest(
    http.Request request,
    Future<void>? abortTrigger,
  ) async {
    if (abortTrigger == null) {
      return httpClient.send(request);
    }

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
    } catch (error) {
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

  /// Applies authentication to a request.
  Future<void> _applyAuthentication(http.BaseRequest request) async {
    final authProvider = config.authProvider;
    if (authProvider == null) return;
    final credentials = await authProvider.getCredentials();
    switch (credentials) {
      case BearerTokenCredentials(:final token):
        if (!request.headers.containsKey('authorization') &&
            !request.headers.containsKey('Authorization')) {
          request.headers['Authorization'] = 'Bearer $token';
        }
      case NoAuthCredentials():
        break;
    }
  }

  /// Maps an HTTP error status code to the appropriate exception.
  OpenResponsesException mapHttpErrorForStreaming(int statusCode, String body) {
    final message = _parseErrorMessage(body);
    switch (statusCode) {
      case 400:
        return ValidationException(
          message: message,
          fieldErrors: _parseFieldErrors(body),
        );
      case 401:
        return AuthenticationException(message: message);
      case 429:
        return RateLimitException(statusCode: statusCode, message: message);
      default:
        return ApiException(statusCode: statusCode, message: message);
    }
  }

  String _parseErrorMessage(String body) {
    if (body.isEmpty) return 'Unknown error';
    try {
      final json = jsonDecode(body);
      if (json is Map<String, dynamic>) {
        final error = json['error'];
        if (error is Map<String, dynamic>) {
          return error['message'] as String? ?? 'Unknown error';
        }
        return json['message'] as String? ?? body;
      }
      return body;
    } catch (_) {
      return body;
    }
  }

  Map<String, List<String>> _parseFieldErrors(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map<String, dynamic>) {
        final error = json['error'];
        if (error is Map<String, dynamic>) {
          final param = error['param'] as String?;
          final message = error['message'] as String?;
          if (param != null && message != null) {
            return {
              param: [message],
            };
          }
        }
      }
    } catch (_) {}
    return {};
  }
}
