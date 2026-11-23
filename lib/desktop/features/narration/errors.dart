// 职责: 将朗读失败转换为可操作的界面说明。
// 关联文件:
//   lib/shared/models/audio/exception.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/reading.json
//   assets/translations/zh-CN/reading.json
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json

import 'package:flutter/widgets.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/audio/exception.dart';

String narrationErrorText(BuildContext context, Object error) {
  if (error is AudioException) {
    return error.providerMessage ??
        context.t(
          error.messageKey ??
              switch (error.code) {
                'narration_empty' => LocaleKeys.narrationEmpty,
                'narration_no_dialogue' =>
                  LocaleKeys.readingNarrationNoDialogue,
                'narration_character_missing' =>
                  LocaleKeys.narrationMissingCharacter,
                'narration_location_missing' ||
                'narration_scene_missing' => LocaleKeys.narrationMissingScene,
                'invalid_config' => LocaleKeys.narrationInvalidConfig,
                'audio_voice_required' =>
                  LocaleKeys.productionSpeechVoiceRequired,
                'authentication' => LocaleKeys.narrationAuthentication,
                'rate_limited' => LocaleKeys.narrationRateLimited,
                _ => LocaleKeys.narrationFailed,
              },
        );
  }
  return context.t(LocaleKeys.narrationFailed);
}
