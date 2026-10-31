// 职责: 校验插件 ZIP 的路径、大小和清单，并将内容解压到专属临时目录。
// 关联文件:
//   lib/shared/models/plugin/manifest.dart
//   lib/shared/services/plugins/host.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import '../../models/plugin/manifest.dart';

class PluginPackageArchive {
  PluginPackageArchive._(this.manifest, this.files);

  static const maxZipBytes = 10 * 1024 * 1024;
  static const maxExpandedBytes = 20 * 1024 * 1024;
  static const maxEntries = 500;
  final PluginManifest manifest;
  final Map<String, Uint8List> files;

  factory PluginPackageArchive.decode(Uint8List bytes) {
    if (bytes.length > maxZipBytes) {
      throw const FormatException('Plugin ZIP exceeds 10 MB');
    }
    final directory = ZipDirectory()..read(InputMemoryStream(bytes));
    if (directory.fileHeaders.length > maxEntries) {
      throw const FormatException('Plugin ZIP exceeds 500 entries');
    }
    final paths = <String, bool>{};
    var expanded = 0;
    for (final header in directory.fileHeaders) {
      final file = header.file!;
      final name = file.filename;
      final isDirectory = name.endsWith('/');
      final path = isDirectory ? name.substring(0, name.length - 1) : name;
      _validatePath(path);
      if (header.filename != name || paths.containsKey(path.toLowerCase())) {
        throw const FormatException('Conflicting plugin ZIP paths');
      }
      paths[path.toLowerCase()] = isDirectory;
      final type = (header.externalFileAttributes >> 16) & 0xf000;
      if (![0, 0x4000, 0x8000].contains(type) ||
          (header.generalPurposeBitFlag & 1) != 0 ||
          ![0, 8].contains(header.compressionMethod)) {
        throw const FormatException('Unsupported plugin ZIP entry');
      }
      expanded += header.uncompressedSize;
      if (expanded > maxExpandedBytes) {
        throw const FormatException('Plugin ZIP expands beyond 20 MB');
      }
    }
    for (final path in paths.keys) {
      final parts = path.split('/');
      for (var i = 1; i < parts.length; i++) {
        if (paths[parts.take(i).join('/')] == false) {
          throw const FormatException('Plugin ZIP file shadows a directory');
        }
      }
    }
    final files = <String, Uint8List>{};
    for (final header in directory.fileHeaders) {
      if (header.filename.endsWith('/')) {
        continue;
      }
      final output = _BoundedOutput(header.uncompressedSize);
      header.file!.decompress(output);
      final content = output.getBytes();
      if (content.length != header.uncompressedSize ||
          getCrc32(content) != header.crc32) {
        throw const FormatException('Corrupted plugin ZIP entry');
      }
      files[header.filename] = content;
    }
    final manifestBytes = files['plugin.json'];
    if (manifestBytes == null) {
      throw const FormatException('Missing root plugin.json');
    }
    final json = jsonDecode(utf8.decode(manifestBytes));
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Plugin manifest must be an object');
    }
    final manifest = PluginManifest.fromJson(json);
    final main = files[manifest.main];
    if (main == null || main.length > 2 * 1024 * 1024) {
      throw const FormatException('Missing or oversized plugin entry');
    }
    utf8.decode(main);
    return PluginPackageArchive._(manifest, Map.unmodifiable(files));
  }

  /// [temporaryRoot] must be an application-owned temporary directory.
  /// The caller owns the returned directory and must clean it on every exit.
  Future<Directory> extract(Directory temporaryRoot) async {
    final directory = await temporaryRoot.createTemp('plugin-install-');
    try {
      for (final entry in files.entries) {
        final file = File(p.joinAll([directory.path, ...entry.key.split('/')]));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.value, flush: true);
      }
      return directory;
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  static void _validatePath(String path) {
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.contains('\\') ||
        RegExp(r'[\x00-\x1f<>:"|?*]').hasMatch(path)) {
      throw const FormatException('Invalid plugin ZIP path');
    }
    for (final part in path.split('/')) {
      if (part.isEmpty ||
          part == '.' ||
          part == '..' ||
          part.endsWith('.') ||
          part.endsWith(' ') ||
          RegExp(
            r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
            caseSensitive: false,
          ).hasMatch(part)) {
        throw const FormatException('Invalid plugin ZIP path component');
      }
    }
  }
}

class _BoundedOutput extends OutputMemoryStream {
  _BoundedOutput(this.limit) : super(size: 1024);
  final int limit;
  void _check(int count) {
    if (length + count > limit) {
      throw const FormatException('Plugin ZIP entry exceeds declared size');
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _check(count);
    super.writeBackReference(distance, count);
  }
}
