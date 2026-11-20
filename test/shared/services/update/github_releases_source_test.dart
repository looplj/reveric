// 职责: 验证 GitHub 更新包按平台与架构选择，拒绝旧包和不匹配架构
// 关联文件:
//   lib/shared/services/update/sources/github_releases_source.dart
//   lib/shared/services/update/models.dart
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/services/update.dart';

class _TrackedClient extends MockClient {
  _TrackedClient(super.handler);
  bool closed = false;
  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  test(
    'each check obtains the current client and closes it on success or failure',
    () async {
      final clients = <_TrackedClient>[];
      final source = GitHubReleasesSource(
        owner: 'example',
        repo: 'app',
        createClient: () async {
          final fail = clients.isEmpty;
          final client = _TrackedClient((_) async {
            if (fail) {
              throw const SocketException('proxy unavailable');
            }
            return http.Response('{"tag_name":"v1.0.0"}', 200);
          });
          clients.add(client);
          return client;
        },
      );
      expect(await source.checkForUpdate('1.0.0'), isA<UpdateCheckFailed>());
      expect(clients.single.closed, true);
      expect(await source.checkForUpdate('1.0.0'), isA<UpdateUpToDate>());
      expect(clients.length, 2);
      expect(clients.last.closed, true);
    },
  );

  Future<UpdateCheckResult> check(
    List<String> names, {
    String platform = 'macos',
    Abi abi = Abi.macosArm64,
  }) => http.runWithClient(
    () => GitHubReleasesSource(
      owner: 'example',
      repo: 'app',
      operatingSystem: platform,
      abi: abi,
    ).checkForUpdate('1.0.0'),
    () => MockClient(
      (_) async => http.Response(
        jsonEncode({
          'tag_name': 'v2.0.0',
          'assets': [
            for (final name in names)
              {
                'name': name,
                'browser_download_url': 'https://example.com/$name',
              },
          ],
        }),
        200,
      ),
    ),
  );

  test(
    'macOS ARM selects its ZIP even when other packages come first',
    () async {
      final result = await check([
        'app-2.0.0-macos.zip',
        'app-2.0.0-macos-x86_64.zip',
        'app-2.0.0-macos-arm64.dmg',
        'app-2.0.0-macos-arm64.zip',
      ]);
      expect(result, isA<UpdateAvailable>());
      expect(
        (result as UpdateAvailable).info.downloadUrl,
        endsWith('-macos-arm64.zip'),
      );
    },
  );

  for (final name in [
    'app-2.0.0-macos.zip',
    'app-2.0.0-macos-universal.zip',
    'app-2.0.0-macos-x86_64.zip',
    'app-2.0.0-macos-arm64.dmg',
    'app-2.0.0-macos-arm64.zip.sha256',
  ]) {
    test('macOS ARM rejects $name', () async {
      expect(await check([name]), isA<UpdateCheckFailed>());
    });
  }

  test('Intel cannot select an ARM-only release', () async {
    expect(
      await check(['app-2.0.0-macos-arm64.zip'], abi: Abi.macosX64),
      isA<UpdateCheckFailed>(),
    );
  });

  test('Intel selects only its own package when one is provided', () async {
    final result = await check([
      'app-2.0.0-macos-arm64.zip',
      'app-2.0.0-macos-x86_64.zip',
    ], abi: Abi.macosX64);
    expect(result, isA<UpdateAvailable>());
    expect(
      (result as UpdateAvailable).info.downloadUrl,
      endsWith('-macos-x86_64.zip'),
    );
  });

  test('Windows still selects the setup executable', () async {
    final result = await check(
      [
        'app-2.0.0-macos-arm64.zip',
        'app-2.0.0-windows.zip',
        'app-2.0.0-windows-setup.exe',
      ],
      platform: 'windows',
      abi: Abi.windowsX64,
    );
    expect(result, isA<UpdateAvailable>());
    expect(
      (result as UpdateAvailable).info.downloadUrl,
      endsWith('-windows-setup.exe'),
    );
  });

  test('GitHub release asset maps to the R2 object for the same tag', () {
    expect(
      githubReleaseMirrorUrl(
        'https://github.com/looplj/reveric/releases/download/v0.8.3/reveric-0.8.3-macos-arm64.zip',
      ),
      'https://downloads.reveric.app/releases/v0.8.3/reveric-0.8.3-macos-arm64.zip',
    );
    expect(
      githubReleaseMirrorUrl('https://example.com/releases/download/v1/a.zip'),
      isNull,
    );
    expect(githubReleaseMirrorUrl('https://github.com/looplj/reveric'), isNull);
  });

  test('available GitHub update keeps the release URL and its R2 mirror', () async {
    final result = await http.runWithClient(
      () => GitHubReleasesSource(
        owner: 'looplj',
        repo: 'reveric',
        operatingSystem: 'macos',
        abi: Abi.macosArm64,
      ).checkForUpdate('0.8.0'),
      () => MockClient(
        (_) async => http.Response(
          jsonEncode({
            'tag_name': 'v0.8.3',
            'assets': [
              {
                'name': 'reveric-0.8.3-macos-arm64.zip',
                'size': 10,
                'browser_download_url':
                    'https://github.com/looplj/reveric/releases/download/v0.8.3/reveric-0.8.3-macos-arm64.zip',
              },
            ],
          }),
          200,
        ),
      ),
    );
    final info = (result as UpdateAvailable).info;
    expect(
      info.downloadUrl,
      'https://github.com/looplj/reveric/releases/download/v0.8.3/reveric-0.8.3-macos-arm64.zip',
    );
    expect(
      info.fallbackDownloadUrl,
      'https://downloads.reveric.app/releases/v0.8.3/reveric-0.8.3-macos-arm64.zip',
    );
  });

  test('Android still selects the arm64-v8a APK', () async {
    final result = await check(
      [
        'app-2.0.0-android-x86_64.apk',
        'app-2.0.0-macos-arm64.zip',
        'app-2.0.0-android-arm64-v8a.apk',
      ],
      platform: 'android',
      abi: Abi.androidArm64,
    );
    expect(result, isA<UpdateAvailable>());
    expect(
      (result as UpdateAvailable).info.downloadUrl,
      endsWith('-android-arm64-v8a.apk'),
    );
  });
}
