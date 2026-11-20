// 职责: 保存制作片段的有序参考身份、来源和用途，不复制来源文件信息。
// 关联文件:
//   lib/shared/database/novel_content_database.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/models/video/request.dart
import '../../utils/short_entity_id.dart';
import '../video/request.dart';

enum ProductionInputType { asset, node }

class ProductionInput {
  const ProductionInput({
    required this.id,
    required this.refType,
    required this.refId,
    required VideoInputRole role,
    this.voiceAssetId,
  }) : _mediaRole = role;

  const ProductionInput.prompt({required this.id, required this.refId})
    : refType = ProductionInputType.node,
      _mediaRole = null,
      voiceAssetId = null;

  factory ProductionInput.text(String nodeId) => ProductionInput.prompt(
    id: buildShortEntityId(ShortEntityIdType.productionInput),
    refId: nodeId,
  );

  factory ProductionInput.asset(String assetId, VideoInputRole role) =>
      ProductionInput(
        id: buildShortEntityId(ShortEntityIdType.productionInput),
        refType: ProductionInputType.asset,
        refId: assetId,
        role: role,
      );

  factory ProductionInput.node(String nodeId, VideoInputRole role) =>
      ProductionInput(
        id: buildShortEntityId(ShortEntityIdType.productionInput),
        refType: ProductionInputType.node,
        refId: nodeId,
        role: role,
      );

  final String id;
  final ProductionInputType refType;
  final String refId;
  final VideoInputRole? _mediaRole;
  bool get isPrompt => _mediaRole == null;
  String get roleName => isPrompt ? 'prompt' : _mediaRole!.name;

  /// 文本输入先展开为提示词，不能作为服务商媒体用途读取。
  VideoInputRole get role =>
      _mediaRole ?? (throw StateError('Prompt input has no media role'));

  /// 本次视频生成选用的角色音色；角色的共享音色集合不决定本次选择。
  final String? voiceAssetId;
  String get voiceInputId => '$id:voice';

  String get identity => id;
  String get sourceIdentity => '${refType.name}:$refId:$roleName';
  String? get sourceNodeId =>
      refType == ProductionInputType.node ? refId : null;

  /// 中间帧在有序输入中的一基序号，包含直接素材与节点引用。
  int? middleFrameIndex(List<ProductionInput> inputs) =>
      isPrompt || role != VideoInputRole.middle_frame
      ? null
      : inputs
                .where(
                  (input) =>
                      !input.isPrompt &&
                      input.role == VideoInputRole.middle_frame,
                )
                .takeWhile((input) => input.id != id)
                .length +
            1;

  ProductionInput withId(String value) => isPrompt
      ? ProductionInput.prompt(id: value, refId: refId)
      : ProductionInput(
          id: value,
          refType: refType,
          refId: refId,
          role: role,
          voiceAssetId: voiceAssetId,
        );

  ProductionInput withRole(VideoInputRole value) => ProductionInput(
    id: id,
    refType: refType,
    refId: refId,
    role: value,
    voiceAssetId: voiceAssetId,
  );

  ProductionInput withVoice(String? assetId) => ProductionInput(
    id: id,
    refType: refType,
    refId: refId,
    role: role,
    voiceAssetId: assetId,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'ref_type': refType.name,
    'ref_id': refId,
    'role': roleName,
    if (voiceAssetId != null) 'voice_asset_id': voiceAssetId,
  };

  factory ProductionInput.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String;
    final refId = json['ref_id'] as String;
    if (id.trim().isEmpty || refId.trim().isEmpty) {
      throw const FormatException('Production input identity is required');
    }
    if (json['role'] == 'prompt') {
      if (json['ref_type'] != 'node' || json['voice_asset_id'] != null) {
        throw const FormatException(
          'Prompt input requires a text node and cannot bind a voice',
        );
      }
      return ProductionInput.prompt(id: id, refId: refId);
    }
    return ProductionInput(
      id: id,
      refType: ProductionInputType.values.byName(json['ref_type'] as String),
      refId: refId,
      role: VideoInputRole.values.byName(json['role'] as String),
      voiceAssetId: json['voice_asset_id'] as String?,
    );
  }

  static void validateList(List<ProductionInput> inputs) {
    for (final input in inputs) {
      if (input.id.trim().isEmpty || input.refId.trim().isEmpty) {
        throw const FormatException('Production input identity is required');
      }
      if (input.voiceAssetId != null &&
          (input.voiceAssetId!.trim().isEmpty ||
              input.refType != ProductionInputType.node ||
              input.role.kind != VideoMediaKind.image)) {
        throw const FormatException('Voice requires a character image input');
      }
    }
    if (inputs.map((i) => i.id).toSet().length != inputs.length ||
        inputs.map((i) => i.sourceIdentity).toSet().length != inputs.length) {
      throw const FormatException('Duplicate production input');
    }
  }
}
