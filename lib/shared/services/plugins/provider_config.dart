// 职责: 按供应商实例前缀读取、校验和保存插件配置与凭据快照。
// 关联文件:
//   lib/shared/services/plugins/host.dart
//   lib/shared/services/plugins/config.dart
//   lib/shared/database/daos/plugin_dao.dart
//   lib/shared/models/plugin/manifest.dart
import 'dart:convert';
import '../../database/daos/plugin_dao.dart';
import '../../logger/app_logger.dart';
import '../../models/plugin/manifest.dart';
import '../../models/plugin/setting_field.dart';

final _log = AppLogger.forModule('PluginProviderConfig');

String pluginProviderPrefix(String providerId) {
  if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(providerId)) {
    throw const FormatException('Invalid provider instance identity');
  }
  return 'provider.$providerId.';
}

class PluginProviderConfiguration {
  PluginProviderConfiguration(
    Map<String, Object?> values,
    Map<String, String?> secrets,
  ) : values = Map.unmodifiable(values),
      secrets = Map.unmodifiable(secrets);
  final Map<String, Object?> values;
  final Map<String, String?> secrets;

  String? invalidField(PluginProviderManifest declaration) {
    for (final field in declaration.fields) {
      if (validatePluginSettingValue(
            field,
            field.isSecret ? secrets[field.key] : values[field.key],
          ) !=
          null) {
        return field.key;
      }
    }
    return null;
  }
}

Future<PluginProviderConfiguration> readPluginProviderConfiguration(
  PluginDao dao,
  PluginManifest manifest,
  String providerId, {
  Map<String, Object?> settings = const {},
  Map<String, String?> secrets = const {},
}) async {
  final declaration = manifest.provider;
  if (declaration == null) {
    throw const FormatException('Plugin does not declare a provider');
  }
  final prefix = pluginProviderPrefix(providerId);
  final fields = {for (final field in declaration.fields) field.key: field};
  if (settings.keys.any(
        (key) => fields[key] == null || fields[key]!.isSecret,
      ) ||
      secrets.keys.any((key) => fields[key]?.isSecret != true)) {
    throw const FormatException('Undeclared provider configuration field');
  }
  final values = <String, Object?>{};
  final credentials = <String, String?>{};
  for (final field in declaration.fields) {
    final key = '$prefix${field.key}';
    if (field.isSecret) {
      final value = secrets.containsKey(field.key)
          ? secrets[field.key]
          : await dao.getSecret(manifest.id, key);
      credentials[field.key] = value == null || value.isEmpty ? null : value;
    } else {
      final stored = await dao.getStorage(manifest.id, key);
      values[field.key] = settings.containsKey(field.key)
          ? settings[field.key] ?? field.defaultValue
          : stored == null
          ? field.defaultValue
          : jsonDecode(stored);
    }
  }
  return PluginProviderConfiguration(values, credentials);
}

Future<void> savePluginProviderConfiguration(
  PluginDao dao,
  PluginManifest manifest,
  String providerId, {
  required Map<String, Object?> settings,
  required Map<String, String?> secrets,
}) async {
  final snapshot = await readPluginProviderConfiguration(
    dao,
    manifest,
    providerId,
    settings: settings,
    secrets: secrets,
  );
  for (final field in manifest.provider!.fields) {
    final value = field.isSecret
        ? snapshot.secrets[field.key]
        : snapshot.values[field.key];
    final issue = validatePluginSettingValue(field, value);
    // Incomplete instances remain editable; submission separately requires every field.
    if (issue != null && issue != PluginSettingIssue.missing) {
      throw FormatException(
        'Invalid provider configuration ${field.key}: ${issue.name}',
      );
    }
  }
  final prefix = pluginProviderPrefix(providerId);
  try {
    await dao.transaction(() async {
      for (final entry in settings.entries) {
        await dao.setStorage(
          manifest.id,
          '$prefix${entry.key}',
          jsonEncode(entry.value),
        );
      }
      for (final entry in secrets.entries) {
        await dao.setSecret(
          manifest.id,
          '$prefix${entry.key}',
          entry.value ?? '',
        );
      }
    });
  } catch (error, stack) {
    _log.error(
      '[DB] plugin_storage/plugin_secrets UPSERT provider=$providerId',
      error: error,
      stackTrace: stack,
    );
    rethrow;
  }
}
