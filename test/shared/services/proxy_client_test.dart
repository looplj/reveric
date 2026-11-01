// 职责: 验证 HTTP/SOCKS5 代理实际路由、认证、直连及代理配置校验。
// 关联文件:
//   lib/shared/services/proxy_client.dart
//   lib/shared/models/network_proxy.dart
//   lib/shared/models/ai_provider.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:socks5_proxy/socks_server.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/network_proxy.dart';
import 'package:reveric/shared/services/proxy_client.dart';

void main() {
  test('stored proxy without credentials retains its route', () {
    for (final mode in NetworkProxyMode.values) {
      final decoded = NetworkProxy.decode(
        jsonEncode({'mode': mode.name, 'url': 'http://127.0.0.1:7890'}),
      );
      expect(decoded.mode, mode);
      expect(decoded.url, 'http://127.0.0.1:7890');
      expect(decoded.username, isEmpty);
      expect(decoded.password, isEmpty);
      expect(decoded.isValid, true);
    }
  });

  test('stored proxy still rejects malformed or incomplete credentials', () {
    for (final credentials in [
      {'username': 'user'},
      {'password': 'secret'},
      {'username': 42, 'password': 'secret'},
    ]) {
      expect(
        () => NetworkProxy.decode(
          jsonEncode({
            'mode': 'custom',
            'url': 'http://127.0.0.1:7890',
            ...credentials,
          }),
        ),
        throwsA(anything),
      );
    }
  });
  test('defaults retain environment mode and custom addresses validate', () {
    expect(const NetworkProxy().mode, NetworkProxyMode.environment);
    for (final url in [
      'http://localhost:7890',
      'http://localhost:80',
      'http://localhost:080/',
      'http://[::1]:80',
      'socks5://127.0.0.1:1080',
      'http://[::1]:7890',
    ]) {
      final config = NetworkProxy(mode: NetworkProxyMode.custom, url: url);
      expect(config.isValid, true, reason: url);
      expect(NetworkProxy.decode(config.encode()).url, url);
    }
    for (final url in [
      '',
      'localhost:7890',
      'https://localhost:7890',
      'socks5://localhost',
      'http://localhost',
      'http://localhost/',
      'http://localhost:0',
      'http://localhost:65536',
      'http://localhost:7890/path',
      'http://localhost:7890?x=1',
    ]) {
      expect(
        NetworkProxy(mode: NetworkProxyMode.custom, url: url).isValid,
        false,
        reason: url,
      );
    }
  });

  for (final cancel in [false, true]) {
    test(
      'SOCKS5 stalled handshake disconnects on ${cancel ? 'close' : 'timeout'}',
      () async {
        final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(proxy.close);
        final greeting = Completer<void>();
        final disconnected = Completer<void>();
        proxy.listen((socket) {
          addTearDown(socket.destroy);
          socket.listen((bytes) {
            if (!greeting.isCompleted) {
              greeting.complete();
            }
          }, onDone: disconnected.complete);
        });
        final client = await createProxyHttpClient(
          NetworkProxy(
            mode: NetworkProxyMode.custom,
            url: 'socks5://127.0.0.1:${proxy.port}',
          ),
        );
        addTearDown(() => client.close(force: true));
        client.connectionTimeout = Duration(seconds: cancel ? 30 : 1);
        final request = expectLater(
          client.getUrl(Uri.parse('https://model.invalid/model')),
          throwsA(anything),
        );
        await greeting.future.timeout(const Duration(seconds: 3));
        if (cancel) {
          client.close(force: true);
        }
        await disconnected.future.timeout(const Duration(seconds: 3));
        await request.timeout(const Duration(seconds: 3));
      },
    );
  }

  test('credentials must be paired and fit the proxy scheme', () {
    NetworkProxyCredentialError? check(String url, String user, String pass) =>
        NetworkProxy.validateCredentials(
          address: url,
          username: user,
          password: pass,
        );
    const http = 'http://127.0.0.1:7890';
    const socks = 'socks5://127.0.0.1:1080';
    expect(check(http, '', ''), isNull);
    expect(check(http, 'user', 'p@ss:word'), isNull);
    expect(check(http, 'user', ''), NetworkProxyCredentialError.incomplete);
    expect(check(http, '', 'pass'), NetworkProxyCredentialError.incomplete);
    expect(
      check(http, 'us:er', 'pass'),
      NetworkProxyCredentialError.invalidCharacter,
    );
    expect(
      check(http, 'user', 'pa;ss'),
      NetworkProxyCredentialError.invalidCharacter,
    );
    expect(
      check(http, ' user', 'pass'),
      NetworkProxyCredentialError.invalidCharacter,
    );
    expect(check(socks, 'us:er', 'pa;ss'), isNull);
    expect(
      check(socks, 'user', 'x' * 256),
      NetworkProxyCredentialError.tooLong,
    );
    const config = NetworkProxy(
      mode: NetworkProxyMode.custom,
      url: http,
      username: 'user',
      password: 'p@ss:word',
    );
    final decoded = NetworkProxy.decode(config.encode());
    expect((decoded.username, decoded.password), ('user', 'p@ss:word'));
    expect(
      const NetworkProxy(
        mode: NetworkProxyMode.custom,
        url: http,
        username: 'user',
      ).isValid,
      false,
    );
  });

  test('custom HTTP sends proxy credentials for plain requests', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => proxy.close(force: true));
    String? authorization;
    proxy.listen((request) async {
      authorization = request.headers.value(
        HttpHeaders.proxyAuthorizationHeader,
      );
      request.response.write('through proxy');
      await request.response.close();
    });
    final client = await createProxyHttpClient(
      NetworkProxy(
        mode: NetworkProxyMode.custom,
        url: 'http://127.0.0.1:${proxy.port}',
        username: 'user',
        password: 'p@ss:word',
      ),
    );
    addTearDown(() => client.close(force: true));
    final response = await (await client.getUrl(
      Uri.parse('http://model.invalid/model'),
    )).close();
    expect(await utf8.decodeStream(response), 'through proxy');
    expect(
      authorization,
      'Basic ${base64Encode(utf8.encode('user:p@ss:word'))}',
    );
  });

  test('custom HTTP sends proxy credentials when tunneling HTTPS', () async {
    final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(proxy.close);
    final connect = Completer<String>();
    proxy.listen((socket) {
      final buffer = StringBuffer();
      socket.listen((data) {
        buffer.write(latin1.decode(data));
        if (!connect.isCompleted && buffer.toString().contains('\r\n\r\n')) {
          connect.complete(buffer.toString());
          socket
            ..write(
              'HTTP/1.1 407 Proxy Authentication Required\r\n'
              'Content-Length: 0\r\n\r\n',
            )
            ..close();
        }
      });
    });
    final client = await createProxyHttpClient(
      NetworkProxy(
        mode: NetworkProxyMode.custom,
        url: 'http://127.0.0.1:${proxy.port}',
        username: 'user',
        password: 'pass',
      ),
    );
    addTearDown(() => client.close(force: true));
    await expectLater(
      client.getUrl(Uri.parse('https://model.invalid/model')),
      throwsA(anything),
    );
    final request = (await connect.future).toLowerCase();
    expect(request, startsWith('connect model.invalid:443'));
    expect(
      request,
      contains(
        'proxy-authorization: basic ${base64Encode(utf8.encode('user:pass'))}'
            .toLowerCase(),
      ),
    );
  });

  test('custom SOCKS5 authenticates with username and password', () async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => origin.close(force: true));
    origin.listen((request) async {
      request.response.write('model');
      await request.response.close();
    });
    final attempts = <(String, String)>[];
    final proxy = SocksServer(
      authHandler: (username, password) {
        attempts.add((username, password));
        return username == 'us:er' && password == 'pa;ss';
      },
      lookup: (host, {type = InternetAddressType.any}) async => [
        InternetAddress.loopbackIPv4,
      ],
    );
    proxy.connections.listen((connection) => connection.forward());
    await proxy.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(proxy.stop);
    final client = await createProxyHttpClient(
      NetworkProxy(
        mode: NetworkProxyMode.custom,
        url: 'socks5://127.0.0.1:${proxy.proxies.keys.single}',
        username: 'us:er',
        password: 'pa;ss',
      ),
    );
    addTearDown(() => client.close(force: true));
    final response = await (await client.getUrl(
      Uri.parse('http://model.invalid:${origin.port}/model'),
    )).close();
    expect(await utf8.decodeStream(response), 'model');
    expect(attempts, [('us:er', 'pa;ss')]);
  });

  test('custom HTTP routes an unreachable target through the proxy', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => proxy.close(force: true));
    Uri? target;
    proxy.listen((request) async {
      target = request.uri;
      request.response.write('through proxy');
      await request.response.close();
    });
    final client = await createProxyHttpClient(
      NetworkProxy(
        mode: NetworkProxyMode.custom,
        url: 'http://127.0.0.1:${proxy.port}',
      ),
    );
    addTearDown(() => client.close(force: true));
    final response = await (await client.getUrl(
      Uri.parse('http://model.invalid/model'),
    )).close();
    expect(await utf8.decodeStream(response), 'through proxy');
    expect(target.toString(), 'http://model.invalid/model');
  });

  for (final mode in [NetworkProxyMode.direct, NetworkProxyMode.custom]) {
    test(
      '$mode reaches the server and SOCKS5 resolves the target remotely',
      () async {
        final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => origin.close(force: true));
        origin.listen((request) async {
          request.response.write('model');
          await request.response.close();
        });
        var proxied = 0;
        final proxy = SocksServer(
          lookup: (host, {type = InternetAddressType.any}) async => [
            InternetAddress.loopbackIPv4,
          ],
        );
        proxy.connections.listen((connection) async {
          proxied++;
          await connection.forward();
        });
        await proxy.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(proxy.stop);
        final client = await createProxyHttpClient(
          NetworkProxy(
            mode: mode,
            url: 'socks5://127.0.0.1:${proxy.proxies.keys.single}',
          ),
        );
        addTearDown(() => client.close(force: true));
        final host = mode == NetworkProxyMode.direct
            ? '127.0.0.1'
            : 'model.invalid';
        final response = await (await client.getUrl(
          Uri.parse('http://$host:${origin.port}/model'),
        )).close();
        expect(await utf8.decodeStream(response), 'model');
        expect(proxied, mode == NetworkProxyMode.direct ? 0 : 1);
      },
    );
  }

  test('AI provider proxy supports SOCKS5 and HTTP credentials', () async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => origin.close(force: true));
    origin.listen((request) async {
      request.response.write('model');
      await request.response.close();
    });
    final socks = SocksServer(
      authHandler: (username, password) =>
          username == 'user' && password == 'secret',
      lookup: (host, {type = InternetAddressType.any}) async => [
        InternetAddress.loopbackIPv4,
      ],
    );
    socks.connections.listen((connection) => connection.forward());
    await socks.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(socks.stop);
    final provider = aiProviderBuiltinById('openai')!;
    final socksClient = provider
        .copyWith(
          proxyUrl: ' socks5://127.0.0.1:${socks.proxies.keys.single} ',
          proxyUsername: 'user',
          proxyPassword: 'secret',
        )
        .createProxyClient()!;
    addTearDown(socksClient.close);
    final socksResponse = await socksClient.get(
      Uri.parse('http://model.invalid:${origin.port}/model'),
    );
    expect(socksResponse.body, 'model');

    final httpProxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => httpProxy.close(force: true));
    String? authorization;
    httpProxy.listen((request) async {
      authorization = request.headers.value(
        HttpHeaders.proxyAuthorizationHeader,
      );
      request.response.write('through proxy');
      await request.response.close();
    });
    final httpClient = provider
        .copyWith(
          proxyUrl: 'http://127.0.0.1:${httpProxy.port}',
          proxyUsername: 'user',
          proxyPassword: 'secret',
        )
        .createProxyClient()!;
    addTearDown(httpClient.close);
    final httpResponse = await httpClient.get(
      Uri.parse('http://model.invalid/model'),
    );
    expect(httpResponse.body, 'through proxy');
    expect(authorization, 'Basic ${base64Encode(utf8.encode('user:secret'))}');
  });
}
