// 职责: 封面工作台的跨平台状态 — 设计器参数、选中态、生成进度，并编排生成/停止/重出。
// 关联文件:
//   lib/shared/services/cover_studio_orchestrator.dart
//   lib/shared/services/cover_prompt_builder.dart
//   lib/shared/providers/ai_providers.dart
//   lib/desktop/features/cover_studio/studio_page.dart
//   lib/mobile/features/cover_studio/studio_page.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/widget-decomposition.md

import 'dart:convert';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../database/app_database.dart';
import '../localization/locale_keys.dart';
import '../services/ai/image.dart';
import '../services/ai/tools.dart' show AiImageGenerationCallback;
import '../services/cover_prompt_builder.dart';
import '../services/cover_studio_orchestrator.dart';
import 'ai_providers.dart';
import 'novel_providers.dart';

part 'cover_studio_providers.g.dart';

/// 配置图片模型后可进入封面工作台。
@riverpod
bool canOpenCoverStudio(Ref ref) =>
    ref.watch(isImageGenerationConfiguredProvider);

/// 面板顶部的一条错误。要么是本地化 key（客户端自己发现的问题，如没配图片模型），
/// 要么是 service 抛上来的原文；两者不能混在一个字符串字段里，否则展示时无从判断
/// 该不该翻译。
class CoverStudioError {
  const CoverStudioError.localized(this.localeKey) : text = null;
  const CoverStudioError.raw(this.text) : localeKey = null;

  final String? localeKey;
  final String? text;
}

/// 一条要弹给作者的短消息。[id] 只用来让同一句话也能重新触发动画。
class CoverStudioToast {
  const CoverStudioToast({
    required this.id,
    required this.messageKey,
    this.args,
  });

  final int id;
  final String messageKey;
  final Map<String, String>? args;
}

/// 页面输入框的提示词真源在 [TextEditingController]，批次选中时用这个事件把
/// 已落库的正文送回页面。序号保证重复选择同一段文本也能触发回填。
class CoverStudioPromptRestore {
  const CoverStudioPromptRestore({required this.sequence, required this.text});

  final int sequence;
  final String text;
}

/// 缩放：书名画在像素里，字有没有画错只能靠放大看，所以上限要够得着 1:1。
const coverZoomMin = 40.0;
const coverZoomMax = 400.0;
const coverZoomStep = 20.0;

/// 100% 时主预览的宽度，缩放在这个基准上算。
const coverPaperWidth = 400.0;

/// 舞台水平内边距 28×2、胶片条 66、与主图间距 12。桌面把胶片条竖排在大图旁边，
/// 所以它吃的是宽度；移动端胶片条横排在图下面，调用时传 0 让宽度全给主图。
const coverStagePadH = 56.0;
const coverFilmstripWidth = 66.0;
const coverFilmstripGap = 12.0;

/// 舞台垂直内边距 16×2，再留出说明行 + 工具带的高度。
const coverStagePadV = 32.0;
const coverStageBelowPaper = 100.0;

/// 按舞台可见区域算「适应画布」缩放，结果对齐到 [coverZoomStep]。
///
/// 几何参数默认就是桌面那套常量。移动端舞台的留白与胶片条方向都不一样，按实际
/// 布局把对应项传进来即可，不要另起一套常量。
double coverFitZoom({
  required double stageWidth,
  required double stageHeight,
  required double aspectRatio,
  double stagePadH = coverStagePadH,
  double stagePadV = coverStagePadV,
  double filmstripWidth = coverFilmstripWidth,
  double filmstripGap = coverFilmstripGap,
  double belowPaper = coverStageBelowPaper,
}) {
  final availW = stageWidth - stagePadH - filmstripWidth - filmstripGap;
  final availH = stageHeight - stagePadV - belowPaper;
  if (availW < 40 || availH < 40 || aspectRatio <= 0) {
    return 100;
  }
  final byWidth = availW / coverPaperWidth * 100;
  final paperHeightAt100 = coverPaperWidth / aspectRatio;
  final byHeight = availH / paperHeightAt100 * 100;
  final raw = byWidth < byHeight ? byWidth : byHeight;
  // 向下取整到步进：四舍五入会把 113% 抬成 120%，画面反而放不下，说明行与
  // 工具带会被顶到底部动作栏底下。
  final snapped = (raw / coverZoomStep).floor() * coverZoomStep;
  return snapped.clamp(coverZoomMin, coverZoomMax).toDouble();
}

