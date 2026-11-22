// 职责: 将剧本文档和小说正文快照编译为受模型长度限制的朗读段落。
// 关联文件:
//   lib/shared/models/screenplay_document.dart
//   lib/shared/models/screenplay_element.dart
//   lib/shared/services/screenplay/narration_service.dart

import 'package:characters/characters.dart';
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
}

class NovelNarrationSource extends NarrationInput {
  const NovelNarrationSource(this.text);

  final String text;
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
  final Map<String, String> characterNames, locationNames;
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
    NovelNarrationSource(:final text) => _compileNovelNarration(
      text,
      settings.narrator,
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
  String text,
  String narrator,
  int maxCharacters,
) {
  final body = text.trim();
  if (body.isEmpty) {
    throw const AudioException('narration_empty');
  }
  final voice = narrator.trim();
  if (voice.isEmpty) {
    throw const AudioException('audio_voice_required');
  }
  final parts = splitNarrationText(
    body,
    maxCharacters,
  ).map((part) => part.trim());
  return List.unmodifiable([
    for (final part in parts)
      if (part.isNotEmpty)
        NarrationSegment(text: part, voice: voice, sceneId: null),
  ]);
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
