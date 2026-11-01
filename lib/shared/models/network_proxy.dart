// 职责: 定义应用网络代理模式、地址与认证信息校验及设置持久化格式。
// 关联文件:
//   lib/shared/providers/settings_providers.dart
//   lib/shared/services/proxy_client.dart
//   lib/shared/widgets/settings/proxy_settings_section.dart
import 'dart:convert';

enum NetworkProxyMode { direct, environment, custom }

enum NetworkProxyCredentialError { incomplete, invalidCharacter, tooLong }

class NetworkProxy {
  const NetworkProxy({
    this.mode = NetworkProxyMode.environment,
    this.url = '',
    this.username = '',
    this.password = '',
  });

  static const settingsKey = 'network_proxy';
  final NetworkProxyMode mode;
  final String url;

  /// 代理认证信息；用户名与密码须同时填写或同时留空。
  final String username;
  final String password;

  bool get hasCredentials => username.isNotEmpty;

  static Uri? parseAddress(String value) {
    try {
      final uri = Uri.parse(value.trim());
      // Uri 会移除 HTTP 的默认端口，仍接受用户显式填写的 :80。
      final hasExplicitPort =
          uri.hasPort ||
          (uri.scheme == 'http' && RegExp(r':0*80/?$').hasMatch(value.trim()));
      if (!['http', 'socks5'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          RegExp(r'\s').hasMatch(uri.host) ||
          !hasExplicitPort ||
          uri.port < 1 ||
          uri.port > 65535 ||
          uri.userInfo.isNotEmpty ||
          (uri.path.isNotEmpty && uri.path != '/') ||
          uri.hasQuery ||
          uri.hasFragment) {
        return null;
      }
      return uri;
    } on FormatException {
      return null;
    }
  }

  /// 校验成对的认证信息，返回 null 表示合法。
  static NetworkProxyCredentialError? validateCredentials({
    required String address,
    required String username,
    required String password,
  }) {
    if (username.isEmpty && password.isEmpty) {
      return null;
    }
    if (username.isEmpty || password.isEmpty) {
      return NetworkProxyCredentialError.incomplete;
    }
    return validateUsername(address, username) ??
        validatePassword(address, password);
  }

  /// 按字段拆分 [validateCredentials] 的结果，供表单把错误挂到对应输入框。
  static ({
    NetworkProxyCredentialError? username,
    NetworkProxyCredentialError? password,
  })
  credentialFieldErrors({
    required String address,
    required String username,
    required String password,
  }) {
    final paired = username.isEmpty == password.isEmpty;
    return (
      username: !paired && username.isEmpty
          ? NetworkProxyCredentialError.incomplete
          : validateUsername(address, username),
      password: !paired && password.isEmpty
          ? NetworkProxyCredentialError.incomplete
          : validatePassword(address, password),
    );
  }

  /// HTTP 代理凭据经 dart:io `findProxy` 的 `PROXY user:pass@host:port`
  /// 字符串传递（HTTPS 隧道也只认这种方式预先发送），该格式以 `;` 分隔多个
  /// 代理、以首个 `:` 拆分用户名并裁掉首尾空白。
  static NetworkProxyCredentialError? validateUsername(
    String address,
    String value,
  ) => _validateCredential(address, value, forbidden: const [':', ';']);

  static NetworkProxyCredentialError? validatePassword(
    String address,
    String value,
  ) => _validateCredential(address, value, forbidden: const [';']);

  static NetworkProxyCredentialError? _validateCredential(
    String address,
    String value, {
    required List<String> forbidden,
  }) {
    if (value.isEmpty) {
      return null;
    }
    if (value.trim() != value) {
      return NetworkProxyCredentialError.invalidCharacter;
    }
    switch (parseAddress(address)?.scheme) {
      case 'http' when forbidden.any(value.contains):
        return NetworkProxyCredentialError.invalidCharacter;
      // SOCKS5 用户名密码认证（RFC 1929）各自限制在 255 字节内。
      case 'socks5' when utf8.encode(value).length > 255:
        return NetworkProxyCredentialError.tooLong;
    }
    return null;
  }

  bool get isValid =>
      mode != NetworkProxyMode.custom ||
      (parseAddress(url) != null &&
          validateCredentials(
                address: url,
                username: username,
                password: password,
              ) ==
              null);

  String encode() => jsonEncode({
    'mode': mode.name,
    'url': url,
    'username': username,
    'password': password,
  });

  factory NetworkProxy.decode(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final config = NetworkProxy(
      mode: NetworkProxyMode.values.byName(json['mode'] as String),
      url: json['url'] as String,
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
    );
    if (!config.isValid) {
      throw const FormatException('Invalid network proxy configuration');
    }
    return config;
  }
}
