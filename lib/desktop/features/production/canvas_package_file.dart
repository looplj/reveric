// 职责: 把画布作品压缩包保存到桌面选择的位置，或打开一个已有压缩包。
// 关联文件:
//   lib/shared/services/production/canvas_package.dart
//   lib/desktop/features/production/package_actions.dart
// 遵循的 Rules:
//   .agents/rules/file-access.md
//   .agents/rules/error-handling.md

import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';

import '../../../shared/logger/app_logger.dart';

final _log = AppLogger.forModule('ProductionCanvasPackageFile');

enum ProductionCanvasPackageSaveStatus { saved, cancelled, failed }

const _zipType = XTypeGroup(
  label: 'ZIP',
  extensions: ['zip'],
  uniformTypeIdentifiers: ['public.zip-archive'],
);

String productionCanvasPackageFileName(String title) {
  const extension = '.canvas.zip';
  final budget = 255 - utf8.encode(extension).length;
  var base = title
      .replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"/\\|?*]'), '_')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  base = _truncate(base, budget).replaceAll(RegExp(r'[. ]+$'), '');
  if (base.isEmpty || base == '.' || base == '..') {
    base = 'Canvas';
  }
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(base)) {
    base = '_$base';
  }
  base = _truncate(base, budget).replaceAll(RegExp(r'[. ]+$'), '');
  return '$base$extension';
}

String _truncate(String text, int maxBytes) {
  final result = StringBuffer();
  var bytes = 0;
  for (final rune in text.runes) {
    final scalar = String.fromCharCode(rune);
    final length = utf8.encode(scalar).length;
    if (bytes + length > maxBytes) {
      break;
    }
    result.write(scalar);
    bytes += length;
  }
  return result.toString();
}

Future<ProductionCanvasPackageSaveStatus> saveProductionCanvasPackage(
  File source, {
  required String title,
  void Function(double progress)? onProgress,
}) async {
  if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    _log.info('export stage=select result=unsupported');
    return ProductionCanvasPackageSaveStatus.failed;
  }
  String? path;
  try {
    path = (await getSaveLocation(
      suggestedName: productionCanvasPackageFileName(title),
      acceptedTypeGroups: const [_zipType],
    ))?.path;
  } catch (error) {
    _log.warning(
      'export stage=select result=failed errorType=${error.runtimeType}',
    );
    return ProductionCanvasPackageSaveStatus.failed;
  }
  if (path == null) {
    _log.info('export stage=select result=cancelled');
    return ProductionCanvasPackageSaveStatus.cancelled;
  }
  try {
    final total = await source.length();
    final sink = File(path).openWrite();
    var copied = 0;
    try {
      await for (final chunk in source.openRead()) {
        sink.add(chunk);
        copied += chunk.length;
        if (total > 0) {
          onProgress?.call(copied / total);
        }
      }
      await sink.flush();
      onProgress?.call(1);
    } finally {
      await sink.close();
    }
    _log.info('export stage=write result=success files=1');
    return ProductionCanvasPackageSaveStatus.saved;
  } catch (error) {
    _log.warning(
      'export stage=write result=failed files=1 errorType=${error.runtimeType}',
    );
    return ProductionCanvasPackageSaveStatus.failed;
  }
}

Future<String?> pickProductionCanvasPackage() async {
  if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    _log.info('import stage=select result=unsupported');
    return null;
  }
  try {
    final file = await openFile(acceptedTypeGroups: const [_zipType]);
    if (file == null) {
      _log.info('import stage=select result=cancelled');
      return null;
    }
    return file.path;
  } catch (error) {
    _log.warning(
      'import stage=select result=failed errorType=${error.runtimeType}',
    );
    return null;
  }
}
