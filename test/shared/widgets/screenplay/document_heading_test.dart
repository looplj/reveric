// 职责: 验证剧本场次头的对齐排版、正文不出排序手柄与无删除按钮。
// 关联文件:
//   lib/shared/widgets/screenplay/document_heading.dart
//   lib/shared/widgets/screenplay/element_layout.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/services/novel_actions.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import 'package:reveric/shared/models/screenplay_element.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/screenplay/document_heading.dart';
import 'package:reveric/shared/widgets/screenplay/document_rows.dart';
import 'package:reveric/shared/widgets/screenplay/document_session.dart';
import 'package:reveric/shared/widgets/screenplay/editing_scope.dart';
import 'package:reveric/shared/widgets/screenplay/element_layout.dart';

late Map<String, dynamic> _translations;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    _translations = (await const MergingAssetLoader().load(
      'assets/translations',
      const Locale('en'),
    ))!;
  });

  testWidgets('场次头左侧只留对齐沟槽，不出排序手柄，右侧也无删除按钮', (tester) async {
    final db = NovelContentDatabase.forTest(NativeDatabase.memory());
    final app = AppDatabase.forTest(NativeDatabase.memory());
    final service = ScreenplayService(db);
    final initial = await service.createInitialStructure();
    final root = (await db.screenplayDao.getRoot())!;
    await service.createScene(
      screenplayId: root.id,
      episodeId: initial.episodeId,
      timeLabel: '日',
    );
    final overlay = WorkingOverlayService(
      db,
      NovelContentService(db),
      novelActionsService: NovelActionsService(app),
    );
    final doc = await service.readDocument(initial.episodeId);
    final session = ScreenplayDocumentSession(
      doc,
      database: db,
      service: service,
      overlay: overlay,
    );
    final controller = session.controller;
    final headingElement = controller.value.firstWhere((e) => e.isHeading);
    if (headingElement.locationId != null) {
      controller.locationNames = {headingElement.locationId!: '萧家演武场'};
    }
    controller.characterNames = {'char_1': '萧炎', 'char_2': '萧薰儿'};

    addTearDown(session.dispose);
    addTearDown(db.close);
    addTearDown(app.close);

    final actions = ScreenplayDocumentActions(
      session,
      (_, _) async => null,
      false,
      'memory:test',
      'work',
    );

    await tester.pumpWidget(
      _wrap(
        ScreenplayDocumentHeading(actions: actions, element: headingElement),
      ),
    );
    await tester.pumpAndSettle();

    // 1. 验证右侧无删除按钮
    expect(find.byIcon(Icons.delete), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is RevericIcon &&
            (w.assetPath == RevericIcons.delete ||
                w.assetPath == RevericIcons.delete_outline),
      ),
      findsNothing,
    );

    // 2. 左侧沟槽仍在，宽度为 ScreenplayElementLayout.gutter (20)，只用来对齐
    expect(
      find.byWidgetPredicate(
        (w) => w is SizedBox && w.width == ScreenplayElementLayout.gutter,
      ),
      findsOneWidget,
    );

    // 3. 排序改到左栏场次列表，正文里既没有手柄图标也不能拖
    expect(
      find.byWidgetPredicate(
        (w) => w is RevericIcon && w.assetPath == RevericIcons.more_vert,
      ),
      findsNothing,
    );
    expect(find.byType(Draggable<String>), findsNothing);
    expect(find.byType(DragTarget<String>), findsNothing);

    // 4. 悬停不改变场次头的呈现
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(
      location: tester.getCenter(find.byType(ScreenplayDocumentHeading)),
    );
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (w) => w is RevericIcon && w.assetPath == RevericIcons.more_vert,
      ),
      findsNothing,
    );

    // 5. 验证正文标题与场号存在
    expect(find.textContaining('1、'), findsOneWidget);

    await gesture.removePointer();

    // 6. 没有正文的场次：点标题下方留出的正文区，能在这一场里落下一条动作
    final emptyHeading = controller.value.lastWhere((e) => e.isHeading);
    expect(controller.value.last, same(emptyHeading));
    final selectedScene = ValueNotifier<String?>(null);
    addTearDown(selectedScene.dispose);
    await tester.pumpWidget(
      _wrap(
        ScreenplayEditingScope(
          controller: controller,
          onFocusElement: (_, _) {},
          child: ScreenplayDocumentRows(
            actions: actions,
            selectedSceneId: selectedScene,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final headingBox = tester.getRect(
      find.byWidgetPredicate(
        (w) =>
            w is ScreenplayDocumentHeading && w.element.id == emptyHeading.id,
      ),
    );
    await tester.tapAt(headingBox.bottomLeft + const Offset(80, 16));
    await tester.pumpAndSettle();
    final added = controller.value.last;
    expect(added.isHeading, isFalse);
    expect(added.type, ScreenplayElementType.action);
    expect(added.sceneId, emptyHeading.sceneId);
    expect(
      controller.positionAt(controller.selection.extentOffset).index,
      controller.value.length - 1,
    );

    // 7. 空首行上退格只删这一行，不走合并场次；光标回到上一场末尾
    controller.edit(
      [...controller.value]
        ..[controller.value.length - 1] = added.copyWith(text: '开场'),
    );
    controller.select(
      TextSelection.collapsed(offset: controller.source.length),
    );
    await controller.enter(soft: false);
    await controller.splitScene();
    await tester.pumpAndSettle();
    final secondHeading = controller.value[controller.value.length - 2];
    expect(secondHeading.isHeading, isTrue);
    expect(controller.value.last.text, isEmpty);
    await tester.tapAt(
      tester
              .getRect(
                find.byWidgetPredicate(
                  (w) =>
                      w is ScreenplayDocumentHeading &&
                      w.element.id == secondHeading.id,
                ),
              )
              .bottomLeft +
          const Offset(80, 16),
    );
    await tester.pumpAndSettle();
    expect(
      controller.positionAt(controller.selection.extentOffset).index,
      controller.value.length - 1,
    );
    // 本场只剩这一条空行：退格问要不要删场，取消则原样不动
    String? asked;
    var answer = false;
    controller.confirmDeleteScene = (_, _, sceneId) async {
      asked = sceneId;
      return answer;
    };
    final before = [...controller.value];
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(asked, secondHeading.sceneId);
    expect(controller.value.map((e) => e.id), before.map((e) => e.id));

    // 确认后整场删掉（不并进上一场），光标回到上一场末尾
    answer = true;
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(controller.value.where((e) => e.isHeading).map((e) => e.id), [
      emptyHeading.id,
    ]);
    expect(controller.value.last.text, '开场');
    expect(controller.screenplay!.scenes.keys, [emptyHeading.sceneId]);
    expect(controller.selection.extentOffset, controller.source.length);

    await tester.pumpWidget(const SizedBox.shrink());
    // 拆场会排一次延迟保存，走完它再结束，免得留下挂起的定时器。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}

Widget _wrap(Widget child) => EasyLocalization(
  supportedLocales: const [Locale('en')],
  path: 'assets/translations',
  assetLoader: const _LoadedTranslations(),
  fallbackLocale: const Locale('en'),
  startLocale: const Locale('en'),
  child: Builder(
    builder: (context) => RevericTheme(
      data: RevericThemeData.reveric,
      child: MaterialApp(
        localizationsDelegates: context.localizationDelegates,
        supportedLocales: context.supportedLocales,
        locale: context.locale,
        theme: RevericThemeData.reveric.toThemeData(),
        home: Scaffold(body: child),
      ),
    ),
  ),
);

class _LoadedTranslations extends AssetLoader {
  const _LoadedTranslations();
  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async =>
      _translations;
}
