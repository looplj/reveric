// 职责: 地图出图参数表单的状态 hook — 来源开关、画风/分辨率/质量、提示词及其自动跟随种子。
//       状态挂在调用方：桌面挂在制图师「生成」tab，移动端挂在工作台页面，
//       参数抽屉是另一条 route，关掉再开也不丢参数和改了一半的提示词。
// 关联文件:
//   lib/shared/widgets/map/map_generate_fields.dart
//   lib/desktop/features/map/map_cartographer_panel.dart
//   lib/mobile/features/map/studio_page.dart
//   lib/shared/services/map_prompt_builder.dart
//   lib/shared/services/generate_map_orchestrator.dart
//   lib/shared/providers/map_studio_providers.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/text-input-ime.md
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../database/novel_content_database.dart';
import '../models/map_agent.dart';
import '../models/map_studio_models.dart';
import '../services/generate_map_orchestrator.dart';
import '../services/map_prompt_builder.dart';

class MapGenerateForm {
  MapGenerateForm._({
    required this.styleId,
    required this.customStyleController,
    required this.customStyleFocusNode,
    required this.customStyleError,
    required this.resolutionId,
    required this.qualityId,
    required this.includeLocations,
    required this.referenceCurrentImage,
    required this.referenceParentImage,
    required this.promptController,
    required this.hasImage,
    required this.parentMap,
    required this.parentMapName,
    required this._resetPrompt,
    required this._applyDraft,
  });

  final ValueNotifier<String?> styleId;
  final TextEditingController customStyleController;
  final FocusNode customStyleFocusNode;
  final ValueNotifier<bool> customStyleError;
  final ValueNotifier<String> resolutionId;
  final ValueNotifier<String> qualityId;
  final ValueNotifier<bool> includeLocations;
  final ValueNotifier<bool> referenceCurrentImage;
  final ValueNotifier<bool> referenceParentImage;
  final TextEditingController promptController;

  /// 当前地图是否已有图片（决定是否能参考上一版重画）。
  final bool hasImage;

  /// 最近一张已经画好的上层地图，可选作画风参考图。
  final NovelMap? parentMap;
  final String? parentMapName;
  final void Function() _resetPrompt;
  final void Function(MapDesignDraft draft) _applyDraft;

  /// 表单里任一选项变化都会通知；字段组件据此重建。
  Listenable get listenable => Listenable.merge([
    styleId,
    customStyleError,
    resolutionId,
    qualityId,
    includeLocations,
    referenceCurrentImage,
    referenceParentImage,
  ]);

  bool get effectiveReferenceCurrentImage =>
      hasImage && referenceCurrentImage.value;

  bool get effectiveReferenceParent =>
      parentMap != null && referenceParentImage.value;

  /// 按当前来源重拼提示词，并清掉「用户改过」标记。
  void resetPrompt() => _resetPrompt();

  /// 把 Agent 草稿的全部参数回填进表单；调用方负责丢弃草稿。
  void applyDraft(MapDesignDraft draft) => _applyDraft(draft);

  String? currentStyleWord() => mapStyleWordOf(
    styleId: styleId.value,
    customStyleWord: customStyleController.text,
  );

  /// 选了「自定义」却没填画风时标错并聚焦输入框。
  bool validateCustomStyle() {
    if (styleId.value != mapCustomStyleId || currentStyleWord() != null) {
      customStyleError.value = false;
      return true;
    }
    customStyleError.value = true;
    customStyleFocusNode.requestFocus();
    return false;
  }

  MapGenerationRequest toRequest() => MapGenerationRequest(
    styleId: styleId.value,
    customStyleWord: styleId.value == mapCustomStyleId
        ? currentStyleWord()
        : null,
    resolutionId: resolutionId.value,
    quality: qualityId.value,
    customPrompt: promptController.text,
    includeLocations: includeLocations.value,
    referenceCurrentImage: effectiveReferenceCurrentImage,
    parentReferenceMapId: effectiveReferenceParent ? parentMap!.id : null,
  );
}

