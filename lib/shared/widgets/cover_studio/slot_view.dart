// 职责: 封面单张画面的无壳视图 — 待出/重出/失败/成图四态渲染、方案说明行与失败文案映射。
// 关联文件:
//   lib/shared/providers/cover_studio_providers.dart
//   lib/desktop/features/cover_studio/canvas.dart
//   lib/mobile/features/cover_studio/canvas.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
//   assets/translations/en/account.json
//   assets/translations/zh-CN/account.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md
//   .agents/rules/icons.md

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../providers/cover_studio_providers.dart';
import '../../providers/novel_providers.dart';
import '../../services/ai/image.dart';
import '../../theme/theme.dart';

/// 画面本体：一个格子在四种状态下分别长什么样。两端共用，外层的纸张尺寸、
/// 圆角与边框由各自画布决定。
class CoverSlotCanvas extends ConsumerWidget {
  const CoverSlotCanvas({
    super.key,
    required this.novelId,
    required this.slot,
    required this.reworking,
    required this.onRework,
  });

  final String novelId;
  final CoverSlotView? slot;
  final bool reworking;
  final void Function(int ordinal) onRework;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(coverStudioControllerProvider(novelId));
    final current = slot;

    if (reworking) {
      return _Pending(
        label: context.t(
          LocaleKeys.editorCoverStageReworking,
          namedArgs: {'index': '${current!.ordinal + 1}'},
        ),
      );
    }
    if (current == null || current.pending) {
      return _Pending(
        label: state.stopping
            ? context.t(LocaleKeys.editorCoverStageStopping)
            : context.t(
                LocaleKeys.editorCoverStageGenerating,
                namedArgs: {'index': '${state.completedCount + 1}'},
              ),
      );
    }
    if (current.failed) {
      return _Failure(
        slot: current,
        busy: state.busy,
        onRework: () => onRework(current.ordinal),
      );
    }
    final path = ref
        .read(imageLibraryServiceProvider)
        .resolve(current.asset?.path);
    if (path == null) {
      return const Center(
        child: RevericIcon(RevericIcons.broken_image_outlined, size: 20),
      );
    }
    return Image.file(File(path), fit: BoxFit.cover);
  }
}

class _Pending extends StatelessWidget {
  const _Pending({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return ColoredBox(
      color: colors.surfaceContainer,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 120,
            child: LinearProgressIndicator(
              color: colors.accent,
              backgroundColor: colors.borderSubtle,
            ),
          ),
          const SizedBox(height: RevericSpacing.md),
          Text(label, style: typo.uiSmall.copyWith(color: colors.textMuted)),
        ],
      ),
    );
  }
}

/// 单张失败：只影响这一张，写清是哪一类错、下一步做什么。
class _Failure extends StatelessWidget {
  const _Failure({
    required this.slot,
    required this.busy,
    required this.onRework,
  });

  final CoverSlotView slot;
  final bool busy;
  final VoidCallback onRework;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final (titleKey, bodyKey) = coverSlotErrorCopy(slot);
    final detail = switch (slot.knownError) {
      AiImageErrorCode.param || AiImageErrorCode.size => slot.errorMessage,
      _ => null,
    };

    return ColoredBox(
      color: colors.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.x3l,
          vertical: RevericSpacing.x3l,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.error.withValues(alpha: 0.1),
              ),
              child: RevericIcon(
                RevericIcons.warning,
                size: 20,
                color: colors.error,
              ),
            ),
            const SizedBox(height: RevericSpacing.md),
            Text(
              context.t(titleKey),
              textAlign: TextAlign.center,
              style: typo.uiSemibold.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: RevericSpacing.sm),
            Text(
              detail ?? context.t(bodyKey),
              textAlign: TextAlign.center,
              maxLines: detail == null ? null : 4,
              overflow: detail == null ? null : TextOverflow.ellipsis,
              style: typo.uiSmall.copyWith(color: colors.textMuted),
            ),
            const SizedBox(height: RevericSpacing.md),

            OutlinedButton.icon(
              onPressed: busy ? null : onRework,
              icon: const RevericIcon(
                RevericIcons.arrow_counter_clockwise,
                size: 14,
              ),
              label: Text(context.t(LocaleKeys.editorCoverRework)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 失败格子该显示哪一对标题/正文。认不出的错误也要有话说，不能空着。
(String, String) coverSlotErrorCopy(CoverSlotView slot) {
  if (slot.canceled) {
    return (
      LocaleKeys.editorCoverErrorCanceledTitle,
      LocaleKeys.editorCoverErrorCanceledBody,
    );
  }
  return switch (slot.knownError) {
    AiImageErrorCode.moderation => (
      LocaleKeys.editorCoverErrorModerationTitle,
      LocaleKeys.editorCoverErrorModerationBody,
    ),
    AiImageErrorCode.rate_limit => (
      LocaleKeys.editorCoverErrorRateLimitTitle,
      LocaleKeys.editorCoverErrorRateLimitBody,
    ),
    AiImageErrorCode.auth => (
      LocaleKeys.editorCoverErrorAuthTitle,
      LocaleKeys.editorCoverErrorAuthBody,
    ),
    AiImageErrorCode.size => (
      LocaleKeys.editorCoverErrorSizeTitle,
      LocaleKeys.editorCoverErrorSizeBody,
    ),
    AiImageErrorCode.param => (
      LocaleKeys.editorCoverErrorParamTitle,
      LocaleKeys.editorCoverErrorParamBody,
    ),
    AiImageErrorCode.credit => (
      LocaleKeys.editorCoverErrorCreditTitle,
      LocaleKeys.editorCoverErrorCreditBody,
    ),
    AiImageErrorCode.model_forbidden => (
      LocaleKeys.editorCoverErrorModelForbiddenTitle,
      LocaleKeys.editorCoverErrorModelForbiddenBody,
    ),
    null => (
      LocaleKeys.editorCoverErrorUnknownTitle,
      LocaleKeys.editorCoverErrorUnknownBody,
    ),
  };
}

/// 画面底下的方案说明行：第几个方案 + 当前状态一句话。
class CoverSlotCaption extends ConsumerWidget {
  const CoverSlotCaption({
    super.key,
    required this.novelId,
    required this.slot,
    this.maxWidth = 460,
  });

  final String novelId;
  final CoverSlotView? slot;

  /// 状态那句话在宽舞台上不要拉成一整行；移动端传 [double.infinity]。
  final double maxWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final state = ref.watch(coverStudioControllerProvider(novelId));
    final current = slot;

    final text = switch (current) {
      null => '',
      _ when state.reworkingOrdinal == current.ordinal => context.t(
        LocaleKeys.editorCoverStageReworkCaption,
      ),
      _ when current.pending && state.stopping => context.t(
        LocaleKeys.editorCoverStageStoppingCaption,
      ),
      _ when current.failed && !current.canceled => context.t(
        LocaleKeys.editorCoverStageFailedCaption,
        namedArgs: {'index': '${current.ordinal + 1}'},
      ),
      _ => '',
    };

    return Column(
      children: [
        if (current != null)
          Text(
            context.t(
              LocaleKeys.editorCoverSchemeLabel,
              namedArgs: {'index': '${current.ordinal + 1}'},
            ),
            style: typo.uiSmall.copyWith(color: colors.textSecondary),
          ),
        if (text.isNotEmpty) ...[
          const SizedBox(height: 2),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: typo.uiSmall.copyWith(color: colors.textSubtle),
            ),
          ),
        ],
      ],
    );
  }
}
