// 职责: 在制片工具栏选择转录渠道或打开配置。转录开始后不能取消。
// 关联文件:
//   lib/desktop/features/production/node_bar.dart
//   lib/shared/providers/transcription.dart
//   lib/shared/providers/settings_navigation.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/agent/agent_tool_dispatcher.dart';
import '../../../shared/components/reveric_context_menu.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/ai_provider.dart';
import '../../../shared/models/transcription/result.dart';
import '../../../shared/providers/settings_navigation.dart';
import '../../../shared/providers/settings_providers.dart';
import '../../../shared/providers/transcription.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/theme/theme.dart';
import 'popover.dart';

class ProductionTranscriptionAction extends HookConsumerWidget {
  const ProductionTranscriptionAction({
    super.key,
    required this.canvas,
    required this.nodeId,
    required this.assetId,
    required this.hasAudio,
  });

  final ProductionCanvasService canvas;
  final String nodeId;
  final String assetId;
  final bool hasAudio;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = useState(false);
    final candidates = ref
        .watch(aiSettingsProvider)
        .availableModelOptionsForKind(AiModelKind.asr);
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    void showError(String key) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.t(key))));
      }
    }

    Future<void> run(AiModelOption option) async {
      if (!context.mounted || running.value) {
        return;
      }
      final service = ref.read(transcriptionServiceProvider);
      final operation = AgentCancellationController();
      running.value = true;
      try {
        await service.run(
          canvas: canvas,
          assetId: assetId,
          nodeId: nodeId,
          selection: await service.selection(
            providerId: option.providerId,
            modelId: option.model,
          ),
          cancellation: operation.token,
        );
        showError(LocaleKeys.productionTranscriptionReady);
      } on TranscriptionException catch (error) {
        if (error.code != 'cancelled') {
          showError(switch (error.code) {
            'object_storage_required' =>
              LocaleKeys.productionTranscriptionStorage,
            'no_audio' => LocaleKeys.productionVideoNoAudio,
            'no_speech' => LocaleKeys.productionTranscriptionNoSpeech,
            'authentication' ||
            'invalid_config' ||
            'transcription_model_required' =>
              LocaleKeys.productionTranscriptionConfig,
            'invalid_audio_size' ||
            'audio_too_long' => LocaleKeys.productionTranscriptionLimit,
            'submission_unknown' => LocaleKeys.productionTranscriptionUnknown,
            _ => LocaleKeys.productionTranscriptionFailed,
          });
        }
      } finally {
        if (context.mounted) {
          running.value = false;
        }
      }
    }

    final label = context.t(
      running.value
          ? LocaleKeys.productionTranscribing
          : LocaleKeys.productionTranscribe,
    );
    final color = hasAudio ? colors.textSecondary : colors.textSubtle;
    return Tooltip(
      message: !hasAudio
          ? context.t(LocaleKeys.productionVideoNoAudio)
          : !running.value && candidates.isEmpty
          ? context.t(LocaleKeys.productionTranscriptionConfig)
          : label,
      child: Builder(
        builder: (anchor) => ProductionPill(
          onTap: !hasAudio || running.value
              ? null
              : () {
                  if (candidates.isEmpty) {
                    ref.read(settingsNavigationProvider).open('providers');
                    return;
                  }
                  final box = anchor.findRenderObject()! as RenderBox;
                  unawaited(
                    showRevericContextMenu(
                      context: anchor,
                      position: box.localToGlobal(
                        Offset(0, box.size.height + RevericSpacing.xs),
                      ),
                      entries: [
                        for (final option in candidates)
                          RevericMenuItem(
                            label: option.providerDisplayName,
                            description: option.model,
                            onTap: () => unawaited(run(option)),
                          ),
                      ],
                    ),
                  );
                },
          padding: const EdgeInsets.symmetric(horizontal: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RevericIcon(RevericIcons.subtitles, size: 14, color: color),
              const SizedBox(width: 5),
              Text(
                label,
                style: typo.uiSmall.copyWith(
                  color: color,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