/// [rootId] 是参与生成的地点树根：正式地图是 map.locationId，待生成是所属地点 id。
/// [lastStyleWord] 是这张图上次成图的画风词；没画过时默认沿用上层地图的画风。
MapGenerateForm useMapGenerateForm({
  required List<Location> locations,
  required String rootId,
  required String mapType,
  required bool hasImage,
  required String? lastStyleWord,
  required NovelMap? parentMap,
  required String? parentMapName,
}) {
  final parentSettings = parentMap == null
      ? null
      : MapStudioSettings.fromMap(parentMap.settings);
  final initialStyle =
      mapStyleSelectionOf(lastStyleWord) ??
      mapStyleSelectionOf(parentSettings?.style);
  final styleId = useState<String?>(
    initialStyle?.styleId ?? mapStyleOptions.first.id,
  );
  final customStyleController = useTextEditingController(
    text: initialStyle?.customStyleWord ?? '',
  );
  final customStyleFocusNode = useFocusNode();
  final customStyleError = useState(false);
  final resolutionId = useState(mapDefaultResolutionId);
  final qualityId = useState(mapDefaultQualityId);
  final includeLocations = useState(true);
  final referenceCurrentImage = useState(false);
  // 有上层地图时默认带上它做画风参考，子地图与父地图风格一致。
  final referenceParentImage = useState(true);

  // 抽屉拿着的是打开时那份表单对象；地点走 ref 取最新，Agent 刚建好的地点点「重置」也能拼进去。
  final latestLocations = useRef(locations)..value = locations;

  // 编辑框只承载地图内容；画风在提交给图片模型时独立追加。
  // 每次调用都读当前开关，抽屉里切完来源再点「重置」拿到的是新种子。
  String composePrompt() {
    final (regions, places) = deriveMapRegionsAndPlaces(
      locations: latestLocations.value,
      rootId: rootId,
    );
    return buildMapImagePrompt(
      regions: regions,
      places: includeLocations.value ? places : const [],
      referenceCurrentImage: hasImage && referenceCurrentImage.value,
      mapType: mapType,
      parentReferenceName: parentMap != null && referenceParentImage.value
          ? parentMapName
          : null,
    );
  }

  final seed = composePrompt();
  final promptController = useTextEditingController(text: seed);
  final promptEdited = useRef(false);
  final seeding = useRef(false);
  useOnListenableChange(promptController, () {
    if (!seeding.value) {
      promptEdited.value = true;
    }
  });

  /// 程序化重写提示词；listener 由 [seeding] 挡住，不算用户编辑。
  void writePrompt(String text, {required bool edited}) {
    seeding.value = true;
    promptController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    seeding.value = false;
    promptEdited.value = edited;
  }

  // 种子变化（地点异步加载完成或来源切换）且用户没改过提示词时，
  // 在帧末自动跟随。必须在 post-frame 改 controller：build 期间写入会打断 IME。
  final lastSeed = useRef<String?>(null);
  if (lastSeed.value != seed) {
    final seedChanged = lastSeed.value != null;
    lastSeed.value = seed;
    if (seedChanged && !promptEdited.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        writePrompt(composePrompt(), edited: false);
      });
    }
  }

  return MapGenerateForm._(
    styleId: styleId,
    customStyleController: customStyleController,
    customStyleFocusNode: customStyleFocusNode,
    customStyleError: customStyleError,
    resolutionId: resolutionId,
    qualityId: qualityId,
    includeLocations: includeLocations,
    referenceCurrentImage: referenceCurrentImage,
    referenceParentImage: referenceParentImage,
    promptController: promptController,
    hasImage: hasImage,
    parentMap: parentMap,
    parentMapName: parentMapName,
    resetPrompt: () => writePrompt(composePrompt(), edited: false),
    applyDraft: (draft) {
      styleId.value = draft.styleId;
      customStyleController.text = draft.customStyleWord ?? '';
      resolutionId.value = draft.resolutionId;
      qualityId.value = draft.qualityId;
      includeLocations.value = draft.includeLocations;
      referenceCurrentImage.value = hasImage && draft.referenceCurrentImage;
      writePrompt(draft.prompt, edited: true);
    },
  );
}
