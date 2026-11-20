// 职责: 验证聊天 Markdown 链接只打开 HTTP(S)，并保留选区和失败反馈。
// 关联文件:
//   lib/shared/widgets/ai/markdown_text.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/ai/markdown_text.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  final launches = <Map<dynamic, dynamic>>[];
  var launchSucceeds = true;
  var launchThrows = false;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() {
    rootBundle.clear();
    launches.clear();
    launchSucceeds = true;
    launchThrows = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'launch');
          launches.add(call.arguments as Map<dynamic, dynamic>);
          if (launchThrows) {
            throw PlatformException(
              code: 'unavailable',
              message: 'private details',
            );
          }
          return launchSucceeds;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    'tapping named and bare web links opens the external browser',
    (tester) async {
      for (final selectable in [true, false]) {
        for (final source in [
          '[Example](https://example.com/news?q=1#part)',
          'http://example.com/news',
        ]) {
          await tester.pumpWidget(_wrap(source, selectable: selectable));
          await tester.pumpAndSettle();
          final label = source.startsWith('[') ? 'Example' : source;
          await tester.tap(find.text(label, findRichText: true));
          await tester.pumpAndSettle();
          expect(
            launches.last['url'],
            source.startsWith('[')
                ? 'https://example.com/news?q=1#part'
                : source,
          );
          expect(launches.last['useWebView'], false);
          expect(launches.last['useSafariVC'], false);
        }
      }
      expect(launches, hasLength(4));
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.android,
    }),
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'rejects all non-web and malformed destinations at the click boundary',
    (tester) async {
      await tester.pumpWidget(_wrap('[Link](https://example.com)'));
      await tester.pumpAndSettle();
      final click = tester
          .widget<GptMarkdown>(find.byType(GptMarkdown))
          .onLinkTap!;
      for (final url in [
        'file:///tmp/a',
        'javascript:alert(1)',
        'data:text/html,hello',
        'mailto:a@example.com',
        'tel:123',
        'ai.reveric://mcp/oauth/callback',
        '//example.com',
        '/relative',
        '#anchor',
        'https:relative',
        'https://',
        'https://[invalid',
      ]) {
        click(url, 'Link');
      }
      await tester.pumpAndSettle();
      expect(launches, isEmpty);
      click('HTTPS://example.com', 'Link');
      await tester.pumpAndSettle();
      expect(launches.single['url'], 'https://example.com');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'launcher failures are handled without exposing platform details',
    (tester) async {
      await tester.pumpWidget(_wrap('[Example](https://example.com)'));
      await tester.pumpAndSettle();
      launchSucceeds = false;
      await tester.tap(find.text('Example', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.text('Unable to open link.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      launchThrows = true;
      await tester.tap(find.text('Example', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.text('Unable to open link.'), findsOneWidget);
      expect(find.textContaining('private details'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  testWidgets(
    'headings and inline code follow the body color, not the Material theme',
    (tester) async {
      const bodyColor = Color(0xFFFFFFFF);
      await tester.pumpWidget(
        MaterialApp(
          // Material Theme 刻意用浅色，正文颜色用白色，模拟两者不一致。
          theme: RevericThemeData.reveric.toThemeData(),
          home: const Scaffold(
            body: AiMarkdownText(
              '# Title\n\nbody `code` end',
              style: TextStyle(color: bodyColor),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final colors = <String, Color?>{};
      void walk(InlineSpan span, TextStyle? inherited) {
        final style = inherited?.merge(span.style) ?? span.style;
        if (span is TextSpan) {
          final text = span.text?.trim();
          if (text != null && text.isNotEmpty) {
            colors[text] = style?.color;
          }
          for (final child in span.children ?? const <InlineSpan>[]) {
            walk(child, style);
          }
        }
      }

      for (final paragraph in tester.renderObjectList<RenderParagraph>(
        find.byWidgetPredicate((widget) => widget is RichText),
      )) {
        walk(paragraph.text, null);
      }
      expect(colors['Title'], bodyColor);
      expect(colors['code'], bodyColor);
    },
  );
}

Widget _wrap(String content, {bool selectable = true}) => EasyLocalization(
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
      home: Scaffold(
        body: AiMarkdownText(
          content,
          style: RevericThemeData.reveric.typography.body,
          selectable: selectable,
        ),
      ),
    ),
  ),
);