class CoverStudioState {
  const CoverStudioState({
    this.ratioId = coverDefaultRatioId,
    this.resolutionId = coverDefaultResolutionId,
    this.qualityId = coverDefaultQualityId,
    this.complexityId,
    this.advancedOpen = false,
    this.batchCount = coverBatchCount,
    this.references = const [],
    this.selectedBatchId,
    this.selectedOrdinal = 0,
    this.zoom = 100,
    this.followFit = true,
    this.pickingReference = false,
    this.generating = false,
    this.stopping = false,
    this.completedCount = 0,
    this.totalCount = coverBatchCount,
    this.reworkingOrdinal,
    this.error,
    this.toast,
    this.draftSeq = 0,
    this.promptRestore,
  });

  final String ratioId;
  final String resolutionId;
  final String qualityId;

  /// 复杂度。null 表示尚未手选；提交时由生图服务按型号校验并补目录默认值。
  final String? complexityId;

  /// 高级设置默认折叠：风格 / 色调 / 构图 / 档案 / 灵感都是点选追加的碎片。
  final bool advancedOpen;

  /// 这一批出几张。作者可调，按实际出图张数计费。
  final int batchCount;

  /// 随请求发出的参考图 assetId，顺序就是 image 1..N 的顺序。
  final List<String> references;

  /// null 表示未选批次（画布空态）；生成成功后会写入新 batchId。
  final String? selectedBatchId;
  final int selectedOrdinal;
  final double zoom;

  /// true 时缩放跟随舞台尺寸；用户点 +/- 后关掉，点「适应画布」再打开。
  final bool followFit;
  final bool pickingReference;

  final bool generating;
  final bool stopping;
  final int completedCount;
  final int totalCount;

  /// 正在重出的格子序号；没有重出时为 null。
  final int? reworkingOrdinal;

  final CoverStudioError? error;
  final CoverStudioToast? toast;

  /// 「新建」按了几次。提示词的真源是页面上的 TextEditingController，controller
  /// 够不着它；页面监听这个序号，变了就把提示词重置回默认种子。
  final int draftSeq;

  final CoverStudioPromptRestore? promptRestore;

  bool get busy => generating || reworkingOrdinal != null;

  CoverStudioState copyWith({
    String? ratioId,
    String? resolutionId,
    String? qualityId,
    String? complexityId,
    bool clearComplexityId = false,
    bool? advancedOpen,
    int? batchCount,
    List<String>? references,
    String? selectedBatchId,
    bool clearSelectedBatchId = false,
    int? selectedOrdinal,
    double? zoom,
    bool? followFit,
    bool? pickingReference,
    bool? generating,
    bool? stopping,
    int? completedCount,
    int? totalCount,
    int? reworkingOrdinal,
    bool clearReworkingOrdinal = false,
    CoverStudioError? error,
    bool clearError = false,
    CoverStudioToast? toast,
    bool clearToast = false,
    int? draftSeq,
    CoverStudioPromptRestore? promptRestore,
  }) {
    return CoverStudioState(
      ratioId: ratioId ?? this.ratioId,
      resolutionId: resolutionId ?? this.resolutionId,
      qualityId: qualityId ?? this.qualityId,
      complexityId: clearComplexityId
          ? null
          : (complexityId ?? this.complexityId),
      advancedOpen: advancedOpen ?? this.advancedOpen,
      batchCount: batchCount ?? this.batchCount,
      references: references ?? this.references,
      selectedBatchId: clearSelectedBatchId
          ? null
          : (selectedBatchId ?? this.selectedBatchId),
      selectedOrdinal: selectedOrdinal ?? this.selectedOrdinal,
      zoom: zoom ?? this.zoom,
      followFit: followFit ?? this.followFit,
      pickingReference: pickingReference ?? this.pickingReference,
      generating: generating ?? this.generating,
      stopping: stopping ?? this.stopping,
      completedCount: completedCount ?? this.completedCount,
      totalCount: totalCount ?? this.totalCount,
      reworkingOrdinal: clearReworkingOrdinal
          ? null
          : (reworkingOrdinal ?? this.reworkingOrdinal),
      error: clearError ? null : (error ?? this.error),
      toast: clearToast ? null : (toast ?? this.toast),
      draftSeq: draftSeq ?? this.draftSeq,
      promptRestore: promptRestore ?? this.promptRestore,
    );
  }
}

