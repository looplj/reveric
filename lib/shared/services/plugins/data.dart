// 职责: 将插件章节和人物请求限定到当前作品，按显示顺序列出摘要，并原子校验版本与保存修改历史。
// 关联文件:
//   lib/shared/services/plugins/host.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/services/working_overlay.dart
//   lib/shared/database/app_database.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/history.json
//   assets/translations/zh-CN/history.json
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import '../../database/app_database.dart';
import '../../database/novel_content_database.dart'
    show nodeTypeChapter, nodeTypeExtra;
import '../../agent/agent_tool_dispatcher.dart';
import '../../models/chapter.dart' show Chapter;
import '../novel_content.dart';
import '../working_overlay.dart';
import 'registry.dart' show canonicalPluginJson;
import 'runtime.dart';

typedef PluginWorkServices = ({
  NovelContentService content,
  WorkingOverlayService overlay,
});

class PluginDataService {
  PluginDataService({required this.database, required this.services});
  final AppDatabase database;
  final PluginWorkServices Function(String databasePath) services;

  Future<Object?> call(
    String method,
    Map<String, dynamic> input, {
    required String? sessionId,
    String? scopeWorkId,
    ToolExecutionContext? executionContext,
    String? toolName,
  }) async {
    final parts = method.split('.');
    if (parts.length != 2 ||
        !['chapters', 'characters'].contains(parts[0]) ||
        !['list', 'get', 'update'].contains(parts[1])) {
      throw PluginHostError(
        'invalid_argument',
        'Unknown data operation: $method',
      );
    }
    final resource = parts[0], operation = parts[1];
    final session = sessionId == null
        ? null
        : await database.aiChatSessionDao.getById(sessionId);
    final workId = scopeWorkId ?? session?.novelId;
    if (workId == null || workId.isEmpty) {
      throw PluginHostError(
        'invalid_scope',
        'This operation requires a current work',
      );
    }
    if (input.containsKey('workId') || input.containsKey('workIds')) {
      throw PluginHostError(
        'invalid_scope',
        'Data operations cannot override their work',
      );
    }
    final access = await _work(workId);
    if (operation == 'list') {
      final limit = _integer(input['limit'] ?? 20, 'limit', 1, 100);
      final offset = _integer(input['offset'] ?? 0, 'offset', 0, 1000000);
      final rows = await access.content.database
          .customSelect(
            resource == 'chapters'
                // 与章节视图的 chapter_num 相同：先按卷顺序，再按卷内顺序。
                ? 'SELECT c.id FROM chapter_nodes c '
                      'LEFT JOIN chapter_nodes p ON c.parent_id = p.id '
                      'WHERE c.deleted_at = 0 AND c.type IN (?, ?) '
                      'ORDER BY COALESCE(p.sibling_order, c.sibling_order), '
                      'CASE WHEN c.parent_id IS NULL THEN 0 ELSE c.sibling_order END, c.id '
                      'LIMIT ? OFFSET ?'
                : 'SELECT id FROM character_profiles WHERE deleted_at = 0 '
                      'ORDER BY sort_order, id LIMIT ? OFFSET ?',
            variables: [
              if (resource == 'chapters') ...[
                Variable.withString(nodeTypeChapter),
                Variable.withString(nodeTypeExtra),
              ],
              Variable.withInt(limit + 1),
              Variable.withInt(offset),
            ],
          )
          .get();
      final items = <Map<String, dynamic>>[];
      for (final (index, row) in rows.take(limit).indexed) {
        final record = await _read(
          access,
          resource,
          row.read<String>('id'),
          workId,
        );
        items.add({
          'id': record['id'],
          'version': record['version'],
          if (resource == 'chapters')
            'title': record['title']
          else
            'name': record['name'],
          'order': offset + index + 1,
        });
      }
      return {'items': items, 'hasMore': rows.length > limit};
    }
    final id = input['id'];
    if (id is! String || id.isEmpty || id.contains('/')) {
      throw PluginHostError(
        'invalid_argument',
        'A valid resource id is required',
      );
    }
    if (operation == 'get') {
      return _read(access, resource, id, workId);
    }
    final fields = resource == 'chapters' ? _chapterFields : _characterFields;
    final patch = input['patch'];
    if (input.keys.any(
          (key) => !const {'id', 'expectedVersion', 'patch'}.contains(key),
        ) ||
        patch is! Map<String, dynamic> ||
        patch.isEmpty ||
        patch.keys.any((key) => !fields.contains(key)) ||
        patch.values.any((value) => value is! String)) {
      throw PluginHostError(
        'invalid_argument',
        'Update takes id, expectedVersion and a patch of supported string fields',
      );
    }
    final expected = input['expectedVersion'];
    if (expected is! String || expected.isEmpty) {
      throw PluginHostError('invalid_argument', 'expectedVersion is required');
    }
    return access.content.database.transaction(() async {
      final before = await _read(access, resource, id, workId);
      if (before['version'] != expected) {
        throw PluginHostError(
          'version_conflict',
          'Resource has changed; currentVersion=${before['version']}',
        );
      }
      final active = await access.content.database
          .customSelect(
            "SELECT 1 FROM working_changes WHERE resource_type = ? AND resource_id = ? AND status = 'active' LIMIT 1",
            variables: [Variable(resource), Variable(id)],
          )
          .get();
      if (active.isNotEmpty) {
        throw PluginHostError('draft_conflict', 'Resource has pending changes');
      }
      final changes = <String>[];
      for (final entry in patch.entries) {
        if (entry.value == before[entry.key]) {
          continue;
        }
        final field = entry.key == 'currentState' ? 'current_state' : entry.key;
        final change = await access.overlay.stageTextChange(
          resourcePath: '/$resource/$id/$field',
          resourceType: resource,
          resourceId: id,
          field: field,
          oldText: before[entry.key] as String? ?? '',
          newText: entry.value as String,
          expectedCurrentText: before[entry.key] as String? ?? '',
          source: workingChangeSourceAi,
          sourceSessionId: executionContext?.sourceSessionId ?? sessionId,
          sourceTurnId: executionContext?.sourceTurnId,
          toolName: toolName,
          summary: 'Plugin update $resource/$id/$field',
        );
        changes.add(change.id);
      }
      await access.overlay.commitWorkingChanges(
        changes,
        source: workingChangeSourceAi,
        message: 'history.commit_message.plugin_update',
      );
      return _read(access, resource, id, workId);
    });
  }

