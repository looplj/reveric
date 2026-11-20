// 职责: 执行全局 AgentSkill 的 Run 子命令，统一处理来源读取、安装与结构化冲突结果。
// 关联文件:
//   lib/shared/services/ai/tools_run.dart
//   lib/shared/providers/novel_agent_skill_providers.dart
//   lib/shared/providers/agent_skill_catalog_providers.dart
//   lib/shared/services/bundled_control_skills.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/agent_skill.json
//   assets/translations/zh-CN/agent_skill.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/error-handling.md

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../providers/async_read.dart';
import '../../localization/locale_keys.dart';
import '../../logger/app_logger.dart';
import '../../models/agent_skill_reference.dart';
import '../../models/agent_skill_revision.dart';
import '../../models/novel_agent_skill.dart';
import '../../providers/agent_skill_catalog_providers.dart';
import '../../providers/novel_agent_skill_providers.dart';
import '../../services/agent_skill_catalog_service.dart';
import '../../services/bundled_control_skills.dart';
import 'tool_error_normalize.dart';

final _log = AppLogger.forModule('AgentSkillsRunCommandHandler');

class AgentSkillsRunCommandHandler {
  AgentSkillsRunCommandHandler({
    required this.container,
    this.contentKind,
    BundledControlSkillsLoader? bundledControlSkillsLoader,
    AssetBundle? assetBundle,
  }) : _bundledControlSkillsLoader =
           bundledControlSkillsLoader ?? const BundledControlSkillsLoader(),
       _assetBundle = assetBundle ?? rootBundle;

  final ProviderContainer container;
  final String? contentKind;
  final BundledControlSkillsLoader _bundledControlSkillsLoader;
  final AssetBundle _assetBundle;

  Future<Map<String, dynamic>> run(Map<String, dynamic> command) async {
    final action = command['action']?.toString().trim() ?? '';
    return switch (action) {
      'list' => _list(),
      'create' => _create(command),
      'update' => _update(command),
      'delete' => _delete(command),
      'reference-list' => _referenceList(command),
      'reference-get' => _referenceGet(command),
      'reference-create' => _referenceCreate(command),
      'reference-update' => _referenceUpdate(command),
      'reference-move' => _referenceMove(command),
      'reference-delete' => _referenceDelete(command),
      'search' => _search(command),
      'get' => _get(command),
      'install' => _install(command),
      _ => Future.value(
        _failure(
          'unknown agent-skills action: $action',
          code: ToolErrorCode.invalid_argument,
        ),
      ),
    };
  }

  Future<Map<String, dynamic>> _list() async {
    try {
      final skills = await container.read(installedAgentSkillsProvider.future);
      return {
        'ok': true,
        'entries': skills.map(_skillSummaryJson).toList(growable: false),
      };
    } catch (error, stackTrace) {
      _log.error(
        'agent-skills list failed',
        error: error,
        stackTrace: stackTrace,
      );
      return _failure(
        'Failed to load agent skills',
        code: ToolErrorCode.internal,
      );
    }
  }

  Future<Map<String, dynamic>> _create(Map<String, dynamic> command) async {
    final name = command['name']?.toString().trim() ?? '';
    final prompt = command['prompt']?.toString().trim() ?? '';
    if (name.isEmpty || prompt.isEmpty) {
      return _failure(
        'agent-skills create requires options.name and options.prompt',
        code: ToolErrorCode.invalid_argument,
      );
    }

    try {
      final input = InstallSkillInput(
        sourceKind: AgentSkillSourceKind.novelLocal,
        name: name,
        whenToUse: command['when-to-use']?.toString().trim() ?? '',
        description: command['description']?.toString().trim() ?? '',
        prompt: prompt,
        references: _parseReferences(command['references']),
        enabled: command['enabled']?.toString().trim() != 'false',
      );
      final skill = await container
          .read(installedAgentSkillsProvider.notifier)
          .createNovelLocalSkill(input);
      return {'ok': true, 'skill': _skillJson(skill)};
    } on FormatException {
      return _invalidReference();
    } on NovelSkillNameConflictException catch (error) {
      return _nameConflict(error.name);
    } catch (error, stackTrace) {
      _log.error(
        'agent-skills create failed',
        error: error,
        stackTrace: stackTrace,
      );
      return _failure(
        'Failed to create agent skill',
        code: ToolErrorCode.internal,
      );
    }
  }

