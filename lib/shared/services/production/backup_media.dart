// 职责: 收集单作品恢复所需的资产身份、批次及关联数据库记录；不决定文件清单。
// 关联文件:
//   lib/shared/services/backup_service.dart
//   lib/shared/database/app_database.dart
//   lib/shared/models/map_studio_models.dart
//   lib/shared/database/type_converters.dart
//   lib/shared/models/subject_photo.dart
// 遵循的 Rules:
//   .agents/rules/file-access.md

import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import '../../database/type_converters.dart';
import '../../models/generation/task.dart';
import '../../models/production/input.dart';
import '../../models/subject_photo.dart';
import '../../models/production/style.dart';
import '../../models/map_studio_models.dart';
import '../../utils/storage_paths.dart';

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
  required Iterable<String> contentPaths,
  Iterable<String> coverAssetIds = const [],
}) {
  final database = sqlite3.open(
    p.join(backup.path, 'reveric.sqlite'),
    mode: OpenMode.readOnly,
  );
  final rows = <String, List<Map<String, Object?>>>{};
  final paths = <String>{};
  final storyboardAssetIds = <String>{...coverAssetIds};
  void addPath(String? value) {
    if (value != null &&
        value.isNotEmpty &&
        !value.startsWith('https://') &&
        !value.startsWith('http://')) {
      paths.add(mediaBackupPath(value));
    }
  }

  void photoReferences(String value) {
    for (final photo in jsonDecode(value) as List) {
      storyboardAssetIds.add(SubjectPhoto.fromJson(photo).assetId);
    }
  }

  try {
    List<Map<String, Object?>> table(String name) {
      return database
          .select(
            'SELECT * FROM "$name"${name == 'generation_tasks' ? ' ORDER BY rowid' : ''}',
          )
          .map((r) => Map<String, Object?>.from(r))
          .toList();
    }

    for (final path in contentPaths) {
      final content = sqlite3.open(path, mode: OpenMode.readOnly);
      try {
        for (final row in content.select(
          'SELECT document FROM video_editings',
        )) {
          final document = const EditingDocumentConverter().fromSql(
            row['document'] as String,
          );
          for (final source in document.clips.map((c) => c.media?.source)) {
            if (source != null) {
              storyboardAssetIds.add(source.assetId);
            }
          }
        }
        for (final row in content.select(
          'SELECT avatar_asset_id FROM character_profiles WHERE avatar_asset_id IS NOT NULL',
        )) {
          storyboardAssetIds.add(row['avatar_asset_id'] as String);
        }
        for (final row in content.select(
          'SELECT voices FROM character_profiles WHERE voices IS NOT NULL',
        )) {
          storyboardAssetIds.addAll(
            const CharacterVoiceListConverter()
                .fromSql(row['voices'] as String)
                .map((voice) => voice.assetId),
          );
        }
        for (final entry in {
          'screenplays': 'style_id',
          'production_clips': 'style_selection',
        }.entries) {
          for (final row in content.select(
            'SELECT "${entry.value}" FROM "${entry.key}" WHERE "${entry.value}" IS NOT NULL',
          )) {
            final id = row[entry.value] as String;
            if (id != 'none' && !isProductionStylePresetRef(id)) {
              storyboardAssetIds.add(id);
            }
          }
        }
        for (final row in content.select(
          'SELECT inputs FROM production_clips',
        )) {
          for (final input in const ProductionInputsConverter().fromSql(
            row['inputs'] as String,
          )) {
            if (input.voiceAssetId != null) {
              storyboardAssetIds.add(input.voiceAssetId!);
            }
            if (input.refType == ProductionInputType.asset) {
              storyboardAssetIds.add(input.refId);
            }
          }
        }
        for (final row in content.select(
          'SELECT adopted_asset_id FROM production_clips WHERE adopted_asset_id IS NOT NULL',
        )) {
          storyboardAssetIds.add(row['adopted_asset_id'] as String);
        }
        for (final table in ['character_profiles', 'locations', 'items']) {
          for (final row in content.select(
            'SELECT photos FROM "$table" WHERE photos IS NOT NULL',
          )) {
            photoReferences(row['photos'] as String);
          }
        }
        for (final tableName in ['working_changes', 'change_commit_items']) {
          for (final row in content.select(
            "SELECT old_text, new_text FROM $tableName WHERE resource_type IN ('characters', 'locations', 'items') AND field = 'photos'",
          )) {
            for (final column in ['old_text', 'new_text']) {
              final value = row[column] as String?;
              if (value != null) {
                photoReferences(value);
              }
            }
          }
          for (final row in content.select(
            "SELECT field, old_text, new_text FROM $tableName WHERE resource_type = 'production_clips'",
          )) {
            for (final column in ['old_text', 'new_text']) {
              final text = row[column] as String?;
              if (text != null) {
                final decoded = jsonDecode(text);
                if (row['field'] == 'inputs') {
                  for (final input in decoded as List) {
                    final reference = ProductionInput.fromJson(
                      Map<String, dynamic>.from(input as Map),
                    );
                    if (reference.voiceAssetId != null) {
                      storyboardAssetIds.add(reference.voiceAssetId!);
                    }
                    if (reference.refType == ProductionInputType.asset) {
                      storyboardAssetIds.add(reference.refId);
                      continue;
                    }
                    final sourceId = reference.refId;
                    for (final node in content.select(
                      'SELECT * FROM canvas_nodes WHERE id = ?',
                      [sourceId],
                    )) {
                      if (node['ref_type'] == 'asset' &&
                          node['ref_id'] is String) {
                        storyboardAssetIds.add(node['ref_id'] as String);
                      }
                      if (node['ref_type'] == 'production_clip') {
                        for (final clip in content.select(
                          'SELECT adopted_asset_id FROM production_clips WHERE id = ?',
                          [node['ref_id']],
                        )) {
                          final adopted = clip['adopted_asset_id'] as String?;
                          if (adopted != null) {
                            storyboardAssetIds.add(adopted);
                          }
                        }
                      }
                    }
                  }
                  continue;
                }
                final snapshot = decoded as Map<String, dynamic>;
                final adopted = snapshot['adopted_asset_id'] as String?;
                if (adopted != null) {
                  storyboardAssetIds.add(adopted);
                }
                final style = snapshot['style_selection'] as String?;
                if (style != null &&
                    style != 'none' &&
                    !isProductionStylePresetRef(style)) {
                  storyboardAssetIds.add(style);
                }
              }
            }
          }
        }
        storyboardAssetIds.addAll(
          content
              .select(
                "SELECT ref_id FROM canvas_nodes WHERE ref_type = 'asset' AND ref_id IS NOT NULL",
              )
              .map((row) => row['ref_id'] as String),
        );
        for (final row in content.select(
          'SELECT settings FROM novel_maps WHERE settings IS NOT NULL',
        )) {
          final settings = MapStudioSettings.fromMap(
            const JsonMapConverter().fromSql(row['settings'] as String),
          );
          addPath(settings.image);
        }
      } finally {
        content.close();
      }
    }
    final tasks = table(
      'generation_tasks',
    ).where((r) => novelIds.contains(r['novel_id'])).toList();
    rows['generation_tasks'] = tasks;
    final assetIds = tasks
        .map((r) => r['result_asset_id'])
        .whereType<String>()
        .toSet();
    assetIds.addAll(storyboardAssetIds);
    for (final task in tasks) {
      final imageOutputs = task['image_outputs'] as String?;
      if (imageOutputs != null) {
        for (final output
            in const ImageTaskOutputsConverter().fromSql(imageOutputs).items) {
          if (output.assetId != null) {
            assetIds.add(output.assetId!);
          }
          addPath(output.path);
        }
      }
      final snapshot = const GenerationRequestConverter().fromSql(
        task['request_json'] as String,
      );
      switch (snapshot) {
        case AudioGenerationRequest(:final request):
          for (final ref in request.references) {
            assetIds.add(ref.assetId);
          }
        case ImageGenerationRequest(:final request):
          for (final ref in request.references) {
            assetIds.add(ref.assetId);
          }
        case VideoGenerationRequest(:final request, :final inputs):
          for (final slot in request.referenceSlots) {
            assetIds.add(slot.assetId);
          }
          for (final input in inputs) {
            assetIds.add(input.assetId);
          }
      }
      addPath(task['path'] as String?);
    }
    final batches = table(
      'image_batches',
    ).where((r) => novelIds.contains(r['novel_id'])).toList();
    rows['image_batches'] = batches;
    final batchIds = batches.map((r) => r['id']).toSet();
    final slots = table(
      'image_batch_slots',
    ).where((r) => batchIds.contains(r['batch_id'])).toList();
    rows['image_batch_slots'] = slots;
    for (final slot in slots) {
      assetIds.addAll(
        [slot['asset_id'], slot['previous_asset_id']].whereType<String>(),
      );
    }
    final allAssets = table('assets');
    for (final asset in allAssets) {
      if (novelIds.contains(asset['novel_id']) ||
          (asset['path'] != null &&
              paths.contains(mediaBackupPath(asset['path'] as String)))) {
        assetIds.add(asset['id'] as String);
      }
    }
    final references = table('image_asset_references');
    var changed = true;
    while (changed) {
      changed = false;
      for (final reference in references) {
        if (assetIds.contains(reference['asset_id']) &&
            reference['reference_asset_id'] is String) {
          changed =
              assetIds.add(reference['reference_asset_id'] as String) ||
              changed;
        }
      }
    }
    rows['image_asset_references'] = references
        .where((r) => assetIds.contains(r['asset_id']))
        .toList();
    final assets = allAssets.where((r) => assetIds.contains(r['id'])).toList();
    rows['assets'] = assets;
    for (final asset in assets) {
      if (asset['path'] is String) {
        final path = mediaBackupPath(asset['path'] as String);
        asset['path'] = path;
      }
    }
    return SelectedMediaBackup(rows);
  } finally {
    database.close();
  }
}