@riverpod
class CoverStudioController extends _$CoverStudioController {
  CoverStudioOrchestrator? _orchestrator;
  var _toastSeq = 0;
  var _promptRestoreSeq = 0;

  @override
  CoverStudioState build(String novelId) => const CoverStudioState();

  // ---- 设计器参数 -------------------------------------------------------

  void setRatio(String id) => state = state.copyWith(ratioId: id);
  void setResolution(String id) => state = state.copyWith(resolutionId: id);
  void setQuality(String id) => state = state.copyWith(qualityId: id);
  void setComplexity(String id) => state = state.copyWith(complexityId: id);

  void toggleAdvanced() =>
      state = state.copyWith(advancedOpen: !state.advancedOpen);

  void setBatchCount(int count) => state = state.copyWith(
    batchCount: count.clamp(coverBatchCountMin, coverBatchCountMax),
  );

  void setZoom(double zoom) => state = state.copyWith(
    followFit: false,
    zoom: zoom.clamp(coverZoomMin, coverZoomMax),
  );

  void zoomBy(double delta) => setZoom(state.zoom + delta);

  /// 「适应画布」：重新跟舞台尺寸走；真正数值由舞台 LayoutBuilder 写入。
  void fitToStage() => state = state.copyWith(followFit: true);

  /// 舞台算出的适应值。仅在 [followFit] 时写入，避免覆盖用户手调。
  void applyFitZoom(double zoom) {
    if (!state.followFit) {
      return;
    }
    final next = zoom.clamp(coverZoomMin, coverZoomMax);
    if ((state.zoom - next).abs() < 0.5) {
      return;
    }
    state = state.copyWith(zoom: next);
  }

  void togglePicking() =>
      state = state.copyWith(pickingReference: !state.pickingReference);

  void dismissToast() => state = state.copyWith(clearToast: true);

  void dismissError() => state = state.copyWith(clearError: true);

  // ---- 选中 -------------------------------------------------------------

  void selectBatch(ImageBatchRow batch) {
    if (state.busy) {
      return;
    }
    // 再点一次当前批次：取消选中，画布回到空态。
    if (state.selectedBatchId == batch.id) {
      clearBatchSelection();
      return;
    }
    final params = _decodeBatchParams(batch.paramsJson);
    final complexityId = _complexityFromParams(params['complexity']);
    state = state.copyWith(
      ratioId: _resolvedRatioId(params['ratio']),
      resolutionId: _resolvedResolutionId(params['resolution']),
      qualityId: _resolvedQualityId(params['quality']),
      complexityId: complexityId,
      clearComplexityId: complexityId == null,
      batchCount: batch.requestedCount.clamp(
        coverBatchCountMin,
        coverBatchCountMax,
      ),
      references: _referencesFromParams(params['references']),
      selectedBatchId: batch.id,
      selectedOrdinal: 0,
      promptRestore: CoverStudioPromptRestore(
        sequence: ++_promptRestoreSeq,
        text: batch.prompt,
      ),
    );
  }

  /// 取消当前批次选中，画布回到空态预览；设计器参数原样保留。
  /// 再点一次当前批次走这里，作者只是想收起预览，不该顺手清掉他填的东西。
  void clearBatchSelection() {
    if (state.busy) {
      return;
    }
    state = state.copyWith(clearSelectedBatchId: true, selectedOrdinal: 0);
  }

  /// 「新建」：整个工作台回到刚进来的样子 —— 批次选中、参考图、质量/分辨率/比例、
  /// 张数与报错全部复位，画布回空态。提示词由页面听 [CoverStudioState.draftSeq]
  /// 重置回默认种子。
  void startNewDraft() {
    if (state.busy) {
      return;
    }
    state = CoverStudioState(draftSeq: state.draftSeq + 1);
  }

  /// 删掉一条生成记录。只软删批次本身：出的图留在图片库里，已设为封面或正被当
  /// 参考图的那张不受影响。删的是当前选中那条时，画布退回空态。
  Future<void> deleteBatch(String batchId) async {
    if (state.busy) {
      return;
    }
    await ref.read(appDatabaseProvider).imageAssetDao.softDeleteBatch(batchId);
    if (!ref.mounted || state.selectedBatchId != batchId) {
      return;
    }
    state = state.copyWith(clearSelectedBatchId: true, selectedOrdinal: 0);
  }