  Future<Map<String, dynamic>> _update(Map<String, dynamic> command) async {
    final id = command['id']?.toString().trim() ?? '';
    if (id.isEmpty) {
      return _failure(
        'agent-skills update requires options.id',
        code: ToolErrorCode.invalid_argument,
      );
    }

    final found = await _findInstalledSkill(id);
    if (found == null) {
      return _failure(
        'agent skill not found: $id',
        code: ToolErrorCode.not_found,
      );
    }
    // 编辑即脱离来源：官方/市场快照被改写后不再声称来自官方，也不再升级。
    // 必须先转换再据此构造 updated，否则会把旧的 source_kind 原样写回去。
    final Map<String, dynamic>? detached;
    final NovelAgentSkillModel existing;
    try {
      final result = await _detachRemoteSource(found);
      existing = result.skill;
      detached = result.notice;
    } catch (error, stackTrace) {
      _log.error(
        'agent-skills update failed to detach source',
        error: error,
        stackTrace: stackTrace,
      );
      return _failure(
        'Failed to update agent skill',
        code: ToolErrorCode.internal,
      );
    }
    final nextName = command['name']?.toString().trim();
    final enabled = command['enabled']?.toString().trim();
    final renamed =
        nextName != null && nextName.isNotEmpty && nextName != existing.name;
    final updated = existing.copyWith(
      name: renamed ? nextName : existing.name,
      whenToUse:
          command['when-to-use']?.toString().trim() ?? existing.whenToUse,
      description:
          command['description']?.toString().trim() ?? existing.description,
      prompt: command['prompt']?.toString().trim() ?? existing.prompt,
      enabled: enabled == null ? existing.enabled : enabled == 'true',
      updatedAt: DateTime.now(),
    );
    final turnId = _turnId(command);
    try {
      final notifier = container.read(installedAgentSkillsProvider.notifier);
      if (renamed) {
        // rename() 校验全局唯一 name，冲突时抛 NovelSkillNameConflictException。
        await notifier.rename(
          id,
          nextName,
          changeSource: SkillRevisionSource.ai_edit,
          turnId: turnId,
        );
      }
      await notifier.updateSnapshotFields(
        updated,
        changeSource: SkillRevisionSource.ai_edit,
        turnId: turnId,
      );
      return {'ok': true, 'skill': _skillJson(updated), ...?detached};
    } on NovelSkillNameConflictException catch (error) {
      return _nameConflict(error.name);
    } catch (error, stackTrace) {
      _log.error(
        'agent-skills update failed',
        error: error,
        stackTrace: stackTrace,
      );
      return _failure(
        'Failed to update agent skill',
        code: ToolErrorCode.internal,
      );
    }
  }

  Future<Map<String, dynamic>> _delete(Map<String, dynamic> command) async {
    final id = command['id']?.toString().trim() ?? '';
    if (id.isEmpty) {
      return _failure(
        'agent-skills delete requires options.id',
        code: ToolErrorCode.invalid_argument,
      );
    }

    final existing = await _findInstalledSkill(id);
    if (existing == null) {
      return _failure(
        'agent skill not found: $id',
        code: ToolErrorCode.not_found,
      );
    }
    try {
      await container.read(installedAgentSkillsProvider.notifier).remove(id);
      return {'ok': true, 'deleted_id': id};
    } catch (error, stackTrace) {
      _log.error(
        'agent-skills delete failed',
        error: error,
        stackTrace: stackTrace,
      );
      return _failure(
        'Failed to delete agent skill',
        code: ToolErrorCode.internal,
      );
    }
  }

