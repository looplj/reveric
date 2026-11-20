// 职责: 在视频角色图片参考的角标上选择本次使用的角色音色，并就地试听。
// 关联文件:
//   lib/desktop/features/production/composer.dart
//   lib/desktop/features/production/voices.dart
//   lib/shared/services/production/voices.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:video_player/video_player.dart';
import '../../../shared/components/reveric_context_menu.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/character_voice.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/services/production/voices.dart';
import '../../../shared/theme/theme.dart';
import 'support.dart';
import 'voice_preview.dart';
import 'voices.dart';

class ProductionCharacterInput extends HookWidget {
  const ProductionCharacterInput({
    super.key,
    required this.service,
    required this.input,
    required this.framesMode,
    required this.onChanged,
    required this.child,
  });
  final ProductionCanvasService service;
  final ProductionInput input;

  /// 首尾帧模式不支持音色；已选的音色保留但标灰，提示用户切换模式或取消。
  final bool framesMode;
  final ValueChanged<ProductionInput> onChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final character = useStream(
      useMemoized(() => service.watchInputCharacter(input), [
        service,
        input.refType,
        input.refId,
        input.roleName,
      ]),
    );
    final asset = useProductionAsset(service, input.voiceAssetId);
    final preview = useVoicePreview();
    final data = character.data;
    if (data == null && input.voiceAssetId == null) {
      return child;
    }
    final voices = data?.voices ?? const <CharacterVoice>[];
    final voice = voices
        .where((v) => v.assetId == input.voiceAssetId)
        .firstOrNull;
    final chosen = input.voiceAssetId != null;
    final label = !chosen
        ? context.t(LocaleKeys.productionVoices)
        : voice?.name.isNotEmpty == true
        ? voice!.name
        : asset?.name ??
              context.t(LocaleKeys.productionGenerateReferenceMissing);
    final colors = RevericTheme.colorsOf(context);
    final active = chosen && !framesMode;

    void select(String? id) {
      if (context.mounted && id != input.voiceAssetId) {
        onChanged(input.withVoice(id));
      }
    }

    final playing = preview.playing == input.voiceAssetId;
    Future<void> play() => productionRun(
      context,
      () => preview.toggle(input.voiceAssetId!, () async {
        final file = await service.requireFile(asset!.path!, type: 'audio');
        return VideoPlayerController.file(
          File(service.library.resolvePath(file.path)),
        );
      }),
    );

    void menu(BuildContext anchor) {
      final box = anchor.findRenderObject()! as RenderBox;
      final check = RevericIcon(
        RevericIcons.check,
        size: 12,
        color: colors.accent,
      );
      showRevericContextMenu(
        context: context,
        position: box.localToGlobal(box.size.bottomLeft(Offset.zero)),
        minWidth: 180,
        entries: [
          if (chosen) ...[
            RevericMenuItem(
              icon: playing
                  ? RevericIcons.stop_rounded
                  : RevericIcons.play_arrow,
              label: context.t(
                playing ? LocaleKeys.commonStop : LocaleKeys.commonPlay,
              ),
              enabled: asset?.path != null,
              onTap: play,
            ),
            const RevericMenuDivider(),
          ],
          for (final v in voices)
            RevericMenuItem(
              label: v.name.isEmpty
                  ? context.t(LocaleKeys.commonUntitled)
                  : v.name,
              trailing: v.assetId == input.voiceAssetId ? check : null,
              onTap: () => select(v.assetId),
            ),
          RevericMenuItem(
            label: context.t(LocaleKeys.commonNone),
            trailing: chosen ? null : check,
            onTap: () => select(null),
          ),
          const RevericMenuDivider(),
          RevericMenuItem(
            label: context.t(LocaleKeys.productionVoicesManage),
            icon: RevericIcons.music_notes,
            onTap: () => showProductionVoices(context, service, data!.id),
          ),
        ],
      );
    }

    // 角标压在缩略图右上角，不额外占宽，输入之间保持原有间距。
    const badge = 18.0;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          top: -RevericSpacing.xxs,
          right: -RevericSpacing.xxs,
          child: Tooltip(
            message: framesMode && chosen
                ? '$label\n${context.t(LocaleKeys.productionVoiceMode)}'
                : label,
            child: Builder(
              builder: (anchor) => MouseRegion(
                cursor: data == null
                    ? SystemMouseCursors.basic
                    : SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: data == null ? null : () => menu(anchor),
                  child: Container(
                    width: badge,
                    height: badge,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: active
                          ? colors.accent
                          : chosen
                          ? colors.warningBg
                          : colors.surface,
                      border: Border.all(
                        color: active ? colors.accent : colors.border,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: RevericIcon(
                      playing
                          ? RevericIcons.speaker_high
                          : RevericIcons.music_notes,
                      size: 11,
                      color: active
                          ? colors.onAccent
                          : chosen
                          ? colors.warningText
                          : colors.textMuted,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
