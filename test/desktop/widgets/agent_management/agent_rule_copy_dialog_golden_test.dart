// 职责: 跨作品复制规则对话框黄金图（加载真实字体），人工目检真实文字下的分栏与勾选态。
// 关联文件:
//   lib/desktop/widgets/agent_management/agent_rule_copy_dialog.dart
//   lib/desktop/widgets/agent_management/agent_rules_grid_page.dart

import 'dart:io';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/widgets/agent_management/agent_rules_grid_page.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../helpers/button_golden_theme.dart';

const _targetPath = 'agent-rule-copy-golden-target';
const _sourcePath = 'agent-rule-copy-golden-source';

Future<void> _loadFont(String family, String path) async {
  final loader = FontLoader(family);
  final bytes = await File(path).readAsBytes();
  loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
  await loader.load();
}

AgentRule _rule(String id, String name, String content, {int sortOrder = 0}) {
  final now = DateTime.now();
  return AgentRule(
    id: id,
    name: name,
    content: content,
    enabled: true,
    sortOrder: sortOrder,
    createdAt: now,
    updatedAt: now,
    deletedAt: notDeletedSentinel,
  );
}

Novel _novel(String id, String title, String? databasePath) {
  final now = DateTime.now();
  return Novel(
    id: id,
    title: title,
    authorName: '作者',
    description: '',
    status: 'ongoing',
    type: 'original',
    contentKind: contentKindNovel,
    contentDatabasePath: databasePath,
    wordCount: 0,
    draft: false,
    category: '玄幻',
    tags: const [],
    createdAt: now,
    updatedAt: now,
    deletedAt: notDeletedSentinel,
  );
}

RevericThemeData _goldenTheme() {
  const source = RevericTypography.desktop;
  return RevericThemeData.reveric.copyWith(
    typography: RevericTypography(
      display: source.display.copyWith(fontFamily: 'LXGWWenKai'),
      heading2: source.heading2.copyWith(fontFamily: 'LXGWWenKai'),
      body: source.body.copyWith(fontFamily: 'LXGWWenKai'),
      bodySmall: source.bodySmall.copyWith(fontFamily: 'LXGWWenKai'),
      bodyItalic: source.bodyItalic.copyWith(fontFamily: 'LXGWWenKai'),
      ui: source.ui.copyWith(fontFamily: 'LXGWWenKai'),
      uiMedium: source.uiMedium.copyWith(fontFamily: 'LXGWWenKai'),
      uiSemibold: source.uiSemibold.copyWith(fontFamily: 'LXGWWenKai'),
      uiSmall: source.uiSmall.copyWith(fontFamily: 'LXGWWenKai'),
      uiSmallSemibold: source.uiSmallSemibold.copyWith(
        fontFamily: 'LXGWWenKai',
      ),
      uiTiny: source.uiTiny.copyWith(fontFamily: 'LXGWWenKai'),
      uiTinySemibold: source.uiTinySemibold.copyWith(fontFamily: 'LXGWWenKai'),
      mono: source.mono.copyWith(fontFamily: 'LXGWWenKai'),
    ),
  );
}

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // 设置服务会在建 widget 树时打开 AppDatabase，需要给 path_provider 兜底目录。
    final tempDir = await Directory.systemTemp.createTemp('agent-rule-copy-');
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => tempDir.path,
        );
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    await _loadFont('LXGWWenKai', 'assets/fonts/LXGWWenKai-Regular.ttf');
    await _loadFont('Georgia', 'assets/fonts/LXGWWenKai-Regular.ttf');
  });

  testWidgets('golden: copy dialog with source novel selected', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final targetDatabase = NovelContentDatabase.forTest(
      NativeDatabase.memory(),
    );
    final sourceDatabase = NovelContentDatabase.forTest(
      NativeDatabase.memory(),
    );
    final targetService = NovelContentService(targetDatabase);
    final sourceService = NovelContentService(sourceDatabase);
    addTearDown(targetDatabase.close);
    addTearDown(sourceDatabase.close);

    await targetService.upsertAgentRule(
      _rule('target-1', '写作风格', '保持轻松幽默的叙事风格，句子短一些。'),
    );
    await sourceService.upsertAgentRule(
      _rule('source-1', '写作风格', '来源作品的同名规则，不能重复复制。'),
    );
    await sourceService.upsertAgentRule(
      _rule('source-2', '视角约束', '全程第三人称限知视角，不写主角以外的心理活动。', sortOrder: 1),
    );
    await sourceService.upsertAgentRule(
      _rule('source-3', '禁用词', '不要出现现代网络流行语与英文缩写。', sortOrder: 2),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          novelContentServiceProvider(
            _targetPath,
          ).overrideWithValue(targetService),
          novelContentServiceProvider(
            _sourcePath,
          ).overrideWithValue(sourceService),
          novelsProvider.overrideWith(
            (ref) => Stream.value([
              _novel('novel-target', '当前作品', _targetPath),
              _novel('novel-source', '参考作品', _sourcePath),
              _novel('novel-other', '另一本长篇', 'agent-rule-copy-golden-other'),
            ]),
          ),
        ],
        child: EasyLocalization(
          supportedLocales: const [Locale('zh', 'CN')],
          path: 'assets/translations',
          assetLoader: const MergingAssetLoader(),
          fallbackLocale: const Locale('zh', 'CN'),
          startLocale: const Locale('zh', 'CN'),
          child: Builder(
            builder: (context) {
              return MaterialApp(
                localizationsDelegates: context.localizationDelegates,
                supportedLocales: context.supportedLocales,
                locale: context.locale,
                theme: withGoldenButtonFont(
                  _goldenTheme().toThemeData(fontFamily: 'LXGWWenKai'),
                  family: 'LXGWWenKai',
                ),
                home: RevericTheme(
                  data: _goldenTheme(),
                  child: Scaffold(
                    body: AgentRulesGridPage(
                      novelId: 'novel-target',
                      databasePath: _targetPath,
                      headerGestureExclusionKey: GlobalKey(),
                      onOpen: (_) {},
                      onCreate: () {},
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('从其他作品复制'));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    await tester.tap(find.descendant(of: dialog, matching: find.text('参考作品')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: dialog, matching: find.text('视角约束')));
    await tester.pumpAndSettle();

    await expectLater(
      dialog,
      matchesGoldenFile('goldens/agent_rule_copy_dialog.png'),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
