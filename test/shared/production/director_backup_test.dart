// 职责: 验证角色音色、镜头参考和音频历史的资源随作品备份保留。
// 关联文件:
//   lib/shared/services/production/backup_media.dart
//   test/helpers/backup_fixture.dart
import 'dart:convert';
import 'package:reveric/shared/models/production/image_request.dart';
import 'package:reveric/shared/models/audio/request.dart';
import 'package:reveric/shared/models/generation/task.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../../helpers/backup_fixture.dart';
import 'package:reveric/shared/services/production/backup_media.dart';

void main() {
  test(
    'selected backup includes every candidate, including shared assets',
    () async {
      final dir = await Directory.systemTemp.createTemp('candidates-backup-');
      final schemas = await BackupDatabases.create();
      final db = schemas.writeMain('${dir.path}/reveric.sqlite');
      for (var i = 0; i < 4; i++) {
        insertBackupRow(db, 'assets', {
          'id': 'candidate-$i',
          'type': 'image',
          'purpose': 'production.generated',
          'path': 'file_workspaces/shared/images/$i.png',
        });
      }
      insertBackupRow(db, 'generation_tasks', {
        'id': 'task',
        'kind': 'image',
        'novel_id': 'work',
        'source_type': 'production_clip',
        'source_id': 'clip',
        'provider_id': 'p',
        'provider_type': 'api88',
        'model_id': 'midjourney-v8.2',
        'status': 'completed',
        'result_asset_id': 'candidate-0',
        'request_json': jsonEncode(
          ImageGenerationRequest(
            ProductionImageRequest(
              providerId: 'p',
              modelId: 'midjourney-v8.2',
              originalPrompt: 'city',
              prompt: 'city',
              ratio: '1:1',
              resolution: 'auto',
              size: null,
            ),
          ).toJson(),
        ),
        'image_outputs': jsonEncode(
          ImageTaskOutputs([
            for (var i = 0; i < 4; i++)
              ImageTaskOutput(assetId: 'candidate-$i'),
          ]).toJson(),
        ),
      });
      db.close();
      try {
        final backup = collectSelectedMedia(
          backup: dir,
          novelIds: {'work'},
          contentPaths: [],
        );
        expect(backup.rows['assets']!.map((row) => row['id']).toSet(), {
          for (var i = 0; i < 4; i++) 'candidate-$i',
        });
        expect(backup.rows['generation_tasks'], hasLength(1));
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'selected backups keep shared voices and removed voices selected by a shot',
    () async {
      final dir = await Directory.systemTemp.createTemp('voices-backup-');
      final schemas = await BackupDatabases.create();
      final main = schemas.writeMain('${dir.path}/reveric.sqlite');
      for (final id in ['shared', 'selected', 'history', 'unrelated']) {
        insertBackupRow(main, 'assets', {
          'id': id,
          'type': 'audio',
          'purpose': 'reference',
          'path': 'file_workspaces/shared/audio/$id.wav',
        });
      }
      main.close();
      final path = '${dir.path}/content.sqlite';
      final content = schemas.writeContent(path);
      insertBackupRow(content, 'character_profiles', {
        'id': 'hero',
        'name': 'Hero',
        'voices': jsonEncode([
          {'asset_id': 'shared', 'name': 'Voice'},
        ]),
      });
      Map<String, Object> input(String voice) => {
        'id': 'input',
        'ref_type': 'node',
        'ref_id': 'character-node',
        'role': 'reference_image',
        'voice_asset_id': voice,
      };
      insertBackupRow(content, 'production_clips', {
        'id': 'clip',
        'episode_id': 'episode',
        'kind': 'video',
        'inputs': jsonEncode([input('selected')]),
      });
      insertBackupRow(content, 'working_changes', {
        'id': 'change',
        'resource_path': 'production_clips/clip/inputs',
        'resource_type': 'production_clips',
        'resource_id': 'clip',
        'field': 'inputs',
        'change_type': 'update',
        'source': 'user',
        'old_text': jsonEncode([input('history')]),
        'new_text': '[]',
      });
      content.close();
      try {
        final backup = collectSelectedMedia(
          backup: dir,
          novelIds: {'work'},
          contentPaths: [path],
        );
        expect(backup.rows['assets']!.map((r) => r['id']).toSet(), {
          'shared',
          'selected',
          'history',
        });
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'audio history keeps frozen reference files and output receipt in selected backups',
    () async {
      final dir = await Directory.systemTemp.createTemp('audio-backup-');
      final schemas = await BackupDatabases.create();
      final db = schemas.writeMain('${dir.path}/reveric.sqlite');
      insertBackupRow(db, 'assets', {
        'id': 'original',
        'type': 'audio',
        'purpose': 'reference',
        'path': 'file_workspaces/work/audio/original.wav',
      });
      final request = AudioGenerationRequest(
        AudioRequest(
          providerId: 'p',
          modelId: 'seed-audio-1.0',
          prompt: '@Audio1',
          originalPrompt: 'voice',
          references: [
            const AudioReference(
              assetId: 'original',
              kind: 'audio',
              mimeType: 'audio/wav',
              bytes: 44,
              durationMs: 1000,
            ),
          ],
        ),
      );
      insertBackupRow(db, 'generation_tasks', {
        'id': 'task',
        'kind': 'audio',
        'novel_id': 'work',
        'source_type': 'production_clip',
        'source_id': 'clip',
        'provider_id': 'p',
        'provider_type': 'test',
        'model_id': 'seed-audio-1.0',
        'status': 'completed',
        'request_json': jsonEncode(request.toJson()),
        'path': 'file_workspaces/work/audio/generated.wav',
        'output_url': 'https://output.example/generated.wav',
      });
      db.close();
      try {
        final backup = collectSelectedMedia(
          backup: dir,
          novelIds: {'work'},
          contentPaths: [],
        );
        expect(
          backup.rows['assets']!.map((row) => row['id']),
          contains('original'),
        );
        expect(
          backup.rows['generation_tasks']!.single['output_url'],
          'https://output.example/generated.wav',
        );
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
