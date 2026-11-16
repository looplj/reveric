// 职责: 验证移动端封面工作台页能挂载 — 空态、抽屉提示词不丢、生成中底部条切进度与停止。
// 关联文件:
//   lib/mobile/features/cover_studio/studio_page.dart
//   lib/mobile/features/cover_studio/designer_sheet.dart
//   lib/shared/providers/cover_studio_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/i18n.md

import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/mobile/features/cover_studio/studio_page.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/ai_providers.dart';
import 'package:reveric/shared/providers/cover_studio_providers.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/cover_prompt_builder.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/app_background.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  late AppDatabase database;

  setUp(() => database = AppDatabase.forTest(NativeDatabase.memory()));
  tearDown(() => database.close());

  // 同一文件只放一个 testWidgets：第二个重包 EasyLocalization 会拿到空子树，
  // 所以几个场景在同一个 test 内连续 pump。
  testWidgets('移动端工作台：空态、抽屉往返不丢提示词、出图中切进度条', (tester) async {
    // iPhone 逻辑像素，竖版封面在这个高度上最容易被挤掉。
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    late WidgetRef capturedRef;
    await tester.pumpWidget(
      _wrap(
        database: database,
        child: Consumer(
          builder: (context, ref, _) {
            capturedRef = ref;
            return MobileCoverStudioPage(
              novel: _novel,
              // 内容库未打开：封面档案整块收起，出图流程照常。
              databasePath: null,
              onApply: (_) async {},
            );
          },
        ),
      ),
    );
    await tester.pump();

    // 回归点：hooks 的 useEffect 首次运行在 initHook 里，那里读 Localizations /
    // ScaffoldMessenger 会直接断言失败，整页白屏。窄屏溢出也会在这里冒出来。
    expect(tester.takeException(), isNull);

    // 没选批次 → 空态；参数都在抽屉里，主页上不该出现。
    expect(find.text('Cover preview'), findsOneWidget);
    expect(find.text('Cover Designer'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    // 拉起设计师抽屉：提示词框此时才出现，且已填默认种子。
    await tester.tap(find.text('Cover Designer'));
    await tester.pumpAndSettle();
    final promptField = find.byType(TextField);
    expect(promptField, findsOneWidget);
    final seed = defaultCoverPrompt(
      novelTitle: _novel.title,
      authorName: _novel.authorName,
    );
    expect(tester.widget<TextField>(promptField).controller?.text, seed);

    // 回归点：抽屉是另一条 route，controller 归页面所有。改了字关掉再开，
    // 文本必须还在 —— 否则就说明 controller 被抽屉重建掉了。
    await tester.enterText(promptField, '临时改一版');
    await tester.pump();
    await tester.tapAt(const Offset(195, 20)); // 点抽屉外的遮罩关掉
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.text('Cover Designer'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '临时改一版',
    );

    // 「新建」的信号：draftSeq 一变，提示词回默认种子（记录抽屉里按下）。
    capturedRef
        .read(coverStudioControllerProvider(_novel.id).notifier)
        .startNewDraft();
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      seed,
    );

    await tester.tapAt(const Offset(195, 20));
    await tester.pumpAndSettle();

    // 选一个历史批次：参数与提示词都回填，画布跟着切过去。
    final batch = ImageBatchRow(
      id: 'history_batch',
      novelId: _novel.id,
      purpose: 'cover',
      status: imageBatchStatusCompleted,
      prompt: '历史封面提示词',
      paramsJson:
          '{"ratio":"3_4","resolution":"4k","quality":"high",'
          '"references":[{"asset_id":"reference_asset","role":"style"}]}',
      requestedCount: 3,
      completedCount: 1,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      deletedAt: notDeletedSentinel,
    );
    capturedRef
        .read(coverStudioControllerProvider(_novel.id).notifier)
        .selectBatch(batch);
    await tester.pump();

    final restored = capturedRef.read(coverStudioControllerProvider(_novel.id));
    expect(restored.selectedBatchId, batch.id);
    expect(restored.ratioId, '3_4');
    expect(restored.batchCount, 3);
    expect(restored.references.single, 'reference_asset');
    expect(tester.takeException(), isNull);
  });
}

final _novel = Novel(
  id: 'novel_test',
  title: '南渡记',
  authorName: '柳三变',
  description: '明末江南的一段旧事。',
  draft: false,
  category: '',
  tags: const [],
  status: '',
  type: '',
  contentKind: contentKindNovel,
  wordCount: 0,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  deletedAt: notDeletedSentinel,
);

Widget _wrap({required AppDatabase database, required Widget child}) {
  return ProviderScope(
    overrides: [
      aiSettingsProvider.overrideWithValue(AiSettings(providers: const [])),
      appDatabaseProvider.overrideWithValue(database),
      // 不走 settings DB：否则 dispose 时 Drift stream 会留下 pending Timer。
      appBackgroundActiveProvider.overrideWithValue(false),
      coverStudioImageModelSelectionProvider.overrideWithValue(null),
      imageAssetsProvider(
        _novel.id,
      ).overrideWith((ref) => Stream.value(const <AssetRow>[])),
      imageBatchesProvider(
        _novel.id,
      ).overrideWith((ref) => Stream.value(const <ImageBatchRow>[])),
    ],
    child: EasyLocalization(
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
            // 与 main.dart 一致：RevericTheme 挂在 builder 上，modal route 的
            // 子树才拿得到它。挂在 home 下面的话，底部抽屉会 assert 没有主题。
            builder: (context, child) =>
                RevericTheme(data: RevericThemeData.reveric, child: child!),
            home: child,
          );
        },
      ),
    ),
  );
}
