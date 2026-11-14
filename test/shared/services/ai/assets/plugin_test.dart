// 职责: 使用真实插件验证认证文件授权、结果落库和注册能力生命周期。
// 关联文件:
//   lib/shared/services/ai/assets/plugin.dart
//   lib/shared/services/ai/assets/certification.dart
import 'dart:io';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fjs/fjs.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/plugin/manifest.dart';
import 'package:reveric/shared/models/production/media.dart';
import 'package:reveric/shared/models/provider_asset.dart';
import 'package:reveric/shared/services/ai/assets/certification.dart';
import 'package:reveric/shared/services/ai/video/reference_storage_service.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/registry.dart';

class _NoStorage implements ReferenceStorageService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Certification must not use S3');
}

void main() {
  setUpAll(() async {
    await LibFjs.init(
      externalLibrary: ExternalLibrary.open(
        Platform.environment['FJS_PROBE_LIBRARY']!,
      ),
    );
  });
  test(
    'plugin certifies via scoped upload without S3 and polls into active',
    () async {
      final db = AppDatabase.forTest(NativeDatabase.memory());
      final dir = await Directory.systemTemp.createTemp(
        'plugin-certification-',
      );
      final file = await File('${dir.path}/image.png').writeAsBytes([1, 2, 3]);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var uploads = 0;
      server.listen((request) async {
        expect(request.uri.path, '/upload');
        expect(await request.fold<List<int>>([], (a, b) => a..addAll(b)), [
          1,
          2,
          3,
        ]);
        uploads++;
        request.response.write('ok');
        await request.response.close();
      });
      final provider = aiProviderBuiltinById('openai')!.copyWith(
        id: 'cert-instance',
        type: 'plugin:test.certification',
        enabled: true,
        apiKey: '',
        baseUrl: '',
      );
      await db.aiProviderDao.upsert(provider);
      final host = PluginHostService(
        dao: db.pluginDao,
        registry: PluginRegistry(hostToolNames: {}),
        platform: 'macos',
        packages: () async => [
          PluginPackage(
            'memory',
            PluginManifest.fromJson({
              'id': 'test.certification',
              'name': 'Certification',
              'version': '1.0.0',
              'pluginApiVersion': '^1',
              'main': 'dist/index.js',
              'provider': {
                'name': 'Certification',
                'settings': {'fields': {}},
              },
            }),
            """var __revericPlugin={apply(setup){setup.provider.register({
      async listModels(){return [];}, video:{async submit(){return {status:"submitted",remoteTaskId:"unused"};},async query(){return {status:"running"};}},
      assets:{async submit(input,ctx){
        if(input.name!=='Portrait' || input.file.mimeType!=='image/png' || input.file.size!==3)throw new Error('wrong file');
        const r=await ctx.files.upload(input.file.handle,{kind:'raw',method:'PUT',url:'http://127.0.0.1:${server.port}/upload'});
        if(r.status!==200)throw new Error('upload failed');
        return {remoteId:'certified-id',remoteTaskId:'poll-id',remoteGroupId:'group'};
      },async state(input){if(input.id!=='poll-id')throw new Error('wrong query id');return {status:'active'};}}
    });}};""",
          ),
        ],
      );
      final service = ProviderAssetService(
        database: db,
        references: _NoStorage(),
        pluginHost: host,
        probe: (_) async => const MediaInfo(
          duration: Duration.zero,
          hasAudio: false,
          hasVideo: true,
          width: 900,
          height: 1600,
        ),
        pollDelays: const [Duration(milliseconds: 5)],
      );
      addTearDown(() async {
        service.dispose();
        await host.dispose();
        await server.close(force: true);
        await db.close();
        await dir.delete(recursive: true);
      });
      await host.start();
      await host.setEnabled('test.certification', true);
      expect(providerSupportsAssetCertification(provider), isTrue);
      await service.certify(
        assetId: 'asset',
        providerId: provider.id,
        file: file,
        mimeType: 'image/png',
        name: 'Portrait',
      );
      for (var n = 0; n < 100; n++) {
        if ((await db.providerAssetDao.find('asset', provider.id))?.status ==
            ProviderAssetStatus.active) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final row = await db.providerAssetDao.find('asset', provider.id);
      expect(row?.status, ProviderAssetStatus.active);
      expect(row?.remoteId, 'certified-id');
      expect(row?.remoteTaskId, 'poll-id');
      expect(uploads, 1);
      await host.setEnabled('test.certification', false);
      expect(providerSupportsAssetCertification(provider), isFalse);
      final resume = await db.providerAssetDao.start('resume', provider.id);
      await db.providerAssetDao.write(
        resume.id,
        const ProviderAssetsCompanion(
          remoteId: Value('certified-id'),
          remoteTaskId: Value('poll-id'),
        ),
      );
      await service.resume();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final paused = await db.providerAssetDao.find('resume', provider.id);
      expect(paused!.status, ProviderAssetStatus.processing);
      expect(paused.errorCode, 'configuration_required');
      await host.setEnabled('test.certification', true);
      for (var n = 0; n < 100; n++) {
        if ((await db.providerAssetDao.find('resume', provider.id))?.status ==
            ProviderAssetStatus.active) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        (await db.providerAssetDao.find('resume', provider.id))?.status,
        ProviderAssetStatus.active,
      );
      expect(uploads, 1, reason: 'Resume must query without uploading again');
    },
  );
}
