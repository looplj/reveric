// 职责: 统一作品资源路径的输出与作用域比较。
// 关联文件:
//   lib/shared/services/ai/tools_support.dart
//   lib/shared/services/working_overlay.dart
//   lib/shared/database/novel_content_daos/working_change_dao.dart

/// 当前作品使用相对路径；全局入口及显式作品路径保留前导斜杠。
String canonicalResourcePath(String path) {
  final local = path.trim().replaceFirst(RegExp(r'^/+'), '');
  if (local.isEmpty) {
    return '/';
  }
  final root = local.split(RegExp(r'[/?]')).first;
  if (root == 'works' || root == '_schema') {
    return '/$local';
  }
  return local;
}

bool resourcePathIsWithin(String path, String scope) {
  final canonical = canonicalResourcePath(path);
  final parent = canonicalResourcePath(scope);
  return canonical == parent || canonical.startsWith('$parent/');
}

const legacyWorkDescriptionPath = 'profile/description';

/// 将旧简介记录的存储路径映射到同一作品的现行地址。
String canonicalWorkingChangePath(
  String path, {
  required String resourceType,
  required String? resourceId,
}) {
  final canonical = canonicalResourcePath(path);
  if (canonical == legacyWorkDescriptionPath &&
      resourceType == 'novel' &&
      resourceId != null &&
      resourceId.isNotEmpty) {
    return '/works/$resourceId/description';
  }
  return canonical;
}
