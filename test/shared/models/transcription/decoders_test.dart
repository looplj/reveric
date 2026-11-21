// 职责: 验证四家转录渠道的时间单位归一、缺失时间戳和空分段处理。
// 关联文件:
//   lib/shared/services/ai/transcription/decoders.dart
//   lib/shared/models/transcription/result.dart

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/transcription/result.dart';
import 'package:reveric/shared/services/ai/transcription/decoders.dart';

void main() {
  test('the four channel schemas normalize provider times to microseconds', () {
    final transcripts = [
      decodeOpenAiTranscript({
        'text': '你好',
        'segments': [
          {'start': 0.125, 'end': 0.5, 'text': '你好'},
        ],
      }),
      decodeDashScopeTranscript({
        'transcripts': [
          {
            'sentences': [
              {'begin_time': 125, 'end_time': 500, 'text': '你好'},
            ],
          },
        ],
      }),
      decodeVolcengineTranscript({
        'result': {
          'utterances': [
            {'start_time': 125, 'end_time': 500, 'text': '你好'},
          ],
        },
      }),
      decodeAtlasTranscript({
        'stt_result': {
          'words': [
            {'type': 'utterance', 'start': 0.125, 'end': 0.5, 'text': '你好'},
          ],
        },
      }),
    ];
    for (final transcript in transcripts) {
      expect(transcript.text, '你好');
      expect(transcript.segments.single.startUs, 125000);
      expect(transcript.segments.single.endUs, 500000);
      final offset = transcript.shift(250000);
      expect(offset.segments.single.startUs, 375000);
      expect(
        Transcript.fromJson(
          jsonDecode(jsonEncode(offset.toJson())) as JsonObject,
        ).toJson(),
        offset.toJson(),
      );
    }
  });

  test('a text-only result survives saving and becomes canvas text', () {
    final transcript = decodeOpenAiTranscript({'text': '你好'});
    expect(transcript.toJson(), {'text': '你好', 'segments': []});
    expect(Transcript.fromJson(transcript.toJson()).toMarkdown(), '你好');
  });

  test(
    'segments keep text even when some timestamps are absent or invalid',
    () {
      final transcript = decodeOpenAiTranscript({
        'segments': [
          {'text': '第一句'},
          {'text': '第二句', 'start': 1, 'end': 2},
          {'text': '第三句', 'start': 4, 'end': 3},
        ],
      }).shift(250000);
      expect(transcript.text, '第一句\n第二句\n第三句');
      expect(transcript.toJson()['segments'], [
        {'text': '第一句'},
        {'text': '第二句', 'start_us': 1250000, 'end_us': 2250000},
        {'text': '第三句'},
      ]);
      expect(
        Transcript.fromJson(transcript.toJson()).toMarkdown(),
        '第一句\n\n**00:00:01.250 → 00:00:02.250**\n\n第二句\n\n第三句',
      );
    },
  );

  test('blank segments and words are omitted from the transcript', () {
    final transcript = decodeOpenAiTranscript({
      'text': '你好',
      'segments': [
        {'text': ' '},
        {'text': '你好', 'start': 0, 'end': 1},
        {'text': ''},
      ],
      'words': [
        {'word': ''},
        {'word': '你好', 'start': 0, 'end': 1},
      ],
    });
    expect(transcript.segments.single.text, '你好');
    expect(transcript.words.single.text, '你好');
    expect(
      decodeDashScopeTranscript({
        'transcripts': [
          {
            'text': '你好',
            'sentences': [
              {'text': ' ', 'words': []},
              {
                'text': '你好',
                'words': [
                  {'text': ''},
                  {'text': '你'},
                ],
              },
            ],
          },
        ],
      }).segments.single.words.single.text,
      '你',
    );
  });

  test('empty speech still returns no_speech', () {
    expect(
      () => decodeOpenAiTranscript({'text': '', 'segments': []}),
      throwsA(
        isA<TranscriptionException>().having(
          (error) => error.code,
          'code',
          'no_speech',
        ),
      ),
    );
  });
}
