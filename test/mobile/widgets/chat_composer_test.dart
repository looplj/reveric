// 职责: 验证移动聊天输入条在 375px 下的附件布局与发送、排队、停止启用状态。
// 关联文件:
//   lib/mobile/widgets/chat_composer.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/en/mobile.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/zh-CN/mobile.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reveric/shared/widgets/ai/chat/composer_controller.dart';
import 'package:reveric/shared/services/ai/chat_attachments.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/mobile/widgets/chat_composer.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => rootBundle.clear());
  testWidgets('inline files preserve IME composition and delete as one unit', (
    tester,
  ) async {
    final controller = ChatComposerController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    controller.insertText('根据');
    controller.insertFiles([
      NamedChatFile.data(Uint8List.fromList([1]), name: '说明.md'),
    ]);
    controller.insertText('继续');
    await tester.pumpWidget(
      _wrap(
        MobileChatComposer(
          controller: controller,
          focusNode: focus,
          isBusy: false,
          onSend: () {},
          onStop: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('[说明.md]'), findsOneWidget);
    await tester.showKeyboard(find.byType(TextField));
    final previous = controller.text;
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: '${previous}zhong',
        selection: TextSelection.collapsed(offset: previous.length + 5),
        composing: TextRange(start: previous.length, end: previous.length + 5),
      ),
    );
    await tester.pump();
    expect(controller.value.composing.isCollapsed, isFalse);
    expect(controller.snapshot().attachments, hasLength(1));
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: '$previous中',
        selection: TextSelection.collapsed(offset: previous.length + 1),
      ),
    );
    await tester.pump();
    controller.selection = const TextSelection.collapsed(offset: 3);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(controller.text, '根据继续中');
    expect(controller.snapshot().attachments, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  for (final (locale, label) in [
    (const Locale('en'), 'Image'),
    (const Locale('zh', 'CN'), '图像'),
  ]) {
    testWidgets('image labels use $label and remain attached after moving', (
      tester,
    ) async {
      final controller = ChatComposerController();
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      controller.insertFiles([
        NamedChatFile.data(Uint8List.fromList([1]), name: 'one.png'),
        NamedChatFile.data(Uint8List.fromList([2]), name: 'two.png'),
      ]);
      await tester.pumpWidget(
        _wrap(
          MobileChatComposer(
            controller: controller,
            focusNode: focus,
            isBusy: false,
            onSend: () {},
            onStop: () {},
          ),
          locale: locale,
        ),
      );
      await tester.pumpAndSettle();
      for (final key in [
        LocaleKeys.aiAttachmentReadFailed,
        LocaleKeys.aiAttachmentTooManyImages,
        LocaleKeys.aiAttachmentModelUnsupported,
        LocaleKeys.aiAttachmentUnavailable,
      ]) {
        expect(
          key.tr(context: tester.element(find.byType(MobileChatComposer))),
          isNot(key),
        );
      }
      expect(find.text('[$label #1]'), findsOneWidget);
      expect(find.text('[$label #2]'), findsOneWidget);
      expect(find.text('[one.png]'), findsNothing);
      controller.moveFile(1, 0);
      await tester.pump();
      expect(
        find.descendant(
          of: find.byTooltip('one.png'),
          matching: find.text('[$label #1]'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byTooltip('two.png'),
          matching: find.text('[$label #2]'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('handles send states without overflowing at 375px', (
    tester,
  ) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 812);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    var referenceTapCount = 0;
    var fileTapCount = 0;
    var sendTapCount = 0;
    var stopTapCount = 0;

    await tester.pumpWidget(
      _wrap(
        MobileChatComposer(
          controller: controller,
          focusNode: focusNode,
          isBusy: false,
          onSend: () {
            sendTapCount++;
          },
          onStop: () {},
          onAttach: () {
            referenceTapCount++;
          },
          onAttachFile: () {
            fileTapCount++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Add context'), findsOneWidget);
    expect(find.byTooltip('Select file'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Send'));
    expect(sendTapCount, 0);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    expect(sendTapCount, 0);

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    expect(sendTapCount, 1);

    await tester.tap(find.byTooltip('Add context'));
    await tester.tap(find.byTooltip('Select file'));
    expect(referenceTapCount, 1);
    expect(fileTapCount, 1);

    controller.clear();
    await tester.pump();
    await tester.pumpWidget(
      _wrap(
        MobileChatComposer(
          controller: controller,
          focusNode: focusNode,
          isBusy: false,
          hasPendingHandoff: true,
          onSend: () {
            sendTapCount++;
          },
          onStop: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Send'));
    expect(sendTapCount, 2);

    controller.text = 'blocked';
    await tester.pumpWidget(
      _wrap(
        MobileChatComposer(
          controller: controller,
          focusNode: focusNode,
          isBusy: false,
          sendBlocked: true,
          onSend: () {
            sendTapCount++;
          },
          onStop: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Send'));
    expect(sendTapCount, 2);

    controller.clear();
    await tester.pumpWidget(
      _wrap(
        MobileChatComposer(
          controller: controller,
          focusNode: focusNode,
          isBusy: true,
          onSend: () {
            sendTapCount++;
          },
          onStop: () {
            stopTapCount++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Stop'), findsOneWidget);
    expect(find.byTooltip('Send'), findsNothing);
    await tester.tap(find.byTooltip('Stop'));
    expect(stopTapCount, 1);

    controller.text = 'queued';
    await tester.pump();
    expect(find.byTooltip('Stop'), findsOneWidget);
    expect(find.byTooltip('Send'), findsOneWidget);
    await tester.tap(find.byTooltip('Send'));
    expect(sendTapCount, 3);

    var dismissCount = 0;
    await tester.pumpWidget(
      _wrap(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MobileChatComposerNotice(
              message:
                  'The model response was incomplete. Press Send to retry.',
              onDismiss: () {
                dismissCount++;
              },
            ),
            MobileChatComposer(
              controller: TextEditingController(text: 'retry me'),
              focusNode: FocusNode(),
              isBusy: false,
              onSend: () {},
              onStop: () {},
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MobileChatComposerNotice), findsOneWidget);
    expect(
      find.textContaining('model response was incomplete'),
      findsOneWidget,
    );
    expect(find.byTooltip('Close'), findsOneWidget);

    await tester.tap(find.byTooltip('Close'));
    expect(dismissCount, 1);
  });
}

Widget _wrap(Widget child, {Locale locale = const Locale('en')}) {
  return EasyLocalization(
    supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    fallbackLocale: const Locale('en'),
    startLocale: locale,
    saveLocale: false,
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