  Future<Map<String, dynamic>> _referenceList(
    Map<String, dynamic> command,
  ) async {
    final name = command['name']?.toString().trim() ?? '';
    final skill = await _findInstalledSkillByName(name);
    if (skill != null) {
      return {
        'ok': true,
        'name': skill.name,
        'count': skill.references.length,
        'references': [
          for (final reference in skill.references) {'path': reference.path},
        ],
      };
    }
    final bundled = await _findBundledControlSkillByName(name);
    if (bundled == null) {
      return _referenceSkillNotFound(name);
    }
    return {
      'ok': true,
      'name': bundled.callName,
      'count': bundled.references.length,
      'references': [
        for (final reference in bundled.references) {'path': reference.path},
      ],
    };
  }

  Future<Map<String, dynamic>> _referenceGet(
    Map<String, dynamic> command,
  ) async {
    final name = command['name']?.toString().trim() ?? '';
    final path = command['path']?.toString().trim() ?? '';
    final skill = await _findInstalledSkillByName(name);
    if (skill != null) {
      final reference = _findReference(skill.references, path);
      if (reference == null) {
        return _referenceNotFound(skill.name, path);
      }
      return {'ok': true, 'name': skill.name, 'reference': reference.toJson()};
    }
    final bundled = await _findBundledControlSkillByName(name);
    if (bundled == null) {
      return _referenceSkillNotFound(name);
    }
    final reference = _findReference(bundled.references, path);
    if (reference == null) {
      return _referenceNotFound(bundled.callName, path);
    }
    return {
      'ok': true,
      'name': bundled.callName,
      'reference': reference.toJson(),
    };
  }

  Future<Map<String, dynamic>> _referenceCreate(
    Map<String, dynamic> command,
  ) async {
    final name = command['name']?.toString().trim() ?? '';
    final path = command['path']?.toString().trim() ?? '';
    final content = command['content']?.toString() ?? '';
    final skill = await _findInstalledSkillByName(name);
    if (skill == null) {
      if (await _findBundledControlSkillByName(name) != null) {
        return _bundledReferenceReadOnly(name);
      }
      return _referenceSkillNotFound(name);
    }
    if (_findReference(skill.references, path) != null) {
      return _referencePathConflict(skill.name, path);
    }
    return _replaceReferences(
      skill,
      [
        ...skill.references,
        AgentSkillReferenceFile(path: path, content: content),
      ],
      operation: 'create',
      turnId: _turnId(command),
    );
  }

  Future<Map<String, dynamic>> _referenceUpdate(
    Map<String, dynamic> command,
  ) async {
    final name = command['name']?.toString().trim() ?? '';
    final path = command['path']?.toString().trim() ?? '';
    final content = command['content']?.toString() ?? '';
    final skill = await _findInstalledSkillByName(name);
    if (skill == null) {
      if (await _findBundledControlSkillByName(name) != null) {
        return _bundledReferenceReadOnly(name);
      }
      return _referenceSkillNotFound(name);
    }
    if (_findReference(skill.references, path) == null) {
      return _referenceNotFound(skill.name, path);
    }
    return _replaceReferences(
      skill,
      [
        for (final reference in skill.references)
          if (reference.path == path)
            AgentSkillReferenceFile(path: path, content: content)
          else
            reference,
      ],
      operation: 'update',
      turnId: _turnId(command),
    );
  }

  Future<Map<String, dynamic>> _referenceMove(
    Map<String, dynamic> command,
  ) async {
    final name = command['name']?.toString().trim() ?? '';
    final path = command['path']?.toString().trim() ?? '';
    final newPath = command['new_path']?.toString().trim() ?? '';
    final skill = await _findInstalledSkillByName(name);
    if (skill == null) {
      if (await _findBundledControlSkillByName(name) != null) {
        return _bundledReferenceReadOnly(name);
      }
      return _referenceSkillNotFound(name);
    }
    final existing = _findReference(skill.references, path);
    if (existing == null) {
      return _referenceNotFound(skill.name, path);
    }
    if (path != newPath && _findReference(skill.references, newPath) != null) {
      return _referencePathConflict(skill.name, newPath);
    }
    return _replaceReferences(
      skill,
      [
        for (final reference in skill.references)
          if (reference.path == path)
            AgentSkillReferenceFile(path: newPath, content: reference.content)
          else
            reference,
      ],
      operation: 'move',
      turnId: _turnId(command),
    );
  }

