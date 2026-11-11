// 职责: 管理角色共用音色并校验视频输入选用的角色参考音频。
// 关联文件:
//   lib/shared/models/character_voice.dart
//   lib/shared/models/production/input.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/services/production/generate_orchestrator.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
//   .agents/rules/error-handling.md
import 'package:drift/drift.dart';
import '../../database/novel_content_database.dart';
import '../../models/video/request.dart';
import '../storyboard/service.dart';
import 'canvas_service.dart';

extension ProductionVoices on ProductionCanvasService {
  Stream<CharacterProfile> watchVoiceCharacter(String characterId) =>
      (db.select(db.characterProfiles)..where(
            (t) =>
                t.id.equals(characterId) &
                t.deletedAt.equals(notDeletedSentinel),
          ))
          .watchSingle();

  Future<CharacterProfile?> inputCharacter(ProductionInput input) async {
    if (input.isPrompt ||
        input.refType != ProductionInputType.node ||
        input.role.kind != VideoMediaKind.image) {
      return null;
    }
    final node = await requireNode(input.refId);
    final clip = node.clipId == null ? null : await shots.getShot(node.clipId!);
    final id = clip?.characterId;
    return id == null ? null : db.characterProfileDao.getById(id);
  }

  Stream<CharacterProfile?> watchInputCharacter(ProductionInput input) => db
      .customSelect(
        'SELECT 1',
        readsFrom: {db.canvasNodes, db.productionClips, db.characterProfiles},
      )
      .watch()
      .asyncMap((_) => inputCharacter(input));

  /// 新接入视频的角色图片默认使用角色的首个音色；没有角色或音色时原样返回。
  Future<ProductionInput> withDefaultVoice(ProductionInput input) async {
    if (input.voiceAssetId != null) {
      return input;
    }
    final voices = (await inputCharacter(input))?.voices ?? const [];
    return voices.isEmpty ? input : input.withVoice(voices.first.assetId);
  }

  /// 列出视频输入里占用音频参考名额的条目，供超限提示区分自连音频与角色音色。
  /// 名称取不到（如音频节点尚未生成）时为 null，由界面显示占位文案。
  Future<({List<String?> audio, List<String?> voices})> audioInputNames(
    List<ProductionInput> inputs,
  ) async {
    final audio = <String?>[];
    final voices = <String?>[];
    for (final input in inputs.where((input) => !input.isPrompt)) {
      if (input.role.kind == VideoMediaKind.audio) {
        try {
          audio.add((await inputAsset(input)).name);
        } on StoryboardException {
          final node = input.sourceNodeId == null
              ? null
              : await db.canvasDao.getNodeById(input.sourceNodeId!);
          final clip = node?.clipId == null
              ? null
              : await shots.getShot(node!.clipId!);
          audio.add(clip?.title.trim().isEmpty ?? true ? null : clip!.title);
        }
      }
      if (input.voiceAssetId != null) {
        final character = await inputCharacter(input);
        final voice = (character?.voices ?? const <CharacterVoice>[])
            .where((v) => v.assetId == input.voiceAssetId)
            .firstOrNull;
        final name = voice?.name.isNotEmpty == true
            ? voice!.name
            : (await library.database.assetDao.getAsset(
                input.voiceAssetId!,
              ))?.name;
        voices.add(
          character == null || name == null
              ? name
              : '${character.name} · $name',
        );
      }
    }
    return (audio: audio, voices: voices);
  }

  Future<void> addCharacterVoice(String characterId, String assetId) =>
      _editCharacterVoices(characterId, (voices) async {
        final asset = await requireAsset(assetId, type: 'audio');
        await requireFile(asset.path!, type: 'audio');
        if (voices.any((v) => v.assetId == assetId)) {
          return voices;
        }
        final name = asset.source == 'bundled' && asset.name.endsWith('.wav')
            ? asset.name.substring(0, asset.name.length - 4)
            : asset.name;
        return [...voices, CharacterVoice(assetId: assetId, name: name)];
      });

  Future<void> renameCharacterVoice(
    String characterId,
    String assetId,
    String name,
  ) => _editCharacterVoices(characterId, (voices) async {
    if (!voices.any((v) => v.assetId == assetId)) {
      throw const StoryboardException('source_missing');
    }
    return [
      for (final voice in voices)
        voice.assetId == assetId ? voice.copyWith(name: name.trim()) : voice,
    ];
  });

  /// 只解除角色关联，已保存的镜头选择和音频资产仍保留。
  Future<void> removeCharacterVoice(String characterId, String assetId) =>
      _editCharacterVoices(
        characterId,
        (voices) async => voices.where((v) => v.assetId != assetId).toList(),
      );

  Future<void> _editCharacterVoices(
    String characterId,
    Future<List<CharacterVoice>> Function(List<CharacterVoice>) edit,
  ) => shots.write('UPDATE character_profiles.voices', characterId, () async {
    final character = await db.characterProfileDao.getById(characterId);
    if (character == null) {
      throw const StoryboardException('source_missing');
    }
    final voices = await edit(character.voices ?? const []);
    await (db.update(
      db.characterProfiles,
    )..where((t) => t.id.equals(characterId))).write(
      CharacterProfilesCompanion(
        voices: Value(voices),
        updatedAt: Value(DateTime.now()),
      ),
    );
  });

  Future<void> requireInputVoice(
    ProductionInput input, {
    bool requireBinding = false,
  }) async {
    final character = await inputCharacter(input);
    if (character == null ||
        input.voiceAssetId == null ||
        (requireBinding &&
            !(character.voices ?? const []).any(
              (v) => v.assetId == input.voiceAssetId,
            ))) {
      throw const StoryboardException('invalid_reference');
    }
    await requireAsset(input.voiceAssetId!, type: 'audio');
  }
}