  Future<PluginWorkServices> _work(String workId) async {
    final work = await database.novelDao.get(workId);
    if (work == null) {
      throw PluginHostError('not_found', 'Work not found: $workId');
    }
    final path = work.contentDatabasePath;
    if (path == null || path.isEmpty) {
      throw PluginHostError(
        'invalid_scope',
        'Work has no content database: $workId',
      );
    }
    return services(path);
  }

  Future<Map<String, dynamic>> _read(
    PluginWorkServices access,
    String resource,
    String id,
    String workId,
  ) async {
    Map<String, dynamic> value;
    if (resource == 'chapters') {
      final Chapter? chapter = await access.content.getChapterById(
        id,
        types: const {nodeTypeChapter, nodeTypeExtra},
      );
      if (chapter == null) {
        throw PluginHostError('not_found', 'Chapter not found: $id');
      }
      value = {
        'id': id,
        'workId': workId,
        'title': chapter.title ?? '',
        'outline': chapter.outline,
        'content': chapter.content,
      };
    } else {
      final character = await access.content.getCharacterProfileById(id);
      if (character == null) {
        throw PluginHostError('not_found', 'Character not found: $id');
      }
      value = {
        'id': id,
        'workId': workId,
        'name': character.name,
        'role': character.role,
        'gender': character.gender,
        'biography': character.biography,
        'description': character.description,
        'appearance': character.appearance,
        'identity': character.identity,
        'age': character.age,
        'motivation': character.motivation,
        'arc': character.arc,
        'personality': character.personality,
        'currentState': character.currentState,
      };
    }
    return {
      ...value,
      'version': sha256
          .convert(utf8.encode(canonicalPluginJson(value)))
          .toString(),
    };
  }

  static const _chapterFields = {'title', 'outline', 'content'};
  static const _characterFields = {
    'name',
    'role',
    'gender',
    'biography',
    'description',
    'appearance',
    'identity',
    'age',
    'motivation',
    'arc',
    'personality',
    'currentState',
  };
  int _integer(Object? value, String key, int min, int max) {
    if (value is! int || value < min || value > max) {
      throw PluginHostError(
        'invalid_argument',
        '$key must be an integer between $min and $max',
      );
    }
    return value;
  }
}
