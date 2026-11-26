// 职责: 将已安装技能的当前包与安装索引存入应用目录，并一次性导入旧数据库快照。
// 关联文件:
//   lib/shared/providers/novel_agent_skill_providers.dart
//   lib/shared/services/agent_skill_import_parser.dart
//   lib/shared/services/backup_service.dart
//   lib/shared/models/novel_agent_skill.dart

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../database/app_database.dart';
import '../logger/app_logger.dart';
import '../models/agent_skill_reference.dart';
import '../models/novel_agent_skill.dart';
import '../utils/random_id.dart';
import '../utils/storage_paths.dart';
import 'agent_skill_import_parser.dart';
import 'agent_skill_package.dart';

final _log = AppLogger.forModule('AgentSkillFileStore');

class AgentSkillFileStore {
  const AgentSkillFileStore(this.supportDirectory);

  static const directoryName = 'agent_skills';
  static const indexName = 'index.json';
  static const migrationMarkerName = '.migrated';
  static const migrationTaskId = 'installed_agent_skills_to_files_v1';
  static const migrationCompletedKey = 'app_initialization.$migrationTaskId';
  static const stagingPrefix = '.reveric_copy_';
  static const _replacementName = '.reveric_replace_package';
  static const _replacementTargetName = 'target.json';
  static const markdownName = agentSkillMarkdownName;
  static final _ownedPackageName = RegExp(r'^pkg_[A-Za-z0-9]{16}$');
  static final _pathSegment = RegExp(r'^[a-zA-Z0-9_-]+$');
  final Future<Directory> Function() supportDirectory;
  static Future<void>? _pending;

  /// Serializes package publication with reads and full backups in this process.
  static Future<T> withSnapshot<T>(Future<T> Function() action) {
    final result = _pending?.then((_) => action()) ?? Future.sync(action);
    late final Future<void> tail;
    void release() {
      if (identical(_pending, tail)) {
        _pending = null;
      }
    }

    tail = result.then<void>(
      (_) => release(),
      onError: (Object _, StackTrace _) => release(),
    );
    _pending = tail;
    return result;
  }

  Future<Directory> _root() async {
    final support = await supportDirectory();
    final root = Directory(p.join(support.absolute.path, directoryName));
    await RevericPaths.requireNoLinks(support, root.path);
    return root;
  }

  Future<void> migrateLegacy(AppDatabase database) => withSnapshot(() async {
    final root = await _root();
    if (await _readIndex(root) != null) {
      await _markMigrated(root);
      return;
    }
    if (await hasMigrationMarker(root) ||
        await database.appStateDao.has(migrationCompletedKey)) {
      throw _missingIndex();
    }

    final rows = await database.novelAgentSkillDao.getAll();
    final references = await database.novelAgentSkillDao
        .getReferencesBySkillIds(rows.map((row) => row.id));

    // The index is published only after every legacy package is ready.
    final entries = <String, Map<String, Object?>>{};
    final staged = <Directory>[];
    try {
      for (final row in rows) {
        final legacy = NovelAgentSkillModel(
          id: row.id,
          sourceKind: AgentSkillSourceKind.fromDbValue(row.sourceKind),
          sourceListingPublicId: row.sourceListingPublicId,
          sourceVersion: row.sourceVersion,
          sourceDisplayName: row.sourceDisplayName,
          name: row.name,
          whenToUse: row.whenToUse,
          description: row.description,
          prompt: row.prompt,
          agentScopes: row.agentScopes,
          category: row.category,
          tags: row.tags,
          references: references[row.id] ?? const [],
          enabled: row.enabled,
          sortOrder: row.sortOrder,
          executionBlockedReason: row.executionBlockedReason,
          createdAt: row.createdAt,
          updatedAt: row.updatedAt,
        );
        final model = await _stage(
          root,
          legacy,
          const {},
          skipIncompatibleReferencePaths: true,
        );
        entries[model.id] = _metadata(model);
        staged.add(Directory(model.skillRoot!));
      }
      await _writeIndex(root, entries);
    } catch (_) {
      for (final directory in staged) {
        await _cleanStaging(directory);
      }
      rethrow;
    }
    await _markMigrated(root);
  });