  Future<Map<String, dynamic>> _referenceDelete(
    Map<String, dynamic> command,
  ) async {
    final name = command['name']?.toString().trim() ?? '';
    final path = command['path']?.toString().trim() ?? '';
    final skill = await _findInstalledSkillByName(name);
    if (skill == null) {
      if (await _findBundledControlSkillByName(name) != null) {
        return _bundledReferenceReadOnly(name);
      }
      return _referenceSkillNotFound(name);
    }
    if (_findReference(skill.references, path) == null) {
      return _referenceNotFound(skill.name, path);
    }
    return _replaceReferences(
      skill,
      [
        for (final reference in skill.references)
          if (reference.path != path) reference,
      ],
      operation: 'delete',
      turnId: _turnId(command),
    );
  }

  /// 搜索 AgentSkill 目录摘要（官方 / 市场，技能库已随全局安装模型移除）。
  ///
  /// **临时策略（目录规模小）**：不做 `query` 文本匹配，直接返回指定来源的全量
  /// 摘要条目，由调用方（模型）自行挑选。`query` 若传入仅原样回传，便于日志/
  /// 意图标注，不参与过滤。`category` / `tag` 仍做精确过滤。
  ///
  /// 目录规模扩大后再评估 query 过滤。
  Future<Map<String, dynamic>> _search(Map<String, dynamic> command) async {
    final query = command['query']?.toString().trim() ?? '';
    final source = command['source']?.toString().trim() ?? '';
    final category = command['category']?.toString().trim() ?? '';
    final tag = command['tag']?.toString().trim() ?? '';
    final sources = source.isEmpty
        ? const ['official', 'marketplace']
        : [source];
    final results = <Map<String, dynamic>>[];
    final unavailableSources = <String>[];

    for (final item in sources) {
      try {
        switch (item) {
          case 'official':
            await _searchOfficial(category, tag, results);
          case 'marketplace':
            throw _AgentSkillsCommandFailure.marketplaceNotConnected();
          default:
            return _invalidSource(item);
        }
      } on _AgentSkillsCommandFailure catch (failure) {
        if (source.isEmpty &&
            item == 'marketplace' &&
            failure.code == ToolErrorCode.unavailable) {
          unavailableSources.add(item);
          continue;
        }
        return failure.toJson();
      } catch (error, stackTrace) {
        _log.error(
          'agent-skills search source=$item failed',
          error: error,
          stackTrace: stackTrace,
        );
        return _sourceRequestFailed(item);
      }
    }

    return {
      'ok': true,
      'query': query,
      'source': source,
      'category': category,
      'tag': tag,
      'total': results.length,
      'entries': results,
      if (unavailableSources.isNotEmpty)
        'unavailable_sources': unavailableSources,
    };
  }

  // 临时：返回 official 全量（仅 category/tag 精确过滤），见 _search 注释。
  Future<void> _searchOfficial(
    String category,
    String tag,
    List<Map<String, dynamic>> results,
  ) async {
    final list = await container.readFuture(
      officialAgentSkillsProvider(
        agentSkillCatalogFilter(category: null, tag: null),
      ).future,
    );
    for (final entry in list.agentSkills) {
      if (category.isNotEmpty && entry.category != category) {
        continue;
      }
      if (tag.isNotEmpty && !entry.tags.contains(tag)) {
        continue;
      }
      results.add({
        'source': 'official',
        'source_id': entry.listingId,
        'name': entry.name,
        'description': entry.description,
        'category': entry.category,
        'tags': entry.tags,
        'version': entry.version,
        'updated_at': entry.updatedAt,
      });
    }
  }

  Future<Map<String, dynamic>> _get(Map<String, dynamic> command) async {
    final source = command['source']?.toString().trim() ?? '';
    final sourceId = command['source_id']?.toString().trim() ?? '';
    if (source.isEmpty || sourceId.isEmpty) {
      return _failure(
        'agent-skills get requires options.source and options.source_id',
        code: ToolErrorCode.invalid_argument,
      );
    }
    try {
      final sourceData = await _readSource(source, sourceId);
      return _sourceJson(source, sourceId, sourceData);
    } on _AgentSkillsCommandFailure catch (failure) {
      return failure.toJson();
    } catch (error, stackTrace) {
      _log.error(
        'agent-skills get source=$source sourceId=$sourceId failed',
        error: error,
        stackTrace: stackTrace,
      );
      return _sourceRequestFailed(source);
    }
  }

