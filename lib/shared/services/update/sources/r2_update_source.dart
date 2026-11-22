// 职责: 从 R2 更新清单读取版本并选择当前平台的安装包。
// 关联文件:
//   .github/workflows/build.yaml
//   scripts/build-update-manifest.py
//   lib/shared/services/update/models.dart
//   lib/shared/services/update/update_source.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../localization/locale_keys.dart';
import '../../../logger/app_logger.dart';
import '../models.dart';
import '../update_source.dart';

final _log = AppLogger.forModule('R2UpdateSource');

class R2UpdateSource implements UpdateSource {
  static const _manifestUrl =
      'https://downloads.reveric.app/updates/latest.json';
  static final _releaseVersion = RegExp(r'^\d+\.\d+\.\d+$');

  final FutureOr<http.Client> Function() createClient;
  final String _operatingSystem;
  final Abi _abi;

  R2UpdateSource({
    this.createClient = http.Client.new,
    String? operatingSystem,
    Abi? abi,
  }) : _operatingSystem = operatingSystem ?? Platform.operatingSystem,
       _abi = abi ?? Abi.current();

  @override
  Future<UpdateCheckResult> checkForUpdate(String currentVersion) async {
    http.Client? client;
    try {
      client = await createClient();
      final response = await client
          .get(Uri.parse(_manifestUrl), headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        _log.warning(
          'Manifest request failed url=$_manifestUrl '
          'status=${response.statusCode} body=${response.body}',
        );
        return const UpdateCheckFailed(LocaleKeys.settingsAboutCheckFailed);
      }

      final manifest =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final version = manifest['version'] as String;
      if (!_releaseVersion.hasMatch(version)) {
        throw FormatException('Invalid update version: $version');
      }
      if (!isNewerVersion(version, currentVersion)) {
        return const UpdateUpToDate();
      }

      final platform = _platformKey();
      if (platform == null) {
        return const UpdateCheckFailed(
          LocaleKeys.settingsAboutUpdateUnsupportedPlatform,
        );
      }
      final platforms = manifest['platforms'] as Map<String, dynamic>;
      final asset = platforms[platform] as Map<String, dynamic>?;
      if (asset == null) {
        throw FormatException('Missing update package for $platform');
      }
      final downloadUrl = asset['download_url'] as String;
      final uri = Uri.parse(downloadUrl);
      final fileName = uri.pathSegments.lastOrNull;
      final expectedSuffix = switch (platform) {
        'windows' => '-windows-setup.exe',
        'android' => '-arm64-v8a-v$version.apk',
        _ => '-$platform.zip',
      };
      if (uri.scheme != 'https' ||
          uri.host.isEmpty ||
          fileName == null ||
          !fileName.endsWith(expectedSuffix)) {
        throw FormatException('Invalid update package for $platform');
      }

      return UpdateAvailable(
        UpdateInfo(
          version: version,
          downloadUrl: downloadUrl,
          fallbackDownloadUrl: asset['fallback_download_url'] as String?,
          fileSize: asset['file_size'] as int?,
          releaseNotes: manifest['release_notes'] as String?,
        ),
      );
    } catch (error, stack) {
      _log.error(
        'Update check failed url=$_manifestUrl currentVersion=$currentVersion',
        error: error,
        stackTrace: stack,
      );
      return const UpdateCheckFailed(LocaleKeys.settingsAboutCheckFailed);
    } finally {
      client?.close();
    }
  }

  String? _platformKey() => switch (_operatingSystem) {
    'macos' => switch (_abi) {
      Abi.macosArm64 => 'macos-arm64',
      Abi.macosX64 => 'macos-x86_64',
      _ => null,
    },
    'windows' || 'linux' || 'android' => _operatingSystem,
    _ => null,
  };
}