  Future<List<NovelAgentSkillModel>> open() => withSnapshot(() async {
    final root = await _root();
    final index = await _requireIndex(root);
    final installed = await _readSkills(root, index);
    await _markMigrated(root);
    final activePaths = _activePaths(root, index);
    for (final directory in await root.list(followLinks: false).toList()) {
      final id = p.basename(directory.path);
      if (directory is Directory && _pathSegment.hasMatch(id)) {
        await _pruneInstallDirectory(directory, activePaths);
      } else if (directory is Directory && id.startsWith(stagingPrefix)) {
        await _cleanStaging(directory);
      }
    }
    return installed;
  });

  /// The index and these directories form a complete backup of the store.
  /// The caller holds [withSnapshot] while copying them.
  static Future<List<Directory>?> indexedPackageDirectories(
    Directory root,
  ) async {
    final index = await _readIndex(root);
    if (index == null) {
      return null;
    }
    final directories = <Directory>[];
    for (final entry in index.entries) {
      final directory = _packageDirectory(root, entry.key, entry.value);
      final markdown = File(p.join(directory.path, markdownName));
      await RevericPaths.requireNoLinks(root, markdown.path);
      if (!await markdown.exists()) {
        throw FileSystemException(
          'Indexed skill package is missing',
          directory.path,
        );
      }
      directories.add(directory);
    }
    return directories;
  }

  Future<List<NovelAgentSkillModel>> readCurrent() => withSnapshot(() async {
    final root = await _root();
    return _readSkills(root, await _requireIndex(root));
  });

  /// Refreshes one installed package. Registration and enablement come from
  /// the installation snapshot and change through the library provider.
  Future<NovelAgentSkillModel> readPackage(NovelAgentSkillModel installed) =>
      withSnapshot(() async {
        final root = await _root();
        final index = File(p.join(root.path, indexName));
        await RevericPaths.requireNoLinks(root, index.path);
        if (!await index.exists()) {
          throw _missingIndex();
        }
        await _recoverPackageReplacement(root);
        final dir = Directory(installed.skillRoot!);
        return _readPackageOrUnavailable(root, dir, installed);
      });

  /// Persists package and index changes under a single published index.
  Future<NovelAgentSkillModel> save(
    NovelAgentSkillModel model, {
    NovelAgentSkillModel? previous,
    Map<String, List<int>>? files,
    Directory? packageDirectory,
  }) => withSnapshot(() async {
    if (previous?.packageReadFailed ?? false) {
      throw StateError(
        'Cannot edit an unreadable installed skill: ${model.id}',
      );
    }
    final root = await _root();
    final index = await _requireIndex(root);
    await _markMigrated(root);
    final entry = index[model.id];
    final destination = entry == null
        ? null
        : _packageDirectory(root, model.id, entry);
    final unchanged =
        files == null &&
        packageDirectory == null &&
        destination != null &&
        previous != null &&
        previous.contentHash == model.contentHash;
    final staged = unchanged
        ? null
        : await _stage(root, model, files, packageDirectory: packageDirectory);
    final stored = model.copyWith(
      skillRoot: destination?.path ?? staged!.skillRoot,
    );
    index[stored.id] = _metadata(stored);
    final candidate = staged == null ? null : Directory(staged.skillRoot!);
    try {
      if (destination != null && candidate != null) {
        await _replacePackage(root, destination, candidate, index, model.id);
      } else {
        await _writeIndex(root, index);
      }
    } catch (_) {
      if (candidate != null && await candidate.exists()) {
        await _cleanStaging(candidate);
      }
      rethrow;
    }
    final activePaths = _activePaths(root, index);
    await _pruneInstallDirectory(
      Directory(p.join(root.path, _segment(stored.id))),
      activePaths,
    );
    return stored;
  });

