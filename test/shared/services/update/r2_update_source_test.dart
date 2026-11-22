// 职责: 验证 R2 清单的版本比较、平台包选择和失败处理。
// 关联文件:
//   lib/shared/services/update/sources/r2_update_source.dart
//   scripts/build-update-manifest.py
import 'dart:convert';
import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/services/update.dart';

const _packageNames = {
  'macos-arm64': 'reveric-2.0.0-macos-arm64.zip',
  'windows': 'reveric-2.0.0-windows-setup.exe',
  'linux': 'reveric-2.0.0-linux.zip',
  'android': 'reveric-android-arm64-v8a-v2.0.0.apk',
};
const _r2Base = 'https://downloads.reveric.app/releases/v2.0.0';
const _githubBase =
    'https://github.com/looplj/reveric/releases/download/v2.0.0';

Map<String, Object> _manifest({String? macOSPackage}) => {
  'version': '2.0.0',
  'release_notes': '更新说明',
  'platforms': {
    for (final entry in _packageNames.entries)
      entry.key: {
        'download_url':
            '$_r2Base/'
            '${entry.key == 'macos-arm64' ? macOSPackage ?? entry.value : entry.value}',
        'fallback_download_url': '$_githubBase/${entry.value}',
        'file_size': 123,
      },
  },
};

Future<UpdateCheckResult> _check({
  String platform = 'macos',
  Abi abi = Abi.macosArm64,
  String version = '1.0.0',
  Map<String, Object>? manifest,
  int statusCode = 200,
}) {
  final source = R2UpdateSource(
    operatingSystem: platform,
    abi: abi,
    createClient: () => MockClient((request) async {
      expect(request.method, 'GET');
      expect(
        request.url.toString(),
        'https://downloads.reveric.app/updates/latest.json',
      );
      return http.Response.bytes(
        utf8.encode(jsonEncode(manifest ?? _manifest())),
        statusCode,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
  return source.checkForUpdate(version);
}

void main() {
  for (final (platform, abi, key) in [
    ('macos', Abi.macosArm64, 'macos-arm64'),
    ('windows', Abi.windowsX64, 'windows'),
    ('linux', Abi.linuxX64, 'linux'),
    ('android', Abi.androidArm64, 'android'),
  ]) {
    test('$platform selects the package listed in the R2 manifest', () async {
      final result = await _check(platform: platform, abi: abi);
      final info = (result as UpdateAvailable).info;
      final fileName = _packageNames[key];
      expect(info.version, '2.0.0');
      expect(info.downloadUrl, '$_r2Base/$fileName');
      expect(info.fallbackDownloadUrl, '$_githubBase/$fileName');
      expect(info.fileSize, 123);
      expect(info.releaseNotes, '更新说明');
    });
  }

  test(
    'an older or already installed version does not offer an update',
    () async {
      for (final version in ['2.0.0+456', '2.1.0']) {
        expect(await _check(version: version), isA<UpdateUpToDate>());
      }
    },
  );

  test('Intel Mac cannot install an ARM-only release', () async {
    expect(await _check(abi: Abi.macosX64), isA<UpdateCheckFailed>());
  });

  test('ARM Mac rejects a mislabeled update package', () async {
    final manifest = _manifest(macOSPackage: 'reveric-2.0.0-macos-x86_64.zip');
    expect(await _check(manifest: manifest), isA<UpdateCheckFailed>());
  });

  test('missing or invalid manifests report a check failure', () async {
    expect(await _check(statusCode: 404), isA<UpdateCheckFailed>());
    expect(
      await _check(manifest: {'version': 'broken'}),
      isA<UpdateCheckFailed>(),
    );
  });
}
