// 职责: 验证插件市场 UI（桌面与移动端尺寸/平台）：页签切换、搜索过滤、状态标识、错误提示与下载安装预览流程。
// 关联文件:
//   lib/shared/widgets/settings/plugins/section.dart
//   lib/shared/widgets/settings/plugins/marketplace_tab.dart
//   lib/shared/widgets/settings/plugins/marketplace_card.dart
//   lib/shared/widgets/settings/plugins/preview_page.dart
//   lib/desktop/widgets/agent_management/plugins_page.dart

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/widgets/agent_management/plugins_page.dart';
import 'package:reveric/shared/database/app_database.dart' hide PluginRegistry;
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/providers/plugin_marketplace_providers.dart';
import 'package:reveric/shared/providers/plugin_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/plugins/host.dart';
import 'package:reveric/shared/services/plugins/installer.dart';
import 'package:reveric/shared/services/plugins/marketplace_service.dart';
import 'package:reveric/shared/services/plugins/package_archive.dart';
import 'package:reveric/shared/services/plugins/registry.dart';
import 'package:reveric/shared/theme/reveric_theme.dart';
import 'package:reveric/shared/widgets/settings/plugins/preview_page.dart';
import 'package:reveric/shared/widgets/settings/plugins/section.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/plugins/host_test.dart' show FakeExecutor, package;

class _FakeHttpAdapter implements HttpClientAdapter {
  _FakeHttpAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => handler(options);

  @override
  void close({bool force = false}) {}
}

