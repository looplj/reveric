// 职责: 管理应用全局技能文件及官方目录安装、覆盖与升级。
// 关联文件:
//   lib/shared/services/agent_skill_file_store.dart
//   lib/shared/services/app_initialization.dart
//   lib/shared/models/novel_agent_skill.dart
//   lib/shared/providers/agent_skill_catalog_providers.dart
//   lib/shared/providers/agent_skill_providers.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/error-handling.md
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'async_read.dart';
import '../database/app_database.dart';
import '../models/agent_skill_reference.dart';
import '../models/catalog_skill_installation_state.dart';
import '../models/novel_agent_skill.dart';
import '../models/official_agent_skill.dart';
import '../services/agent_skill_file_store.dart';
import '../utils/random_id.dart';
import 'agent_skill_catalog_providers.dart';

final agentSkillAppDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final agentSkillFileStoreProvider = Provider<AgentSkillFileStore>((ref) {
  return const AgentSkillFileStore(getApplicationSupportDirectory);
});

// ── 异常 ─────────────────────────────────────────────────────────────────────

class NovelSkillNameConflictException implements Exception {
  NovelSkillNameConflictException(this.name);
  final String name;

  @override
  String toString() => 'NovelSkillNameConflictException: $name';
}

// ── 应用全局可执行快照(NovelAgentSkill)──────────────────────────────────────

/// 安装输入，区分本地官方目录与技能市场来源。
class InstallSkillInput {
  const InstallSkillInput({
    required this.sourceKind,
    this.sourceListingPublicId,
    this.sourceVersion,
    this.sourceDisplayName,
    required this.name,
    required this.description,
    required this.prompt,
    this.whenToUse = '',
    this.agentScopes = const [],
    this.category = '',
    this.tags = const [],
    this.references = const [],
    this.packageFiles = const {},
    this.packageDirectory,
    this.enabled = true,
  });

  final AgentSkillSourceKind sourceKind;
  final String? sourceListingPublicId;
  final String? sourceVersion;
  final String? sourceDisplayName;

  /// 应用全局唯一的工具名。
  final String name;
  final String whenToUse;
  final String description;
  final String prompt;
  final List<String> agentScopes;
  final String category;
  final List<String> tags;
  final List<AgentSkillReferenceFile> references;
  final Map<String, List<int>> packageFiles;
  final Directory? packageDirectory;
  final bool enabled;
}

