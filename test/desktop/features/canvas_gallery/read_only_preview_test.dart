// 职责: 验证公开对话不会请求正文图片，并限制归档图片的读取和解码。
// 关联文件:
//   lib/shared/widgets/ai/chat/chat_message_view.dart
//   lib/shared/widgets/ai/chat/published_chat_image.dart
//   lib/shared/widgets/ai/tools/character_image_tool_card.dart

import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;
import 'package:reveric/desktop/features/asset/media_preview.dart';
import 'package:reveric/desktop/features/canvas_gallery/detail_panel.dart';
import 'package:reveric/desktop/widgets/ai/chat/floating.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/production/canvas_package.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/ai/chat/chat_message_view.dart';
import 'package:reveric/shared/widgets/ai/chat/published_chat_image.dart';
import 'package:reveric/shared/widgets/ai/chat/ui_message.dart';
import 'package:reveric/shared/widgets/ai/tools/character_image_tool_card.dart';
import 'package:reveric/shared/widgets/app_background.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());

  testWidgets('public Markdown and image cards do not request remote images', (
    tester,
  ) async {
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: const [Locale('en')],
        path: 'assets/translations',
        assetLoader: const MergingAssetLoader(),
        fallbackLocale: const Locale('en'),
        startLocale: const Locale('en'),
        child: Builder(
          builder: (context) => MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            theme: RevericThemeData.reveric.toThemeData(),
            home: RevericTheme(
              data: RevericThemeData.reveric,
              child: ProviderScope(
                overrides: [aiAgentAvatarPathProvider.overrideWithValue('')],
                child: const Scaffold(
                  body: SingleChildScrollView(
                    child: ChatMessageView(
                      activeSessionId: null,
                      readOnly: true,
                      message: UIMessage(
                        id: 'gallery-1',
                        role: AiMessageRole.assistant,
                        type: AiMessageType.text,
                        content: '',
                        isStreaming: false,
                        isStreamingTail: false,
                        sourceIds: ['gallery-1'],
                        blocks: [
                          AiTextBlock(
                            id: 'text',
                            text:
                                'Hello ![caption](https://example.com/photo.png) '
                                '[Read more](https://example.com/article)',
                          ),
                          AiImageBlock(
                            id: 'image',
                            prompt: 'A portrait',
                            toolName: 'GeneratePhoto',
                            status: AiImageStatus.success,
                            imageUrl: 'https://example.com/result.png',
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final markdown = find.byType(GptMarkdown);
    expect(markdown, findsOneWidget);
    expect(tester.widget<GptMarkdown>(markdown).onLinkTap, isNotNull);
    expect(find.textContaining('Read more', findRichText: true), findsWidgets);
    expect(
      find.descendant(of: markdown, matching: find.byType(Image)),
      findsNothing,
    );
    final toolCard = find.byType(AiCharacterImageToolCard);
    expect(toolCard, findsOneWidget);
    expect(
      find.descendant(of: toolCard, matching: find.byType(Image)),
      findsNothing,
    );
  });

  test(
    'public image provider validates raw dimensions and bounds file reads',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'public-chat-image',
      );
      try {
        final small = await File(
          p.join(directory.path, 'small.png'),
        ).writeAsBytes(image.encodePng(image.Image(width: 384, height: 192)));
        final preview = await _load(
          PublishedChatImage(small.path, previewSide: 192),
        );
        try {
          expect(preview.image.width, 192);
          expect(preview.image.height, 96);
        } finally {
          preview.dispose();
        }

        final tooWide = await File(
          p.join(directory.path, 'wide.png'),
        ).writeAsBytes(image.encodePng(image.Image(width: 4097, height: 1)));
        await expectLater(
          _load(PublishedChatImage(tooWide.path)),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('dimension'),
            ),
          ),
        );

        final tooManyBytes = File(p.join(directory.path, 'large.png'));
        final handle = await tooManyBytes.open(mode: FileMode.write);
        try {
          await handle.truncate(32 * 1024 * 1024 + 1);
        } finally {
          await handle.close();
        }
        await expectLater(
          _load(PublishedChatImage(tooManyBytes.path)),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('byte'),
            ),
          ),
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'MediaPreviewDialog resolves sandbox images through required MediaPathResolver',
    (tester) async {
      final dir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('media-resolver-test'),
      ))!;
      addTearDown(() async {
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      });
      final pngFile = (await tester.runAsync(
        () => File(
          p.join(dir.path, 'pic.png'),
        ).writeAsBytes(image.encodePng(image.Image(width: 24, height: 16))),
      ))!;
      final resolver = _FakePathResolver({
        'file_workspaces/g/pic.png': pngFile.path,
      });

      await tester.pumpWidget(
        EasyLocalization(
          supportedLocales: const [Locale('en')],
          path: 'assets/translations',
          assetLoader: const MergingAssetLoader(),
          fallbackLocale: const Locale('en'),
          startLocale: const Locale('en'),
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              theme: RevericThemeData.reveric.toThemeData(),
              home: RevericTheme(
                data: RevericThemeData.reveric,
                child: ProviderScope(
                  child: Scaffold(
                    body: MediaPreviewDialog.file(
                      path: 'file_workspaces/g/pic.png',
                      type: 'image',
                      name: 'Sandbox pic',
                      pathResolver: resolver,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      await tester.pump();

      expect(resolver.requested, contains('file_workspaces/g/pic.png'));
      expect(find.text('Sandbox pic'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'read-only FloatingAiChat switches static gallery conversations and shows model subtitle',
    (tester) async {
      final now = DateTime(2026, 8, 12, 10);
      final conversations = [
        ProductionCanvasPackageConversation(
          ProductionCanvasPackageConversationSummary(
            id: 'c1',
            title: 'First storyboard chat',
            createdAt: now,
            updatedAt: now,
            model: 'claude-sonnet-4',
            agentSlug: 'director',
            messageCount: 1,
            fileCount: 0,
          ),
          [
            AiMessage.user(
              id: 'm1',
              content: 'Draft shot one',
              blocks: const [AiTextBlock(id: 'b1', text: 'Draft shot one')],
            ),
          ],
        ),
        ProductionCanvasPackageConversation(
          ProductionCanvasPackageConversationSummary(
            id: 'c2',
            title: 'Lighting pass',
            createdAt: now,
            updatedAt: now,
            model: 'gemini-2.5-pro',
            agentSlug: null,
            messageCount: 1,
            fileCount: 0,
          ),
          [
            AiMessage.user(
              id: 'm2',
              content: 'Add warm sunset rim light',
              blocks: const [
                AiTextBlock(id: 'b2', text: 'Add warm sunset rim light'),
              ],
            ),
          ],
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appBackgroundActiveProvider.overrideWithValue(false),
            aiAgentAvatarPathProvider.overrideWithValue(''),
          ],
          child: EasyLocalization(
            supportedLocales: const [Locale('en')],
            path: 'assets/translations',
            assetLoader: const MergingAssetLoader(),
            fallbackLocale: const Locale('en'),
            startLocale: const Locale('en'),
            child: Builder(
              builder: (context) => MaterialApp(
                localizationsDelegates: context.localizationDelegates,
                supportedLocales: context.supportedLocales,
                locale: context.locale,
                theme: RevericThemeData.reveric.toThemeData(),
                home: RevericTheme(
                  data: RevericThemeData.reveric,
                  child: Scaffold(
                    body: FloatingAiChat(
                      open: true,
                      onOpenChanged: (_) {},
                      sessionId: null,
                      readOnly: true,
                      panel: GalleryFloatingChatPanel(
                        conversations: conversations,
                        onClose: () {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('First storyboard chat'), findsOneWidget);
      expect(find.text('claude-sonnet-4'), findsNWidgets(2));
      expect(
        find.textContaining('Draft shot one', findRichText: true),
        findsWidgets,
      );
      final composer = find.byKey(const Key('gallery-read-only-composer'));
      expect(composer, findsOneWidget);
      final field = tester.widget<TextField>(
        find.descendant(of: composer, matching: find.byType(TextField)),
      );
      expect(field.readOnly, isTrue);
      expect(field.enabled, isFalse);
      expect(field.canRequestFocus, isFalse);
      expect(
        tester
            .widget<OutlinedButton>(
              find.descendant(
                of: composer,
                matching: find.byType(OutlinedButton),
              ),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.descendant(of: composer, matching: find.byType(IconButton)),
            )
            .onPressed,
        isNull,
      );

      // 点击标题下拉切换到第二个会话。
      await tester.tap(find.text('First storyboard chat'));
      await tester.pumpAndSettle();
      expect(find.text('Lighting pass'), findsOneWidget);
      await tester.tap(find.text('Lighting pass'));
      await tester.pumpAndSettle();

      expect(find.text('gemini-2.5-pro'), findsNWidgets(2));
      expect(
        find.textContaining('Add warm sunset rim light', findRichText: true),
        findsWidgets,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}

class _FakePathResolver implements MediaPathResolver {
  _FakePathResolver(this.mapping);

  final Map<String, String> mapping;
  final requested = <String>[];

  @override
  String resolvePath(String stored) {
    requested.add(stored);
    return mapping[stored]!;
  }
}

Future<ImageInfo> _load(PublishedChatImage image) async {
  final result = Completer<ImageInfo>();
  final stream = image.resolve(ImageConfiguration.empty);
  final listener = ImageStreamListener(
    (image, _) => result.complete(image),
    onError: (error, stackTrace) => result.completeError(error, stackTrace),
  );
  stream.addListener(listener);
  try {
    return await result.future;
  } finally {
    stream.removeListener(listener);
    await image.evict();
  }
}
