// 职责: 验证剧本导入原文的格式、空文件、总字数与单行字数校验，以及开场提示词拼接。
// 关联文件:
//   lib/shared/services/screenplay_import.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/services/screenplay_import.dart';

void main() {
  group('loadScreenplaySource', () {
    test('loads txt content with title and line count', () async {
      final source = await loadScreenplaySource(
        _textFile('/tmp/原著.TXT', '第一章\r\n正文\n结尾'),
      );

      expect(source.fileName, '原著.TXT');
      expect(source.title, '原著');
      expect(source.content, '第一章\r\n正文\n结尾');
      expect(source.lineCount, 3);
    });

    test('rejects unsupported and empty files', () async {
      await expectLater(
        loadScreenplaySource(_textFile('/tmp/data.csv', 'a,b')),
        throwsA(_failure(ScreenplaySourceFailure.unsupportedType)),
      );
      await expectLater(
        loadScreenplaySource(_textFile('/tmp/empty.md', ' \n ')),
        throwsA(_failure(ScreenplaySourceFailure.empty)),
      );
    });

    test('rejects files over the character limit', () async {
      final content = List.filled(
        screenplaySourceMaxCharacters ~/ 100 + 1,
        'a' * 99,
      ).join('\n');

      await expectLater(
        loadScreenplaySource(_textFile('/tmp/long.txt', content)),
        throwsA(_failure(ScreenplaySourceFailure.tooLarge)),
      );
    });

    test('rejects a line over the per-line limit', () async {
      final accepted = await loadScreenplaySource(
        _textFile('/tmp/ok.txt', '中' * screenplaySourceMaxLineCharacters),
      );
      expect(accepted.lineCount, 1);

      await expectLater(
        loadScreenplaySource(
          _textFile(
            '/tmp/wall.txt',
            '开头\n${'中' * (screenplaySourceMaxLineCharacters + 1)}',
          ),
        ),
        throwsA(_failure(ScreenplaySourceFailure.lineTooLong)),
      );
    });
  });

  test('kickoff prompt points to the material content path', () {
    final prompt = buildScreenplayImportKickoffPrompt(
      prompt: '帮我把这份文件改编为剧本。',
      materialTitle: '原著',
      lineCount: 120,
    );

    expect(prompt, startsWith('帮我把这份文件改编为剧本。\n\n'));
    expect(prompt, contains('materials/原著/content'));
    expect(prompt, contains('共 120 行'));
  });
}

XFile _textFile(String path, String content) {
  return XFile.fromData(
    Uint8List.fromList(utf8.encode(content)),
    path: path,
    name: path.split('/').last,
    mimeType: 'text/plain',
  );
}

Matcher _failure(ScreenplaySourceFailure failure) {
  return isA<ScreenplaySourceException>().having(
    (error) => error.failure,
    'failure',
    failure,
  );
}