  /// Keep the indexed path stable. Publishing the prepared index commits the
  /// swap, and its source file marks any interrupted swap for rollback.
  Future<void> _replacePackage(
    Directory root,
    Directory destination,
    Directory candidate,
    Map<String, Map<String, Object?>> index,
    String id,
  ) async {
    await RevericPaths.requireNoLinks(root, destination.path);
    final destinationType = await FileSystemEntity.type(
      destination.path,
      followLinks: false,
    );
    if (destinationType != FileSystemEntityType.directory &&
        destinationType != FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Invalid skill package directory',
        destination.path,
      );
    }
    final hadPackage = destinationType == FileSystemEntityType.directory;
    final replacement = Directory(p.join(root.path, _replacementName));
    if (await replacement.exists()) {
      throw FileSystemException(
        'Previous skill package replacement needs cleanup',
      );
    }
    await replacement.create();
    final pendingIndex = File(p.join(replacement.path, indexName));
    try {
      final next = await candidate.rename(p.join(replacement.path, 'next'));
      await File(
        p.join(replacement.path, _replacementTargetName),
      ).writeAsString(
        jsonEncode({
          'id': id,
          'package': p.basename(destination.path),
          'had_package': hadPackage,
        }),
        flush: true,
      );
      await pendingIndex.writeAsString(jsonEncode(index), flush: true);
      if (hadPackage) {
        await destination.rename(p.join(replacement.path, 'previous'));
      }
      await next.rename(destination.path);
      await pendingIndex.rename(p.join(root.path, indexName));
    } catch (_) {
      await _recoverPackageReplacement(root);
      rethrow;
    }
    await _cleanStaging(replacement);
  }

  static Future<void> _recoverPackageReplacement(Directory root) async {
    final replacement = Directory(p.join(root.path, _replacementName));
    final type = await FileSystemEntity.type(
      replacement.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      return;
    }
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Invalid skill package replacement directory',
        replacement.path,
      );
    }
    final pendingIndex = File(p.join(replacement.path, indexName));
    await RevericPaths.requireNoLinks(root, pendingIndex.path);
    if (await pendingIndex.exists()) {
      final targetFile = File(p.join(replacement.path, _replacementTargetName));
      await RevericPaths.requireNoLinks(root, targetFile.path);
      final target =
          jsonDecode(await targetFile.readAsString()) as Map<String, dynamic>;
      final destination = _packageDirectory(
        root,
        target['id'] as String,
        target,
      );
      await RevericPaths.requireNoLinks(root, destination.path);
      final previous = Directory(p.join(replacement.path, 'previous'));
      final next = Directory(p.join(replacement.path, 'next'));
      await RevericPaths.requireNoLinks(root, previous.path);
      await RevericPaths.requireNoLinks(root, next.path);
      final restorePackage = await previous.exists();
      final removeUnpublishedPackage = target['had_package'] == false;
      if ((restorePackage || removeUnpublishedPackage) &&
          !await next.exists() &&
          await destination.exists()) {
        await destination.rename(next.path);
      }
      if (restorePackage) {
        await previous.rename(destination.path);
      }
      // Recursive cleanup can be interrupted. Retire the rollback marker first.
      await pendingIndex.delete();
    }
    await _cleanStaging(replacement);
  }

  Future<void> remove(String id) => withSnapshot(() async {
    final root = await _root();
    final index = await _requireIndex(root);
    await _markMigrated(root);
    final parent = Directory(p.join(root.path, _segment(id)));
    index.remove(id);
    await _writeIndex(root, index);
    await _pruneInstallDirectory(parent, _activePaths(root, index));
  });

  // Match conservatively on case-insensitive volumes before deleting.
  Set<String> _activePaths(
    Directory root,
    Map<String, Map<String, Object?>> index,
  ) => {
    for (final entry in index.entries)
      _packageDirectory(root, entry.key, entry.value).path.toLowerCase(),
  };

  Future<void> _pruneInstallDirectory(
    Directory parent,
    Set<String> activePaths,
  ) async {
    try {
      if (await FileSystemEntity.type(parent.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        return;
      }
      var removedPackage = false;
      for (final entry in await parent.list(followLinks: false).toList()) {
        final name = p.basename(entry.path);
        if (entry is Directory &&
            (_ownedPackageName.hasMatch(name) ||
                name.startsWith(stagingPrefix)) &&
            !activePaths.contains(entry.path.toLowerCase())) {
          await entry.delete(recursive: true);
          removedPackage = true;
        }
      }
      if (removedPackage && await parent.list(followLinks: false).isEmpty) {
        await parent.delete();
      }
    } on FileSystemException catch (error, stackTrace) {
      _log.error(
        'Failed to remove an unindexed skill package id=${p.basename(parent.path)}',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> reorder(List<NovelAgentSkillModel> models) =>
      withSnapshot(() async {
        final root = await _root();
        final index = await _requireIndex(root);
        await _markMigrated(root);
        for (final model in models) {
          index[model.id]!['sort_order'] = model.sortOrder;
        }
        await _writeIndex(root, index);
      });

  Future<Map<String, Map<String, Object?>>> _requireIndex(
    Directory root,
  ) async {
    final index = await _readIndex(root);
    if (index == null) {
      throw _missingIndex();
    }
    return index;
  }

  static Future<Map<String, Map<String, Object?>>?> _readIndex(
    Directory root,
  ) async {
    final file = File(p.join(root.path, indexName));
    await RevericPaths.requireNoLinks(root, file.path);
    await _recoverPackageReplacement(root);
    final String content;
    try {
      content = await file.readAsString();
    } on PathNotFoundException {
      return null;
    }
    final data = jsonDecode(content) as Map<String, dynamic>;
    return data.map((id, value) {
      final entry = Map<String, Object?>.from(value as Map);
      _packageDirectory(root, id, entry);
      return MapEntry(id, entry);
    });
  }

  static StateError _missingIndex() => StateError(
    'Installed skill index is missing. Restore the skill files from a full backup.',
  );

  static Future<bool> hasMigrationMarker(Directory root) async {
    final marker = File(p.join(root.path, migrationMarkerName));
    await RevericPaths.requireNoLinks(root, marker.path);
    try {
      await marker.length();
      return true;
    } on PathNotFoundException {
      return false;
    }
  }

  // Keep a separate completion marker before exposing the store for edits.
  // The startup task's SQLite completion record is written after this step.
  Future<void> _markMigrated(Directory root) async {
    if (!await hasMigrationMarker(root)) {
      await File(
        p.join(root.path, migrationMarkerName),
      ).writeAsString('', flush: true);
    }
  }

  Future<void> _writeIndex(
    Directory root,
    Map<String, Map<String, Object?>> index,
  ) async {
    await root.create(recursive: true);
    final staging = await root.createTemp(stagingPrefix);
    try {
      final file = File(p.join(staging.path, indexName));
      await file.writeAsString(jsonEncode(index), flush: true);
      await file.rename(p.join(root.path, indexName));
    } finally {
      await _cleanStaging(staging);
    }
  }

  Future<NovelAgentSkillModel> _stage(
    Directory root,
    NovelAgentSkillModel model,
    Map<String, List<int>>? files, {
    Directory? packageDirectory,
    bool skipIncompatibleReferencePaths = false,
  }) async {
    final parent = Directory(p.join(root.path, _segment(model.id)));
    await RevericPaths.requireNoLinks(root, parent.path);
    await parent.create(recursive: true);
    final staging = await parent.createTemp(stagingPrefix);
    try {
      await File(p.join(staging.path, markdownName)).writeAsString(
        AgentSkillImportParser.write(
          name: model.name,
          description: model.description,
          body: model.prompt,
          whenToUse: model.whenToUse,
          category: model.category,
          tags: model.tags,
          installed: true,
        ),
        flush: true,
      );
      final referencePaths = <String>[];
      for (final ref in AgentSkillReferences.normalizeOrThrow(
        model.references,
      )) {
        final parts = ref.path.split('/');
        final portablePath = ref.path.toLowerCase();
        if (!parts.every(isPortableSkillPathSegment) ||
            referencePaths.any(
              (path) =>
                  path == portablePath ||
                  path.startsWith('$portablePath/') ||
                  portablePath.startsWith('$path/'),
            )) {
          if (skipIncompatibleReferencePaths) {
            _log.warning(
              'Skipped incompatible legacy skill reference id=${model.id} path=${ref.path}',
            );
            continue;
          }
          throw FormatException(
            'Invalid or conflicting skill reference path',
            ref.path,
          );
        }
        referencePaths.add(portablePath);
        final file = File(p.joinAll([staging.path, ...parts]));
        await file.parent.create(recursive: true);
        await file.writeAsString(ref.content, flush: true);
      }
      final resourceDirectory =
          packageDirectory ??
          (files == null && model.skillRoot != null
              ? Directory(model.skillRoot!)
              : null);
      if (resourceDirectory != null) {
        await RevericPaths.requireNoLinks(
          packageDirectory ?? root,
          resourceDirectory.path,
        );
        await for (final resource in agentSkillPackageFiles(
          resourceDirectory,
        )) {
          final file = File(
            p.joinAll([staging.path, ...resource.path.split('/')]),
          );
          await file.parent.create(recursive: true);
          await resource.file.copy(file.path);
        }
      }
      if (files != null) {
        for (final entry in files.entries) {
          if (!isAgentSkillResourcePath(entry.key)) {
            throw FormatException('Invalid skill package path', entry.key);
          }
          final file = File(p.joinAll([staging.path, ...entry.key.split('/')]));
          await file.parent.create(recursive: true);
          // Exclusive creation also catches case-insensitive path collisions.
          await file.create(exclusive: true);
          await file.writeAsBytes(entry.value, flush: true);
        }
      }
      final destination = p.join(parent.path, buildRandomId('pkg'));
      await staging.rename(destination);
      return model.copyWith(skillRoot: destination);
    } finally {
      if (await staging.exists()) {
        await _cleanStaging(staging);
      }
    }
  }

  static Future<void> _cleanStaging(Directory directory) async {
    try {
      await directory.delete(recursive: true);
    } on FileSystemException catch (error, stackTrace) {
      _log.warning(
        'Failed to clean up unpublished skill files: $error\n$stackTrace',
      );
    }
  }

  Map<String, Object?> _metadata(NovelAgentSkillModel model) => {
    'package': p.basename(model.skillRoot!),
    'name': model.name,
    'source_kind': model.sourceKind.dbValue,
    'source_listing_public_id': model.sourceListingPublicId,
    'source_version': model.sourceVersion,
    'source_display_name': model.sourceDisplayName,
    'agent_scopes': model.agentScopes,
    'enabled': model.enabled,
    'sort_order': model.sortOrder,
    'blocked_reason': model.executionBlockedReason,
    'created_at': model.createdAt?.toIso8601String(),
    'updated_at': model.updatedAt?.toIso8601String(),
  };

  Future<List<NovelAgentSkillModel>> _readSkills(
    Directory root,
    Map<String, Map<String, Object?>> index,
  ) async {
    final models = <NovelAgentSkillModel>[];
    final names = <String, List<NovelAgentSkillModel>>{};
    for (final MapEntry(key: id, value: data) in index.entries) {
      final dir = _packageDirectory(root, id, data);
      final metadata = NovelAgentSkillModel(
        id: id,
        name:
            data['name'] as String? ??
            data['source_display_name'] as String? ??
            id,
        description: '',
        prompt: '',
        skillRoot: dir.path,
        sourceKind: AgentSkillSourceKind.fromDbValue(
          data['source_kind'] as String,
        ),
        sourceListingPublicId: data['source_listing_public_id'] as String?,
        sourceVersion: data['source_version'] as String?,
        sourceDisplayName: data['source_display_name'] as String?,
        agentScopes: (data['agent_scopes'] as List).cast<String>(),
        enabled: data['enabled'] as bool,
        sortOrder: data['sort_order'] as int,
        executionBlockedReason: data['blocked_reason'] as String?,
        createdAt: DateTime.tryParse(data['created_at'] as String? ?? ''),
        updatedAt: DateTime.tryParse(data['updated_at'] as String? ?? ''),
      );
      final model = await _readPackageOrUnavailable(root, dir, metadata);
      models.add(model);
      if (!model.packageReadFailed || data['name'] != null) {
        (names[model.name] ??= []).add(model);
      }
    }

    final conflicts = <String>{};
    for (final group in names.values.where((group) => group.length > 1)) {
      // An exact, unique match with the saved name identifies the original owner.
      // Older indexes can lack this hint. Block ambiguous matches until resolved.
      final owners = group.where(
        (item) => index[item.id]!['name'] == item.name,
      );
      final owner = owners.length == 1 ? owners.single : null;
      for (final model in group) {
        if (model != owner) {
          conflicts.add(model.id);
          _log.warning('Duplicate installed skill name id=${model.id}');
        }
      }
    }

    final readableNames = {
      for (final model in models)
        if (!model.packageReadFailed && !conflicts.contains(model.id))
          model.name,
    };
    for (var i = 0; i < models.length; i++) {
      final model = models[i];
      if (model.packageReadFailed || conflicts.contains(model.id)) {
        final name = index[model.id]!['name'] as String? ?? model.name;
        // Avoid shadowing a readable skill in callers that look up by name.
        models[i] = model.copyWith(
          name: readableNames.contains(name) ? '$name (${model.id})' : name,
          description: '',
          prompt: '',
          whenToUse: '',
          references: const [],
          packageReadFailed: true,
        );
      }
    }
    models.sort((a, b) {
      final order = a.sortOrder.compareTo(b.sortOrder);
      return order == 0 ? a.id.compareTo(b.id) : order;
    });
    return models;
  }

  Future<NovelAgentSkillModel> _readPackageOrUnavailable(
    Directory root,
    Directory dir,
    NovelAgentSkillModel metadata,
  ) async {
    try {
      return await _readSkillPackage(root, dir, metadata);
    } catch (error, stackTrace) {
      if (error is! FileSystemException && error is! FormatException) {
        rethrow;
      }
      _log.error(
        'Failed to read skill package id=${metadata.id}',
        error: error,
        stackTrace: stackTrace,
      );
      return metadata.copyWith(
        description: '',
        prompt: '',
        whenToUse: '',
        references: const [],
        packageReadFailed: true,
      );
    }
  }

  Future<NovelAgentSkillModel> _readSkillPackage(
    Directory root,
    Directory dir,
    NovelAgentSkillModel metadata,
  ) async {
    final markdown = File(p.join(dir.path, markdownName));
    await RevericPaths.requireNoLinks(root, markdown.path);
    final parsed = AgentSkillImportParser.parse(
      await markdown.readAsString(),
      installed: true,
    );
    if (parsed == null) {
      throw FormatException('Invalid installed SKILL.md', metadata.id);
    }
    final references = <AgentSkillReferenceFile>[];
    final referenceDir = await findAgentSkillReferenceDirectory(dir);
    if (referenceDir != null) {
      await for (final entity in referenceDir.list(
        recursive: true,
        followLinks: false,
      )) {
        final relative = p
            .split(p.relative(entity.path, from: dir.path))
            .join('/');
        if (entity is File &&
            AgentSkillReferences.isValidRelativePath(relative)) {
          if (await entity.length() > AgentSkillReferences.maxContentBytes ||
              references.length == AgentSkillReferences.maxCount) {
            throw FormatException(
              'Installed skill references exceed file limits',
              metadata.id,
            );
          }
          references.add(
            AgentSkillReferenceFile(
              path: relative,
              content: await entity.readAsString(),
            ),
          );
        }
      }
    }
    return metadata.copyWith(
      name: parsed.name,
      description: parsed.description,
      prompt: parsed.body,
      whenToUse: parsed.whenToUse,
      category: parsed.category,
      tags: parsed.tags,
      references: AgentSkillReferences.normalizeOrThrow(references),
    );
  }

  static Directory _packageDirectory(
    Directory root,
    String id,
    Map<String, Object?> data,
  ) => Directory(
    p.join(root.path, _segment(id), _segment(data['package'] as String)),
  );

  static String _segment(String value) {
    if (!_pathSegment.hasMatch(value)) {
      throw FormatException('Invalid skill installation path segment', value);
    }
    return value;
  }
}
