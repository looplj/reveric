// 职责: 验证朗读分声、场次边界、括注处理及长文本无损切分。
// 关联文件:
//   lib/shared/models/narration.dart
//   lib/shared/models/screenplay_document.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/audio/exception.dart';
import 'package:reveric/shared/models/narration.dart';
import 'package:reveric/shared/models/screenplay_document.dart';
import 'package:reveric/shared/models/screenplay_element.dart';

NarrationSource narrationFixture({String? startSceneId, bool orphan = false}) {
  var id = 0;
  ScreenplayElement e(
    ScreenplayElementType type, {
    String text = '',
    String? character,
    String scene = 's1',
  }) => ScreenplayElement(
    id: 'e${id++}',
    episodeId: 'ep',
    sceneId: scene,
    type: type,
    text: text,
    characterId: character,
    timeLabel: type == ScreenplayElementType.scene_heading ? '夜' : null,
  );
  return NarrationSource(
    startSceneId: startSceneId,
    characterNames: {'a': '甲', 'b': '乙'},
    locationNames: {},
    document: ScreenplayDocument(
      episodeId: 'ep',
      screenplayId: 'work',
      elements: [
        e(ScreenplayElementType.scene_heading),
        e(ScreenplayElementType.action, text: '雨落下来。'),
        e(ScreenplayElementType.character, character: 'a'),
        e(ScreenplayElementType.parenthetical, text: '低声'),
        e(ScreenplayElementType.dialogue, text: '走吧。'),
        e(ScreenplayElementType.note, text: '不要朗读这条笔记'),
        e(ScreenplayElementType.character, character: 'b'),
        e(ScreenplayElementType.dialogue, text: '等一下！'),
        e(ScreenplayElementType.scene_heading, scene: 's2'),
        if (!orphan)
          e(ScreenplayElementType.character, character: 'a', scene: 's2'),
        e(ScreenplayElementType.dialogue, text: '到了。', scene: 's2'),
      ],
      scenes: {
        's1': ScreenplayDocumentScene(id: 's1'),
        's2': ScreenplayDocumentScene(id: 's2'),
      },
    ),
  );
}

void main() {
  final settings = NarrationSettings(
    narrator: 'narrator',
    voices: {'a': 'voice-a', 'b': 'voice-b'},
  );
  test('novel snapshots use a single voice and skip blank segments', () {
    final segments = compileNarration(
      const NovelNarrationSource('　第一句。\n           第二句。　'),
      NarrationSettings(narrator: 'reader', includeNarration: false),
      maxCharacters: 5,
      supportsInstructions: true,
    );
    expect(segments.map((segment) => segment.text), ['第一句。', '第二句。']);
    for (final segment in segments) {
      expect(segment.voice, 'reader');
      expect(segment.characterId, isNull);
      expect(segment.instructions, isEmpty);
    }
    expect(
      () => compileNarration(
        const NovelNarrationSource('　\n '),
        settings,
        maxCharacters: 500,
        supportsInstructions: true,
      ),
      throwsA(
        isA<AudioException>().having(
          (error) => error.code,
          'code',
          'narration_empty',
        ),
      ),
    );
  });

  test('characters switch voices, directions do not enter spoken text', () {
    final segments = compileNarration(
      narrationFixture(),
      settings,
      maxCharacters: 500,
      supportsInstructions: true,
    );
    expect(segments.map((s) => s.text), [
      '夜',
      '雨落下来。',
      '走吧。',
      '等一下！',
      '夜',
      '到了。',
    ]);
    expect(segments.map((s) => s.voice), [
      'narrator',
      'narrator',
      'voice-a',
      'voice-b',
      'narrator',
      'voice-a',
    ]);
    expect(segments[2].instructions, '低声');
    expect(segments[3].instructions, isEmpty);
    expect(segments.last.instructions, isEmpty);
  });

  test(
    'current scene range and dialogue-only mode exclude prior scenes and narration',
    () {
      final segments = compileNarration(
        narrationFixture(startSceneId: 's2'),
        NarrationSettings(narrator: 'n', includeNarration: false),
        maxCharacters: 500,
        supportsInstructions: false,
      );
      expect(segments.single.text, '到了。');
      expect(segments.single.voice, 'n');
      final dialogue = compileNarration(
        narrationFixture(),
        NarrationSettings(narrator: 'n', includeNarration: false),
        maxCharacters: 500,
        supportsInstructions: false,
      );
      expect(dialogue.map((s) => s.text), ['走吧。', '等一下！', '到了。']);
      expect(dialogue.every((s) => s.instructions.isEmpty), isTrue);
    },
  );

  test('deleted character references fail before assigning a voice', () {
    final original = narrationFixture();
    final missing = NarrationSource(
      document: original.document,
      characterNames: {'b': '乙'},
      locationNames: {},
    );
    expect(
      () => compileNarration(
        missing,
        settings,
        maxCharacters: 500,
        supportsInstructions: true,
      ),
      throwsA(
        isA<AudioException>().having(
          (e) => e.code,
          'code',
          'narration_character_missing',
        ),
      ),
    );
  });

  test(
    'missing start scene is explicit and settings round trip preserve voice identities',
    () {
      expect(
        () => narrationFixture(startSceneId: 'missing').elements,
        throwsA(isA<AudioException>()),
      );
      final restored = NarrationSettings.fromJson(settings.toJson());
      expect(restored.voices, settings.voices);
      expect(restored.narrator, 'narrator');
    },
  );

  test(
    'long CJK text, punctuation and emoji are preserved within codepoint limits',
    () {
      final text = List.filled(120, '他说：“你好👩🏽‍🚀！”\n然后走开。é').join();
      final chunks = splitNarrationText(text, 57);
      expect(chunks.join(), text);
      expect(chunks.every((c) => c.runes.length <= 57 && c.isNotEmpty), isTrue);
      expect(splitNarrationText('第一句。第二句很长很长。', 8).first, '第一句。');
      expect(
        () => splitNarrationText('👩🏽‍🚀', 1),
        throwsA(isA<AudioException>()),
      );
    },
  );
}
