// 职责: 从保存后的制作配置和有序输入编译请求预览并创建唯一来源的视频任务。
// 关联文件:
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/services/ai/video/task_service.dart
//   lib/shared/models/video/request.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
import 'dart:io';
import '../../database/novel_content_database.dart';
import '../../models/ai_provider.dart' show aiProviderTypeConfigFor;
import '../../models/storyboard/prompt.dart';
import '../../models/video/request.dart';
import '../../models/video/channels.dart';
import '../../models/video/capabilities.dart';
import '../../models/video/task_result.dart';
import '../ai/video/draft.dart';
import '../ai/video/task_service.dart';
import '../storyboard/service.dart';
import 'canvas_service.dart';
import 'voices.dart';

VideoProtocol productionProtocol(String type) =>
    aiProviderTypeConfigFor(type)?.videoProtocol ??
    (throw const StoryboardException('invalid_config'));

/// 制作只允许渠道登记了能力的型号；底层视频接口本身不拦截未登记型号。
bool productionSupportsVideoModel(String providerType, String? modelId) =>
    lookupVideoChannelModel(providerType, modelId) != null;

VideoRequest shotVideoRequest(ProductionClipRow shot) => VideoRequest(
  modelId: shot.modelId ?? '',
  prompt: shot.prompt,
  mode: VideoMode.values.byName(shot.referenceMode),
  resolution: shot.resolution,
  ratio: shot.ratio,
  durationSeconds: (shot.durationMs ?? 0) ~/ 1000,
  audio: shot.generateAudio,
);

/// 用户只选两种生成方式：全参考（不挂输入就是文生视频）和首尾帧（只挂首帧是它的子集）。
/// 接口用的方式由 [productionSubmitMode] 按实际发送的输入算。
bool productionUsesFrames(VideoMode mode) => mode == VideoMode.first_last_frame;

/// 当前组别参与提交校验的用途；全参考模式保留各类帧的编辑用途。
List<VideoInputRole> productionRoles(VideoMode mode) =>
    productionUsesFrames(mode)
    ? const [
        VideoInputRole.first_frame,
        VideoInputRole.middle_frame,
        VideoInputRole.last_frame,
      ]
    : const [
        VideoInputRole.reference_image,
        VideoInputRole.reference_video,
        VideoInputRole.reference_audio,
        VideoInputRole.first_frame,
        VideoInputRole.last_frame,
        VideoInputRole.middle_frame,
      ];

/// 全参考模式保留编辑用途，发送时把首帧、中间帧和尾帧作为普通参考图。
VideoInputRole productionSubmitRole(VideoMode mode, VideoInputRole role) =>
    (mode == VideoMode.reference || mode == VideoMode.text) &&
        (role == VideoInputRole.first_frame ||
            role == VideoInputRole.last_frame ||
            role == VideoInputRole.middle_frame)
    ? VideoInputRole.reference_image
    : role;

/// 组别 + 实际发送的输入 → 接口要求的生成方式。
VideoMode productionSubmitMode(
  VideoMode mode,
  Iterable<VideoInputRole> roles,
) => productionUsesFrames(mode)
    ? (roles.contains(VideoInputRole.last_frame) ||
              roles.contains(VideoInputRole.middle_frame)
          ? VideoMode.first_last_frame
          : VideoMode.first_frame)
    : (roles.isEmpty ? VideoMode.text : VideoMode.reference);

/// 以稳定身份展开角色选中的音色，编号与普通音频共同按最终输入顺序分配。
List<ProductionInput> productionInputsWithVoices(
  List<ProductionInput> inputs,
) => [
  for (final input in inputs) ...[
    input,
    if (input.voiceAssetId != null)
      ProductionInput(
        id: input.voiceInputId,
        refType: ProductionInputType.asset,
        refId: input.voiceAssetId!,
        role: VideoInputRole.reference_audio,
      ),
  ],
];

class ResolvedProductionInput {
  const ResolvedProductionInput(this.input, this.assetId);
  final ProductionInput input;
  final String assetId;
  VideoInputRole get role => input.role;
  String get id => input.id;
}