Uint8List _zipPackage({
  required String id,
  required String version,
  List<String> permissions = const ['network'],
}) {
  final archive = Archive()
    ..addFile(
      ArchiveFile.string(
        'plugin.json',
        jsonEncode({
          'id': id,
          'name': {'en': 'Remote Video', 'zh-CN': '远端视频'},
          'description': {'en': 'Cloud video plugin', 'zh-CN': '云端视频插件'},
          'author': 'Reveric',
          'version': version,
          'pluginApiVersion': '^1',
          'main': 'dist/index.js',
          'platforms': ['windows', 'macos', 'android'],
          'permissions': permissions,
        }),
      ),
    )
    ..addFile(ArchiveFile.string('dist/index.js', 'export function init() {}'));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Future<void> _pumpApp(
  WidgetTester tester, {
  required Widget child,
  required PluginHostService host,
  required PluginMarketplaceService marketplaceService,
  required TargetPlatform targetPlatform,
  required Size size,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        pluginHostServiceProvider.overrideWithValue(host),
        pluginMarketplaceServiceProvider.overrideWithValue(marketplaceService),
        aiSettingsProvider.overrideWithValue(AiSettings.defaults()),
      ],
      child: EasyLocalization(
        supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
        path: 'assets/translations',
        assetLoader: const MergingAssetLoader(),
        fallbackLocale: const Locale('en'),
        startLocale: const Locale('zh', 'CN'),
        saveLocale: false,
        child: Builder(
          builder: (context) => MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            theme: RevericThemeData.reveric.toThemeData().copyWith(
              platform: targetPlatform,
            ),
            builder: (context, inner) => RevericTheme(
              data: RevericThemeData.reveric,
              child: Scaffold(body: inner),
            ),
            home: child,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _flushAsyncAndSettle(WidgetTester tester) async {
  for (var i = 0; i < 80; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 30));
    if (i >= 5 &&
        tester.widgetList(find.byType(CircularProgressIndicator)).isEmpty) {
      break;
    }
  }
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  setUp(() {
    rootBundle.clear();
  });

  Future<({AppDatabase db, PluginHostService host, Directory root})> makeHost({
    required String platform,
    List<PluginPackage> bundled = const [],
  }) async {
    final root = await Directory.systemTemp.createTemp('plugin-mkt-ui-');
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (call) async {
          if (call.method == 'getTemporaryDirectory' ||
              call.method == 'getApplicationSupportDirectory') {
            return root.path;
          }
          return null;
        });
    final db = AppDatabase.forTest(NativeDatabase.memory());
    final host = PluginHostService(
      dao: db.pluginDao,
      registry: PluginRegistry(hostToolNames: {}),
      packages: () async => bundled,
      executorFactory: (call, stop) => FakeExecutor(),
      platform: platform,
      applicationSupport: () async => root,
    );
    await host.start();
    return (db: db, host: host, root: root);
  }

  testWidgets(
    'desktop switches tabs, filters search, downloads package, and installs via preview without unreviewed warning',
    (tester) async {
      final setup = await tester.runAsync(
        () => makeHost(
          platform: 'macos',
          bundled: [package(id: 'reveric.builtin', version: '1.0.0')],
        ),
      );
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              null,
            );
        await setup!.host.dispose();
        await setup.db.close();
        if (await setup.root.exists()) {
          await setup.root.delete(recursive: true);
        }
      });

      // 先安装一个更低版本的本地可更新插件。
      final oldZip = _zipPackage(id: 'reveric.updatable', version: '1.0.0');
      await tester.runAsync(
        () => PluginInstallOrchestrator().install(
          host: setup!.host,
          archive: PluginPackageArchive.decode(oldZip),
          grantedPermissions: const {'network'},
          temporaryRoot: setup.root,
        ),
      );

      final newRemoteZip = _zipPackage(id: 'reveric.remote', version: '1.0.0');
      final newRemoteHash = sha256.convert(newRemoteZip).toString();
      final updatableZip = _zipPackage(
        id: 'reveric.updatable',
        version: '1.2.0',
      );
      final updatableHash = sha256.convert(updatableZip).toString();

      final catalogPayload = jsonEncode({
        'schemaVersion': 1,
        'plugins': [
          {
            'id': 'reveric.builtin',
            'name': {'en': 'Builtin Plugin', 'zh-CN': '内置插件'},
            'versions': [
              {
                'version': '2.0.0',
                'pluginApiVersion': '^1',
                'platforms': ['macos'],
                'url': 'https://downloads.reveric.app/builtin.zip',
                'size': 10,
                'sha256': 'a' * 64,
              },
            ],
          },
          {
            'id': 'reveric.remote',
            'name': {'en': 'Remote Video', 'zh-CN': '远端视频'},
            'description': {'en': 'Cloud video plugin', 'zh-CN': '云端视频插件'},
            'author': 'Reveric',
            'repository': 'https://github.com/looplj/reveric-plugins',
            'versions': [
              {
                'version': '1.0.0',
                'pluginApiVersion': '^1',
                'platforms': ['windows', 'macos', 'android'],
                'url': 'https://downloads.reveric.app/remote.zip',
                'size': newRemoteZip.length,
                'sha256': newRemoteHash,
                'releaseUrl':
                    'https://github.com/looplj/reveric-plugins/releases/tag/remote%2Fv1.0.0',
              },
            ],
          },
          {
            'id': 'reveric.updatable',
            'name': {'en': 'Updatable Tool', 'zh-CN': '可更新工具'},
            'versions': [
              {
                'version': '1.2.0',
                'pluginApiVersion': '^1',
                'platforms': ['macos'],
                'url': 'https://downloads.reveric.app/updatable.zip',
                'size': updatableZip.length,
                'sha256': updatableHash,
              },
            ],
          },
          {
            'id': 'reveric.winonly',
            'name': {'en': 'Windows Only', 'zh-CN': '仅限 Windows'},
            'versions': [
              {
                'version': '1.0.0',
                'pluginApiVersion': '^1',
                'platforms': ['windows'],
                'url': 'https://downloads.reveric.app/winonly.zip',
                'size': 10,
                'sha256': 'b' * 64,
              },
            ],
          },
        ],
      });

      final service = PluginMarketplaceService(
        cacheFile: File('${setup!.root.path}/marketplace_cache.json'),
        createClient: () =>
            Dio()
              ..httpClientAdapter = _FakeHttpAdapter((options) async {
                final uri = options.uri.toString();
                if (uri.endsWith('/index.json')) {
                  final bytes = utf8.encode(catalogPayload);
                  return ResponseBody.fromBytes(
                    bytes,
                    200,
                    headers: {
                      Headers.contentLengthHeader: ['${bytes.length}'],
                    },
                  );
                }
                if (uri.endsWith('/remote.zip')) {
                  return ResponseBody.fromBytes(
                    newRemoteZip,
                    200,
                    headers: {
                      Headers.contentLengthHeader: ['${newRemoteZip.length}'],
                    },
                  );
                }
                throw StateError('Unexpected URL $uri');
              }),
      );

      await _pumpApp(
        tester,
        child: const PluginsRegion(),
        host: setup.host,
        marketplaceService: service,
        targetPlatform: TargetPlatform.macOS,
        size: const Size(1000, 800),
      );

      try {
        // 默认停留在「已安装」页签。
        expect(find.text(LocaleKeys.pluginTabMarketplace.tr()), findsOneWidget);

        // 切到「插件市场」。
        await tester.tap(find.text(LocaleKeys.pluginTabMarketplace.tr()));
        await _flushAsyncAndSettle(tester);

        expect(find.text('远端视频'), findsOneWidget);
        expect(find.text('内置插件'), findsOneWidget);
        expect(find.text('可更新工具'), findsOneWidget);
        expect(find.text('仅限 Windows'), findsOneWidget);
        expect(
          find.text(
            LocaleKeys.pluginMarketplaceUpdateVersion.tr(
              namedArgs: {'version': '1.2.0'},
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.text(LocaleKeys.pluginMarketplaceUnsupported.tr()),
          findsWidgets,
        );

        // 防抖搜索收敛到「远端视频」。
        await tester.enterText(find.byType(TextField), '远端');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(find.text('远端视频'), findsOneWidget);
        expect(find.text('可更新工具'), findsNothing);

        // 点击「安装」进入预览页，不显示本地未审核警告，显示来源外链并可完成授权安装。
        await tester.tap(find.text(LocaleKeys.commonInstall.tr()));
        await _flushAsyncAndSettle(tester);

        expect(find.byType(PluginPreviewPage), findsOneWidget);
        expect(
          find.text(LocaleKeys.pluginGrantAndInstall.tr()),
          findsOneWidget,
        );
        expect(find.text(LocaleKeys.pluginUnreviewed.tr()), findsNothing);
        expect(
          find.text(LocaleKeys.pluginMarketplaceRepository.tr()),
          findsOneWidget,
        );
        expect(
          find.text(LocaleKeys.pluginMarketplaceReleaseNotes.tr()),
          findsOneWidget,
        );

        await tester.tap(find.text(LocaleKeys.pluginGrantAndInstall.tr()));
        await _flushAsyncAndSettle(tester);

        // 安装成功后切到插件详情页且宿主状态存在该插件。
        expect(
          setup.host.statuses.any(
            (s) => s.id == 'reveric.remote' && s.source == 'local',
          ),
          isTrue,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets(
    'mobile viewport renders error retry and friendly download error without overflow or raw exceptions',
    (tester) async {
      final setup = await tester.runAsync(() => makeHost(platform: 'android'));
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              null,
            );
        await setup!.host.dispose();
        await setup.db.close();
        if (await setup.root.exists()) {
          await setup.root.delete(recursive: true);
        }
      });

      var failIndex = true;
      final zipBytes = _zipPackage(id: 'reveric.mobile', version: '1.0.0');
      final digest = sha256.convert(zipBytes).toString();
      final catalogPayload = jsonEncode({
        'schemaVersion': 1,
        'plugins': [
          {
            'id': 'reveric.mobile',
            'name': {'en': 'Mobile Tool', 'zh-CN': '移动端插件名称非常长用于测试窄屏自适应'},
            'description': {
              'en': 'Works on Android',
              'zh-CN': '在移动端测试窄屏换行与错误提示显示效果。',
            },
            'author': 'Reveric',
            'repository': 'https://github.com/looplj/reveric-plugins',
            'versions': [
              {
                'version': '1.0.0',
                'pluginApiVersion': '^1',
                'platforms': ['android'],
                'url': 'https://downloads.reveric.app/mobile.zip',
                'size': zipBytes.length,
                'sha256': digest,
              },
            ],
          },
        ],
      });

      final service = PluginMarketplaceService(
        cacheFile: File('${setup!.root.path}/marketplace_cache.json'),
        createClient: () =>
            Dio()
              ..httpClientAdapter = _FakeHttpAdapter((options) async {
                final uri = options.uri.toString();
                if (uri.endsWith('/index.json')) {
                  if (failIndex) {
                    throw DioException.connectionError(
                      requestOptions: options,
                      reason: 'INTERNAL_RAW_SOCKET_DETAIL',
                    );
                  }
                  return ResponseBody.fromString(
                    catalogPayload,
                    200,
                    headers: {
                      Headers.contentLengthHeader: [
                        '${utf8.encode(catalogPayload).length}',
                      ],
                    },
                  );
                }
                // 下载包失败（损坏字节触发完整性校验失败）。
                return ResponseBody.fromBytes(
                  List<int>.filled(zipBytes.length, 9),
                  200,
                  headers: {
                    Headers.contentLengthHeader: ['${zipBytes.length}'],
                  },
                );
              }),
      );

      await _pumpApp(
        tester,
        child: const PluginsSettingsSection(),
        host: setup.host,
        marketplaceService: service,
        targetPlatform: TargetPlatform.android,
        size: const Size(360, 800),
      );

      try {
        await tester.tap(find.text(LocaleKeys.pluginTabMarketplace.tr()));
        await _flushAsyncAndSettle(tester);

        // 首次网络失败显示错误占位，且不泄露底层异常字符串。
        expect(
          find.text(LocaleKeys.pluginMarketplaceLoadFailed.tr()),
          findsOneWidget,
        );
        expect(find.textContaining('INTERNAL_RAW_SOCKET_DETAIL'), findsNothing);

        // 重试后成功加载列表。
        failIndex = false;
        await tester.tap(find.text(LocaleKeys.commonRetry.tr()));
        await _flushAsyncAndSettle(tester);
        expect(find.text('移动端插件名称非常长用于测试窄屏自适应'), findsOneWidget);

        // 点击安装遭遇校验失败时展示友好提示。
        await tester.tap(find.text(LocaleKeys.commonInstall.tr()));
        await _flushAsyncAndSettle(tester);
        expect(
          find.text(LocaleKeys.pluginMarketplaceIntegrityFailed.tr()),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    },
  );
}
