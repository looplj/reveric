// 职责: 本地头像落盘 — 把用户选中的图片复制到应用支持目录，返回可持久保存的路径。
// 关联文件:
//   lib/shared/utils/storage_paths.dart
//   lib/shared/widgets/user_profile_edit_dialog.dart
//   lib/shared/hooks/use_onboarding_setup.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'storage_paths.dart';

int _avatarWriteSeq = 0;

Future<String> _storeAvatar(
  String extension,
  Future<void> Function(String dest) writeFile,
) async {
  final appDir = await getApplicationSupportDirectory();
  final avatarDir = Directory(p.join(appDir.path, 'avatars'));
  if (!await avatarDir.exists()) {
    await avatarDir.create(recursive: true);
  }
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final seq = ++_avatarWriteSeq;
  // 每次写入使用唯一文件名，避免同名覆盖导致 Flutter imageCache 命中旧图
  // 以及设置相等性检查忽略新头像。
  final dest = p.join(avatarDir.path, 'avatar_${stamp}_$seq$extension');
  await writeFile(dest);
  return RevericPaths.toRelative(dest) ?? dest;
}

/// 把 [sourcePath] 复制到 `<appSupport>/avatars/avatar_<stamp>_<seq>.<ext>`。
///
/// 直接存用户原文件路径的话，原图被移动/删除后头像就失效了。
/// 返回值已过 [RevericPaths.toRelative]，可直接写入设置。
Future<String> storeAvatarFile(String sourcePath) {
  return _storeAvatar(
    p.extension(sourcePath),
    (dest) => File(sourcePath).copy(dest),
  );
}

/// 把内存中的图片字节写入 `<appSupport>/avatars/avatar_<stamp>_<seq>.<ext>`。
///
/// 返回值已过 [RevericPaths.toRelative]，可直接写入设置。
Future<String> storeAvatarBytes(Uint8List bytes, {required String extension}) {
  return _storeAvatar(
    extension,
    (dest) => File(dest).writeAsBytes(bytes, flush: true),
  );
}
