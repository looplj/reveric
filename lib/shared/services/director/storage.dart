// 职责: 为导演文件导入导出及渲染任务提供私有工作区和系统文件访问。
// 关联文件:
//   lib/shared/models/director/document.dart
//   lib/shared/services/director/export_task.dart
import '../../utils/storage_paths.dart';
import 'package:path/path.dart' as p;
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import 'package:reveric/shared/models/director/document.dart';

class DirectorStorage {
  final Directory root;
  final Directory temporary;
  DirectorStorage(this.root, this.temporary);

  /// 解析指定作品的导演工作根目录，不创建任何目录。
  static Directory resolveRoot(String novelId, {Directory? base}) {
    final support = base ?? Directory(RevericPaths.fileWorkspaceParent);
    return Directory(
      p.join(support.path, RevericPaths.mediaPath(novelId, 'file', 'director')),
    );
  }

  static Future<DirectorStorage> open(String novelId) async {
    final root = resolveRoot(novelId),
        temporary = Directory(
          '${(await getTemporaryDirectory()).path}/director_probe',
        );
    await root.create(recursive: true);
    await temporary.create(recursive: true);
    return DirectorStorage(root, temporary);
  }

  Future<void> atomicJson(File file, Json data) async {
    await file.parent.create(recursive: true);
    final part = File('${file.path}.${const Uuid().v4()}.pending');
    await part.writeAsString(jsonEncode(data), flush: true);
    await part.rename(file.path);
  }

  Future<DirectorDocument?> importDocument() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Director JSON',
          extensions: ['json'],
          uniformTypeIdentifiers: ['public.json'],
          mimeTypes: ['application/json'],
        ),
      ],
    );
    if (file == null) {
      return null;
    }
    if (await file.length() > 5 * 1024 * 1024) {
      throw const DocumentError(r'$', 'file_too_large');
    }
    // XFile uses the platform plugin's authorized/cache copy; never reopen its
    // path with dart:io, especially for Android content URIs.
    final document = DirectorDocument.parse(
      utf8.decode(await file.readAsBytes()),
    );
    final dir = Directory('${root.path}/imports');
    await dir.create(recursive: true);
    final target = File('${dir.path}/${const Uuid().v4()}.director.json');
    await target.writeAsString(document.encode(), flush: true);
    return document;
  }

  Future<String> offerFile(File file, String name) async {
    if (Platform.isAndroid || Platform.isIOS) {
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          fileNameOverrides: [name],
          sharePositionOrigin: const Rect.fromLTWH(0, 0, 1, 1),
        ),
      );
      return result.status == ShareResultStatus.dismissed
          ? 'cancelled'
          : 'panel_opened';
    }
    final location = await getSaveLocation(suggestedName: name);
    if (location == null) {
      return 'cancelled';
    }
    await XFile(file.path).saveTo(location.path);
    return 'saved';
  }

  Future<int> availableBytes(String path) async {
    final value = await const MethodChannel(
      'ai.reveric.director/storage',
    ).invokeMethod<int>('availableBytes', {'path': path});
    if (value == null || value < 0) {
      throw StateError('storage_probe_failed');
    }
    return value;
  }
}
