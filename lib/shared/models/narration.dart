// 职责: 将剧本文档和小说正文快照编译为受模型长度限制的朗读段落。
// 关联文件:
//   lib/shared/models/screenplay_document.dart
//   lib/shared/models/screenplay_element.dart
//   lib/shared/services/screenplay/narration_service.dart
//   lib/shared/utils/chapter_entity_recognition.dart

import 'package:characters/characters.dart';
import '../database/novel_content_database.dart' show entityTypeCharacter;
import '../utils/chapter_entity_recognition.dart';
import 'audio/exception.dart';
import 'screenplay_document.dart';
import 'screenplay_element.dart';

class NarrationSettings {
  NarrationSettings({
    this.providerId = '',
    this.modelId = '',
    this.narrator = '',
    this.includeNarration = true,
    Map<String, String> voices = const {},
  }) : voices = Map.unmodifiable(voices);

  final String providerId, modelId, narrator;
  final bool includeNarration;
  final Map<String, String> voices;

  Map<String, Object> toJson() => {
    'providerId': providerId,
    'modelId': modelId,
    'narrator': narrator,
    'includeNarration': includeNarration,
    'voices': voices,
  };

  factory NarrationSettings.fromJson(Map<String, dynamic> json) =>
      NarrationSettings(
        providerId: json['providerId'] as String,
        modelId: json['modelId'] as String,
        narrator: json['narrator'] as String,
        includeNarration: json['includeNarration'] as bool,
        voices: Map<String, String>.from(json['voices'] as Map),
      );
}

sealed class NarrationInput {
  const NarrationInput();

  Map<String, String> get characterNames;
  Set<String> get characterIds;
}

typedef NarrationCharacter = ({String id, String name, List<String> aliases});

class NovelNarrationSource extends NarrationInput {
  NovelNarrationSource(
    this.text, {
    Iterable<NarrationCharacter> characters = const [],
  }) : _characters = List.unmodifiable(characters);

  final String text;
  final List<NarrationCharacter> _characters;
  late final _reading = _parseNovelNarration(text, _characters);

  @override
  Map<String, String> get characterNames => _reading.names;

  @override
  Set<String> get characterIds => characterNames.keys.toSet();

  late final bool hasUnattributedDialogue = _reading.parts.any(
    (part) => part.dialogue && part.characterId == null,
  );
}

class NarrationSource extends NarrationInput {
  NarrationSource({
    required this.document,
    required Map<String, String> characterNames,
    required Map<String, String> locationNames,
    this.startSceneId,
  }) : characterNames = Map.unmodifiable(characterNames),
       locationNames = Map.unmodifiable(locationNames);

  final ScreenplayDocument document;
  @override
  final Map<String, String> characterNames;
  final Map<String, String> locationNames;
  final String? startSceneId;

  List<ScreenplayElement> get elements {
    if (startSceneId == null) {
      return document.elements;
    }
    final index = document.elements.indexWhere(
      (e) => e.isHeading && e.sceneId == startSceneId,
    );
    if (index < 0) {
      throw const AudioException('narration_scene_missing');
    }
    return document.elements.sublist(index);
  }

  @override
  Set<String> get characterIds => {
    for (final e in elements)
      if (e.type == ScreenplayElementType.character) e.characterId!,
  };
}

class NarrationSegment {
  const NarrationSegment({
    required this.text,
    required this.voice,
    required this.sceneId,
    this.characterId,
    this.instructions = '',
  });
  final String text, voice, instructions;
  final String? sceneId, characterId;
  (String, String, String) get cacheKey => (text, voice, instructions);
}

List<NarrationSegment> compileNarration(
  NarrationInput source,
  NarrationSettings settings, {
  required int maxCharacters,
  required bool supportsInstructions,
}) {
  if (maxCharacters <= 0) {
    throw const AudioException('invalid_config');
  }
  return switch (source) {
    NovelNarrationSource() => _compileNovelNarration(
      source,
      settings,
      maxCharacters,
    ),
    NarrationSource() => _compileScreenplayNarration(
      source,
      settings,
      maxCharacters,
      supportsInstructions,
    ),
  };
}

