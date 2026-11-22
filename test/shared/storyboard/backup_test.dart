// 职责: 验证作品备份收集分镜当前与历史引用的共享资源身份及文件。
// 关联文件:
//   lib/shared/services/production/backup_media.dart
//   test/helpers/backup_fixture.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/production/backup_media.dart';
import 'package:reveric/shared/database/type_converters.dart';
import 'package:reveric/shared/models/generation/task.dart';
import 'package:reveric/shared/models/production/image_request.dart';
import '../../helpers/backup_fixture.dart';

void main() {
  test(
    'includes all shared storyboard assets regardless of references',
    () async {
      final dir = await Directory.systemTemp.createTemp('storyboard-backup-');
      final schemas = await BackupDatabases.create();
      final main = schemas.writeMain('${dir.path}/reveric.sqlite');
      final photos = [
        'character-only',
        'location-only',
        for (final type in ['item', 'creature', 'faction', 'skill'])
          '$type-only',
        for (final resource in ['characters', 'locations', 'items'])
          for (final table in ['working_changes', 'change_commit_items']) ...[
            '$resource-$table-before',
            '$resource-$table-after',
          ],
      ];
      for (final id in [
        'current',
        'history',
        'video',
        'unrelated',
        'image-result',
        'image-ref',
        'standalone',
        'deleted-node-asset',
        'clip-id',
        'staging-id',
        ...photos,
      ]) {
        insertBackupRow(main, 'assets', {
          'id': id,
          'type': 'image',
          'purpose': 'reference',
          'path': 'file_workspaces/shared/images/$id.png',
        });
      }
      for (final id in ['style-global', 'style-override', 'style-history']) {
        insertBackupRow(main, 'assets', {
          'id': id,
          'type': 'image',
          'purpose': 'reference',
        });
      }
      final content = schemas.writeContent('${dir.path}/content.sqlite');
      for (final (type, id, deletedAt) in [
        ('asset', 'standalone', 0),
        ('asset', 'deleted-node-asset', 1),
        ('production_clip', 'clip-id', 0),
        ('staging', 'staging-id', 0),
      ]) {
        insertBackupRow(content, 'canvas_nodes', {
          'id': 'node-$id',
          'canvas_id': 'canvas',
          'ref_type': type,
          'ref_id': id,
          'deleted_at': deletedAt,
          'x': 0,
          'y': 0,
        });
      }
      // History input also resolves through a node to its currently adopted asset.
      insertBackupRow(content, 'canvas_nodes', {
        'id': 'history-source',
        'canvas_id': 'canvas',
        'ref_type': 'production_clip',
        'ref_id': 'clip',
        'x': 0,
        'y': 0,
      });
      insertBackupRow(content, 'production_clips', {
        'id': 'clip',
        'episode_id': 'episode',
        'kind': 'image',
        'adopted_asset_id': 'video',
        'style_selection': 'style-override',
        'inputs': jsonEncode([
          {
            'id': 'current-input',
            'ref_type': 'asset',
            'ref_id': 'current',
            'role': 'reference_image',
          },
        ]),
      });
      for (final type in ['item', 'creature', 'faction', 'skill']) {
        insertBackupRow(content, 'items', {
          'id': type,
          'title': type,
          'type': type,
          'photos': jsonEncode([
            {'asset_id': '$type-only', 'name': 'Reference'},
          ]),
        });
      }
      for (final (table, id) in [
        ('character_profiles', 'character-only'),
        ('locations', 'location-only'),
      ]) {
        insertBackupRow(content, table, {
          'id': id,
          'name': id,
          'photos': jsonEncode([
            {'asset_id': id, 'name': ''},
          ]),
        });
      }
      insertBackupRow(content, 'screenplays', {
        'id': 'script',
        'style_id': 'style-global',
      });
      for (final table in ['working_changes', 'change_commit_items']) {
        final defaults = <String, Object?>{
          'resource_path': '/production/clips/clip',
          'resource_type': 'production_clips',
          if (table == 'working_changes') ...{
            'change_type': 'update',
            'source': 'manual_edit',
          } else ...{
            'commit_id': 'commit',
            'working_change_id': 'working',
          },
        };
        insertBackupRow(content, table, {
          ...defaults,
          'id': 'document',
          'field': 'document',
          'old_text': jsonEncode({
            'adopted_asset_id': 'video',
            'style_selection': 'style-history',
          }),
        });
        insertBackupRow(content, table, {
          ...defaults,
          'id': 'inputs',
          'field': 'inputs',
          'old_text': jsonEncode([
            {
              'id': 'history-input',
              'ref_type': 'asset',
              'ref_id': 'history',
              'role': 'reference_image',
            },
            {
              'id': 'node-input',
              'ref_type': 'node',
              'ref_id': 'history-source',
              'role': 'reference_image',
            },
          ]),
        });
        for (final resource in ['characters', 'locations', 'items']) {
          insertBackupRow(content, table, {
            ...defaults,
            'id': resource,
            'resource_type': resource,
            'field': 'photos',
            'old_text': jsonEncode([
              {'asset_id': '$resource-$table-before', 'name': '原图'},
            ]),
            'new_text': jsonEncode([
              {'asset_id': '$resource-$table-after', 'name': '夜景'},
            ]),
          });
        }
      }
      insertBackupRow(main, 'generation_tasks', {
        'id': 'image-task',
        'novel_id': 'work',
        'kind': 'image',
        'source_type': 'production_clip',
        'source_id': 'clip',
        'provider_id': 'provider',
        'provider_type': 'test',
        'model_id': 'image-model',
        'status': 'completed',
        'request_json': const GenerationRequestConverter().toSql(
          ImageGenerationRequest(
            ProductionImageRequest(
              providerId: 'provider',
              modelId: 'image-model',
              originalPrompt: 'Body',
              prompt: 'Body',
              ratio: '1:1',
              resolution: '2K',
              size: '2048x2048',
              references: const [
                ProductionImageReference(assetId: 'image-ref'),
              ],
            ),
          ),
        ),
        'result_asset_id': 'image-result',
        'path': 'file_workspaces/work/images/result.png',
      });
      content.close();
      main.close();
      try {
        final backup = collectSelectedMedia(backup: dir, novelIds: {'work'});
        expect(backup.rows['assets']!.map((r) => r['id']).toSet(), {
          ...photos,
          'current',
          'history',
          'video',
          'image-ref',
          'style-global',
          'style-override',
          'style-history',
          'image-result',
          'standalone',
          'deleted-node-asset',
          'unrelated',
          'clip-id',
          'staging-id',
        });
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
