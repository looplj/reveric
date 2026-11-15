// 职责: 解析与筛选插件市场官方索引（schemaVersion: 1），并匹配当前宿主平台与插件 API 的兼容版本。
// 关联文件:
//   lib/shared/models/plugin/text.dart
//   lib/shared/services/plugins/marketplace_service.dart
//   lib/shared/services/plugins/package_archive.dart
// 遵循的 Rules:
//   .agents/rules/code-style.md

import 'dart:ui';

import 'package:pub_semver/pub_semver.dart';

import 'text.dart';

/// 当前宿主支持的插件 API 版本。
final Version hostPluginApiVersion = Version(1, 0, 0);

final RegExp _sha256HexPattern = RegExp(r'^[a-f0-9]{64}$');
final RegExp _pluginIdPattern = RegExp(r'^[a-z0-9]+(\.[a-z0-9-]+)+$');
final RegExp _whitespaceOrControlPattern = RegExp(r'[\s\x00-\x1f\x7f]');

/// 校验并返回规范化后的 HTTPS 外部链接；不合法时返回 null。
String? normalizeMarketplaceHttpsUrl(Object? raw) {
  if (raw is! String) {
    return null;
  }
  final trimmed = raw.trim();
  if (trimmed.isEmpty || _whitespaceOrControlPattern.hasMatch(trimmed)) {
    return null;
  }
  final uri = Uri.tryParse(trimmed);
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.toString();
}

/// 判断插件声明的 [range] 是否兼容宿主 [hostApiVersion]。
bool isPluginApiVersionCompatible(String range, {Version? hostApiVersion}) {
  final trimmed = range.trim();
  if (trimmed.isEmpty) {
    return false;
  }
  try {
    final constraint = trimmed == '^1'
        ? VersionConstraint.parse('>=1.0.0 <2.0.0')
        : VersionConstraint.parse(trimmed);
    return constraint.allows(hostApiVersion ?? hostPluginApiVersion);
  } on FormatException {
    return false;
  }
}

/// 插件市场索引中的单个发布版本。
class MarketplacePluginVersion {
  const MarketplacePluginVersion({
    required this.version,
    required this.parsedVersion,
    required this.pluginApiVersion,
    required this.platforms,
    required this.url,
    this.fallbackUrl,
    required this.size,
    required this.sha256,
    this.releaseUrl,
    this.sourceCommit,
  });

  factory MarketplacePluginVersion.fromJson(
    Map<String, Object?> json, {
    required int maxPackageBytes,
  }) {
    final rawVersion = json['version'];
    if (rawVersion is! String || rawVersion.trim().isEmpty) {
      throw const FormatException('Invalid version string');
    }
    final parsedVersion = Version.parse(rawVersion.trim());
    final pluginApiVersion = json['pluginApiVersion'];
    if (pluginApiVersion is! String || pluginApiVersion.trim().isEmpty) {
      throw const FormatException('Invalid pluginApiVersion');
    }
    final rawPlatforms = json['platforms'];
    if (rawPlatforms is! List || rawPlatforms.isEmpty) {
      throw const FormatException('Invalid platforms list');
    }
    final platforms = <String>[];
    for (final item in rawPlatforms) {
      if (item is! String || item.trim().isEmpty) {
        throw const FormatException('Invalid platform item');
      }
      platforms.add(item.trim());
    }
    final url = normalizeMarketplaceHttpsUrl(json['url']);
    if (url == null) {
      throw const FormatException('Invalid marketplace download url');
    }
    final rawFallback = json['fallbackUrl'];
    final fallbackUrl = rawFallback == null
        ? null
        : normalizeMarketplaceHttpsUrl(rawFallback);
    if (rawFallback != null && fallbackUrl == null) {
      throw const FormatException('Invalid marketplace fallbackUrl');
    }
    final size = json['size'];
    if (size is! int || size <= 0 || size > maxPackageBytes) {
      throw const FormatException('Invalid package size');
    }
    final sha256 = json['sha256'];
    if (sha256 is! String || !_sha256HexPattern.hasMatch(sha256)) {
      throw const FormatException('Invalid package sha256');
    }
    final rawReleaseUrl = json['releaseUrl'];
    final releaseUrl = rawReleaseUrl == null
        ? null
        : normalizeMarketplaceHttpsUrl(rawReleaseUrl);
    if (rawReleaseUrl != null && releaseUrl == null) {
      throw const FormatException('Invalid releaseUrl');
    }
    final rawCommit = json['sourceCommit'];
    final sourceCommit = rawCommit is String && rawCommit.trim().isNotEmpty
        ? rawCommit.trim()
        : null;

    return MarketplacePluginVersion(
      version: parsedVersion.toString(),
      parsedVersion: parsedVersion,
      pluginApiVersion: pluginApiVersion.trim(),
      platforms: List.unmodifiable(platforms),
      url: url,
      fallbackUrl: fallbackUrl,
      size: size,
      sha256: sha256,
      releaseUrl: releaseUrl,
      sourceCommit: sourceCommit,
    );
  }