List<VideoReferenceSlot> productionSlots(
  VideoProtocol protocol,
  List<ResolvedProductionInput> inputs, {
  required VideoMode mode,
  bool indexedKeyframes = false,
}) {
  final imageOrder = [
    if (mode == VideoMode.first_frame || mode == VideoMode.first_last_frame)
      for (final role in [
        VideoInputRole.first_frame,
        VideoInputRole.middle_frame,
        VideoInputRole.last_frame,
      ])
        ...inputs.where((input) => input.role == role),
    ...inputs.where(
      (input) =>
          productionSubmitRole(mode, input.role) ==
          VideoInputRole.reference_image,
    ),
  ];
  final counts = <VideoMediaKind, int>{};
  return inputs.map((input) {
    final role = productionSubmitRole(mode, input.role);
    final kind = role.kind;
    final index = counts.update(kind, (n) => n + 1, ifAbsent: () => 1);
    final slot = switch (role) {
      _ when indexedKeyframes && kind == VideoMediaKind.image =>
        '@image_${imageOrder.indexWhere((item) => item.id == input.id) + 1}',
      _ when indexedKeyframes => '@${kind.name}_$index',
      VideoInputRole.first_frame => 'first frame',
      VideoInputRole.last_frame => 'last frame',
      VideoInputRole.middle_frame => 'middle frame $index',
      _ when protocol == VideoProtocol.atlascloud_video =>
        '@${switch (kind) {
          VideoMediaKind.image => 'Image',
          VideoMediaKind.video => 'Video',
          VideoMediaKind.audio => 'Audio',
        }}$index',
      _ when protocol == VideoProtocol.agnes_video =>
        '<${switch (kind) {
          VideoMediaKind.image => 'Picture',
          VideoMediaKind.video => 'Video',
          VideoMediaKind.audio => 'Audio',
        }} $index>',
      _ =>
        protocol == VideoProtocol.minimax_video_v2
            ? 'reference ${kind.name} $index'
            : '${switch (kind) {
                VideoMediaKind.image => '图片',
                VideoMediaKind.video => '视频',
                VideoMediaKind.audio => '音频',
              }}$index',
    };
    return VideoReferenceSlot(input.assetId, role, slot, inputId: input.id);
  }).toList();
}

VideoRequest compileProductionPrompt(
  String providerType,
  VideoRequest raw,
  List<ResolvedProductionInput> inputs,
) {
  final parsed = StoryboardPrompt.parse(raw.prompt);
  final slots = productionSlots(
    productionProtocol(providerType),
    inputs,
    mode: raw.mode,
    indexedKeyframes:
        (lookupVideoChannelModel(
              providerType,
              raw.modelId,
            )?.capabilities.maxMiddleFrames ??
            0) >
        0,
  );
  if (inputs.map((s) => s.id).toSet().length != slots.length) {
    throw const StoryboardException('invalid_reference');
  }
  final text = parsed.parts.map((part) {
    if (!part.isReference) {
      return part.text;
    }
    final slot = slots.where((s) => s.inputId == part.inputId).firstOrNull;
    if (slot == null) {
      throw const StoryboardException('invalid_reference');
    }
    return slot.slot;
  }).join();
  final middleFrameIds = [
    for (final input in inputs)
      if (input.role == VideoInputRole.middle_frame) input.id,
  ];
  final frameInstructions = <String>[
    for (final (index, input) in inputs.indexed)
      if (productionSubmitRole(raw.mode, input.role) != input.role)
        switch (input.role) {
          VideoInputRole.first_frame =>
            '以 ${slots[index].slot} 作为视频起始画面，延续其构图、人物姿态和场景状态。',
          VideoInputRole.last_frame =>
            '视频结束画面应呈现 ${slots[index].slot} 所示的构图、人物姿态和场景状态。',
          VideoInputRole.middle_frame =>
            '以 ${slots[index].slot} 作为第 ${middleFrameIds.indexOf(input.id) + 1} 个中间过程的画面参考。',
          _ => throw StateError('Unexpected converted production role'),
        },
  ];
  final voiceInstructions = <String>[];
  for (final input in inputs) {
    if (input.input.voiceAssetId == null) {
      continue;
    }
    final imageSlot = slots.singleWhere((s) => s.inputId == input.id);
    final audioSlot = slots
        .where((s) => s.inputId == input.input.voiceInputId)
        .firstOrNull;
    if (audioSlot == null) {
      throw const StoryboardException('invalid_reference');
    }
    voiceInstructions.add(
      '${imageSlot.slot} 中的角色使用 ${audioSlot.slot} 的音色。参考音频仅提供声线，台词与情绪以本次提示词为准。',
    );
  }
  final defaults = lookupVideoChannelModel(
    providerType,
    raw.modelId,
  )?.requestDefaults;
  return VideoRequest(
    modelId: raw.modelId,
    prompt: [
      text,
      ...frameInstructions,
      ...voiceInstructions,
    ].where((s) => s.isNotEmpty).join('\n'),
    mode: raw.mode,
    resolution: raw.resolution,
    ratio: raw.ratio,
    durationSeconds: raw.durationSeconds,
    audio: raw.audio ?? defaults?.audio,
    promptExtend: raw.promptExtend ?? defaults?.promptExtend,
    originalPrompt: raw.prompt,
    referenceSlots: slots,
  );
}

class ProductionPreview {
  ProductionPreview(
    this.node,
    this.providerId,
    this.request,
    List<VideoSourceInput> inputs, {
    this.draft = false,
  }) : inputs = List.unmodifiable(inputs);
  final CanvasNode node;
  final String providerId;
  final VideoRequest request;
  final List<VideoSourceInput> inputs;
  final bool draft;
  String get sourceType => 'production_clip';
  String get sourceId => node.clipId!;
}

