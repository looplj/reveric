// 职责: 通过 Android SAF 读写用户选择的目录，承接文档与 AgentSkill 的移动端导入导出
// 关联文件:
//   lib/mobile/pages/novel_editor_page.dart
//   android/app/src/main/kotlin/ai/reveric/MainActivity.kt
//   lib/shared/services/documents_service.dart
//   lib/shared/services/agent_skill_transfer.dart
//   lib/shared/logger/app_logger.dart
import 'dart:io';
import 'package:flutter/services.dart';

import '../../shared/logger/app_logger.dart';
import '../../shared/models/agent_skill_reference.dart';
import '../../shared/services/agent_skill_package.dart';

final _log = AppLogger.forModule('AndroidSafDirectoryImport');

const _channel = MethodChannel('reveric/android_directory_import');

const androidDocumentImportExtensions = <String>{'txt', 'md', 'csv'};

typedef AndroidSafSkillCandidate = ({
  String id,
  String path,
  String markdown,
  bool hasScripts,
});

class AndroidSafSkillDirectory {
  const AndroidSafSkillDirectory(this._token, this.candidates);
  final String _token;
  final List<AndroidSafSkillCandidate> candidates;

  Future<void> copyPackage(String id, Directory destination) async {
    try {
      await _channel.invokeMethod<void>('copySkillPackage', {
        'token': _token,
        'id': id,
        'path': destination.path,
      });
    } on PlatformException catch (error) {
      if (error.code == 'skill_package_too_large') {
        throw const AgentSkillImportLimitException();
      }
      if (error.code == 'skill_package_unavailable') {
        throw const FileSystemException(
          'Selected Android skill is unavailable',
        );
      }
      rethrow;
    }
  }

  Future<void> close() async {
    await _channel.invokeMethod<void>('closeSkillDirectory', {'token': _token});
  }
}

Future<AndroidSafSkillDirectory?> scanAndroidSkillDirectory() async {
  final Map<Object?, Object?>? result;
  try {
    result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'scanSkillDirectory',
      {
        'ignored': agentSkillIgnoredDirectories.toList(growable: false),
        'referenceExtensions': [
          for (final ext in AgentSkillReferences.allowedExtensions)
            ext.substring(1),
        ],
        'scriptExtensions': [
          for (final ext in agentSkillScriptExtensions) ext.substring(1),
        ],
        'packageBytes': agentSkillMaxPackageBytes,
        'packageFiles': agentSkillMaxPackageFiles,
        'markdownBytes': agentSkillMaxMarkdownBytes,
        'scanEntries': agentSkillMaxScanEntries,
        'candidates': agentSkillMaxCandidates,
        'scanMarkdownBytes': agentSkillMaxScanMarkdownBytes,
        'referenceBytes': AgentSkillReferences.maxContentBytes,
        'totalReferenceBytes': AgentSkillReferences.maxTotalContentBytes,
        'referenceCount': AgentSkillReferences.maxCount,
      },
    );
  } on PlatformException catch (error) {
    if (error.code == 'skill_package_too_large') {
      throw const AgentSkillImportLimitException();
    }
    rethrow;
  }
  if (result == null) {
    return null;
  }
  final token = result['token'];
  final skills = result['skills'];
  if (token is! String || skills is! List) {
    throw const FormatException(
      'Android skill directory returned an invalid result',
    );
  }
  try {
    final candidates = <AndroidSafSkillCandidate>[];
    for (final skill in skills) {
      if (skill case {
        'id': final String id,
        'path': final String path,
        'markdown': final String markdown,
        'hasScripts': final bool hasScripts,
      }) {
        candidates.add((
          id: id,
          path: path,
          markdown: markdown,
          hasScripts: hasScripts,
        ));
      } else {
        throw const FormatException(
          'Android skill directory returned an invalid candidate',
        );
      }
    }
    _log.info(
      'Android skill directory scanned candidates=${candidates.length}',
    );
    return AndroidSafSkillDirectory(token, candidates);
  } on FormatException {
    await _channel.invokeMethod<void>('closeSkillDirectory', {'token': token});
    rethrow;
  }
}

class AndroidSafDirectoryExportResult {
  const AndroidSafDirectoryExportResult({
    required this.directoryName,
    required this.fileCount,
  });

  final String directoryName;
  final int fileCount;
}

class AndroidSafDirectoryImportResult {
  const AndroidSafDirectoryImportResult({
    required this.directoryPath,
    required this.directoryName,
    required this.fileCount,
    required this.directoryCount,
  });

  final String directoryPath;
  final String directoryName;
  final int fileCount;
  final int directoryCount;
}

Future<AndroidSafDirectoryImportResult?> pickAndCopyAndroidDirectory({
  Set<String> extensions = androidDocumentImportExtensions,
}) async {
  final rawResult = await _channel.invokeMethod<Map<Object?, Object?>>(
    'pickAndCopyDirectory',
    <String, Object>{
      'extensions': extensions
          .map((extension) => extension.toLowerCase().replaceFirst('.', ''))
          .toList(growable: false),
    },
  );
  if (rawResult == null) {
    _log.info('directory selection cancelled');
    return null;
  }

  final path = rawResult['path'];
  final name = rawResult['name'];
  final fileCount = rawResult['fileCount'];
  final directoryCount = rawResult['directoryCount'];
  if (path is! String ||
      name is! String ||
      fileCount is! int ||
      directoryCount is! int) {
    throw const FormatException(
      'Android directory import returned an invalid result.',
    );
  }

  _log.info(
    'directory copied to app cache files=$fileCount directories=$directoryCount',
  );
  return AndroidSafDirectoryImportResult(
    directoryPath: path,
    directoryName: name,
    fileCount: fileCount,
    directoryCount: directoryCount,
  );
}

Future<void> deleteAndroidDirectoryImport(String directoryPath) async {
  try {
    final directory = Directory(directoryPath);
    if (await directory.exists()) {
      await directory.delete(recursive: true);
      _log.info('temporary directory deleted');
    }
  } on FileSystemException catch (error, stackTrace) {
    _log.warning('temporary directory cleanup failed: $error\n$stackTrace');
  }
}

Future<AndroidSafDirectoryExportResult?> exportAndroidSkillDirectory(
  Directory directory,
) async {
  final rawResult = await _channel.invokeMethod<Map<Object?, Object?>>(
    'exportSkillDirectory',
    {'path': directory.path},
  );
  if (rawResult == null) {
    _log.info('directory export selection cancelled');
    return null;
  }
  final name = rawResult['name'];
  final count = rawResult['fileCount'];
  if (name is! String || count is! int) {
    throw const FormatException(
      'Android directory export returned an invalid result.',
    );
  }
  _log.info('files written to selected Android directory count=$count');
  return AndroidSafDirectoryExportResult(directoryName: name, fileCount: count);
}
