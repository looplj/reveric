// 职责: 用本地 HTTP 服务验证插件网络限制、编码、取消和重定向。
// 关联文件:
//   lib/shared/services/plugins/http.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/plugins/http.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';

void main() {
  late HttpServer server;
  late String origin;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${server.port}';
  });
  tearDown(() async {
    await server.close(force: true);
  });
  for (final query in ['hello', '庆余年 小说 猫腻', '中文 café 😀']) {
    test('request body uses UTF-8 bytes: $query', () async {
      final received = <List<int>>[];
      server.listen((req) async {
        received.add(
          await req.fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk)),
        );
        req.response.write('ok');
        await req.response.close();
      });
      final api = PluginHttpApi();
      addTearDown(api.cancel);
      final body = jsonEncode({
        'query': query,
        'count': 5,
        'need_content': false,
      });
      for (final contentType in [null, 'application/json']) {
        final result = await api.fetch({
          'url': origin,
          'method': 'POST',
          if (contentType != null) 'headers': {'Content-Type': contentType},
          'body': body,
        });
        expect(result['status'], 200);
        expect(received.last, utf8.encode(body));
        expect(jsonDecode(utf8.decode(received.last)), jsonDecode(body));
      }
      expect(received, hasLength(2));
    });
  }
  test(
    'redirect bodies do not count toward the final response limit',
    () async {
      var targets = 0;
      server.listen((req) async {
        if (req.uri.path == '/redirect') {
          req.response.statusCode = 302;
          req.response.headers.set('location', '/target');
          req.response.write('x' * 64);
        } else {
          targets++;
          req.response.write('ok');
        }
        await req.response.close();
      });
      final api = PluginHttpApi();
      addTearDown(api.cancel);
      final result = await api.fetch({
        'url': '$origin/redirect',
        'maxBytes': 16,
      });
      expect(result['body'], 'ok');
      expect(result['url'], '$origin/target');
      expect(targets, 1);
    },
  );
  test('redirect chain resolves relative locations to the final URL', () async {
    server.listen((req) async {
      switch (req.uri.path) {
        case '/start':
          req.response.statusCode = 302;
          req.response.headers.set('location', '/nested/step');
        case '/nested/step':
          req.response.statusCode = 307;
          req.response.headers.set('location', 'final?q=1');
        default:
          req.response.write('ok');
      }
      await req.response.close();
    });
    final api = PluginHttpApi();
    addTearDown(api.cancel);
    final result = await api.fetch({'url': '$origin/start'});
    expect(result['url'], '$origin/nested/final?q=1');
    expect(result['body'], 'ok');
  });
  test(
    'Dart keeps same-host credentials and strips them on another host',
    () async {
      final received = <String, Map<String, String?>>{};
      server.listen((req) async {
        received[req.uri.path] = {
          'authorization': req.headers.value('authorization'),
          'cookie': req.headers.value('cookie'),
          'accept': req.headers.value('accept'),
        };
        if (req.uri.path == '/start') {
          req.response.statusCode = 302;
          req.response.headers.set('location', '/same');
        } else if (req.uri.path == '/same') {
          req.response.statusCode = 302;
          req.response.headers.set(
            'location',
            'http://other.test:${server.port}/other',
          );
        } else {
          req.response.write('ok');
        }
        await req.response.close();
      });
      final api = PluginHttpApi(
        clientFactory: () =>
            HttpClient()
              ..connectionFactory = (uri, proxyHost, proxyPort) =>
                  Socket.startConnect(InternetAddress.loopbackIPv4, uri.port),
      );
      addTearDown(api.cancel);
      final result = await api.fetch({
        'url': '$origin/start',
        'headers': {
          'Authorization': 'Bearer test-token',
          'Cookie': 'session=test',
          'Accept': 'text/plain',
        },
      });
      expect(result['body'], 'ok');
      for (final path in ['/start', '/same']) {
        expect(received[path], {
          'authorization': 'Bearer test-token',
          'cookie': 'session=test',
          'accept': 'text/plain',
        });
      }
      expect(received['/other'], {
        'authorization': null,
        'cookie': null,
        'accept': 'text/plain',
      });
    },
  );
  test('POST 303 becomes GET without replaying the body', () async {
    final received = <(String, String, String)>[];
    server.listen((req) async {
      received.add((
        req.uri.path,
        req.method,
        await utf8.decoder.bind(req).join(),
      ));
      if (req.uri.path == '/submit') {
        req.response.statusCode = 303;
        req.response.headers.set('location', '/result');
      } else {
        req.response.write('ok');
      }
      await req.response.close();
    });
    final api = PluginHttpApi();
    addTearDown(api.cancel);
    final result = await api.fetch({
      'url': '$origin/submit',
      'method': 'POST',
      'body': 'payload',
    });
    expect(received, [('/submit', 'POST', 'payload'), ('/result', 'GET', '')]);
    expect(result['url'], '$origin/result');
    expect(result['body'], 'ok');
  });
  test('POST 307 is returned according to Dart redirect semantics', () async {
    var requests = 0;
    server.listen((req) async {
      requests++;
      await req.drain<void>();
      req.response.statusCode = 307;
      req.response.headers.set('location', '/target');
      await req.response.close();
    });
    final api = PluginHttpApi();
    addTearDown(api.cancel);
    final result = await api.fetch({
      'url': '$origin/submit',
      'method': 'POST',
      'body': 'payload',
    });
    expect(result['status'], 307);
    expect(result['url'], '$origin/submit');
    expect(requests, 1);
  });
  test('redirect, non-2xx, UTF-8 and explicit charset', () async {
    server.listen((req) async {
      switch (req.uri.path) {
        case '/redirect':
          req.response.statusCode = 302;
          req.response.headers.set('location', '/utf');
        case '/utf':
          req.response.statusCode = 404;
          req.response.add(utf8.encode('中文'));
        case '/latin':
          req.response.headers.set(
            'content-type',
            'text/plain; charset=iso-8859-1',
          );
          req.response.add([233]);
      }
      await req.response.close();
    });
    final api = PluginHttpApi();
    addTearDown(api.cancel);
    final result = await api.fetch({'url': '$origin/redirect'});
    expect(result['status'], 404);
    expect(result['url'], '$origin/utf');
    expect(result['body'], '中文');
    expect((await api.fetch({'url': '$origin/latin'}))['body'], 'é');
  });
  test('size, request budget, timeout, cancellation and invalid URL', () async {
    server.listen((req) async {
      if (req.uri.path == '/hang') {
        return;
      }
      req.response.write('123456');
      await req.response.close();
    });
    final api = PluginHttpApi();
    addTearDown(api.cancel);
    Future<void> fails(Future<Object?> future, String code) => expectLater(
      future,
      throwsA(isA<PluginHostError>().having((e) => e.code, 'code', code)),
    );
    await fails(api.fetch({'url': 'file:///etc/hosts'}), 'invalid_url');
    await fails(api.fetch({'url': origin, 'maxBytes': 2}), 'too_large');
    await fails(api.fetch({'url': '$origin/hang', 'timeoutMs': 20}), 'timeout');
    for (var i = 0; i < 47; i++) {
      await api.fetch({'url': origin});
    }
    await fails(api.fetch({'url': origin}), 'rate_limited');
    final pageApi = PluginHttpApi(requestLimit: null);
    addTearDown(pageApi.cancel);
    for (var i = 0; i < 51; i++) {
      await pageApi.fetch({'url': origin});
    }
    final cancelled = PluginHttpApi();
    final pending = cancelled.fetch({'url': '$origin/hang'});
    Timer(const Duration(milliseconds: 20), cancelled.cancel);
    await fails(pending, 'cancelled');
  });
  test('at most four concurrent requests queue and resume', () async {
    var active = 0;
    var peak = 0;
    server.listen((req) async {
      active++;
      if (active > peak) {
        peak = active;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      req.response.write('ok');
      await req.response.close();
      active--;
    });
    final api = PluginHttpApi();
    addTearDown(api.cancel);
    await Future.wait(List.generate(9, (_) => api.fetch({'url': origin})));
    expect(peak, 4);
  });
}
