// 职责: 将各转写渠道的分段字段和时间单位转换为统一结果。
// 关联文件:
//   lib/shared/services/ai/transcription/client.dart
//   lib/shared/models/transcription/result.dart

import '../../../models/transcription/result.dart';

typedef JsonObject = Map<String, dynamic>;

List<JsonObject> _rows(Object? value) =>
    value == null ? const [] : (value as List).cast<JsonObject>();

TranscriptSpan? _span(
  JsonObject row, {
  required String start,
  required String end,
  required int scale,
  String text = 'text',
  String speaker = 'speaker',
  List<TranscriptSpan> words = const [],
}) {
  final value = row[text];
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  final startUs = _microseconds(row[start], scale);
  final endUs = _microseconds(row[end], scale);
  final timed =
      startUs != null && endUs != null && startUs >= 0 && endUs > startUs;
  return TranscriptSpan(
    value,
    timed ? startUs : null,
    timed ? endUs : null,
    speaker: row[speaker]?.toString(),
    words: words,
  );
}

List<TranscriptSpan> _spans(Iterable<TranscriptSpan?> spans) => [
  for (final span in spans)
    if (span != null) span,
];

int? _microseconds(Object? value, int scale) {
  if (value is! num) {
    return null;
  }
  final scaled = value * scale;
  return scaled.isFinite ? scaled.round() : null;
}

Transcript decodeOpenAiTranscript(JsonObject json) => Transcript(
  json['text'] as String?,
  _spans(
    _rows(
      json['segments'],
    ).map((row) => _span(row, start: 'start', end: 'end', scale: 1000000)),
  ),
  words: _spans(
    _rows(json['words']).map(
      (row) =>
          _span(row, start: 'start', end: 'end', scale: 1000000, text: 'word'),
    ),
  ),
);

Transcript decodeDashScopeTranscript(JsonObject json) {
  final channels = _rows(json['transcripts']);
  return Transcript(
    channels
        .map((channel) => channel['text'] as String? ?? '')
        .where((line) => line.isNotEmpty)
        .join('\n'),
    _spans([
      for (final channel in channels)
        for (final row in _rows(channel['sentences']))
          _span(
            row,
            start: 'begin_time',
            end: 'end_time',
            scale: 1000,
            speaker: 'speaker_id',
            words: _spans(
              _rows(row['words']).map(
                (word) => _span(
                  word,
                  start: 'begin_time',
                  end: 'end_time',
                  scale: 1000,
                ),
              ),
            ),
          ),
    ]),
  );
}

Transcript decodeVolcengineTranscript(JsonObject json) {
  final result = json['result'] as JsonObject;
  return Transcript(
    result['text'] as String?,
    _spans(
      _rows(result['utterances']).map(
        (row) => _span(
          row,
          start: 'start_time',
          end: 'end_time',
          scale: 1000,
          words: _spans(
            _rows(row['words']).map(
              (word) => _span(
                word,
                start: 'start_time',
                end: 'end_time',
                scale: 1000,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Transcript decodeAtlasTranscript(JsonObject json) {
  final result = json['stt_result'] as JsonObject?;
  final outputs = json['outputs'] as List?;
  final text = result?['text'] as String? ?? (outputs?.firstOrNull as String?);
  final spans = _rows(result?['words']);
  final segments = <TranscriptSpan>[];
  final words = <TranscriptSpan>[];
  for (final row in spans) {
    final span = _span(
      row,
      start: 'start',
      end: 'end',
      scale: 1000000,
      speaker: 'speaker_id',
    );
    if (span == null) {
      continue;
    }
    if (row['type'] == 'utterance') {
      segments.add(span);
    } else {
      words.add(span);
    }
  }
  // Some responses expose only a word timeline. Those intervals are still
  // provider timestamps and can be used directly as the smallest segments.
  return Transcript(text, segments.isEmpty ? words : segments, words: words);
}
