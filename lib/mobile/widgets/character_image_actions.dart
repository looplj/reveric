// 职责: 从移动人物编辑页选择图像风格，保存资料后携带人物引用进入 AI 聊天生成头像或照片。
// 关联文件:
//   lib/mobile/pages/character_editor_page.dart
//   lib/mobile/pages/novel_chat_page.dart
//   lib/mobile/widgets/character_image_style_sheet.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/providers/ai_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/tool.json
//   assets/translations/zh-CN/tool.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
//   .agents/rules/ai-calling.md

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/components/reveric_button.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/logger/app_logger.dart';
import '../../shared/models/novel_workspace.dart';
import '../../shared/models/queued_chat_message.dart';
import '../../shared/providers/ai_providers.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/services/character_image_prompt_builder.dart';
import '../../shared/theme/theme.dart';
import '../pages/agent_model_settings_page.dart';
import '../pages/novel_chat_page.dart';
import 'character_image_style_sheet.dart';
import 'sheet.dart';

final _log = AppLogger.forModule('MobileCharacterImages');

class MobileCharacterImageActions extends HookConsumerWidget {
  const MobileCharacterImageActions({
    super.key,
    required this.databasePath,
    required this.characterId,
    required this.prepareCharacter,
  });

  final String databasePath;
  final String characterId;
  final Future<bool> Function() prepareCharacter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = useState(false);

    Future<void> generate({required bool avatar}) async {
      if (busy.value) {
        return;
      }
      busy.value = true;
      try {
        if (!ref.read(isImageGenerationConfiguredProvider)) {
          await openMobileAgentModelSettingsPage(context);
          return;
        }
        final label = context.t(
          avatar
              ? LocaleKeys.toolNameGenerateAvatar
              : LocaleKeys.toolNameGeneratePhoto,
        );
        final style = await showMobileSheet<String>(
          context: context,
          builder: (_) => MobileCharacterImageStyleSheet(
            title: context.t(
              avatar
                  ? LocaleKeys.workspaceCharacterGenerateAvatar
                  : LocaleKeys.workspaceCharacterGeneratePhoto,
            ),
            confirmLabel: label,
          ),
        );
        if (!context.mounted || style == null) {
          return;
        }
        if (!await prepareCharacter()) {
          throw StateError('Character edits could not be saved');
        }
        if (!context.mounted) {
          return;
        }
        final service = ref.read(novelContentServiceProvider(databasePath));
        final novel = await ref
            .read(novelActionsProvider)
            .getNovelByContentDatabasePath(databasePath);
        final character = await service.getCharacterProfileById(characterId);
        if (!context.mounted) {
          return;
        }
        if (novel == null || character == null) {
          throw StateError('Character image generation target is missing');
        }
        final prompt = avatar
            ? buildCharacterAvatarPrompt(
                name: character.name,
                stylePrompt: style,
              )
            : buildCharacterPhotoPrompt(
                name: character.name,
                stylePrompt: style,
                avatarAssetId: character.avatarAssetId,
              );
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => MobileNovelChatPage(
              novelId: novel.id,
              databasePath: databasePath,
              handoff: PendingChatHandoff(
                label: label,
                content: prompt,
                initialText: prompt,
                autoSend: true,
                references: [
                  AiContextReference(
                    section: NovelWorkspaceSection.characters,
                    itemId: character.id,
                    label: character.name,
                  ),
                ],
              ),
            ),
          ),
        );
      } catch (error, stackTrace) {
        _log.error(
          'Start character image generation failed',
          error: error,
          stackTrace: stackTrace,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
          );
        }
      } finally {
        if (context.mounted) {
          busy.value = false;
        }
      }
    }

    return Wrap(
      spacing: RevericSpacing.sm,
      runSpacing: RevericSpacing.sm,
      children: [
        RevericButton.secondary(
          key: const ValueKey('character-generate-avatar'),
          label: context.t(LocaleKeys.workspaceCharacterGenerateAvatar),
          icon: RevericIcons.auto_awesome,
          onPressed: busy.value ? null : () => generate(avatar: true),
        ),
        RevericButton.secondary(
          key: const ValueKey('character-generate-photo'),
          label: context.t(LocaleKeys.workspaceCharacterGeneratePhoto),
          icon: RevericIcons.auto_awesome,
          onPressed: busy.value ? null : () => generate(avatar: false),
        ),
      ],
    );
  }
}
