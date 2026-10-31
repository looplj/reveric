// 职责: 解析并校验插件清单、配置字段、设置操作、页面、任务与入口路径。
// 关联文件:
//   lib/shared/services/plugins/host.dart
//   lib/shared/models/plugin/setting_field.dart
//   lib/shared/models/plugin/action.dart
import 'package:pub_semver/pub_semver.dart';
import 'action.dart';
import 'setting_field.dart';
import 'text.dart';
import 'view.dart';
import 'task.dart';

class PluginManifest {
  PluginManifest._(
    this.json,
    this.name,
    this.description,
    this.settings,
    this.actions,
    this.database,
    this.pages,
    this.tasks,
  );
  final Map<String, dynamic> json;
  final PluginText name;
  final PluginText? description;
  final List<PluginSettingField> settings;
  final List<PluginAction> actions;
  final PluginDatabaseManifest? database;
  final List<PluginView> pages;
  final List<PluginTaskDefinition> tasks;
  String get id => json['id'] as String;
  String get version => json['version'] as String;
  String get main => json['main'] as String;
  String? get author => json['author'] as String?;
  Set<String> get permissions => Set.unmodifiable(
    (json['permissions'] as List? ?? const []).cast<String>(),
  );
  bool get defaultEnabled => json['defaultEnabled'] as bool? ?? false;
  List<String> get platforms => List<String>.from(
    json['platforms'] as List? ?? ['windows', 'macos', 'android'],
  );
  factory PluginManifest.fromJson(Map<String, dynamic> json) {
    for (final key in ['id', 'version', 'pluginApiVersion', 'main']) {
      if (json[key] is! String || (json[key] as String).trim().isEmpty) {
        throw FormatException('Invalid manifest $key');
      }
    }
    if (!RegExp(r'^[a-z0-9]+(\.[a-z0-9-]+)+$').hasMatch(json['id'] as String)) {
      throw const FormatException('Invalid plugin id');
    }
    Version.parse(json['version'] as String);
    final api = json['pluginApiVersion'] as String;
    final constraint = api == '^1'
        ? VersionConstraint.parse('>=1.0.0 <2.0.0')
        : VersionConstraint.parse(api);
    if (!constraint.allows(Version(1, 0, 0))) {
      throw FormatException('Unsupported plugin API: $api');
    }
    final main = json['main'] as String;
    if (main.startsWith('/') ||
        main.contains('\\') ||
        main.contains(':') ||
        main.split('/').any((s) => s == '..' || s.isEmpty)) {
      throw const FormatException('Entry must remain within plugin package');
    }
    final name = parsePluginText(json['name'], 'name');
    final description = parseOptionalPluginText(
      json['description'],
      'description',
    );
    if (json.containsKey('author') && json['author'] is! String) {
      throw const FormatException('Invalid author');
    }
    if (json.containsKey('defaultEnabled') && json['defaultEnabled'] is! bool) {
      throw const FormatException('Invalid defaultEnabled');
    }
    for (final key in ['platforms', 'permissions']) {
      if (json.containsKey(key) &&
          (json[key] is! List ||
              (json[key] as List).any((v) => v is! String))) {
        throw FormatException('Invalid $key');
      }
    }
    if ([
      'uiProtocol',
      'uiProtocols',
      'actions',
      'views',
    ].any(json.containsKey)) {
      throw const FormatException(
        'Use settings.actions and per-page/card protocols',
      );
    }
    if ((json['platforms'] as List? ?? []).any(
      (p) => !['windows', 'macos', 'android'].contains(p),
    )) {
      throw const FormatException('Unknown platform');
    }
    if (json.containsKey('settings') &&
        json['settings'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid settings');
    }
    final config = json['settings'] as Map<String, dynamic>? ?? {};
    if (config.keys.any((key) => !{'fields', 'actions'}.contains(key))) {
      throw const FormatException('Invalid settings section');
    }
    final settings = parsePluginSettingFields(config['fields']);
    List<Map<String, dynamic>> declarations(String key) {
      final entries = json[key] ?? <String, dynamic>{};
      if (entries is! Map<String, dynamic>) {
        throw FormatException('Invalid $key');
      }
      return entries.entries.map((entry) {
        final value = entry.value;
        if (value is! Map<String, dynamic> || value.containsKey('id')) {
          throw FormatException('Invalid $key declaration: ${entry.key}');
        }
        return <String, dynamic>{...value, 'id': entry.key};
      }).toList();
    }

    return PluginManifest._(
      Map.unmodifiable(json),
      name,
      description,
      List.unmodifiable(settings),
      List.unmodifiable(
        parsePluginActions(config['actions'], {
          for (final field in settings) field.key,
        }),
      ),
      json['database'] == null
          ? null
          : PluginDatabaseManifest.parse(json['database']),
      List.unmodifiable(
        declarations(
          'pages',
        ).map((value) => PluginView(json['id'] as String, value)),
      ),
      List.unmodifiable(
        declarations('tasks').map(
          (value) => PluginTaskDefinition(
            pluginId: json['id'] as String,
            version: json['version'] as String,
            definition: value,
          ),
        ),
      ),
    );
  }
}

class PluginDatabaseManifest {
  PluginDatabaseManifest._(this.version, this.migrations);
  final int version;
  final List<({int version, String source})> migrations;
  factory PluginDatabaseManifest.parse(Object? value) {
    if (value is! Map ||
        value['version'] is! int ||
        value['version'] < 1 ||
        value['migrations'] is! List) {
      throw const FormatException('Invalid plugin database declaration');
    }
    final rows = value['migrations'] as List;
    if (rows.length != value['version']) {
      throw const FormatException(
        'Database migrations must be complete and consecutive',
      );
    }
    final migrations = <({int version, String source})>[];
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row is! Map || row['version'] != i + 1 || row['source'] is! String) {
        throw const FormatException('Invalid database migration');
      }
      final source = row['source'] as String;
      if (!source.endsWith('.sql') ||
          source.startsWith('/') ||
          source.contains('\\') ||
          source.contains(':') ||
          source.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
        throw const FormatException('Migration must be a package SQL file');
      }
      migrations.add((version: i + 1, source: source));
    }
    if (migrations.map((m) => m.source).toSet().length != migrations.length) {
      throw const FormatException('Duplicate migration source');
    }
    return PluginDatabaseManifest._(
      value['version'] as int,
      List.unmodifiable(migrations),
    );
  }
}