  Future<Map<String, dynamic>> _install(Map<String, dynamic> command) async {
    final source = command['source']?.toString().trim() ?? '';
    final sourceId = command['source_id']?.toString().trim() ?? '';
    if (source.isEmpty || sourceId.isEmpty) {
      return _failure(
        'agent-skills install requires options.source and options.source_id',
        code: ToolErrorCode.invalid_argument,
      );
    }
    final requestedName = command['call_name']?.toString().trim() ?? '';
    final conflictResolution =
        command['conflict_resolution']?.toString().trim() ?? '';

    late OfficialAgentSkill sourceData;
    try {
      sourceData = await _readSource(source, sourceId);
    } on _AgentSkillsCommandFailure catch (failure) {
      return failure.toJson();
    } catch (error, stackTrace) {
      _log.error(
        'agent-skills install source read source=$source sourceId=$sourceId failed',
        error: error,
        stackTrace: stackTrace,
      );
      return _sourceRequestFailed(source);
    }

    final name = requestedName.isEmpty ? sourceData.name : requestedName;
    try {
      return await _performInstall(
        source: source,
        sourceData: sourceData,
        name: name,
        conflictResolution: conflictResolution,
      );
    } catch (error, stackTrace) {
      _log.error(
        'agent-skills install source=$source sourceId=$sourceId failed',
        error: error,
        stackTrace: stackTrace,
      );
      return _failure(
        'Failed to install agent skill',
        code: ToolErrorCode.internal,
      );
    }
  }

  Future<OfficialAgentSkill> _readSource(String source, String sourceId) async {
    switch (source) {
      case 'official':
        final detail = await container.readFuture(
          officialAgentSkillDetailProvider(sourceId).future,
        );
        return detail;
      case 'marketplace':
        throw _AgentSkillsCommandFailure.marketplaceNotConnected();
      default:
        throw _AgentSkillsCommandFailure.invalidSource(source);
    }
  }

  Future<Map<String, dynamic>> _performInstall({
    required String source,
    required OfficialAgentSkill sourceData,
    required String name,
    required String conflictResolution,
  }) async {
    final notifier = container.read(installedAgentSkillsProvider.notifier);
    final firstResult = await notifier.installFromOfficial(
      source: sourceData,
      overrideName: name,
    );

    if (firstResult is InstallFromCatalogSuccess) {
      return _catalogSuccess(firstResult.novelAgentSkillId);
    }
    if (firstResult is! InstallFromCatalogConflict) {
      return _failure('Unknown install result', code: ToolErrorCode.internal);
    }
    if (conflictResolution != 'overwrite') {
      return _nameConflict(
        firstResult.conflictingName,
        existingId: firstResult.existingId,
      );
    }

    final updatedId = await notifier.overwriteInstall(
      existingNovelAgentSkillId: firstResult.existingId,
      source: InstallFromOfficialSource(sourceData),
    );
    final result = await _catalogSuccess(updatedId);
    return {...result, 'overwritten': true};
  }

  Future<Map<String, dynamic>> _catalogSuccess(String id) async {
    final installed = await _findInstalledSkill(id);
    return {
      'ok': true,
      if (installed != null) 'skill': _skillJson(installed) else 'id': id,
    };
  }

  Future<NovelAgentSkillModel?> _findInstalledSkill(String id) async {
    final skills = await container.read(installedAgentSkillsProvider.future);
    for (final skill in skills) {
      if (skill.id == id) {
        return skill;
      }
    }
    return null;
  }

  Future<NovelAgentSkillModel?> _findInstalledSkillByName(String name) async {
    final skills = await container.read(installedAgentSkillsProvider.future);
    for (final skill in skills) {
      if (skill.name == name) {
        return skill;
      }
    }
    return null;
  }

