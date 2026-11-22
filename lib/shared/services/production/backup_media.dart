// 职责: 从备份主库收集所选作品和共享素材的数据库记录。
// 关联文件:
//   lib/shared/services/backup_service.dart
//   lib/shared/database/app_database.dart
//   lib/shared/utils/storage_paths.dart
// 遵循的 Rules:
//   .agents/rules/file-access.md

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../utils/storage_paths.dart';
import '../../utils/windows_safe_path.dart';

class SelectedMediaBackup {
  SelectedMediaBackup(this.rows);
  final Map<String, List<Map<String, Object?>>> rows;
}

String mediaBackupPath(String stored) {
  final syntax = RevericPaths.contextForStoredPath(stored);
  final segments = syntax.split(stored);
  if (segments.contains('..')) {
    throw const FormatException('Unsafe media path');
  }
  if (syntax.isAbsolute(stored) ||
      segments.length < 3 ||
      segments.first != 'file_workspaces' ||
      segments.any((part) => part == '.' || part.contains(':'))) {
    throw const FormatException('Media path is outside the controlled library');
  }
  return p.posix.joinAll(segments);
}

SelectedMediaBackup collectSelectedMedia({
  required Directory backup,
  required Set<String> novelIds,
}) {
  final database = sqlite3.open(
    toWindowsSafePath(p.join(backup.path, 'reveric.sqlite')),
    mode: OpenMode.readOnly,
  );
  try {
    final parameters = [jsonEncode(novelIds.toList())];
    const selectedWorks = 'novel_id IN (SELECT value FROM json_each(?))';
    const selectedAssets = 'novel_id IS NULL OR $selectedWorks';

    List<Map<String, Object?>> select(String sql) => database
        .select(sql, parameters)
        .map((row) => Map<String, Object?>.from(row))
        .toList();

    final assets = select('SELECT * FROM assets WHERE $selectedAssets');
    for (final asset in assets) {
      final path = asset['path'] as String?;
      if (path != null) {
        asset['path'] = mediaBackupPath(path);
      }
    }
    return SelectedMediaBackup({
      'assets': assets,
      'generation_tasks': select(
        'SELECT * FROM generation_tasks WHERE $selectedWorks ORDER BY rowid',
      ),
      'image_batches': select(
        'SELECT * FROM image_batches WHERE $selectedWorks',
      ),
      'image_batch_slots': select(
        'SELECT * FROM image_batch_slots WHERE batch_id IN '
        '(SELECT id FROM image_batches WHERE $selectedWorks)',
      ),
      'image_asset_references': select(
        'SELECT * FROM image_asset_references WHERE asset_id IN '
        '(SELECT id FROM assets WHERE $selectedAssets)',
      ),
    });
  } finally {
    database.close();
  }
}
