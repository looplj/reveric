// 职责: 验证 Android SAF 目录扫描、逐包复制、目录导出和取消的通道契约。
// 关联文件:
//   lib/mobile/services/android_saf_directory_import.dart
//   android/app/src/main/kotlin/ai/reveric/MainActivity.kt

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/mobile/services/android_saf_directory_import.dart';
import 'package:reveric/shared/services/agent_skill_package.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('reveric/android_directory_import');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('parses copied document directory result', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'pickAndCopyDirectory');
      expect(call.arguments, {
        'extensions': ['txt', 'md', 'csv'],
      });
      return <String, Object>{
        'path': '/data/user/0/ai.reveric/cache/import-1',
        'name': '资料',
        'fileCount': 2,
        'directoryCount': 1,
      };
    });

    final result = await pickAndCopyAndroidDirectory();

    expect(result, isNotNull);
    expect(result!.directoryPath, contains('/cache/import-1'));
    expect(result.directoryName, '资料');
    expect(result.fileCount, 2);
    expect(result.directoryCount, 1);
  });

  test('returns null when Android picker is cancelled', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);

    expect(await pickAndCopyAndroidDirectory(), isNull);
    expect(await scanAndroidSkillDirectory(), isNull);
    expect(await exportAndroidSkillDirectory(Directory('unused')), isNull);
  });

  test('scans metadata first and requests only the selected skill', () async {
    final methods = <String>[];
    final destination = Directory(
      '/data/user/0/ai.reveric/cache/reveric_skill_import_test',
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      switch (call.method) {
        case 'scanSkillDirectory':
          expect(
            call.arguments['ignored'],
            unorderedEquals(agentSkillIgnoredDirectories),
          );
          expect(call.arguments['packageBytes'], agentSkillMaxPackageBytes);
          expect(call.arguments['packageFiles'], agentSkillMaxPackageFiles);
          expect(call.arguments['scriptExtensions'], contains('py'));
          return {
            'token': 'tree-token',
            'skills': [
              {
                'id': '1',
                'path': 'skill/SKILL.md',
                'markdown': 'skill text',
                'hasScripts': true,
              },
            ],
          };
        case 'copySkillPackage':
          expect(call.arguments, {
            'token': 'tree-token',
            'id': '1',
            'path': destination.path,
          });
          throw PlatformException(code: 'skill_package_too_large');
        case 'closeSkillDirectory':
          expect(call.arguments, {'token': 'tree-token'});
          return null;
        default:
          fail('Unexpected call ${call.method}');
      }
    });

    final selected = (await scanAndroidSkillDirectory())!;
    expect(selected.candidates.single.markdown, 'skill text');
    expect(methods, ['scanSkillDirectory']);
    await expectLater(
      selected.copyPackage(selected.candidates.single.id, destination),
      throwsA(isA<AgentSkillImportLimitException>()),
    );
    await selected.close();
    expect(methods, [
      'scanSkillDirectory',
      'copySkillPackage',
      'closeSkillDirectory',
    ]);
  });

  test(
    'exports from the private staging path without transferring file bytes',
    () async {
      final directory = Directory(
        '/data/user/0/ai.reveric/cache/reveric_skill_export_test',
      );
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'exportSkillDirectory');
        expect(call.arguments, {'path': directory.path});
        return <String, Object>{'name': 'Downloads', 'fileCount': 2};
      });

      final result = await exportAndroidSkillDirectory(directory);

      expect(result, isNotNull);
      expect(result!.directoryName, 'Downloads');
      expect(result.fileCount, 2);
    },
  );
}