  Future<BundledControlSkill?> _findBundledControlSkillByName(
    String name,
  ) async {
    if (!bundledControlCallNames.contains(name)) {
      return null;
    }
    return _bundledControlSkillsLoader.findByCallName(
      _assetBundle,
      name,
      contentKind: contentKind,
    );
  }

  List<AgentSkillReferenceFile> _parseReferences(Object? raw) {
    if (raw == null) {
      return const [];
    }
    if (raw is! List) {
      throw const FormatException('references must be an array');
    }
    final references = <AgentSkillReferenceFile>[];
    for (final entry in raw) {
      if (entry is! Map) {
        throw const FormatException('reference must be an object');
      }
      final path = entry['path'];
      final content = entry['content'];
      if (path is! String || content is! String) {
        throw const FormatException(
          'reference path and content must both be strings',
        );
      }
      references.add(AgentSkillReferenceFile(path: path, content: content));
    }
    return AgentSkillReferences.normalizeOrThrow(references);
  }

  AgentSkillReferenceFile? _findReference(
    Iterable<AgentSkillReferenceFile> references,
    String path,
  ) {
    for (final reference in references) {
      if (reference.path == path) {
        return reference;
      }
    }
    return null;
  }

  Future<Map<String, dynamic>> _replaceReferences(
    NovelAgentSkillModel skill,
    Iterable<AgentSkillReferenceFile> references, {
    required String operation,
    String? turnId,
  }) async {
    try {
      final detached = (await _detachRemoteSource(skill)).notice;
      final updated = await container
          .read(installedAgentSkillsProvider.notifier)
          .replaceReferencesByName(
            name: skill.name,
            references: references,
            changeSource: SkillRevisionSource.ai_edit,
            turnId: turnId,
          );
      return {
        'ok': true,
        'name': updated.name,
        'operation': operation,
        'references': [
          for (final reference in updated.references) {'path': reference.path},
        ],
        ...?detached,
      };
    } on FormatException {
      return _invalidReference();
    } catch (error, stackTrace) {
      _log.error(
        'agent-skills reference-$operation failed name=${skill.name}',
        error: error,
        stackTrace: stackTrace,
      );
      return _failure(
        'Failed to $operation agent skill reference',
        code: ToolErrorCode.internal,
      );
    }
  }

  /// 一轮 AI 任务内的多次技能写入共用同一个 turn id，历史里只留一条。
  String? _turnId(Map<String, dynamic> command) {
    final value = command['_turn_id']?.toString().trim() ?? '';
    return value.isEmpty ? null : value;
  }

  Map<String, dynamic> _referenceSkillNotFound(String name) {
    return _failure(
      'agent skill not found: $name',
      code: ToolErrorCode.not_found,
      extra: {'name': name},
    );
  }

  Map<String, dynamic> _bundledReferenceReadOnly(String name) {
    return _failure(
      'Bundled agent skill references are read-only: $name',
      code: ToolErrorCode.permission_denied,
      extra: {'name': name},
    );
  }

  Map<String, dynamic> _referenceNotFound(String name, String path) {
    return _failure(
      'agent skill reference not found: $path',
      code: ToolErrorCode.not_found,
      extra: {'name': name, 'path': path},
    );
  }

  Map<String, dynamic> _referencePathConflict(String name, String path) {
    return _failure(
      'agent skill reference path already exists: $path',
      code: ToolErrorCode.already_exists,
      extra: {'name': name, 'path': path},
    );
  }

  Map<String, dynamic> _invalidReference() {
    return _failure(
      'Invalid agent skill reference',
      code: ToolErrorCode.invalid_argument,
    );
  }

  /// 官方/市场技能被改写前先断开来源关联，与两端 UI 的「编辑即脱离来源」一致。
  ///
  /// 返回转换后的快照与用于工具结果的说明；非远端来源原样返回、说明为 null。
  Future<({NovelAgentSkillModel skill, Map<String, dynamic>? notice})>
  _detachRemoteSource(NovelAgentSkillModel skill) async {
    if (!skill.sourceKind.isRemote) {
      return (skill: skill, notice: null);
    }
    final converted = await container
        .read(installedAgentSkillsProvider.notifier)
        .convertToNovelLocal(skill.id);
    return (
      skill: converted,
      notice: {
        'converted_to_local': true,
        'notice':
            'Editing detached this skill from its ${skill.sourceKind.dbValue} '
            'source; it will no longer receive updates.',
      },
    );
  }

