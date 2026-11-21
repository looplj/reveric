// 职责: 表达转录文本及以原素材起点为基准的可选时间戳。
// 关联文件:
//   lib/shared/services/ai/transcription/client.dart
//   lib/shared/services/production/transcription_service.dart

class TranscriptionException implements Exception {
  const TranscriptionException(this.code, [this.detail]);
  final String code;
  final String? detail;

  @override
  String toString() => 'TranscriptionException($code)';
}

class TranscriptSpan {
  TranscriptSpan(
    this.text,
    this.startUs,
    this.endUs, {
    this.speaker,
    List<TranscriptSpan> words = const [],
  }) : words = List.unmodifiable(words) {
    if (text.trim().isEmpty) {
      throw const FormatException('Empty transcript span');
    }
  }

  final String text;
  final int? startUs;
  final int? endUs;
  final String? speaker;
  final List<TranscriptSpan> words;

  TranscriptSpan shift(int offsetUs) => TranscriptSpan(
    text,
    startUs == null ? null : startUs! + offsetUs,
    endUs == null ? null : endUs! + offsetUs,
    speaker: speaker,
    words: words.map((word) => word.shift(offsetUs)).toList(),
  );

  Map<String, dynamic> toJson() => {
    'text': text,
    'start_us': ?startUs,
    'end_us': ?endUs,
    if (speaker != null) 'speaker': speaker,
    if (words.isNotEmpty) 'words': words.map((word) => word.toJson()).toList(),
  };

  factory TranscriptSpan.fromJson(Map<String, dynamic> json) => TranscriptSpan(
    json['text'] as String,
    json['start_us'] as int?,
    json['end_us'] as int?,
    speaker: json['speaker'] as String?,
    words: (json['words'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(TranscriptSpan.fromJson)
        .toList(),
  );
}

class Transcript {
  Transcript(
    String? text,
    List<TranscriptSpan> segments, {
    List<TranscriptSpan> words = const [],
  }) : text = text?.trim().isNotEmpty == true
           ? text!
           : segments.map((segment) => segment.text).join('\n'),
       segments = List.unmodifiable(
         segments.every((segment) => segment.startUs != null)
             ? ([...segments]..sort((a, b) => a.startUs!.compareTo(b.startUs!)))
             : segments,
       ),
       words = List.unmodifiable(words) {
    if (this.text.trim().isEmpty) {
      throw const TranscriptionException('no_speech');
    }
  }

  final String text;
  final List<TranscriptSpan> segments;
  final List<TranscriptSpan> words;

  Transcript shift(int offsetUs) => offsetUs == 0
      ? this
      : Transcript(
          text,
          segments.map((segment) => segment.shift(offsetUs)).toList(),
          words: words.map((word) => word.shift(offsetUs)).toList(),
        );

  Map<String, dynamic> toJson() => {
    'text': text,
    'segments': segments.map((segment) => segment.toJson()).toList(),
    if (words.isNotEmpty) 'words': words.map((word) => word.toJson()).toList(),
  };

  factory Transcript.fromJson(Map<String, dynamic> json) => Transcript(
    json['text'] as String?,
    (json['segments'] as List)
        .cast<Map<String, dynamic>>()
        .map(TranscriptSpan.fromJson)
        .toList(),
    words: (json['words'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(TranscriptSpan.fromJson)
        .toList(),
  );

  String toMarkdown() {
    if (segments.isEmpty) {
      return text;
    }
    return segments
        .map((segment) {
          final start = segment.startUs;
          final end = segment.endUs;
          return start == null || end == null
              ? segment.text
              : '**${_clock(start)} → ${_clock(end)}**\n\n${segment.text}';
        })
        .join('\n\n');
  }

  static String _clock(int us) {
    final duration = Duration(microseconds: us);
    final hours = duration.inHours.toString().padLeft(2, '0');
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    final milliseconds = (duration.inMilliseconds % 1000).toString().padLeft(
      3,
      '0',
    );
    return '$hours:$minutes:$seconds.$milliseconds';
  }
}
