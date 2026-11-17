// 职责: 验证 Markdown 只读预览支持文本选择，并可通过复制按钮写入原始 Markdown。
// 关联文件:
//   lib/shared/widgets/md/reveric_markdown_editor.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/i18n.md
//   .agents/rules/code-style.md
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/md/reveric_markdown_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('selects and copies the original Markdown', (tester) async {
    const markdown = '## Core principle\n\nKeep the plot moving.';
    String? clipboardText;
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments as Map<dynamic, dynamic>;
            clipboardText = args['text']?.toString();
          }
          return null;
        });

    await tester.pumpWidget(
      _wrap(const RevericMarkdownPreview(data: markdown, showCopyButton: true)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(IconButton), findsOneWidget);

    tester.widget<IconButton>(find.byType(IconButton)).onPressed!();
    await tester.pump();

    expect(clipboardText, markdown);

    // maxLines 限定下只解析可见范围，但复制按钮仍写入完整原文。
    final long = '- item\n' * 400;
    await tester.pumpWidget(
      _wrap(
        RevericMarkdownPreview(
          data: long,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          showCopyButton: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final rendered = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((widget) => widget.text.toPlainText())
        .firstWhere((text) => text.startsWith('• item'));
    expect(rendered.length, lessThan(long.length));

    tester.widget<IconButton>(find.byType(IconButton)).onPressed!();
    await tester.pump();

    expect(clipboardText, long);
  });

  testWidgets('drag-selects preview text and copies that range', (
    tester,
  ) async {
    const source = 'Alpha beta gamma delta';
    String? clipboardText;
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments as Map<dynamic, dynamic>;
            clipboardText = args['text']?.toString();
          }
          return null;
        });

    await tester.pumpWidget(
      _wrap(
        const SingleChildScrollView(
          child: RevericMarkdownPreview(data: source, showCopyButton: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final rich = tester.widget<RichText>(find.byType(RichText));
    expect(rich.selectionRegistrar, isNotNull);
    expect(rich.selectionColor, isNotNull);

    final rect = tester.getRect(find.byType(RichText));
    final gesture = await tester.startGesture(
      rect.centerLeft + const Offset(2, 0),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(rect.centerRight - const Offset(2, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(clipboardText, isNotNull);
    expect(source.contains(clipboardText!), isTrue);
    expect(clipboardText!.trim().length, greaterThan(4));
  });
}

Widget _wrap(Widget child) {
  return EasyLocalization(
    supportedLocales: const [Locale('en')],
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    fallbackLocale: const Locale('en'),
    startLocale: const Locale('en'),
    child: Builder(
      builder: (context) {
        return MaterialApp(
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          theme: RevericThemeData.reveric.toThemeData(),
          home: RevericTheme(
            data: RevericThemeData.reveric,
            child: Scaffold(body: child),
          ),
        );
      },
    ),
  );
}