  /// 按这一批当时的参数再出一批。提示词用落库的 finalized prompt，避免再包一层参考说明。
  Future<void> reuseBatch(ImageBatchRow batch) async {
    if (state.busy) {
      return;
    }
    final params = _decodeBatchParams(batch.paramsJson);
    final prompt = batch.prompt.trim();
    if (prompt.isEmpty) {
      return;
    }

    final ratioId = params['ratio'] as String? ?? state.ratioId;
    final resolutionId = params['resolution'] as String? ?? state.resolutionId;
    final qualityId = params['quality'] as String? ?? state.qualityId;
    final complexityId = _complexityFromParams(params['complexity']);
    final references = _referencesFromParams(params['references']);

    state = state.copyWith(
      ratioId: ratioId,
      resolutionId: resolutionId,
      qualityId: qualityId,
      complexityId: complexityId,
      clearComplexityId: complexityId == null,
      references: references,
      selectedBatchId: batch.id,
      selectedOrdinal: 0,
    );

    // batch.prompt 已含「参考：」时 finalizeCoverPrompt 不会再追加。
    await generate(prompt: prompt);
  }

  static Map<String, dynamic> _decodeBatchParams(String? paramsJson) {
    if (paramsJson == null || paramsJson.isEmpty) {
      return const {};
    }
    try {
      final decoded = jsonDecode(paramsJson);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  /// 旧批次的 params 里每张图还带着 `role`，这里只取 asset_id —— 用途已经改由
  /// 作者写在提示词里，读回来也没有地方用。
  static List<String> _referencesFromParams(Object? raw) {
    if (raw is! List) {
      return const [];
    }
    final next = <String>[];
    for (final item in raw) {
      if (item is! Map) {
        continue;
      }
      final assetId = item['asset_id'] as String?;
      if (assetId == null || assetId.isEmpty) {
        continue;
      }
      next.add(assetId);
    }
    return next;
  }

  /// 记录里没有复杂度，说明那一批没手选、用的是目录默认值；恢复成未选，
  /// 不沿用当前面板上的选择。
  static String? _complexityFromParams(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  static String _resolvedRatioId(Object? value) =>
      coverRatioOf(value is String ? value : '').id;

  static String _resolvedResolutionId(Object? value) =>
      coverResolutionOf(value is String ? value : '').id;

  static String _resolvedQualityId(Object? value) =>
      coverQualityOf(value is String ? value : '').id;

  void selectOrdinal(int ordinal) =>
      state = state.copyWith(selectedOrdinal: ordinal);

  // ---- 参考图 -----------------------------------------------------------

  void addReference(String assetId) {
    if (state.references.contains(assetId)) {
      state = state.copyWith(pickingReference: false);
      return;
    }
    if (state.references.length >= coverReferenceLimit) {
      state = state.copyWith(
        pickingReference: false,
        toast: _toast(
          LocaleKeys.editorCoverReferenceLimitAlert,
          args: {'limit': '$coverReferenceLimit'},
        ),
      );
      return;
    }
    state = state.copyWith(
      references: [...state.references, assetId],
      pickingReference: false,
    );
  }

  /// 多选导入被上限截断时补一次上限提示，复用 [addReference] 的同一文案。
  void notifyReferenceLimit() {
    state = state.copyWith(
      toast: _toast(
        LocaleKeys.editorCoverReferenceLimitAlert,
        args: {'limit': '$coverReferenceLimit'},
      ),
    );
  }

  void removeReference(String assetId) {
    state = state.copyWith(
      references: state.references
          .where((item) => item != assetId)
          .toList(growable: false),
    );
  }

  /// 以当前这张为底图再来一批：把它排到参考图第一位，然后照常生成。
  Future<void> seedFrom({
    required String assetId,
    required String prompt,
  }) async {
    if (state.busy) {
      return;
    }
    final next = [
      assetId,
      ...state.references.where((item) => item != assetId),
    ].take(coverReferenceLimit).toList(growable: false);
    state = state.copyWith(
      references: next,
      toast: _toast(LocaleKeys.editorCoverToastSeedFrom),
    );
    await generate(prompt: prompt);
  }

  // ---- 生成 -------------------------------------------------------------

  /// 下发的正文就是作者写的提示词本身；参考图怎么用由作者自己写进去。
  String finalizePrompt(String userPrompt) =>
      finalizeCoverPrompt(userPrompt: userPrompt);

  /// [prompt] 是右侧提示词框里的原文：它就是这次出图的全部说明，书名、署名、
  /// 简介都已经写在里面，界面上没有别的字段能再改它。
  Future<void> generate({required String prompt}) async {
    if (state.busy) {
      return;
    }
    if (prompt.trim().isEmpty) {
      return;
    }

    final selection = ref.read(coverStudioImageModelSelectionProvider);
    if (selection == null) {
      state = state.copyWith(
        error: const CoverStudioError.localized(
          LocaleKeys.aiConfigureImageModel,
        ),
      );
      return;
    }
    final callback = _resolveCallback();
    if (callback == null) {
      return;
    }

    final references = state.references;
    final size = coverImageSize(
      coverRatioOf(state.ratioId),
      coverResolutionOf(state.resolutionId),
    );
    final quality = coverQualityOf(state.qualityId).apiValue;
    final finalized = finalizePrompt(prompt);

    state = state.copyWith(
      generating: true,
      stopping: false,
      completedCount: 0,
      totalCount: state.batchCount,
      selectedOrdinal: 0,
      clearSelectedBatchId: true,
      clearError: true,
    );

    final orchestrator = CoverStudioOrchestrator();
    _orchestrator = orchestrator;
    try {
      final result = await orchestrator.generateBatch(
        database: ref.read(appDatabaseProvider),
        imageLibrary: ref.read(imageLibraryServiceProvider),
        callback: callback,
        novelId: novelId,
        prompt: finalized,
        requestedCount: state.batchCount,
        model: selection.model,
        size: size,
        quality: quality,
        complexity: state.complexityId,
        paramsJson: jsonEncode({
          'ratio': state.ratioId,
          'resolution': state.resolutionId,
          'quality': state.qualityId,
          'complexity': ?state.complexityId,
          'size': size,
          'references': references
              .map((assetId) => {'asset_id': assetId})
              .toList(),
        }),
        references: references,
        onProgress: (count) {
          if (!ref.mounted) {
            return;
          }
          state = state.copyWith(completedCount: count);
        },
      );
      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(
        selectedBatchId: result.batchId,
        toast: _batchToast(result),
      );
    } catch (error) {
      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(error: CoverStudioError.raw(error.toString()));
    } finally {
      _orchestrator = null;
      if (ref.mounted) {
        state = state.copyWith(generating: false, stopping: false);
      }
    }
  }

  /// 停止：只清掉还没发出的请求，在途那一张留着让它画完。
  void stop() {
    if (!state.generating || state.stopping) return;
    _orchestrator?.stop();
    state = state.copyWith(
      stopping: true,
      toast: _toast(LocaleKeys.editorCoverToastStopped),
    );
  }

  /// 单张重出：沿用这一批的参数与参考图，只重跑这一格。
  Future<void> rework({required String batchId, required int ordinal}) async {
    if (state.busy) {
      return;
    }
    final selection = ref.read(coverStudioImageModelSelectionProvider);
    if (selection == null) {
      state = state.copyWith(
        error: const CoverStudioError.localized(
          LocaleKeys.aiConfigureImageModel,
        ),
      );
      return;
    }
    final callback = _resolveCallback();
    if (callback == null) {
      return;
    }

    final database = ref.read(appDatabaseProvider);
    final batch = await database.imageAssetDao.getBatch(batchId);
    if (batch == null || !ref.mounted) {
      return;
    }

    state = state.copyWith(reworkingOrdinal: ordinal, clearError: true);
    try {
      final result = await CoverStudioOrchestrator().regenerateSlot(
        database: database,
        imageLibrary: ref.read(imageLibraryServiceProvider),
        callback: callback,
        batchId: batchId,
        ordinal: ordinal,
        novelId: novelId,
        // 重出用这一批当初的提示词，不是右侧现在的参数 —— 否则「重出这张」会
        // 悄悄换掉方案的取向，作者只是想再抽一次。
        prompt: batch.prompt,
        model: selection.model,
        size: coverImageSize(
          coverRatioOf(state.ratioId),
          coverResolutionOf(state.resolutionId),
        ),
        quality: coverQualityOf(state.qualityId).apiValue,
        complexity: state.complexityId,
        references: state.references,
      );
      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(
        selectedOrdinal: ordinal,
        toast: _toast(
          result.succeeded
              ? LocaleKeys.editorCoverToastReworked
              : LocaleKeys.editorCoverToastReworkFailed,
          args: {'index': '${ordinal + 1}'},
        ),
      );
    } catch (error) {
      if (!ref.mounted) {
        return;
      }
      state = state.copyWith(error: CoverStudioError.raw(error.toString()));
    } finally {
      if (ref.mounted) {
        state = state.copyWith(clearReworkingOrdinal: true);
      }
    }
  }

  /// 有参考图时走多图编辑通道，否则走普通生图。
  AiImageGenerationCallback? _resolveCallback() {
    final generation = ref.read(coverImageGenerationCallbackProvider);
    if (generation == null) {
      state = state.copyWith(
        error: const CoverStudioError.localized(
          LocaleKeys.aiConfigureImageModel,
        ),
      );
      return null;
    }
    final references = state.references;
    if (references.isEmpty) return generation;

    final multiEdit = ref.read(coverImageMultiEditCallbackProvider);
    if (multiEdit == null) {
      state = state.copyWith(
        error: const CoverStudioError.localized(
          LocaleKeys.aiConfigureImageModel,
        ),
      );
      return null;
    }
    final library = ref.read(imageLibraryServiceProvider);
    final database = ref.read(appDatabaseProvider);
    return (prompt, {model, size, quality, complexity}) async {
      final paths = <String>[];
      for (final assetId in references) {
        final asset = await database.imageAssetDao.getAsset(assetId);
        final path = library.resolve(asset?.path);
        if (path != null) paths.add(path);
      }
      if (paths.isEmpty) {
        return generation(
          prompt,
          model: model,
          size: size,
          quality: quality,
          complexity: complexity,
        );
      }
      return multiEdit(
        prompt,
        imageData: paths,
        model: model,
        size: size,
        quality: quality,
        complexity: complexity,
      );
    };
  }

  CoverStudioToast _toast(String key, {Map<String, String>? args}) {
    return CoverStudioToast(id: ++_toastSeq, messageKey: key, args: args);
  }

  CoverStudioToast _batchToast(CoverStudioBatchResult result) {
    final count = '${result.assetPaths.length}';
    return switch (result.status) {
      imageBatchStatusCompleted => _toast(
        LocaleKeys.editorCoverToastGenerated,
        args: {'count': count},
      ),
      imageBatchStatusCanceled => _toast(LocaleKeys.editorCoverToastCanceled),
      imageBatchStatusFailed => _toast(LocaleKeys.editorCoverToastFailed),
      _ => _toast(LocaleKeys.editorCoverToastPartial, args: {'count': count}),
    };
  }
}

/// 一个格子在界面上的样子：把 slot 行和它指向的资产合到一起。
class CoverSlotView {
  const CoverSlotView({
    required this.ordinal,
    required this.status,
    this.asset,
    this.previousAsset,
    this.errorCode,
    this.errorMessage,
  });

  final int ordinal;
  final String status;
  final AssetRow? asset;
  final AssetRow? previousAsset;
  final String? errorCode;
  final String? errorMessage;

  bool get succeeded => status == imageBatchSlotStatusSucceeded;
  bool get failed => status == imageBatchSlotStatusFailed;
  bool get pending => status == imageBatchSlotStatusPending;

  /// 作者叫停导致没发出的格子，与真失败区分展示。
  bool get canceled => errorCode == coverSlotErrorCanceled;

  /// 认得出的失败分类；认不出（或没失败）为 null。
  AiImageErrorCode? get knownError {
    for (final code in AiImageErrorCode.values) {
      if (code.name == errorCode) return code;
    }
    return null;
  }
}

/// 指定批次的格子视图，按序号排好。
///
/// 同步 provider 而不是自己合流两个 Stream：Riverpod 已经在管这两个 watch 的
/// 订阅与重算，手写 StreamController 只是把生命周期又扛回自己身上。
@riverpod
List<CoverSlotView> coverSlotViews(Ref ref, String batchId, String? novelId) {
  final slots = ref.watch(imageBatchSlotsProvider(batchId)).asData?.value;
  if (slots == null) return const [];
  final assetRows =
      ref.watch(imageAssetsProvider(novelId)).asData?.value ??
      const <AssetRow>[];
  final assets = {for (final asset in assetRows) asset.id: asset};
  return slots
      .map(
        (slot) => CoverSlotView(
          ordinal: slot.ordinal,
          status: slot.status,
          asset: slot.assetId == null ? null : assets[slot.assetId],
          previousAsset: slot.previousAssetId == null
              ? null
              : assets[slot.previousAssetId],
          errorCode: slot.errorCode,
          errorMessage: slot.errorMessage,
        ),
      )
      .toList(growable: false);
}
