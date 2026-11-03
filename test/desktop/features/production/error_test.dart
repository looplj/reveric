// 职责: 验证视频参考校验提示、音视频 HTTP 失败的中英文提示及预期错误日志。
// 关联文件:
//   lib/desktop/features/production/composer.dart
//   lib/desktop/features/production/support.dart
//   lib/shared/services/ai/video/agnes.dart
//   lib/shared/localization/merging_asset_loader.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json

import 'dart:convert';
import 'dart:io';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/desktop/features/production/support.dart';
import 'package:reveric/desktop/features/production/composer.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/video/capabilities.dart';
import 'package:reveric/shared/models/video/channels.dart';
import 'package:reveric/shared/models/video/task_result.dart';
import 'package:reveric/shared/services/production/generate_orchestrator.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/models/audio/request.dart';
import 'package:reveric/shared/services/ai/audio/seed.dart';
import 'package:reveric/shared/services/ai/video/agnes.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final (model, mode, inputRoles, expected) in [
    (
      'veo-3.1',
      VideoMode.reference,
      [VideoInputRole.middle_frame],
      LocaleKeys.productionGenerateReferenceUnsupported,
    ),
    (
      'veo-3.1',
      VideoMode.first_last_frame,
      [VideoInputRole.first_frame, VideoInputRole.middle_frame],
      LocaleKeys.productionGenerateMiddleFramesUnsupported,
    ),
    (
      'veo-3.1',
      VideoMode.reference,
      [VideoInputRole.first_frame],
      LocaleKeys.productionGenerateReferenceUnsupported,
    ),
    (
      'veo-3.1',
      VideoMode.first_last_frame,
      [VideoInputRole.first_frame, VideoInputRole.last_frame],
      LocaleKeys.productionGenerateFramesUnsupported,
    ),
    (
      'veo-3.1',
      VideoMode.first_last_frame,
      <VideoInputRole>[],
      LocaleKeys.productionGenerateFramesRequired,
    ),
    (
      'veo-3.1',
      VideoMode.first_last_frame,
      [VideoInputRole.first_frame, VideoInputRole.first_frame],
      LocaleKeys.productionGenerateFramesRequired,
    ),
  ]) {
    test('$model $mode $inputRoles explains the actual reference failure', () {
      final roles = inputRoles
          .map((role) => productionSubmitRole(mode, role))
          .toList();
      try {
        const VideoCapabilities('api88').validateParameters(
          VideoRequest(
            modelId: model,
            prompt: 'bird',
            mode: productionSubmitMode(mode, roles),
            resolution: '720p',
            ratio: '16:9',
            durationSeconds: 4,
          ),
          roles,
        );
        fail('Expected reference validation to reject these inputs');
      } on VideoException catch (error) {
        expect(error.field, 'references');
        expect(
          productionReferenceErrorKey(
            channel: lookupVideoChannelModel('api88', model)!,
            mode: mode,
            roles: roles,
          ),
          expected,
        );
      }
    });
  }
  test('New API Veo accepts the same image as a single first frame', () {
    const VideoCapabilities('api88').validateParameters(
      const VideoRequest(
        modelId: 'veo-3.1',
        prompt: 'bird',
        mode: VideoMode.first_frame,
        resolution: '720p',
        ratio: '16:9',
        durationSeconds: 4,
      ),
      [VideoInputRole.first_frame],
    );
  });
  test('reference hints are translated in both interface languages', () {
    for (final locale in ['en', 'zh-CN']) {
      final strings =
          jsonDecode(
                File(
                  'assets/translations/$locale/screenplay.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      for (final key in [
        LocaleKeys.productionGenerateReferenceUnsupported,
        LocaleKeys.productionGenerateFramesUnsupported,
        LocaleKeys.productionGenerateReferencesInvalid,
        LocaleKeys.productionGenerateMiddleFramesUnsupported,
      ]) {
        expect(
          strings[key],
          isA<String>().having((s) => s.trim(), 'text', isNotEmpty),
        );
        expect(
          strings[key],
          isNot(strings[LocaleKeys.productionGenerateFramesRequired]),
        );
      }
    }
  });
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  for (final (locale, expected, status, body) in [
    (
      const Locale('en'),
      'No service channel is currently available for this model. Try again later or choose another provider.',
      503,
      '{"error":{"message":"No available channel for private-model"}}',
    ),
    (
      const Locale('zh', 'CN'),
      '模型服务暂无可用渠道，请稍后重试或更换模型服务。',
      503,
      '{"error":{"message":"No available channel for private-model"}}',
    ),
    (
      const Locale('zh', 'CN'),
      '参考图片被供应商判定可能包含真人，未通过审核。请检查图片是否符合该模型的使用要求。',
      400,
      '{"error":{"code":"InputImageSensitiveContentDetected.PrivacyInformation","message":"Request failed"}}',
    ),
    (
      const Locale('en'),
      'The provider rejected the reference images because they may contain real people. Check whether the images meet this model\'s usage requirements.',
      400,
      '{"error":{"code":"InputImageSensitiveContentDetected.PrivacyInformation","message":"Request failed"}}',
    ),
  ]) {
    for (final audio in [false, true]) {
      testWidgets(
        '${audio ? "audio" : "video"} HTTP $status displays the matched provider reason in $locale',
        (tester) async {
          final lines = <String>[];
          final originalDebugPrint = debugPrint;
          debugPrint = (message, {wrapWidth}) {
            if (message != null) {
              lines.add(message);
            }
          };
          addTearDown(() => debugPrint = originalDebugPrint);
          try {
            BuildContext? actionContext;
            await tester.pumpWidget(
              EasyLocalization(
                supportedLocales: [locale],
                path: 'assets/translations',
                assetLoader: const MergingAssetLoader(),
                startLocale: locale,
                fallbackLocale: locale,
                saveLocale: false,
                child: Builder(
                  builder: (context) => MaterialApp(
                    localizationsDelegates: context.localizationDelegates,
                    supportedLocales: context.supportedLocales,
                    locale: context.locale,
                    home: Scaffold(
                      body: Builder(
                        builder: (context) {
                          actionContext = context;
                          return const SizedBox.shrink();
                        },
                      ),
                    ),
                  ),
                ),
              ),
            );
            for (var i = 0; i < 30 && actionContext == null; i++) {
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(actionContext, isNotNull);
            var posts = 0;
            final transport = MockClient((_) async {
              posts++;
              return http.Response(body, status);
            });
            final client = AgnesVideoClient(
              httpClient: transport,
              providerType: 'agnes',
              endpoint: Uri.parse('https://example.test/v1'),
              apiKey: 'test-key',
            );
            await productionRun(actionContext!, () async {
              if (audio) {
                await SeedAudioClient(
                  transport,
                  'test-key',
                  providerType: 'volcengine',
                ).generate(
                  AudioRequest(
                    providerId: 'audio',
                    modelId: 'seed-audio-1.0',
                    prompt: 'bird',
                    originalPrompt: 'bird',
                  ),
                );
                return;
              }
              await client.submit(
                const VideoRequest(
                  modelId: 'agnes-video-2.5-flash',
                  prompt: 'bird',
                  mode: VideoMode.text,
                  resolution: '720P',
                  ratio: '16:9',
                  durationSeconds: 6,
                ),
                [],
              );
            });
            await tester.pumpAndSettle();
            expect(find.text(expected), findsOneWidget);
            expect(find.textContaining('private-model'), findsNothing);
            expect(posts, 1);
            expect(
              lines.where(
                (line) => line.contains(
                  audio ? '[WARN] [AudioClient]' : '[WARN] [VideoClient]',
                ),
              ),
              hasLength(1),
            );
            expect(
              lines.join('\n'),
              isNot(contains('[Production] UI operation failed')),
            );
            // Unexpected program errors still retain their diagnostic at the UI boundary.
            await productionRun(
              actionContext!,
              () async => throw StateError('unexpected-marker'),
            );
            expect(
              lines.join('\n'),
              contains('[Production] UI operation failed'),
            );
            expect(lines.join('\n'), contains('unexpected-marker'));
            transport.close();
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
          } finally {
            debugPrint = originalDebugPrint;
          }
        },
        variant: TargetPlatformVariant({
          TargetPlatform.windows,
          TargetPlatform.macOS,
          TargetPlatform.android,
        }),
      );
    }
  }
}