class ProductionGenerateOrchestrator {
  Future<ProductionPreview> preview(
    ProductionCanvasService service,
    String nodeId, {
    bool draft = false,
  }) async {
    final node = await service.requireNode(nodeId);
    final shot = node.clipId == null
        ? null
        : await service.shots.getShot(node.clipId!);
    final raw = shot == null ? null : shotVideoRequest(shot);
    final providerId = shot?.providerId;
    if (shot?.kind != 'video' ||
        raw == null ||
        providerId == null ||
        (shot?.durationMs != null && shot!.durationMs! % 1000 != 0)) {
      throw const StoryboardException('invalid_config');
    }
    final provider = await service.library.database.aiProviderDao.getById(
      providerId,
    );
    if (provider == null ||
        !provider.enabled ||
        !provider.videoModels.contains(raw.modelId) ||
        !productionSupportsVideoModel(provider.type, raw.modelId)) {
      throw const VideoException(VideoErrorCode.configuration_required);
    }
    if (draft &&
        lookupVideoChannelModel(
              provider.type,
              raw.modelId,
            )?.protocolOptions.supportsDraft !=
            true) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'draft',
      );
    }
    final savedInputs = await service.inputs(nodeId);
    for (final input in savedInputs.where((i) => i.voiceAssetId != null)) {
      if (productionUsesFrames(raw.mode)) {
        throw const VideoException(
          VideoErrorCode.invalid_request,
          field: 'voice_mode',
        );
      }
      await service.requireInputVoice(input);
    }
    final ordered = <ResolvedProductionInput>[];
    final inputs = <VideoSourceInput>[];
    final references = <VideoReference>[];
    final allowed = productionRoles(raw.mode);
    for (final input in productionInputsWithVoices(savedInputs)) {
      if (!allowed.contains(input.role)) {
        continue;
      }
      final role = productionSubmitRole(raw.mode, input.role);
      if (input.sourceNodeId != null) {
        await service.requireAcyclic(
          input.sourceNodeId!,
          node.id,
          node.canvasId,
        );
      }
      final asset = await service.inputAsset(input);
      final media = await service.requireFile(
        asset.path!,
        type: input.role.kind.name,
      );
      final file = File(service.library.resolvePath(media.path));
      final info = await service.library.media.probe(file.path);
      ordered.add(ResolvedProductionInput(input, asset.id));
      inputs.add(
        VideoSourceInput(
          file: file,
          assetId: asset.id,
          role: role,
          mimeType: media.mimeType,
        ),
      );
      references.add(
        VideoReference(
          role: role,
          url: 'https://local.invalid/preview',
          mimeType: media.mimeType,
          fileSize: await file.length(),
          mediaInfo: VideoMediaInfo(
            width: info.width,
            height: info.height,
            durationMs: info.duration.inMilliseconds,
            frameRate: info.frameRate,
          ),
        ),
      );
    }
    final compiled = compileProductionPrompt(
      provider.type,
      VideoRequest(
        modelId: raw.modelId,
        prompt: raw.prompt,
        mode: productionSubmitMode(raw.mode, ordered.map((i) => i.role)),
        resolution: draft ? videoDraftResolution : raw.resolution,
        ratio: raw.ratio,
        durationSeconds: raw.durationSeconds,
        audio:
            lookupVideoChannelModel(
                  provider.type,
                  raw.modelId,
                )?.requiresAudio ==
                true
            ? raw.audio
            : null,
      ),
      ordered,
    );
    final style = await service.effectiveStyle(shot!);
    final request = compiled.withPrompt(
      style?.assemble(compiled.prompt) ?? compiled.prompt,
    );
    VideoCapabilities(provider.type).validate(request, references);
    return ProductionPreview(node, providerId, request, inputs, draft: draft);
  }

  Future<String> submit(
    ProductionCanvasService service,
    VideoTaskService tasks,
    ProductionPreview preview, {
    required bool acknowledgeReferenceUpload,
  }) async {
    // The preview is the explicit submission snapshot; later UI edits cannot change it.
    await service.requireNode(preview.node.id);
    final id = await tasks.create(
      providerId: preview.providerId,
      novelId: service.novelId,
      sourceType: preview.sourceType,
      sourceId: preview.sourceId,
      request: preview.request,
      inputs: preview.inputs,
      draft: preview.draft,
    );
    await service.shots.setErrorDismissed(preview.sourceId, false);
    await tasks.submit(
      id,
      acknowledgeReferenceUpload: acknowledgeReferenceUpload,
    );
    return id;
  }

  Future<String> completeDraft(
    ProductionCanvasService service,
    VideoTaskService tasks,
    String draftTaskId,
  ) async {
    final draft = await tasks.getTask(draftTaskId);
    if (draft == null ||
        draft.novelId != service.novelId ||
        draft.sourceType != 'production_clip') {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'draft',
      );
    }
    final id = await tasks.createDraftCompletion(draftTaskId);
    await service.shots.setErrorDismissed(draft.sourceId, false);
    await tasks.submit(id);
    return id;
  }
}
