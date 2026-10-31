// 职责: 在用户确认插件信息与权限后安装已校验的包，并协调目录与登记事务。
// 关联文件:
//   lib/shared/services/plugins/package_archive.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/database/daos/plugin_dao.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import '../../logger/app_logger.dart';
import 'host.dart';
import 'package_archive.dart';

final _log = AppLogger.forModule('PluginInstall');

class PluginInstallOrchestrator {
  /// The caller confirms package identity and the exact declared permissions
  /// before calling this method. Parsing a package never executes its code.
  Future<void> install({
    required PluginHostService host,
    required PluginPackageArchive archive,
    required Set<String> grantedPermissions,
    required Directory temporaryRoot,
  }) async {
    await host.start();
    return host.mutate(
      archive.manifest.id,
      () => _install(
        host: host,
        archive: archive,
        grantedPermissions: grantedPermissions,
        temporaryRoot: temporaryRoot,
      ),
    );
  }

  Future<void> _install({
    required PluginHostService host,
    required PluginPackageArchive archive,
    required Set<String> grantedPermissions,
    required Directory temporaryRoot,
  }) async {
    final manifest = archive.manifest;
    if (!grantedPermissions.containsAll(manifest.permissions)) {
      throw StateError('Plugin permissions were not confirmed');
    }
    final existing = await host.dao.getPlugin(manifest.id);
    if (existing != null &&
        (existing.source != 'local' ||
            Version.parse(manifest.version) <=
                Version.parse(existing.version))) {
      throw StateError('Plugin update must have a newer local package version');
    }
    final support = await host.supportDirectory();
    final relative = 'plugins/${manifest.id}/${manifest.version}';
    final destination = Directory(
      p.joinAll([support.path, ...relative.split('/')]),
    );
    final staging = await archive.extract(temporaryRoot);
    var moved = false;
    var committed = false;
    try {
      if (await destination.exists()) {
        // Soft uninstall keeps packages. Reinstall the exact retained package;
        // a different payload must use a new version.
        final retained = <String>{};
        await for (final entity in destination.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is Link) {
            throw const FormatException(
              'Installed package contains a symbolic link',
            );
          }
          if (entity is File) {
            final path = p
                .relative(entity.path, from: destination.path)
                .split(p.separator)
                .join('/');
            retained.add(path);
            if (!listEquals(await entity.readAsBytes(), archive.files[path])) {
              throw StateError('Retained package differs; use a newer version');
            }
          }
        }
        if (!setEquals(retained, archive.files.keys.toSet())) {
          throw StateError('Retained package is incomplete');
        }
      } else {
        await destination.parent.create(recursive: true);
        // Staging is application-owned and expected on the same filesystem.
        await staging.rename(destination.path);
        moved = true;
      }
      await host.dao.install(
        pluginId: manifest.id,
        version: manifest.version,
        packagePath: relative,
        permissions: manifest.permissions,
      );
      committed = true;
      await host.loadInstalled(
        PluginPackage(
          relative,
          manifest,
          utf8.decode(archive.files[manifest.main]!),
          source: 'local',
        ),
      );
      if (existing != null && existing.packagePath != relative) {
        final oldExpected = 'plugins/${manifest.id}/${existing.version}';
        if (existing.packagePath == oldExpected) {
          try {
            final old = Directory(
              p.joinAll([support.path, ...oldExpected.split('/')]),
            );
            if (await old.exists()) {
              await old.delete(recursive: true);
            }
          } catch (error, stack) {
            _log.error(
              'Old package cleanup failed: ${manifest.id}',
              error: error,
              stackTrace: stack,
            );
          }
        }
      }
    } catch (error, stack) {
      _log.error(
        'Package installation failed: ${manifest.id}',
        error: error,
        stackTrace: stack,
      );
      if (moved && !committed) {
        await destination.delete(recursive: true);
      }
      rethrow;
    } finally {
      if (await staging.exists()) {
        await staging.delete(recursive: true);
      }
    }
  }
}
