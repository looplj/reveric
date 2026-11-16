// 职责: 验证封面生成记录列表空态、「新建」复位工作台，以及记录行只留时间/状态与删除入口。
// 关联文件:
//   lib/desktop/features/cover_studio/records.dart
//   lib/shared/providers/cover_studio_providers.dart
//   lib/shared/database/daos/image_asset_dao.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/data-deletion.md
//   .agents/rules/i18n.md

import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/shared/providers/cover_studio_providers.dart';
import 'package:reveric/desktop/features/cover_studio/records.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/cover_prompt_builder.dart';
import 'package:reveric/shared/theme/theme.dart';
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
  testWidgets('新建复位工作台；记录行只剩时间与状态，删记录不删图', (tester) async {
    late WidgetRef capturedRef;
    await tester.pumpWidget(
      _wrap(
        database: database,
        child: Consumer(
          builder: (context, ref, _) {
            capturedRef = ref;
            return const CoverStudioRecordsList(novelId: 'novel_test');
          },
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Generation Records'), findsOneWidget);
    expect(find.text('Batches you generate show up here'), findsOneWidget);
    expect(find.byKey(const ValueKey('cover-studio-back')), findsNothing);

    // ---- 「新建」= 整个工作台复位 ----------------------------------------
    final newButton = find.byKey(const ValueKey('cover-studio-new'));
    expect(newButton, findsOneWidget);

    final notifier = capturedRef.read(
      coverStudioControllerProvider('novel_test').notifier,
    );
    notifier.selectBatch(
      ImageBatchRow(
        id: 'batch_a',
        purpose: 'cover',
        status: imageBatchStatusCompleted,
        prompt: '一张封面',
        requestedCount: 1,
        completedCount: 1,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        deletedAt: notDeletedSentinel,
      ),
    );
    notifier.addReference('asset_a');
    notifier.setRatio('1_1');
    notifier.setBatchCount(3);
    await tester.pump();
    final dirty = capturedRef.read(coverStudioControllerProvider('novel_test'));
    expect(dirty.selectedBatchId, 'batch_a');
    expect(dirty.references, hasLength(1));

    await tester.tap(newButton);
    await tester.pump();
    final fresh = capturedRef.read(coverStudioControllerProvider('novel_test'));
    expect(fresh.selectedBatchId, isNull);
    expect(fresh.references, isEmpty);
    expect(fresh.ratioId, coverDefaultRatioId);
    expect(fresh.batchCount, coverBatchCount);
    // 页面靠这个序号把提示词重置回默认种子。
    expect(fresh.draftSeq, 1);

    // ---- 记录行：无预览图、无前后图标，只留行尾的删除 ---------------------
    await _seedBatch(database);
    await tester.pump();
    await tester.pump();

    final deleteButton = find.byKey(
      const ValueKey('cover-batch-delete-batch_a'),
    );
    expect(deleteButton, findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(_iconFinder(RevericIcons.history_outlined), findsNothing);
    expect(_iconFinder(RevericIcons.arrow_counter_clockwise), findsNothing);
    expect(find.text('1 images'), findsOneWidget);
    expect(find.text('1 reference images'), findsOneWidget);

    // ---- 删记录只收走批次，图留在库里 -------------------------------------
    notifier.selectBatch(
      ImageBatchRow(
        id: 'batch_a',
        purpose: 'cover',
        status: imageBatchStatusCompleted,
        prompt: '一张封面',
        requestedCount: 1,
        completedCount: 1,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        deletedAt: notDeletedSentinel,
      ),
    );
    await tester.pump();
    await tester.tap(deleteButton);
    await tester.pump();
    await tester.pump();

    expect(await database.imageAssetDao.getBatch('batch_a'), isNull);
    expect(await database.imageAssetDao.getAsset('asset_a'), isNotNull);
    expect(
      capturedRef
          .read(coverStudioControllerProvider('novel_test'))
          .selectedBatchId,
      isNull,
    );
    expect(deleteButton, findsNothing);
    expect(tester.takeException(), isNull);

    // 拆掉整棵树并 settle：drift 的 StreamQueryStore 在 provider dispose 时会排
    // 一个 0 延时 timer，不走这一步会以「Timer is still pending」告败。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

Finder _iconFinder(String assetPath) => find.byWidgetPredicate(
  (widget) => widget is RevericIcon && widget.assetPath == assetPath,
);

/// 一批出了一张图：批次 + 格子 + 资产，用来验证删批次不会连图一起删。
Future<void> _seedBatch(AppDatabase database) async {
  final dao = database.imageAssetDao;
  await dao.insertAsset(
    AssetsCompanion.insert(
      type: 'image',
      id: 'asset_a',
      purpose: 'cover',
      path: Value('covers/asset_a.png'),
      content: const Value(ImageAssetContent(mimeType: 'image/png')),
      novelId: const Value('novel_test'),
      batchId: const Value('batch_a'),
      deletedAt: Value(notDeletedSentinel),
    ),
  );
  await dao.insertBatch(
    ImageBatchesCompanion.insert(
      id: 'batch_a',
      prompt: '一张封面',
      novelId: const Value('novel_test'),
      status: const Value(imageBatchStatusCompleted),
      completedCount: const Value(1),
      paramsJson: const Value('{"references":[{"assetId":"asset_ref"}]}'),
      deletedAt: Value(notDeletedSentinel),
    ),
  );
  await dao.insertSlots([
    ImageBatchSlotsCompanion.insert(
      id: 'slot_a',
      batchId: 'batch_a',
      ordinal: 0,
      status: const Value(imageBatchSlotStatusSucceeded),
      assetId: const Value('asset_a'),
    ),
  ]);
}

Widget _wrap({required AppDatabase database, required Widget child}) {
  return ProviderScope(
    overrides: [
      aiSettingsProvider.overrideWithValue(AiSettings(providers: const [])),
      appDatabaseProvider.overrideWithValue(database),
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
              child: Scaffold(body: SizedBox(width: 236, child: child)),
            ),
          );
        },
      ),
    ),
  );
}
