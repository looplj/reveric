// 职责: 验证插件安装包在解压前拒绝危险路径和无效入口，并保留正常资源。
// 关联文件:
//   lib/shared/services/plugins/package_archive.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/plugins/package_archive.dart';

Uint8List package({
  List<ArchiveFile> extras = const [],
  String main = 'dist/index.js',
  bool entry = true,
}) {
  final archive = Archive()
    ..addFile(
      ArchiveFile.string(
        'plugin.json',
        jsonEncode({
          'id': 'example.test',
          'name': 'Test',
          'version': '1.0.0',
          'pluginApiVersion': '^1',
          'main': main,
        }),
      ),
    );
  if (entry) {
    archive.addFile(
      ArchiveFile.string('dist/index.js', 'globalThis.__revericPlugin = {};'),
    );
  }
  for (final file in extras) {
    archive.addFile(file);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  test(
    'extracts validated package and Unicode resources into unique staging',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'plugin-archive-test-',
      );
      try {
        final archive = PluginPackageArchive.decode(
          package(extras: [ArchiveFile.string('资源/说明.txt', '你好')]),
        );
        final directory = await archive.extract(root);
        expect(archive.manifest.id, 'example.test');
        expect(await File('${directory.path}/资源/说明.txt').readAsString(), '你好');
        expect(await File('${directory.path}/dist/index.js').exists(), true);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  for (final path in [
    '../outside',
    '/absolute',
    'C:/outside',
    'dir/../file',
    'dir//file',
    'dir/./file',
    'NUL.txt',
    'dir/file.',
    'dir/file ',
    'dir/file:ads',
  ]) {
    test('rejects unsafe path $path', () {
      expect(
        () => PluginPackageArchive.decode(
          package(extras: [ArchiveFile.string(path, 'x')]),
        ),
        throwsFormatException,
      );
    });
  }
  test('rejects raw backslash paths without encoder normalization', () {
    final bytes = package(extras: [ArchiveFile.string('dir/file', 'x')]);
    final name = utf8.encode('dir/file');
    for (var i = 0; i <= bytes.length - name.length; i++) {
      if (List.generate(name.length, (j) => bytes[i + j]).join(',') ==
          name.join(',')) {
        bytes[i + 3] = 92;
      }
    }
    expect(() => PluginPackageArchive.decode(bytes), throwsFormatException);
  });
  test('rejects symlinks and case-insensitive collisions', () {
    expect(
      () => PluginPackageArchive.decode(
        package(extras: [ArchiveFile.string('link', 'outside')..mode = 0xa1ff]),
      ),
      throwsFormatException,
    );
    expect(
      () => PluginPackageArchive.decode(
        package(extras: [ArchiveFile.string('PLUGIN.JSON', '{}')]),
      ),
      throwsFormatException,
    );
  });
  test('rejects files used as ancestor directories', () {
    expect(
      () => PluginPackageArchive.decode(
        package(extras: [ArchiveFile.string('dist', 'x')]),
      ),
      throwsFormatException,
    );
  });
  test('requires a valid root manifest and in-package entry', () {
    expect(
      () => PluginPackageArchive.decode(package(entry: false)),
      throwsFormatException,
    );
    expect(
      () => PluginPackageArchive.decode(package(main: '../outside')),
      throwsFormatException,
    );
    expect(
      () => PluginPackageArchive.decode(
        Uint8List.fromList(
          ZipEncoder().encode(
            Archive()..addFile(ArchiveFile.string('nested/plugin.json', '{}')),
          ),
        ),
      ),
      throwsFormatException,
    );
  });
  test('rejects excessive entry counts and compressed input', () {
    expect(
      () => PluginPackageArchive.decode(
        package(
          extras: [
            for (var i = 0; i < 499; i++) ArchiveFile.string('file$i', ''),
          ],
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => PluginPackageArchive.decode(
        Uint8List(PluginPackageArchive.maxZipBytes + 1),
      ),
      throwsFormatException,
    );
  });
  test('rejects excessive expanded size before extracting', () {
    expect(
      () => PluginPackageArchive.decode(
        package(
          extras: [
            ArchiveFile.bytes(
              'large',
              Uint8List(PluginPackageArchive.maxExpandedBytes + 1),
            ),
          ],
        ),
      ),
      throwsFormatException,
    );
  });
}
