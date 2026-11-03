// 职责: 验证启动期 PureFox Media 型号登记 — 读取持久化配置、只拉一次、失败不影响启动。
// 关联文件:
//   lib/shared/providers/purefox_media_providers.dart
//   lib/shared/services/ai/purefox_media.dart
//   lib/shared/providers/settings_providers.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/testing.md

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/video/channels.dart';
import 'package:reveric/shared/providers/purefox_media_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';

const _videoId = 'startup-video-model';

String _payload() => jsonEncode({
  'data': [
    {
      'id': _videoId,
      'kind': 'video',
      'qualities': ['720p'],
      'duration': {
        'mode': 'options',
        'options': [5],
      },
      'refImages': 1,
    },
  ],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;

  setUp(() {
    database = AppDatabase.forTest(NativeDatabase.memory());
  });

  tearDown(() async {
    purefoxMediaVideoModels.remove(_videoId);
    await database.close();
  });

  Future<ProviderContainer> createContainer(http.Client client) async {
    final container = ProviderContainer(
      overrides: [
        appSettingsDatabaseProvider.overrideWithValue(database),
        purefoxMediaHttpClientProvider.overrideWithValue(client),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
    return container;
  }

  test('registers models saved in the database on startup', () async {
    final media = aiProviderBuiltinById('purefox_media')!.copyWith(
      enabled: true,
      apiKey: 'purefox-key',
      videoModels: const [_videoId],
    );
    await database.aiProviderDao.upsert(media);

    var requests = 0;
    final container = await createContainer(
      MockClient((request) async {
        requests++;
        expect(request.headers['Authorization'], 'Bearer purefox-key');
        return http.Response(_payload(), 200);
      }),
    );

    await container.read(purefoxMediaModelsProvider.future);

    expect(requests, 1);
    final channel = lookupVideoChannelModel('purefox_media', _videoId);
    expect(channel, isNotNull);
    expect(channel!.capabilities.durations, {5});
  });

  test('startup keeps working when the gateway fails', () async {
    final media = aiProviderBuiltinById('purefox_media')!.copyWith(
      enabled: true,
      apiKey: 'purefox-key',
      videoModels: const [_videoId],
    );
    await database.aiProviderDao.upsert(media);

    final container = await createContainer(
      MockClient((_) async => http.Response('boom', 500)),
    );

    await expectLater(
      container.read(purefoxMediaModelsProvider.future),
      completes,
    );
    expect(lookupVideoChannelModel('purefox_media', _videoId), isNull);
  });

  test(
    'does not call the gateway when no media provider is configured',
    () async {
      var requests = 0;
      final container = await createContainer(
        MockClient((_) async {
          requests++;
          return http.Response(_payload(), 200);
        }),
      );

      await container.read(purefoxMediaModelsProvider.future);

      expect(requests, 0);
    },
  );
}
