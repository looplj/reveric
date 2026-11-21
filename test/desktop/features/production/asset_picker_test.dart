// 职责: 验证制作画布资产选择器的跨作品确认、取消和放置重试。
// 关联文件:
//   lib/desktop/features/production/asset_picker.dart
//   lib/shared/services/production/share_asset_orchestrator.dart
//   test/desktop/director/harness.dart

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:reveric/desktop/features/production/support.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/utils/storage_paths.dart';

import '../../director/harness.dart';

void main() {
  setUpAll(initializeDirectorTest);
  setUp(() => rootBundle.clear());

  testWidgets('keeps sharing explicit and retries only the canvas placement', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppDatabase.forTest(NativeDatabase.memory());
    final content = NovelContentDatabase.forTest(NativeDatabase.memory());
    final root = Directory.systemTemp.createTempSync('asset-picker-');
    addTearDown(() async {
      await content.close();
      await app.close();
      await root.delete(recursive: true);
    });
    for (final (id, title) in [
      ('current', 'Current work'),
      ('source', 'Source work'),
    ]) {
      await app.novelDao.create(id: id, title: title, description: '');
      final path = RevericPaths.mediaPath(id, 'image', 'still.png');
      final source = File(p.join(root.path, path));
      source.parent.createSync(recursive: true);
      source.writeAsBytesSync(img.encodePng(img.Image(width: 8, height: 6)));
      await app.assetDao.insertAsset(
        AssetsCompanion.insert(
          id: id,
          novelId: Value(id),
          type: 'image',
          purpose: 'upload',
          name: Value('$title still'),
          path: Value(path),
          inLibrary: const Value(true),
          content: const Value(ImageAssetContent(mimeType: 'image/png')),
        ),
      );
    }
    final service = ProductionCanvasService(
      StoryboardService(content),
      MediaLibraryService(app, MediaService(FfmpegRunner()), root),
      'current',
    );
    late Completer<AssetRow> initialAttempt;
    final placements = <AssetRow>[];
    await tester.pumpWidget(
      directorTestApp(
        Builder(
          builder: (context) {
            return TextButton(
              onPressed: () => pickProductionAsset(
                context,
                service,
                types: const {'image'},
                addToCanvas: (asset) async {
                  placements.add(asset);
                  if (placements.length == 1) {
                    initialAttempt.complete(asset);
                    throw StateError('Canvas write failed');
                  }
                },
              ),
              child: const Text('Open picker'),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> selectForeignAsset() async {
      await tester.tap(find.text('Open picker'));
      await tester.pumpAndSettle();
      expect(find.text('Current work still'), findsOneWidget);
      expect(find.text('Source work'), findsNothing);
      await tester.tap(find.text('Other works'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Source work'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Source work still'));
      await tester.pumpAndSettle();
      expect(find.text('Share and add'), findsOneWidget);
    }

    await selectForeignAsset();
    await tester.tap(find.text('Source work still'));
    await tester.pumpAndSettle();
    expect(placements, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect((await app.assetDao.getAsset('source'))?.novelId, 'source');

    await selectForeignAsset();
    final shared = (await tester.runAsync(() async {
      initialAttempt = Completer<AssetRow>.sync();
      await tester.tap(find.text('Share and add'));
      return initialAttempt.future.timeout(const Duration(seconds: 5));
    }))!;
    await tester.pumpAndSettle();
    expect(shared.id, 'source');
    expect(shared.novelId, isNull);
    expect(find.textContaining('The asset was shared but'), findsOneWidget);
    await tester.tap(find.text('Add to canvas'));
    await tester.pumpAndSettle();
    expect(placements, [shared, shared]);
    expect(find.text('Shared assets'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
