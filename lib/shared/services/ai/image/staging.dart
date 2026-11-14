// 职责: 按任务归属、确认回执与内容摘要核对图片暂存清单，恢复候选并清理已登记副本。
// 关联文件:
//   lib/shared/services/plugins/media_files.dart
//   lib/shared/services/production/image_service.dart
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../../../models/generation/provider_result.dart';
import '../../../models/generation/task.dart';
import '../../../utils/storage_paths.dart';
import '../../../logger/app_logger.dart';

final _log = AppLogger.forModule('ImageStaging');

class ImageStagingSnapshot {
  const ImageStagingSnapshot({this.outputs, required this.hasUnconfirmed});
  final List<ImageTaskOutput>? outputs;
  final bool hasUnconfirmed;
}

Future<Map<String, Map<String, dynamic>>> _records(
  String taskId,
  String providerId,
  String providerType,
) async {
  final directory = Directory(
    p.join(RevericPaths.fileWorkspaceParent, 'file_workspaces'),
  );
  if (!await directory.exists()) {
    return {};
  }
  final values = <String, Map<String, dynamic>>{};
  final identity = providerType.startsWith('plugin:')
      ? providerType.substring(7)
      : providerType;
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File ||
        !RegExp(r'^[a-f0-9-]{36}\.json$').hasMatch(p.basename(entity.path))) {
      continue;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(await entity.readAsString());
    } on FormatException catch (error, stack) {
      _log.error(
        'Incomplete staging ownership record name=${p.basename(entity.path)}',
        error: error,
        stackTrace: stack,
      );
      continue;
    }
    if (decoded is! Map<String, dynamic> || decoded['taskId'] != taskId) {
      continue;
    }
    if (decoded['providerId'] != providerId ||
        decoded['pluginId'] != identity) {
      throw const FormatException('Staging owner does not match task');
    }
    final handle = decoded['handle'];
    final path = decoded['path'];
    if (handle is! String ||
        p.basename(entity.path) != '$handle.json' ||
        path is! String ||
        !p.equals(
          p.dirname(p.normalize(p.absolute(path))),
          p.normalize(directory.absolute.path),
        ) ||
        !p.basename(path).startsWith('reveric_image_result_$handle.') ||
        !path.endsWith('.part')) {
      throw const FormatException('Invalid staging path');
    }
    values[handle] = decoded;
  }
  return values;
}

Future<void> _verify(
  Map<String, dynamic> record,
  ProviderFileOutput output,
) async {
  final path = record['path'] as String;
  if (record['mimeType'] != output.mimeType ||
      record['byteLength'] != output.byteLength ||
      record['sha256'] is! String ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(record['sha256'] as String) ||
      await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
    throw const FormatException('Invalid staged image metadata');
  }
  final file = File(path);
  if (await file.length() != output.byteLength ||
      (await sha256.bind(file.openRead()).first).toString() !=
          record['sha256']) {
    throw const FormatException('Staged image content changed');
  }
}

Future<ImageStagingSnapshot> readImageStaging({
  required String taskId,
  required String providerId,
  required String providerType,
  List<ImageTaskOutput>? existing,
}) async {
  final records = await _records(taskId, providerId, providerType);
  final confirmed =
      records.values
          .where(
            (record) =>
                record['confirmed'] == true && record['receipt'] is List,
          )
          .toList()
        ..sort(
          (a, b) =>
              (b['confirmedAt'] as int).compareTo(a['confirmedAt'] as int),
        );
  if (confirmed.isEmpty) {
    return ImageStagingSnapshot(hasUnconfirmed: records.isNotEmpty);
  }
  final receipt = ProviderSucceeded.fromJson({
    'status': 'succeeded',
    'outputs': confirmed.first['receipt'],
  });
  if (existing != null && existing.length != receipt.outputs.length) {
    throw const FormatException('Staging candidate count changed');
  }
  final result = <ImageTaskOutput>[];
  for (final (index, output) in receipt.outputs.indexed) {
    final saved = existing == null ? null : existing[index];
    if (saved?.path != null || saved?.assetId != null) {
      result.add(saved!);
      continue;
    }
    if (output is ProviderUrlOutput) {
      result.add(saved ?? ImageTaskOutput(url: output.url));
    } else {
      final file = output as ProviderFileOutput;
      final record = records[file.handle];
      if (record == null) {
        throw const FormatException('Staged output has no ownership record');
      }
      await _verify(record, file);
      final path = RevericPaths.toRelative(record['path'] as String);
      if (path == null) {
        throw const FormatException(
          'Staged output is outside application storage',
        );
      }
      result.add(ImageTaskOutput(path: path, hash: record['sha256'] as String));
    }
  }
  return ImageStagingSnapshot(
    outputs: result,
    hasUnconfirmed: records.values.any((record) => record['confirmed'] != true),
  );
}

/// Only confirmed, task-owned temporary bytes already registered with the same hash are removed.
Future<void> cleanupRegisteredImageStaging({
  required String taskId,
  required String providerId,
  required String providerType,
  required Set<String> registeredHashes,
}) async {
  final records = await _records(taskId, providerId, providerType);
  final accepted = <String>{};
  for (final record in records.values.where(
    (record) => record['confirmed'] == true && record['receipt'] is List,
  )) {
    final receipt = ProviderSucceeded.fromJson({
      'status': 'succeeded',
      'outputs': record['receipt'],
    });
    accepted.addAll(
      receipt.outputs.whereType<ProviderFileOutput>().map(
        (file) => file.handle,
      ),
    );
  }
  for (final handle in accepted) {
    final record = records[handle];
    if (record == null || !registeredHashes.contains(record['sha256'])) {
      continue;
    }
    final file = File(record['path'] as String);
    if (await file.exists()) {
      await _verify(
        record,
        ProviderFileOutput(
          handle: handle,
          mimeType: record['mimeType'] as String,
          byteLength: record['byteLength'] as int,
        ),
      );
      await file.delete();
    }
    await File(p.join(file.parent.path, '$handle.json')).delete();
  }
}
