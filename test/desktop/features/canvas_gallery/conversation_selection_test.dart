// 职责: 验证发布和本机导出共用的会话选择器可按行独立多选。
// 关联文件:
//   lib/desktop/features/canvas_gallery/conversation_selection.dart
//   lib/shared/services/production/canvas_package.dart

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/features/canvas_gallery/conversation_selection.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_chat_models.dart';
import 'package:reveric/shared/services/production/canvas_package.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());

  testWidgets(
    'sessions can be selected independently from the row or the checkbox',
    (tester) async {
      final selection = ValueNotifier<Set<String>>({});
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
                child: Scaffold(
                  body: ValueListenableBuilder(
                    valueListenable: selection,
                    builder: (context, selected, _) =>
                        CanvasConversationSelection(
                          sessions: [
                            _session('one', 'First chat'),
                            _session('two', 'Second chat'),
                          ],
                          selected: selected,
                          onChanged: (id, checked) {
                            selection.value = toggleCanvasConversation(
                              selection.value,
                              id,
                              checked,
                            );
                          },
                          onReplace: (next) => selection.value = next,
                        ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Include saved conversations'), findsOneWidget);
      final toggles = find.byType(Checkbox);
      expect(toggles, findsNWidgets(2));
      expect(selection.value, isEmpty);
      expect(find.text('Public message in one'), findsNothing);
      await tester.tap(find.text('First chat'));
      await tester.pumpAndSettle();
      expect(selection.value, {'one'});
      await tester.tap(toggles.at(1));
      await tester.pumpAndSettle();
      expect(selection.value, {'one', 'two'});
      await tester.tap(toggles.at(0));
      await tester.pumpAndSettle();
      expect(selection.value, {'two'});
      await tester.tap(find.text('Deselect all'));
      await tester.pumpAndSettle();
      expect(selection.value, isEmpty);
      await tester.tap(find.text('Select all'));
      await tester.pumpAndSettle();
      expect(selection.value, {'one', 'two'});
      await tester.pumpWidget(const SizedBox.shrink());
      selection.dispose();
    },
  );
}

ProductionCanvasPackageConversation _session(String id, String title) =>
    ProductionCanvasPackageConversation(
      ProductionCanvasPackageConversationSummary(
        id: id,
        title: title,
        createdAt: DateTime(2026, 3, 1),
        updatedAt: DateTime(2026, 3, 2),
        model: null,
        agentSlug: null,
        messageCount: 1,
        fileCount: 0,
      ),
      [AiMessage.user(id: id, content: 'Public message in $id')],
    );