class InstalledAgentSkillsNotifier
    extends AsyncNotifier<List<NovelAgentSkillModel>> {
  AgentSkillFileStore? _store;
  Future<void> _pendingMutation = Future.value();

  @override
  Future<List<NovelAgentSkillModel>> build() {
    final store = ref.watch(agentSkillFileStoreProvider);
    _store = store;
    return store.open();
  }

  Future<List<NovelAgentSkillModel>> readCurrent() async {
    final cached = state.value ?? await future;
    return await _store?.readCurrent() ?? cached;
  }

  Future<NovelAgentSkillModel?> readPackageById(
    String id, {
    bool forExecution = false,
  }) => _readInstalledPackage(
    (skills) => _findById(skills, id),
    forExecution: forExecution,
  );

  Future<NovelAgentSkillModel?> readPackageByName(
    String name, {
    bool forExecution = false,
  }) => _readInstalledPackage(
    (skills) => _findByName(skills, name),
    forExecution: forExecution,
  );

  Future<NovelAgentSkillModel?> _readInstalledPackage(
    NovelAgentSkillModel? Function(List<NovelAgentSkillModel>) select, {
    required bool forExecution,
  }) => _mutate(() async {
    // Wait for preceding writes to publish their new package and provider state.
    final skills = state.value ?? await future;
    final installed = select(skills);
    if (installed == null ||
        installed.packageReadFailed ||
        (forExecution && !installed.isExecutable)) {
      return installed;
    }
    final loaded = await _store?.readPackage(installed) ?? installed;
    if (loaded.name != installed.name &&
        skills.any(
          (entry) => entry.id != installed.id && entry.name == loaded.name,
        )) {
      return installed.copyWith(
        prompt: '',
        references: const [],
        packageReadFailed: true,
      );
    }
    return loaded;
  });

  Future<T> _mutate<T>(Future<T> Function() action) {
    final result = _pendingMutation.then((_) => action());
    _pendingMutation = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// 安装技能。name 冲突时抛 [NovelSkillNameConflictException],
  /// 由 UI 决定覆盖或重命名后再次调用 [installOverwrite] / [installRename]。
  Future<NovelAgentSkillModel> install(InstallSkillInput input) =>
      _mutate(() async {
        final current = await readCurrent();
        final name = input.name.trim();
        final conflict = _findByName(current, name);
        if (conflict != null) {
          throw NovelSkillNameConflictException(name);
        }
        return _persistInstall(input, name, current);
      });

  /// 用新包覆盖同名安装，保留安装身份和用户设置。
  Future<NovelAgentSkillModel> installOverwrite(InstallSkillInput input) =>
      _mutate(() async {
        final current = await readCurrent();
        final name = input.name.trim();
        return _persistInstall(
          input,
          name,
          current,
          existing: _findByName(current, name),
        );
      });

  /// 以新名称安装:保留两条独立安装,不破坏新来源的升级关联。
  Future<NovelAgentSkillModel> installRename(
    InstallSkillInput input,
    String name,
  ) => _mutate(() async {
    final current = await readCurrent();
    final trimmed = name.trim();
    if (_findByName(current, trimmed) != null) {
      throw NovelSkillNameConflictException(trimmed);
    }
    return _persistInstall(input, trimmed, current);
  });

  Future<NovelAgentSkillModel> _persistInstall(
    InstallSkillInput input,
    String name,
    List<NovelAgentSkillModel> current, {
    NovelAgentSkillModel? existing,
  }) async {
    final now = DateTime.now();
    final model = NovelAgentSkillModel(
      id: existing?.id ?? buildRandomId('nas'),
      sourceKind: input.sourceKind,
      sourceListingPublicId: input.sourceListingPublicId,
      sourceVersion: input.sourceVersion,
      sourceDisplayName: input.sourceDisplayName,
      name: name,
      whenToUse: input.whenToUse,
      description: input.description,
      prompt: input.prompt,
      agentScopes: input.agentScopes,
      category: input.category,
      tags: input.tags,
      references: AgentSkillReferences.sanitize(input.references),
      enabled: existing?.enabled ?? input.enabled,
      sortOrder:
          existing?.sortOrder ??
          (current.fold(
                -1,
                (maxOrder, skill) =>
                    skill.sortOrder > maxOrder ? skill.sortOrder : maxOrder,
              ) +
              1),
      createdAt: existing == null ? now : existing.createdAt,
      updatedAt: now,
    );
    final stored = await _store!.save(
      model,
      files: input.packageFiles,
      packageDirectory: input.packageDirectory,
    );
    if (existing != null) {
      _replaceInState(current, stored);
    } else if (ref.mounted) {
      state = AsyncValue.data([...current, stored]);
    }
    return stored;
  }

  /// 直接创建本地技能(source_kind=novel_local)。
  Future<NovelAgentSkillModel> createNovelLocalSkill(InstallSkillInput input) {
    return install(input.copyWith(sourceKind: AgentSkillSourceKind.novelLocal));
  }

  Future<void> toggleEnabled(String id) => _mutate(() async {
    final current = await readCurrent();
    final target = _findById(current, id);
    if (target == null) {
      return;
    }
    final updated = target.copyWith(
      enabled: !target.enabled,
      updatedAt: DateTime.now(),
    );
    await _writeUpdate(current, updated, previous: target);
  });

  Future<void> rename(String id, String name) => _mutate(() async {
    final current = await readCurrent();
    final trimmed = name.trim();
    if (_findByName(current, trimmed)?.id == id) {
      return; // 未变化。
    }
    if (_findByName(current, trimmed) != null) {
      throw NovelSkillNameConflictException(trimmed);
    }
    final target = _findById(current, id);
    if (target == null) {
      return;
    }
    final updated = target.copyWith(name: trimmed, updatedAt: DateTime.now());
    await _writeUpdate(current, updated, previous: target);
  });

  Future<NovelAgentSkillModel> updateSnapshotFields(
    NovelAgentSkillModel updated,
  ) => _mutate(() async {
    final current = await readCurrent();
    final name = updated.name.trim();
    final conflict = _findByName(current, name);
    if (conflict != null && conflict.id != updated.id) {
      throw NovelSkillNameConflictException(name);
    }
    final previous = _findById(current, updated.id);
    if (previous == null) {
      throw StateError('Installed skill no longer exists: ${updated.id}');
    }
    final withTimestamp = updated.copyWith(
      name: name,
      updatedAt: DateTime.now(),
    );
    return _writeUpdate(current, withTimestamp, previous: previous);
  });

  /// 替换指定 Skill 的全部 references；调用方负责以语义化操作构造目标列表。
  ///
  /// 统一在此处严格校验并持久化，避免 AI 工具或 UI 绕过全局技能缓存直接写 DAO。
  Future<NovelAgentSkillModel> replaceReferencesByName({
    required String name,
    required Iterable<AgentSkillReferenceFile> references,
  }) => _mutate(() async {
    final current = await readCurrent();
    final target = _findByName(current, name);
    if (target == null) {
      throw StateError('NovelAgentSkill not found: ${name.trim()}');
    }
    final normalized = AgentSkillReferences.normalizeOrThrow(references);
    final updated = target.copyWith(
      references: normalized,
      updatedAt: DateTime.now(),
    );
    return _writeUpdate(current, updated, previous: target);
  });

  /// 显式升级:覆盖来源追溯与快照内容,保留 id/name/enabled/sortOrder。
  Future<NovelAgentSkillModel> upgradeSnapshot({
    required String id,
    required String sourceVersion,
    required String sourceDisplayName,
    required String whenToUse,
    required String description,
    required String prompt,
    required List<String> agentScopes,
    required String category,
    required List<String> tags,
  }) => _mutate(() async {
    final current = await readCurrent();
    final target = _findById(current, id);
    if (target == null) {
      throw StateError('NovelAgentSkill not found: $id');
    }
    final upgraded = target.withUpgradedSnapshot(
      sourceVersion: sourceVersion,
      sourceDisplayName: sourceDisplayName,
      whenToUse: whenToUse,
      description: description,
      prompt: prompt,
      agentScopes: agentScopes,
      category: category,
      tags: tags,
      updatedAt: DateTime.now(),
    );
    return _writeUpdate(current, upgraded, previous: target);
  });

  /// 设置/清除运行时阻止原因(用于紧急撤销)。null 表示清除阻止。
  Future<void> setExecutionBlockedReason(String id, String? reason) =>
      _mutate(() async {
        final current = await readCurrent();
        final target = _findById(current, id);
        if (target == null) {
          return;
        }
        final updated = target.copyWith(
          executionBlockedReason: reason,
          updatedAt: DateTime.now(),
        );
        await _writeUpdate(current, updated, previous: target);
      });

  Future<void> remove(String id) => _mutate(() async {
    final store = _store!;
    await store.remove(id);
    final remaining = await store.readCurrent();
    if (ref.mounted) {
      state = AsyncValue.data(remaining);
    }
  });

  Future<void> reorder(List<String> ids) => _mutate(() async {
    final current = await readCurrent();
    final byId = {for (final item in current) item.id: item};
    final orderedIds = {...ids, ...byId.keys};
    final ordered = [for (final id in orderedIds) ?byId[id]];
    final updated = [
      for (var i = 0; i < ordered.length; i++)
        ordered[i].copyWith(sortOrder: i),
    ];
    await _store!.reorder(updated);
    if (ref.mounted) {
      state = AsyncValue.data(updated);
    }
  });

  /// 将已安装的官方/市场技能断开来源关联,保留当前快照为本地技能。
  Future<NovelAgentSkillModel> convertToNovelLocal(String id) =>
      _mutate(() async {
        final current = await readCurrent();
        final target = _findById(current, id);
        if (target == null) {
          throw StateError('NovelAgentSkill not found: $id');
        }
        if (target.sourceKind == AgentSkillSourceKind.novelLocal) {
          return target;
        }
        final converted = _asNovelLocal(target, DateTime.now());
        return _writeUpdate(current, converted, previous: target);
      });

  // ── 目录安装/覆盖/升级 ─────────────────────────────────

  /// 从官方目录安装。name 冲突时返回 [InstallFromCatalogConflict],
  /// 不写入;由 UI 决定调用 [overwriteInstall] 或以新 name 重试。
  Future<InstallFromCatalogResult> installFromOfficial({
    required OfficialAgentSkill source,
    String? overrideName,
  }) => _mutate(() async {
    final current = await readCurrent();
    final name = (overrideName ?? source.name).trim();
    final conflict = _findByName(current, name);
    if (conflict != null) {
      return InstallFromCatalogConflict(conflict.id, conflict.name);
    }
    final input = InstallSkillInput(
      sourceKind: AgentSkillSourceKind.official,
      sourceListingPublicId: source.listingId,
      sourceVersion: source.version.toString(),
      sourceDisplayName: source.name,
      name: name,
      whenToUse: source.whenToUse,
      description: source.description,
      prompt: source.prompt,
      category: source.category,
      tags: source.tags,
      references: _sanitizeCatalogReferences(source.references),
      enabled: true,
    );
    final installed = await _persistInstall(input, name, current);
    return InstallFromCatalogSuccess(installed.id);
  });

  /// 覆盖安装:用新来源的快照替换 existing 记录,保留 id/name/enabled/
  /// sort_order/created_at,清空 execution_blocked_reason。
  /// 用于 UI 收到 [InstallFromCatalogConflict] 后用户选择覆盖。
  Future<String> overwriteInstall({
    required String existingNovelAgentSkillId,
    required InstallFromCatalogSource source,
  }) => _mutate(() async {
    final current = await readCurrent();
    final target = _findById(current, existingNovelAgentSkillId);
    if (target == null) {
      throw StateError('NovelAgentSkill not found: $existingNovelAgentSkillId');
    }
    final now = DateTime.now();
    final updated = switch (source) {
      InstallFromOfficialSource(:final dto) => target.copyWith(
        sourceKind: AgentSkillSourceKind.official,
        sourceListingPublicId: dto.listingId,
        sourceVersion: dto.version.toString(),
        sourceDisplayName: dto.name,
        whenToUse: dto.whenToUse,
        description: dto.description,
        prompt: dto.prompt,
        category: dto.category,
        tags: dto.tags,
        references: _sanitizeCatalogReferences(dto.references),
        executionBlockedReason: null,
        updatedAt: now,
      ),
    };
    final stored = await _writeUpdate(
      current,
      updated,
      previous: target,
      packageFiles: const {},
    );
    return stored.id;
  });

  /// 更新 source_version/source_display_name,保留 id/name/enabled/sort_order。
  Future<UpgradeResult> upgradeNovelAgentSkill({
    required String novelAgentSkillId,
  }) async {
    final installed = await readPackageById(novelAgentSkillId);
    if (!ref.mounted) {
      return const UpgradeNotTraceable();
    }
    if (installed == null) {
      throw StateError('NovelAgentSkill not found: $novelAgentSkillId');
    }
    if (installed.sourceKind != AgentSkillSourceKind.official) {
      return const UpgradeNotTraceable();
    }

    final catalogName = officialSkillCatalogName(installed);
    final officialList = await ref.readFuture(
      officialAgentSkillCatalogProvider.future,
    );
    if (!ref.mounted) {
      return const UpgradeNotTraceable();
    }
    final match = _findOfficialByName(officialList.agentSkills, catalogName);
    if (match == null) {
      return const UpgradeNotTraceable();
    }
    final installedVersion = int.tryParse(installed.sourceVersion ?? '');
    if (installedVersion != null && match.version <= installedVersion) {
      return AlreadyLatestVersion(installedVersion);
    }
    final detail = await ref.readFuture(
      officialAgentSkillDetailProvider(match.listingId).future,
    );

    return _mutate(() async {
      if (!ref.mounted) {
        return const UpgradeNotTraceable();
      }
      final current = await readCurrent();
      final target = _findById(current, novelAgentSkillId);
      if (!ref.mounted ||
          target == null ||
          target.sourceKind != AgentSkillSourceKind.official ||
          officialSkillCatalogName(target) != catalogName) {
        return const UpgradeNotTraceable();
      }
      final currentVersion = int.tryParse(target.sourceVersion ?? '');
      if (currentVersion != null && detail.version <= currentVersion) {
        return AlreadyLatestVersion(currentVersion);
      }
      final upgraded = target.withUpgradedSnapshot(
        sourceListingPublicId: detail.listingId,
        sourceVersion: detail.version.toString(),
        sourceDisplayName: detail.name,
        whenToUse: detail.whenToUse,
        description: detail.description,
        prompt: detail.prompt,
        // 目录详情不包含 agent_scopes，升级时保留本地已有值。
        agentScopes: target.agentScopes,
        category: detail.category,
        tags: detail.tags,
        references: _sanitizeCatalogReferences(detail.references),
        updatedAt: DateTime.now(),
      );
      await _writeUpdate(
        current,
        upgraded,
        previous: target,
        packageFiles: const {},
      );
      return UpgradeSuccess(currentVersion ?? 0, detail.version);
    });
  }

  /// 检测可升级(供 UI 显示「有新版本」标记)。不写入,仅返回结果。
  Future<UpgradeAvailability> checkUpgradeAvailable({
    required String novelAgentSkillId,
  }) async {
    final current = await readCurrent();
    final target = _findById(current, novelAgentSkillId);
    if (target == null) {
      throw StateError('NovelAgentSkill not found: $novelAgentSkillId');
    }
    final currentVersion = int.tryParse(target.sourceVersion ?? '');
    switch (target.sourceKind) {
      case AgentSkillSourceKind.official:
        final officialList = await ref.readFuture(
          officialAgentSkillsProvider(agentSkillCatalogFilter()).future,
        );
        final match = _findOfficialByName(
          officialList.agentSkills,
          officialSkillCatalogName(target),
        );
        if (match == null) {
          return const UpgradeAvailabilityNotTraceable();
        }
        if (currentVersion != null && match.version <= currentVersion) {
          return UpgradeAvailabilityUpToDate(currentVersion);
        }
        return UpgradeAvailabilityAvailable(currentVersion ?? 0, match.version);
      case AgentSkillSourceKind.marketplace:
      case AgentSkillSourceKind.novelLocal:
        return const UpgradeAvailabilityNotTraceable();
    }
  }

  // ── helpers ───────────────────────────────────────────────────────────

  NovelAgentSkillModel _asNovelLocal(
    NovelAgentSkillModel target,
    DateTime now,
  ) {
    return NovelAgentSkillModel(
      id: target.id,
      skillRoot: target.skillRoot,
      sourceKind: AgentSkillSourceKind.novelLocal,
      sourceListingPublicId: null,
      sourceVersion: null,
      sourceDisplayName: null,
      name: target.name,
      whenToUse: target.whenToUse,
      description: target.description,
      prompt: target.prompt,
      agentScopes: target.agentScopes,
      category: target.category,
      tags: target.tags,
      references: target.references,
      enabled: target.enabled,
      sortOrder: target.sortOrder,
      executionBlockedReason: null,
      createdAt: target.createdAt,
      updatedAt: now,
    );
  }

  // 普通编辑沿用现有包的资源。替换来源时，传入新来源的资源清单，可为空。
  Future<NovelAgentSkillModel> _writeUpdate(
    List<NovelAgentSkillModel> current,
    NovelAgentSkillModel model, {
    required NovelAgentSkillModel previous,
    Map<String, List<int>>? packageFiles,
  }) async {
    final stored = await _store!.save(
      model.copyWith(skillRoot: previous.skillRoot),
      previous: previous,
      files: packageFiles,
    );
    _replaceInState(current, stored);
    return stored;
  }

  void _replaceInState(
    List<NovelAgentSkillModel> current,
    NovelAgentSkillModel updated,
  ) {
    if (!ref.mounted) {
      return;
    }
    state = AsyncValue.data([
      for (final item in current)
        if (item.id == updated.id) updated else item,
    ]);
  }

  NovelAgentSkillModel? _findById(List<NovelAgentSkillModel> items, String id) {
    for (final item in items) {
      if (item.id == id) {
        return item;
      }
    }
    return null;
  }

  NovelAgentSkillModel? _findByName(
    List<NovelAgentSkillModel> items,
    String name,
  ) {
    final trimmed = name.trim();
    for (final item in items) {
      if (item.name == trimmed) {
        return item;
      }
    }
    return null;
  }

  OfficialAgentSkillSummary? _findOfficialByName(
    List<OfficialAgentSkillSummary> list,
    String name,
  ) {
    for (final dto in list) {
      if (dto.name == name) {
        return dto;
      }
    }
    return null;
  }
}

final installedAgentSkillsProvider =
    AsyncNotifierProvider<
      InstalledAgentSkillsNotifier,
      List<NovelAgentSkillModel>
    >(InstalledAgentSkillsNotifier.new);

// ── InstallSkillInput 扩展 ───────────────────────────────────────────────────

extension InstallSkillInputCopy on InstallSkillInput {
  InstallSkillInput copyWith({
    AgentSkillSourceKind? sourceKind,
    String? sourceListingPublicId,
    String? sourceVersion,
    String? sourceDisplayName,
    String? name,
    String? description,
    String? prompt,
    String? whenToUse,
    List<String>? agentScopes,
    String? category,
    List<String>? tags,
    List<AgentSkillReferenceFile>? references,
    bool? enabled,
    Map<String, List<int>>? packageFiles,
    Directory? packageDirectory,
  }) {
    return InstallSkillInput(
      sourceKind: sourceKind ?? this.sourceKind,
      sourceListingPublicId:
          sourceListingPublicId ?? this.sourceListingPublicId,
      sourceVersion: sourceVersion ?? this.sourceVersion,
      sourceDisplayName: sourceDisplayName ?? this.sourceDisplayName,
      name: name ?? this.name,
      description: description ?? this.description,
      prompt: prompt ?? this.prompt,
      whenToUse: whenToUse ?? this.whenToUse,
      agentScopes: agentScopes ?? this.agentScopes,
      category: category ?? this.category,
      tags: tags ?? this.tags,
      references: references ?? this.references,
      enabled: enabled ?? this.enabled,
      packageFiles: packageFiles ?? this.packageFiles,
      packageDirectory: packageDirectory ?? this.packageDirectory,
    );
  }
}

// ── 安装/升级结果类型 ───────────────────────────────────────────

/// [InstalledAgentSkillsNotifier.overwriteInstall] 的本地官方目录来源。
sealed class InstallFromCatalogSource {
  const InstallFromCatalogSource();
}

class InstallFromOfficialSource extends InstallFromCatalogSource {
  const InstallFromOfficialSource(this.dto);
  final OfficialAgentSkill dto;
}

/// [InstalledAgentSkillsNotifier.installFromOfficial] 的结果。
sealed class InstallFromCatalogResult {
  const InstallFromCatalogResult();
}

class InstallFromCatalogSuccess extends InstallFromCatalogResult {
  const InstallFromCatalogSuccess(this.novelAgentSkillId);
  final String novelAgentSkillId;
}

class InstallFromCatalogConflict extends InstallFromCatalogResult {
  const InstallFromCatalogConflict(this.existingId, this.conflictingName);
  final String existingId;
  final String conflictingName;
}

/// [InstalledAgentSkillsNotifier.upgradeNovelAgentSkill] 的结果。
sealed class UpgradeResult {
  const UpgradeResult();
}

class UpgradeSuccess extends UpgradeResult {
  const UpgradeSuccess(this.oldVersion, this.newVersion);
  final int oldVersion;
  final int newVersion;
}

class AlreadyLatestVersion extends UpgradeResult {
  const AlreadyLatestVersion(this.currentVersion);
  final int currentVersion;
}

class UpgradeNotTraceable extends UpgradeResult {
  const UpgradeNotTraceable();
}

/// [InstalledAgentSkillsNotifier.checkUpgradeAvailable] 的结果。
sealed class UpgradeAvailability {
  const UpgradeAvailability();
}

class UpgradeAvailabilityAvailable extends UpgradeAvailability {
  const UpgradeAvailabilityAvailable(this.currentVersion, this.latestVersion);
  final int currentVersion;
  final int latestVersion;
}

class UpgradeAvailabilityUpToDate extends UpgradeAvailability {
  const UpgradeAvailabilityUpToDate(this.currentVersion);
  final int currentVersion;
}

class UpgradeAvailabilityNotTraceable extends UpgradeAvailability {
  const UpgradeAvailabilityNotTraceable();
}

List<AgentSkillReferenceFile> _sanitizeCatalogReferences(
  List<AgentSkillReferenceFile> refs,
) {
  return AgentSkillReferences.sanitize(refs);
}