List<NarrationSegment> _compileNovelNarration(
  NovelNarrationSource source,
  NarrationSettings settings,
  int maxCharacters,
) {
  if (source.text.trim().isEmpty) {
    throw const AudioException('narration_empty');
  }
  final narrator = settings.narrator.trim();
  if (narrator.isEmpty) {
    throw const AudioException('audio_voice_required');
  }
  final segments = <NarrationSegment>[];
  void append(String text, String? characterId) {
    final selected = settings.voices[characterId]?.trim() ?? '';
    for (final part in splitNarrationText(text.trim(), maxCharacters)) {
      if (part.trim().isNotEmpty) {
        segments.add(
          NarrationSegment(
            text: part.trim(),
            voice: selected.isEmpty ? narrator : selected,
            sceneId: null,
            characterId: characterId,
          ),
        );
      }
    }
  }

  final prose = StringBuffer();
  for (final part in source._reading.parts) {
    if (settings.includeNarration) {
      if (part.characterId == null) {
        prose.write(part.text);
        continue;
      }
      append(prose.toString(), null);
      prose.clear();
      append(part.text, part.characterId);
    } else if (part.dialogue) {
      append(part.text.substring(1, part.text.length - 1), part.characterId);
    }
  }
  append(prose.toString(), null);
  if (segments.isEmpty) {
    throw const AudioException('narration_no_dialogue');
  }
  return List.unmodifiable(segments);
}

typedef _NovelPart = ({String text, bool dialogue, String? characterId});

final _dialogueQuotes = RegExp(
  r'“[^“”]+”|「[^「」]+」|『[^『』]+』|‘[^‘’]+’|"[^"\r\n]+"',
);
const _speechVerb =
    r'(?:说(?:道)?|问(?:道)?|答(?:道)?|回答(?:道)?|喊(?:道)?|叫(?:道)?|'
    r'应道|念道|笑道|低语|嘀咕(?:道)?|said|asked|replied|answered|'
    r'whispered|shouted|murmured|muttered|added)';
const _speechModifier = r'(?:轻声|低声|小声|大声|冷冷地|笑着|低声地|轻轻地)?';
final _dialogueColon = RegExp(r'[:：][ \t]*$');
final _prefixStart = RegExp(r'(?:^|[。！？!?.；;，,\r\n])[ \t\u3000]*$');
final _prefixEnd = RegExp(
  r'^[ \t]*(?:[:：]|'
  '$_speechModifier$_speechVerb'
  r'[ \t]*[:：,，]?)[ \t]*$',
  caseSensitive: false,
);
final _suffixStart = RegExp(r'^[ \t]*[,，]?[ \t]*$');
final _suffixEnd = RegExp(
  r'^[ \t]*'
  '$_speechModifier$_speechVerb'
  r'(?=$|[ \t。！？!?.；;，,：:\r\n])',
  caseSensitive: false,
);

bool _introducesDialogue(String text, ChapterEntityMatch mention) =>
    _prefixEnd.hasMatch(text.substring(mention.end)) &&
    _prefixStart.hasMatch(text.substring(0, mention.start));

({List<_NovelPart> parts, Map<String, String> names}) _parseNovelNarration(
  String text,
  List<NarrationCharacter> characters,
) {
  final namesById = {for (final entry in characters) entry.id: entry.name};
  final idsByName = <String, Set<String>>{};
  for (final character in characters) {
    for (final name in [character.name, ...character.aliases]) {
      final key = name.trim();
      if (key.isNotEmpty) {
        (idsByName[key] ??= {}).add(character.id);
      }
    }
  }
  final catalog = [
    for (final entry in idsByName.entries)
      ChapterEntityMention(
        entityType: entityTypeCharacter,
        id: entry.value.first,
        label: entry.key,
      ),
  ]..sort((a, b) => b.label.length.compareTo(a.label.length));

  final quotes = _dialogueQuotes.allMatches(text).iterator;
  var hasQuote = quotes.moveNext();
  var offset = 0;
  var beforeMentions = hasQuote
      ? findChapterEntityMatches(
          text.substring(0, quotes.current.start),
          catalog,
        )
      : const <ChapterEntityMatch>[];
  final parts = <_NovelPart>[];
  final speakers = <String, String>{};
  while (hasQuote) {
    final quote = quotes.current;
    hasQuote = quotes.moveNext();
    final before = text.substring(offset, quote.start);
    final after = text.substring(
      quote.end,
      hasQuote ? quotes.current.start : text.length,
    );
    final afterMentions = findChapterEntityMatches(after, catalog);
    final candidates = <String>{};
    for (final mention in beforeMentions.reversed) {
      if (_introducesDialogue(before, mention)) {
        candidates.addAll(idsByName[mention.entity.label]!);
        break;
      }
    }
    final firstAfter = afterMentions.firstOrNull;
    if (firstAfter != null &&
        _suffixStart.hasMatch(after.substring(0, firstAfter.start)) &&
        _suffixEnd.hasMatch(after.substring(firstAfter.end))) {
      final introducesNext =
          hasQuote &&
          _introducesDialogue(after, firstAfter) &&
          (_dialogueColon.hasMatch(after) || candidates.isNotEmpty);
      if (!introducesNext) {
        candidates.addAll(idsByName[firstAfter.entity.label]!);
      }
    }
    final speaker = candidates.length == 1 ? candidates.single : null;
    if (speaker != null) {
      speakers[speaker] = namesById[speaker]!;
    }
    parts.add((text: before, dialogue: false, characterId: null));
    parts.add((text: quote[0]!, dialogue: true, characterId: speaker));
    offset = quote.end;
    beforeMentions = afterMentions;
  }
  parts.add((text: text.substring(offset), dialogue: false, characterId: null));
  return (parts: parts, names: Map.unmodifiable(speakers));
}

