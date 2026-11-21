// 职责: 验证本地头像落盘工具为每次保存生成独立路径，不覆盖旧文件。
// 关联文件:
//   lib/shared/utils/avatar_storage.dart
//   lib/shared/utils/storage_paths.dart

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reveric/shared/utils/avatar_storage.dart';
import 'package:reveric/shared/utils/storage_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempSupport;

  setUp(() async {
    tempSupport = await Directory.systemTemp.createTemp('reveric_avatar_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async {
            if (call.method == 'getApplicationSupportDirectory') {
              return tempSupport.path;
            }
            return null;
          },
        );
    await RevericPaths.initialize();
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (await tempSupport.exists()) {
      await tempSupport.delete(recursive: true);
    }
  });

  test(
    'storeAvatarFile writes distinct relative paths for consecutive same-extension picks',
    () async {
      final sourceA = File(p.join(tempSupport.path, 'pick_a.png'))
        ..writeAsBytesSync([1, 2, 3]);
      final sourceB = File(p.join(tempSupport.path, 'pick_b.png'))
        ..writeAsBytesSync([4, 5, 6]);

      final storedA = await storeAvatarFile(sourceA.path);
      final storedB = await storeAvatarFile(sourceB.path);

      expect(storedA, isNot(equals(storedB)));
      expect(storedA, startsWith('avatars/'));
      expect(storedB, startsWith('avatars/'));
      expect(storedA, endsWith('.png'));
      expect(storedB, endsWith('.png'));

      final resolvedA = RevericPaths.resolveStored(storedA)!;
      final resolvedB = RevericPaths.resolveStored(storedB)!;
      expect(File(resolvedA).readAsBytesSync(), [1, 2, 3]);
      expect(File(resolvedB).readAsBytesSync(), [4, 5, 6]);
    },
  );

  test(
    'storeAvatarBytes writes distinct relative paths without overwriting previous files',
    () async {
      final storedA = await storeAvatarBytes(
        Uint8List.fromList([7, 8, 9]),
        extension: '.jpg',
      );
      final storedB = await storeAvatarBytes(
        Uint8List.fromList([10, 11, 12]),
        extension: '.jpg',
      );

      expect(storedA, isNot(equals(storedB)));
      expect(File(RevericPaths.resolveStored(storedA)!).readAsBytesSync(), [
        7,
        8,
        9,
      ]);
      expect(File(RevericPaths.resolveStored(storedB)!).readAsBytesSync(), [
        10,
        11,
        12,
      ]);
    },
  );
}
