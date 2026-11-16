// 职责: 验证封面工作台整页能挂载 — 画布|设计师两列、hooks 生命周期与 toast 都不在 build 期违规。
// 关联文件:
//   lib/desktop/features/cover_studio/studio_page.dart
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
import 'package:reveric/shared/providers/cover_studio_providers.dart';
import 'package:reveric/desktop/features/cover_studio/studio_page.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/ai_providers.dart';
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

  // 同一文件只放一个 testWidgets：第二个重包 EasyLocalization 会拿到空子树。
  testWidgets('整页能挂载并弹出 toast，不在 build 期读 InheritedWidget', (tester) async {
    // 编辑器主区在 1470 宽窗口下的可用宽度。
    await tester.binding.setSurfaceSize(const Size(1470, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    late WidgetRef capturedRef;
    await tester.pumpWidget(
      _wrap(
        database: database,
        child: Consumer(
          builder: (context, ref, _) {
            capturedRef = ref;
            return CoverStudio(
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
    // ScaffoldMessenger 会直接断言失败，整页白屏。
    expect(tester.takeException(), isNull);

    // 生成记录已迁到侧栏中栏；Main 只剩画布 + 设计师。
    expect(find.text('Generation Records'), findsNothing);
    expect(find.text('Cover Designer'), findsOneWidget);

    // 走一遍 toast：从 controller 发一条，应当弹出且不抛异常。
    capturedRef
        .read(coverStudioControllerProvider(_novel.id).notifier)
        .stop(); // 未在生成中，不该弹
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);

    capturedRef
        .read(coverStudioControllerProvider(_novel.id).notifier)
        .selectOrdinal(1);
    await tester.pump();
    expect(tester.takeException(), isNull);

    // 「新建」按在侧栏中栏，这里只能验证它的信号：draftSeq 一变，提示词回默认种子。
    final promptField = find.byType(TextField);
    expect(promptField, findsOneWidget);
    await tester.enterText(promptField, '临时改一版');
    expect(tester.widget<TextField>(promptField).controller?.text, '临时改一版');

    capturedRef
        .read(coverStudioControllerProvider(_novel.id).notifier)
        .startNewDraft();
    await tester.pump();
    expect(
      tester.widget<TextField>(promptField).controller?.text,
      defaultCoverPrompt(
        novelTitle: _novel.title,
        authorName: _novel.authorName,
      ),
    );

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
    expect(restored.resolutionId, '4k');
    expect(restored.qualityId, 'high');
    expect(restored.batchCount, 3);
    // 旧批次的 params 里还带着 role，读回来只取 asset_id。
    expect(restored.references.single, 'reference_asset');
    expect(
      tester.widget<TextField>(promptField).controller?.text,
      batch.prompt,
    );
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
            home: RevericTheme(
              data: RevericThemeData.reveric,
              child: Scaffold(body: child),
            ),
          );
        },
      ),
    ),
  );
}