List<NarrationSegment> _compileScreenplayNarration(
  NarrationSource source,
  NarrationSettings settings,
  int maxCharacters,
  bool supportsInstructions,
) {
  final segments = <NarrationSegment>[];
  String? speaker;
  var extension = '';
  var direction = '';
  for (final element in source.elements) {
    String? text;
    String? characterId;
    var instructions = '';
    switch (element.type) {
      case ScreenplayElementType.scene_heading:
        speaker = null;
        extension = direction = '';
        if (settings.includeNarration) {
          if (element.locationId != null &&
              !source.locationNames.containsKey(element.locationId)) {
            throw const AudioException('narration_location_missing');
          }
          text = [
            source.document.scenes[element.sceneId]?.title ?? '',
            if (element.interiorExterior != null)
              switch (element.interiorExterior) {
                'interior' => '内景',
                'exterior' => '外景',
                _ => '内外景',
              },
            source.locationNames[element.locationId] ?? '',
            element.timeLabel ?? '',
          ].where((s) => s.trim().isNotEmpty).join('，');
        }
      case ScreenplayElementType.character:
        speaker = element.characterId;
        extension = element.extension;
        direction = '';
      case ScreenplayElementType.parenthetical:
        direction = element.text;
      case ScreenplayElementType.dialogue:
        if (speaker == null || !source.characterNames.containsKey(speaker)) {
          throw const AudioException('narration_character_missing');
        }
        characterId = speaker;
        text = element.text;
        if (supportsInstructions) {
          instructions = [
            extension,
            direction,
          ].where((s) => s.trim().isNotEmpty).join('；');
        }
      case ScreenplayElementType.action:
      case ScreenplayElementType.subtitle:
        speaker = null;
        extension = direction = '';
        if (settings.includeNarration) {
          text = element.text;
        }
      case ScreenplayElementType.transition:
        speaker = null;
        extension = direction = '';
      case ScreenplayElementType.note:
        break;
    }
    if (text == null || text.trim().isEmpty) {
      continue;
    }
    final voice = (settings.voices[characterId] ?? settings.narrator).trim();
    if (voice.isEmpty) {
      throw const AudioException('audio_voice_required');
    }
    for (final part in splitNarrationText(text.trim(), maxCharacters)) {
      segments.add(
        NarrationSegment(
          text: part,
          voice: voice,
          sceneId: element.sceneId,
          characterId: characterId,
          instructions: instructions,
        ),
      );
    }
  }
  if (segments.isEmpty) {
    throw const AudioException('narration_empty');
  }
  return List.unmodifiable(segments);
}

/// 按句界优先切分，保留原文和 Unicode 字素；长度口径与音频请求的 runes 一致。
List<String> splitNarrationText(String text, int limit) {
  if (limit <= 0) {
    throw ArgumentError.value(limit, 'limit');
  }
  final result = <String>[];
  var buffer = <String>[];
  var size = 0;
  var boundary = 0;
  for (final character in text.characters) {
    final length = character.runes.length;
    if (length > limit) {
      throw const AudioException('audio_prompt_length');
    }
    if (size + length > limit) {
      final cut = boundary > 0 ? boundary : buffer.length;
      result.add(buffer.take(cut).join());
      buffer = buffer.skip(cut).toList();
      size = buffer.join().runes.length;
      boundary = 0;
      // A short suffix after a sentence boundary may still fill the next chunk.
      if (size + length > limit) {
        result.add(buffer.join());
        buffer = [];
        size = 0;
      }
    }
    buffer.add(character);
    size += length;
    if (RegExp(r'[。！？!?\n；;.]').hasMatch(character)) {
      boundary = buffer.length;
    }
  }
  if (buffer.isNotEmpty) {
    result.add(buffer.join());
  }
  return result;
}
