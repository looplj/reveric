// 职责: 验证对象存储表单的服务商预设推导、字段校验、折叠字段的错误回填，以及仅在连接测试通过后才保存配置并通知调用方。
// 关联文件:
//   lib/shared/widgets/settings/object_storage_form.dart
//   lib/shared/services/object_storage/service.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/object_storage_config.dart';
import 'package:reveric/shared/providers/object_storage.dart';
import 'package:reveric/shared/services/object_storage/service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/settings/object_storage_form.dart';
import 'package:reveric/shared/widgets/confirm_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppDatabase database;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() {
    rootBundle.clear();
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1000, 1600);
    view.devicePixelRatio = 1;
    database = AppDatabase.forTest(NativeDatabase.memory());
  });
  tearDown(() async {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
    await database.close();
  });

  Future<void> fill(WidgetTester tester, String field, String value) async {
    final input = find.descendant(
      of: find.byKey(ValueKey('object_storage_${field}_field')),
      matching: find.byType(EditableText),
    );
    await tester.ensureVisible(input);
    await tester.enterText(input, value);
  }

  Future<void> submit(WidgetTester tester) async {
    final button = find.byKey(const ValueKey('object_storage_save_button'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  for (final fails in [false, true]) {
    testWidgets(
      'clear confirms, refreshes only on success, failure=$fails',
      (tester) async {
        final service = _FakeService(database)..clearFails = fails;
        var config = const ObjectStorageConfig(
          endpoint: 'https://s3.example.com',
          bucket: 'media',
          accessKeyId: 'ak',
          secretAccessKey: 'sk',
        );
        var savedCalls = 0;
        await tester.pumpWidget(
          _wrap(
            service,
            StatefulBuilder(
              builder: (context, setState) {
                service.onCleared = () =>
                    setState(() => config = const ObjectStorageConfig());
                return ObjectStorageForm(
                  config: config,
                  onSaved: () => savedCalls++,
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        final clear = find.byKey(const ValueKey('object_storage_clear_button'));
        await tester.ensureVisible(clear);
        await tester.tap(clear);
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(ConfirmDialog),
            matching: find.text('Cancel'),
          ),
        );
        await tester.pumpAndSettle();
        expect(service.clearCalls, 0);
        await tester.tap(clear);
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(ConfirmDialog),
            matching: find.text('Clear'),
          ),
        );
        await tester.pumpAndSettle();
        expect(service.clearCalls, 1);
        expect(service.tested, isEmpty);
        expect(service.saved, isEmpty);
        expect(
          savedCalls,
          0,
        ); // Clearing must not close the generation configuration dialog as ready.
        final secret = tester.widget<EditableText>(
          find.descendant(
            of: find.byKey(
              const ValueKey('object_storage_secretAccessKey_field'),
            ),
            matching: find.byType(EditableText),
          ),
        );
        expect(secret.controller.text, fails ? 'sk' : '');
        expect(clear, fails ? findsOneWidget : findsNothing);
        expect(
          find.text(
            fails
                ? 'Could not clear object storage settings. Please try again.'
                : 'Object storage settings cleared.',
          ),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }

  testWidgets('blocks incomplete config before testing the connection', (
    tester,
  ) async {
    final service = _FakeService(database);
    await tester.pumpWidget(
      _wrap(service, const ObjectStorageForm(config: _customConfig)),
    );
    await tester.pumpAndSettle();

    await fill(tester, 'endpoint', '');
    await submit(tester);

    expect(find.text('Enter a valid HTTP or HTTPS URL.'), findsOneWidget);
    expect(service.tested, isEmpty);
    expect(service.saved, isEmpty);
  });

  testWidgets('derives the endpoint from the region for preset vendors', (
    tester,
  ) async {
    final service = _FakeService(database);
    await tester.pumpWidget(
      _wrap(service, const ObjectStorageForm(config: ObjectStorageConfig())),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('object_storage_endpoint_field')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('object_storage_create_bucket')),
      findsOneWidget,
    );

    await fill(tester, 'bucket', 'media');
    await fill(tester, 'accessKeyId', 'ak');
    await fill(tester, 'secretAccessKey', 'sk');
    await submit(tester);
    expect(find.text('Required'), findsOneWidget);
    expect(service.tested, isEmpty);

    await fill(tester, 'region', 'cn hangzhou');
    await submit(tester);
    expect(find.text('Use only letters, digits and hyphens.'), findsOneWidget);
    expect(service.tested, isEmpty);

    await fill(tester, 'region', 'CN-Hangzhou');
    await submit(tester);

    final saved = service.saved.single;
    expect(saved.endpoint, 'https://s3.oss-cn-hangzhou.aliyuncs.com');
    expect(saved.region, 'cn-hangzhou');
    expect(saved.pathStyle, isFalse);
  });

  testWidgets('restores Cloudflare R2 from a saved config', (tester) async {
    final service = _FakeService(database);
    await tester.pumpWidget(
      _wrap(
        service,
        const ObjectStorageForm(
          config: ObjectStorageConfig(
            endpoint: 'https://abc123.r2.cloudflarestorage.com',
            region: 'auto',
            bucket: 'media',
            accessKeyId: 'ak',
            secretAccessKey: 'sk',
            pathStyle: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Cloudflare R2'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('object_storage_region_field')),
      findsNothing,
    );

    await fill(tester, 'accountId', 'def456');
    await submit(tester);

    final saved = service.saved.single;
    expect(saved.endpoint, 'https://def456.r2.cloudflarestorage.com');
    expect(saved.region, 'auto');
    expect(saved.pathStyle, isTrue);
  });

  testWidgets('saves only after the connection test passes', (tester) async {
    final service = _FakeService(database)
      ..failure = ObjectStorageFailure.unauthorized;
    var savedCalls = 0;
    await tester.pumpWidget(
      _wrap(
        service,
        ObjectStorageForm(config: _customConfig, onSaved: () => savedCalls++),
      ),
    );
    await tester.pumpAndSettle();

    await fill(tester, 'endpoint', 'https://s3.example.com');
    await fill(tester, 'bucket', 'media');
    await fill(tester, 'accessKeyId', 'ak');
    await fill(tester, 'secretAccessKey', 'sk');
    await submit(tester);

    expect(service.tested.single.bucket, 'media');
    expect(service.saved, isEmpty);
    expect(savedCalls, 0);
    expect(
      find.text(
        'Authentication failed. Check the access key, secret key and region.',
      ),
      findsOneWidget,
    );

    service.failure = null;
    await submit(tester);

    expect(service.saved.single.secretAccessKey, 'sk');
    expect(savedCalls, 1);
  });

  testWidgets('expands advanced options when a collapsed field fails', (
    tester,
  ) async {
    final service = _FakeService(database);
    await tester.pumpWidget(
      _wrap(service, const ObjectStorageForm(config: _customConfig)),
    );
    await tester.pumpAndSettle();

    final toggle = find.byKey(const ValueKey('object_storage_advanced_toggle'));
    final publicUrl = find.byKey(
      const ValueKey('object_storage_publicBaseUrl_field'),
    );
    expect(publicUrl.hitTestable(), findsNothing);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await fill(tester, 'endpoint', 'https://s3.example.com');
    await fill(tester, 'bucket', 'media');
    await fill(tester, 'accessKeyId', 'ak');
    await fill(tester, 'secretAccessKey', 'sk');
    await fill(tester, 'publicBaseUrl', 'not a url');
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(publicUrl.hitTestable(), findsNothing);

    await submit(tester);

    expect(publicUrl.hitTestable(), findsOneWidget);
    expect(find.text('Enter a valid HTTP or HTTPS URL.'), findsOneWidget);
    expect(service.tested, isEmpty);
  });
}

/// 无法匹配任何服务商预设的 Endpoint，表单按自定义服务展示。
const _customConfig = ObjectStorageConfig(endpoint: 'https://s3.example.com');

Widget _wrap(ObjectStorageService service, Widget child) {
  return ProviderScope(
    overrides: [objectStorageServiceProvider.overrideWithValue(service)],
    child: EasyLocalization(
      supportedLocales: const <Locale>[Locale('en')],
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
            child: Scaffold(body: SingleChildScrollView(child: child)),
          ),
        ),
      ),
    ),
  );
}

class _FakeService extends ObjectStorageService {
  _FakeService(AppDatabase database) : super(database: database);

  ObjectStorageFailure? failure;
  bool clearFails = false;
  int clearCalls = 0;
  VoidCallback? onCleared;

  @override
  Future<void> clear() async {
    clearCalls++;
    if (clearFails) {
      throw StateError('write failed');
    }
    onCleared?.call();
  }

  final tested = <ObjectStorageConfig>[];
  final saved = <ObjectStorageConfig>[];

  @override
  Future<ObjectStorageFailure?> test(ObjectStorageConfig config) async {
    tested.add(config);
    return failure;
  }

  @override
  Future<void> save(ObjectStorageConfig config) async {
    saved.add(config);
  }
}