  final String version;
  final Version parsedVersion;
  final String pluginApiVersion;
  final List<String> platforms;
  final String url;
  final String? fallbackUrl;
  final int size;
  final String sha256;
  final String? releaseUrl;
  final String? sourceCommit;

  /// 按优先级返回下载地址列表：CDN 主地址优先，GitHub Release 备用地址其次。
  List<String> get downloadUrls => [
    url,
    if (fallbackUrl != null && fallbackUrl != url) fallbackUrl!,
  ];

  bool supportsPlatform(String platform) => platforms.contains(platform);

  bool isCompatible({required String platform, Version? hostApiVersion}) =>
      supportsPlatform(platform) &&
      isPluginApiVersionCompatible(
        pluginApiVersion,
        hostApiVersion: hostApiVersion,
      );
}

/// 插件市场中的单个插件条目及其全部已发布版本。
class MarketplacePluginEntry {
  const MarketplacePluginEntry({
    required this.id,
    required this.name,
    this.description,
    this.author,
    this.repository,
    required this.versions,
  });

  factory MarketplacePluginEntry.fromJson(
    Map<String, Object?> json, {
    required int maxPackageBytes,
  }) {
    final id = json['id'];
    if (id is! String || !_pluginIdPattern.hasMatch(id)) {
      throw const FormatException('Invalid marketplace plugin id');
    }
    final name = parsePluginText(json['name'], 'name');
    final rawDescription = json['description'];
    final description =
        rawDescription == null ||
            (rawDescription is String && rawDescription.trim().isEmpty)
        ? null
        : parseOptionalPluginText(rawDescription, 'description');
    final rawAuthor = json['author'];
    if (rawAuthor != null && rawAuthor is! String) {
      throw const FormatException('Invalid marketplace plugin author');
    }
    final author = rawAuthor is String && rawAuthor.trim().isNotEmpty
        ? rawAuthor.trim()
        : null;
    final rawRepository = json['repository'];
    final repository = rawRepository == null
        ? null
        : normalizeMarketplaceHttpsUrl(rawRepository);
    if (rawRepository != null && repository == null) {
      throw const FormatException('Invalid marketplace plugin repository');
    }
    final rawVersions = json['versions'];
    if (rawVersions is! List || rawVersions.isEmpty) {
      throw const FormatException('Marketplace plugin requires versions');
    }
    final versions = <MarketplacePluginVersion>[];
    for (final item in rawVersions) {
      if (item is! Map) {
        throw const FormatException('Invalid marketplace version entry');
      }
      versions.add(
        MarketplacePluginVersion.fromJson(
          item.cast<String, Object?>(),
          maxPackageBytes: maxPackageBytes,
        ),
      );
    }
    versions.sort((a, b) => b.parsedVersion.compareTo(a.parsedVersion));

    return MarketplacePluginEntry(
      id: id,
      name: name,
      description: description,
      author: author,
      repository: repository,
      versions: List.unmodifiable(versions),
    );
  }

  final String id;
  final PluginText name;
  final PluginText? description;
  final String? author;
  final String? repository;
  final List<MarketplacePluginVersion> versions;

  /// 最新发布版本（语义版本最高）。
  MarketplacePluginVersion get latestVersion => versions.first;

  /// 返回兼容目标平台与宿主 API 的最高版本，没有兼容版本时返回 null。
  MarketplacePluginVersion? resolveCompatibleVersion({
    required String platform,
    Version? hostApiVersion,
  }) {
    for (final version in versions) {
      if (version.isCompatible(
        platform: platform,
        hostApiVersion: hostApiVersion,
      )) {
        return version;
      }
    }
    return null;
  }

  /// 搜索过滤：匹配本地化或回退名称、描述、插件 ID 与作者。
  bool matches(String query, Locale locale) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return true;
    }
    final candidates = <String>[
      id,
      name.resolve(locale),
      ...name.values.values,
      if (description != null) description!.resolve(locale),
      if (description != null) ...description!.values.values,
      ?author,
    ];
    return candidates.any((value) => value.toLowerCase().contains(normalized));
  }
}

/// 插件市场官方索引根目录。
class MarketplacePluginIndex {
  const MarketplacePluginIndex({
    required this.schemaVersion,
    required this.plugins,
  });

  factory MarketplacePluginIndex.fromJson(
    Map<String, Object?> json, {
    required int maxPackageBytes,
  }) {
    final schemaVersion = json['schemaVersion'];
    if (schemaVersion != 1) {
      throw FormatException('Unsupported plugin index schema: $schemaVersion');
    }
    final rawPlugins = json['plugins'];
    if (rawPlugins is! List) {
      throw const FormatException('Invalid plugins list in index');
    }
    final plugins = <MarketplacePluginEntry>[];
    for (final item in rawPlugins) {
      if (item is! Map) {
        throw const FormatException('Invalid plugin item in index');
      }
      plugins.add(
        MarketplacePluginEntry.fromJson(
          item.cast<String, Object?>(),
          maxPackageBytes: maxPackageBytes,
        ),
      );
    }
    return MarketplacePluginIndex(
      schemaVersion: 1,
      plugins: List.unmodifiable(plugins),
    );
  }

  final int schemaVersion;
  final List<MarketplacePluginEntry> plugins;
}
