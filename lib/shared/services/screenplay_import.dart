// 职责: 剧本导入源文件 — 选择、解码并校验 txt/md 原文，生成指向资料原文的开场提示词。
// 关联文件:
//   lib/shared/utils/text_file_decoder.dart
//   lib/shared/services/novel_actions.dart
//   lib/shared/widgets/screenplay/import_dialog.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

import '../localization/locale_keys.dart';
import '../logger/app_logger.dart';
import '../utils/text_file_decoder.dart';

const int screenplaySourceMaxCharacters = 2000000;

/// Read 按行分页且不限单行字数，超长行会让一次读取撑爆上下文。
const int screenplaySourceMaxLineCharacters = 5000;

const int _maxUtf8BytesPerCharacter = 4;
const int _utf8BomByteCount = 3;

const _sourceTypeGroup = XTypeGroup(
  label: 'text',
  extensions: <String>['txt', 'md'],
  mimeTypes: <String>['text/plain', 'text/markdown'],
  uniformTypeIdentifiers: <String>[
    'public.plain-text',
    'net.daringfireball.markdown',
  ],
);

final _lineBreak = RegExp(r'\r\n|\r|\n');

final _log = AppLogger.forModule('ScreenplayImport');

enum ScreenplaySourceFailure {
  unsupportedType,
  empty,
  tooLarge,
  lineTooLong,
  readFailed,
}

class ScreenplaySourceException implements Exception {
  const ScreenplaySourceException(this.failure);

  final ScreenplaySourceFailure failure;

  @override
  String toString() => 'ScreenplaySourceException(${failure.name})';
}

String screenplaySourceFailureLocaleKey(ScreenplaySourceFailure failure) {
  return switch (failure) {
    ScreenplaySourceFailure.unsupportedType =>
      LocaleKeys.aiContextFileUnsupported,
    ScreenplaySourceFailure.empty => LocaleKeys.aiContextFileEmpty,
    ScreenplaySourceFailure.tooLarge =>
      LocaleKeys.libraryImportScreenplayTooLarge,
    ScreenplaySourceFailure.lineTooLong =>
      LocaleKeys.libraryImportScreenplayLineTooLong,
    ScreenplaySourceFailure.readFailed => LocaleKeys.aiContextFileReadFailed,
  };
}

/// 已读入内存的剧本原文，导入时整份存为资料。
class ScreenplaySource {
  const ScreenplaySource({
    required this.fileName,
    required this.content,
    required this.lineCount,
  });

  final String fileName;
  final String content;
  final int lineCount;

  /// 剧本与原文资料的标题，取文件名去扩展名。
  String get title => p.basenameWithoutExtension(fileName).trim();
}

Future<ScreenplaySource?> pickScreenplaySource() async {
  try {
    final file = await openFile(acceptedTypeGroups: const [_sourceTypeGroup]);
    if (file == null) {
      return null;
    }
    return await loadScreenplaySource(file);
  } on ScreenplaySourceException {
    rethrow;
  } catch (error, stackTrace) {
    _log.error(
      'failed to select screenplay source',
      error: error,
      stackTrace: stackTrace,
    );
    throw const ScreenplaySourceException(ScreenplaySourceFailure.readFailed);
  }
}

Future<ScreenplaySource> loadScreenplaySource(XFile file) async {
  final fileName = file.name.trim();
  final extension = p.extension(fileName).toLowerCase();
  if (extension != '.txt' && extension != '.md') {
    throw const ScreenplaySourceException(
      ScreenplaySourceFailure.unsupportedType,
    );
  }

  final String content;
  try {
    final byteLength = await file.length();
    if (byteLength >
        screenplaySourceMaxCharacters * _maxUtf8BytesPerCharacter +
            _utf8BomByteCount) {
      throw const ScreenplaySourceException(ScreenplaySourceFailure.tooLarge);
    }
    content = decodeImportedTextBytes(await file.readAsBytes());
  } on ScreenplaySourceException {
    rethrow;
  } catch (error, stackTrace) {
    _log.error(
      'failed to read screenplay source extension=$extension',
      error: error,
      stackTrace: stackTrace,
    );
    throw const ScreenplaySourceException(ScreenplaySourceFailure.readFailed);
  }

  if (content.trim().isEmpty) {
    throw const ScreenplaySourceException(ScreenplaySourceFailure.empty);
  }
  if (content.runes.length > screenplaySourceMaxCharacters) {
    throw const ScreenplaySourceException(ScreenplaySourceFailure.tooLarge);
  }
  final lines = content.split(_lineBreak);
  if (lines.any(
    (line) => line.runes.length > screenplaySourceMaxLineCharacters,
  )) {
    throw const ScreenplaySourceException(ScreenplaySourceFailure.lineTooLong);
  }
  return ScreenplaySource(
    fileName: fileName,
    content: content,
    lineCount: lines.length,
  );
}

/// 用户提示词后追加原文资料的位置，让 Agent 分段读取而不是一次读完。
String buildScreenplayImportKickoffPrompt({
  required String prompt,
  required String materialTitle,
  required int lineCount,
}) {
  return '$prompt\n\n'
      '原文已保存在资料 materials/$materialTitle/content，共 $lineCount 行，'
      '请用 Read 的 offset/limit 分段读取。';
}
