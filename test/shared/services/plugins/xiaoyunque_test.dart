// 职责: 在真实 QuickJS 宿主中验证两个小云雀插件的模型、配置与启用状态独立。
// 关联文件:
//   plugins/xiaoyunque/src/index.ts
//   plugins/xiaoyunque-marketing/src/index.ts
//   lib/shared/services/plugins/host.dart
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:fjs/fjs.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart' show AppDatabase;
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/models/video/catalog.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/shared/services/plugins/runtime.dart';

void main() {
  setUpAll(() async {
    await LibFjs.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['FJS_PROBE_LIBRARY']!,
      ),
    );
  });
  test(
    'short-film and marketing plugins load independently with distinct settings',
    () async {
      final packages = [
        for (final id in ['reveric.xiaoyunque', 'reveric.xiaoyunque-marketing'])
          PluginPackage(
            'assets/plugins/$id',
            PluginManifest.fromJson(
              jsonDecode(
                    File('assets/plugins/$id/plugin.json').readAsStringSync(),
                  )
                  as Map<String, dynamic>,
            ),
            File('assets/plugins/$id/dist/index.js').readAsStringSync(),
          ),
      ];
      final db = AppDatabase.forTest(NativeDatabase.memory());
      final host = PluginHostService(
        dao: db.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        packages: () async => packages,
        platform: 'macos',
      );
      try {
        await host.start();
        for (var i = 0; i < packages.length; i++) {
          final manifest = packages[i].manifest;
          final marketing = i == 1;
          expect(
            manifest.name.values['zh-CN'],
            marketing ? '小云雀-营销' : '小云雀-短片',
          );
          expect(
            manifest.provider!.fields
                .map((f) => f.key)
                .contains('showSubtitle'),
            marketing,
          );
          await host.setEnabled(manifest.id, true);
          final provider = aiProviderBuiltinById('openai')!.copyWith(
            id: 'xiaoyunque-$i',
            type: 'plugin:${manifest.id}',
            builtin: false,
            enabled: true,
            apiKey: '',
            baseUrl: '',
            models: [],
            imageModels: [],
            videoModels: [],
          );
          await db.aiProviderDao.upsert(provider);
          // Enabling/configuring the first plugin must not supply the second one's key.
          expect(
            (await host.loadProviderConfig(provider)).savedSecrets,
            isEmpty,
          );
          await expectLater(
            host.callProvider(provider, 'checkConnection'),
            throwsA(
              isA<PluginHostError>().having(
                (e) => e.code,
                'code',
                'configuration_required',
              ),
            ),
          );
          await host.saveProviderConfig(
            provider,
            settings: {},
            secrets: {'accessKey': 'test-only-key-$i'},
          );
          final discovery = await host.discoverProviderModels(provider);
          expect(discovery.models, hasLength(marketing ? 4 : 10));
          const catalogIds = {
            'seedance2.0_fast_vision': 'doubao-seedance-2-0-fast-260128',
            'seedance2.0_vision': 'doubao-seedance-2-0-260128',
            'Seedance_2.0_mini': 'doubao-seedance-2-0-mini-260615',
            'Seedance_2.0_mini_lite': 'doubao-seedance-2-0-mini-260615',
            'Seedance_2.5': 'doubao-seedance-2-5-260628',
            'MiniMax-H3': 'MiniMax-H3',
            'MiniMax-H3-Max': 'hailuo-3-max',
            'wan3.0': 'wan3.0-video',
            'happyhorse-1.1': 'happyhorse-1.1',
          };
          for (final model in discovery.models) {
            final actual = model.video!;
            if (model.id == 'Seedance_2.5_flash') {
              // Flash uses the supplied channel config rather than the standard 2.5 catalog.
              expect(marketing, isFalse);
              expect(actual.resolutions, {'480p', '720p'});
              expect(actual.durations, {
                for (var seconds = 4; seconds <= 30; seconds++) seconds,
              });
              expect(actual.maxReferences, 50);
              expect(actual.maxPromptCharacters, 15000);
              final limits = actual.references.map(
                (kind, limit) => MapEntry(kind.name, limit),
              );
              expect(limits['image']!.maxCount, 10);
              expect(limits['image']!.maxSizeMb, 30);
              expect(limits['video']!.maxCount, 5);
              expect(limits['video']!.maxTotalDurationMs, 30200);
              expect(limits['audio']!.maxCount, 5);
              expect(limits['audio']!.maxDurationMs, 30000);
              continue;
            }
            final expected =
                videoModelsCatalog[catalogIds[model.id]]!.capabilities;
            expect(
              actual.maxReferences,
              expected.maxReferences,
              reason: model.id,
            );
            expect(
              actual.references.map(
                (kind, limits) => MapEntry(kind, limits.maxCount),
              ),
              expected.references.map(
                (kind, limits) => MapEntry(kind, limits.maxCount),
              ),
              reason: model.id,
            );
            if (!marketing) {
              expect(actual.durations, expected.durations, reason: model.id);
            }
          }
          expect(
            discovery.models.every(
              (m) => m.video != null && !m.id.contains('/'),
            ),
            isTrue,
          );
          expect(
            discovery.models.any((m) => m.id == 'Seedance_2.5'),
            !marketing,
          );
          expect(
            host.providerHasMethod(manifest.id, 'uploadReference'),
            isTrue,
          );
          expect(host.providerHasMethod(manifest.id, 'video.query'), isTrue);
          expect(
            host.providerHasMethod(manifest.id, 'actions.queryCredits'),
            isTrue,
          );
          expect(host.providerHasMethod(manifest.id, 'image.submit'), isFalse);
        }
        await host.setEnabled('reveric.xiaoyunque', false);
        expect(aiProviderTypeConfigFor('plugin:reveric.xiaoyunque'), isNull);
        expect(
          aiProviderTypeConfigFor('plugin:reveric.xiaoyunque-marketing'),
          isNotNull,
        );
      } finally {
        await host.dispose();
        await db.close();
      }
    },
  );
}
