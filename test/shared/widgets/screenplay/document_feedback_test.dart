// 职责: 验证桌面和移动尺寸下重载草稿失败时提示留在弹窗内，且仍能关闭弹窗。
// 关联文件:
//   lib/shared/widgets/screenplay/document_rows.dart
//   lib/shared/components/dialog_feedback.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/components/dialog_feedback.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/screenplay_document.dart';
import 'package:reveric/shared/services/document_save_coordinator.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/screenplay/document_rows.dart';
import 'package:reveric/shared/widgets/screenplay/document_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());

  for (final width in [900.0, 375.0]) {
    testWidgets('reload failure stays in the dialog at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = _ReloadFailureSession();
      addTearDown(session.queue.dispose);
      final actions = ScreenplayDocumentActions(
        session,
        (_, _) async => null,
        width < 600,
        'unused',
        'work',
      );
      await tester.pumpWidget(
        EasyLocalization(
          supportedLocales: const [Locale('en')],
          path: 'assets/translations',
          assetLoader: const MergingAssetLoader(),
          startLocale: const Locale('en'),
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              theme: RevericThemeData.reveric.toThemeData(),
              builder: (_, child) =>
                  RevericTheme(data: RevericThemeData.reveric, child: child!),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => actions.showSaveError(context),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final dialogRect = tester.getRect(find.byType(DialogFeedback).first);
      await tester.tap(find.text('Discard draft and reload'));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      final snackRect = tester.getRect(find.byType(SnackBar));
      expect(dialogRect.intersect(snackRect), snackRect);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}

class _ReloadFailureSession implements ScreenplayDocumentSession {
  @override
  final queue = DocumentSaveCoordinator<ScreenplayDocument>(save: (_) async {});

  @override
  Future<void> reload() async => throw StateError('reload failed');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
