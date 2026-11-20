// 职责: 定位媒体请求和响应中已存在的 JSON Pointer 字段，拒绝缺失路径及非法转义。
// 关联文件:
//   lib/shared/services/plugins/runtime.dart
import 'runtime.dart';

({Object? value, void Function(Object?) replace}) pluginMediaPointer(
  Object? root,
  Object? pointer,
) {
  if (pointer is! String || !pointer.startsWith('/')) {
    throw PluginHostError(
      'invalid_request',
      'Expected a non-root JSON Pointer',
    );
  }
  final tokens = pointer.substring(1).split('/').map((token) {
    if (RegExp(r'~(?![01])').hasMatch(token)) {
      throw PluginHostError('invalid_request', 'Invalid JSON Pointer escape');
    }
    return token.replaceAll('~1', '/').replaceAll('~0', '~');
  }).toList();
  Object? current = root;
  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    final parent = current;
    late Object? value;
    late void Function(Object?) replace;
    if (parent is Map<String, dynamic> && parent.containsKey(token)) {
      value = parent[token];
      replace = (value) => parent[token] = value;
    } else if (parent is List && RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(token)) {
      final index = int.tryParse(token);
      if (index == null || index >= parent.length) {
        throw PluginHostError(
          'invalid_request',
          'JSON Pointer index does not exist',
        );
      }
      value = parent[index];
      replace = (value) => parent[index] = value;
    } else {
      throw PluginHostError(
        'invalid_request',
        'JSON Pointer field does not exist',
      );
    }
    if (i == tokens.length - 1) {
      return (value: value, replace: replace);
    }
    current = value;
  }
  throw PluginHostError('invalid_request', 'Empty JSON Pointer');
}