  Map<String, dynamic> _sourceJson(
    String source,
    String sourceId,
    OfficialAgentSkill sourceData,
  ) {
    return {
      'ok': true,
      'source': source,
      'source_id': sourceId,
      'name': sourceData.name,
      'when_to_use': sourceData.whenToUse,
      'description': sourceData.description,
      'category': sourceData.category,
      'tags': sourceData.tags,
      'prompt': sourceData.prompt,
      'version': sourceData.version,
      'updated_at': sourceData.updatedAt,
    };
  }

  Map<String, dynamic> _skillJson(NovelAgentSkillModel skill) {
    return {
      'id': skill.id,
      'call_name': skill.name,
      'name': skill.name,
      'when_to_use': skill.whenToUse,
      'description': skill.description,
      'prompt': skill.prompt,
      'source_kind': skill.sourceKind.dbValue,
      'enabled': skill.enabled,
      'sort_order': skill.sortOrder,
      if (skill.executionBlockedReason != null)
        'execution_blocked_reason': skill.executionBlockedReason,
    };
  }

  Map<String, dynamic> _skillSummaryJson(NovelAgentSkillModel skill) {
    return {
      'id': skill.id,
      'call_name': skill.name,
      'name': skill.name,
      'description': skill.description,
      'source_kind': skill.sourceKind.dbValue,
      'enabled': skill.enabled,
      if (skill.executionBlockedReason != null)
        'execution_blocked_reason': skill.executionBlockedReason,
    };
  }

  /// name 全局唯一冲突。wire 字段沿用 `call_name*` 命名，与 tools_run.dart 里
  /// 面向模型的既有帮助文本（call_name / call_name_conflict）保持一致。
  Map<String, dynamic> _nameConflict(String name, {String? existingId}) {
    return _failure(
      'agent skill name already exists: $name',
      code: ToolErrorCode.already_exists,
      extra: {
        'conflicting_call_name': name,
        'existing_id': ?existingId,
        'supported_resolutions': ['overwrite', 'rename', 'cancel'],
      },
    );
  }

  Map<String, dynamic> _invalidSource(String source) {
    return _failure(
      tr(
        LocaleKeys.agentSkillInstallInvalidSource,
        namedArgs: {'source': source},
      ),
      code: ToolErrorCode.invalid_argument,
      extra: {'source': source},
    );
  }

  Map<String, dynamic> _sourceRequestFailed(String source) {
    return _failure(
      'Failed to load $source agent skills',
      code: ToolErrorCode.unavailable,
      extra: {'source': source},
    );
  }

  Map<String, dynamic> _failure(
    String error, {
    required ToolErrorCode code,
    Map<String, dynamic> extra = const {},
  }) {
    return {'ok': false, 'error': error, 'error_code': code.name, ...extra};
  }
}

class _AgentSkillsCommandFailure implements Exception {
  const _AgentSkillsCommandFailure(
    this.error,
    this.code, [
    this.extra = const {},
  ]);

  factory _AgentSkillsCommandFailure.marketplaceNotConnected() {
    return _AgentSkillsCommandFailure(
      tr(LocaleKeys.agentSkillMarketNotConnected),
      ToolErrorCode.unavailable,
    );
  }

  factory _AgentSkillsCommandFailure.invalidSource(String source) {
    return _AgentSkillsCommandFailure(
      tr(
        LocaleKeys.agentSkillInstallInvalidSource,
        namedArgs: {'source': source},
      ),
      ToolErrorCode.invalid_argument,
      {'source': source},
    );
  }

  final String error;
  final ToolErrorCode code;
  final Map<String, dynamic> extra;

  Map<String, dynamic> toJson() {
    return {'ok': false, 'error': error, 'error_code': code.name, ...extra};
  }
}
