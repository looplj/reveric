// 职责: 验证供应商模型候选、URL 粘贴清理、手动编辑保护和请求错误映射。
// 关联文件:
//   lib/shared/widgets/settings/provider_config_panel.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/provider.json
//   assets/translations/zh-CN/provider.json

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/models/audio/channels.dart';
import 'package:reveric/shared/models/image/channels.dart';
import 'package:reveric/shared/models/production/image_request.dart';
import 'package:reveric/shared/models/video/channels.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/widgets/settings/provider_config_panel.dart';

void main() {
  test('unsupported provider cannot fetch models or issue a request', () async {
    final provider = aiProviderBuiltinById(
      'openai',
    )!.copyWith(type: 'test_xxx');
    await http.runWithClient(
      () => expectLater(fetchProviderModels(provider), throwsUnsupportedError),
      () => MockClient(
        (_) async => throw StateError('Unexpected network request'),
      ),
    );
  });

  test('MiniMax chat picker offers its catalog without a request', () async {
    final provider = aiProviderBuiltinById('openai')!.copyWith(
      type: AiProviderType.minimax.name,
      apiKey: 'test-key',
      baseUrl: '',
    );
    await http.runWithClient(
      () async =>
          expect(await fetchProviderModels(provider), minimaxPresetChatModels),
      () => MockClient(
        (_) async => throw StateError('Unexpected network request'),
      ),
    );
  });

  test(
    'image picker offers channel catalogs without fetching chat models',
    () async {
      for (final type in ['qwen', 'doubao', 'volcengine']) {
        final provider = aiProviderBuiltinById('openai')!.copyWith(type: type);
        final models = await http.runWithClient(
          () => fetchProviderModels(provider, kind: AiModelKind.image),
          () => MockClient((_) => throw StateError('no network needed')),
        );
        expect(models, imageModelsForProvider(type));
        expect(models, isNotEmpty);
      }
    },
  );
  test(
    'AtlasCloud image picker fetches the image catalog and keeps unknown models',
    () async {
      final provider = aiProviderBuiltinById(
        'openai',
      )!.copyWith(type: 'atlascloud', apiKey: 'key');
      final models = await http.runWithClient(
        () => fetchProviderModels(provider, kind: AiModelKind.image),
        () => MockClient((request) async {
          expect(
            request.url.toString(),
            'https://api.atlascloud.ai/api/v1/models?type=Image',
          );
          expect(request.headers['Authorization'], 'Bearer key');
          return http.Response(
            jsonEncode({
              'code': 200,
              'data': [
                {
                  'model': 'openai/gpt-image-2/text-to-image',
                  'type': 'Image',
                  'display_console': true,
                },
                {
                  'model': 'vendor/new-image',
                  'type': 'Image',
                  'display_console': true,
                },
                {
                  'model': 'hidden/internal',
                  'type': 'Image',
                  'display_console': false,
                },
                {
                  'model': 'openai/gpt-4o',
                  'type': 'Text',
                  'display_console': true,
                },
              ],
            }),
            200,
          );
        }),
      );
      expect(models, ['openai/gpt-image-2/text-to-image', 'vendor/new-image']);
      expect(lookupImageChannelModel('atlascloud', 'vendor/new-image'), isNull);
      expect(
        lookupImageChannelModel(
          'atlascloud',
          'openai/gpt-image-2/text-to-image',
        )!.catalogId,
        'gpt-image-2',
      );
      final unlisted = ProductionImageCapabilities(
        provider.copyWith(imageModels: models),
        'vendor/new-image',
      );
      expect(unlisted.isSupported, isTrue);
      expect(unlisted.verifiedCapabilities, isNull);
      expect(unlisted.ratios, contains('16:9'));
      expect(unlisted.resolutions, contains('2K'));
      expect(unlisted.maxReferences, isNull);
    },
  );

  test(
    'Agnes image picker offers its catalog without fetching unrelated models',
    () async {
      final provider = aiProviderBuiltinById('openai')!.copyWith(type: 'agnes');
      final models = await http.runWithClient(
        () => fetchProviderModels(provider, kind: AiModelKind.image),
        () => MockClient((_) => throw StateError('no network needed')),
      );
      expect(models, [
        'agnes-image-2.0-flash',
        'agnes-image-2.1-flash',
        'agnes-image-2.5-flash',
      ]);
    },
  );
  test('Qwen model fetch follows the configured proxy URL', () async {
    final provider = aiProviderBuiltinById('openai')!.copyWith(
      type: 'qwen',
      baseUrl: 'https://proxy.example/prefix/compatible-mode/v1',
      apiKey: 'key',
    );
    await http.runWithClient(
      () => fetchProviderModels(provider),
      () => MockClient((r) async {
        expect(
          r.url.toString(),
          'https://proxy.example/prefix/compatible-mode/v1/models',
        );
        expect(r.headers['Authorization'], 'Bearer key');
        return http.Response('{"data":[{"id":"qwen3.8-flash"}]}', 200);
      }),
    );
  });
  test(
    'Codex image picker offers image presets without fetching chat models',
    () async {
      final provider = aiProviderBuiltinById(
        'openai',
      )!.copyWith(type: 'codex', apiKey: '');
      expect(
        await fetchProviderModels(provider, kind: AiModelKind.image),
        codexPresetImageModels,
      );
    },
  );

  test(
    'video picker uses each provider catalog without a chat models request',
    () async {
      for (final sample in [
        ('doubao', VideoProtocol.ark_video),
        ('volcengine', VideoProtocol.ark_video),
        ('qwen', VideoProtocol.wan_video),
        ('minimax', VideoProtocol.minimax_video_v2),
        ('metaso', VideoProtocol.minimax_video_v2),
        ('agnes', VideoProtocol.agnes_video),
        ('atlascloud', VideoProtocol.atlascloud_video),
      ]) {
        final provider = aiProviderBuiltinById(
          'openai',
        )!.copyWith(type: sample.$1);
        final models = await http.runWithClient(
          () => fetchProviderModels(provider, kind: AiModelKind.video),
          () => MockClient((_) => throw StateError('no network needed')),
        );
        expect(models, isNotEmpty);
        expect(models, videoModelsForProvider(sample.$1));
      }
    },
  );

  test(
    'audio picker keeps provider catalogs separate without a models API',
    () async {
      for (final sample in [
        ('atlascloud', audioModelsForProvider('atlascloud')),
        (
          'qwen',
          [
            'qwen-audio-3.1-tts-plus',
            'qwen-audio-3.0-tts-flash',
            'qwen-audio-3.1-tts-next',
          ],
        ),
        ('volcengine', ['seed-audio-1.0']),
        ('minimax', ['speech-2.8-hd', 'music-3.0', 'music-2.6']),
      ]) {
        final provider = aiProviderBuiltinById(
          'openai',
        )!.copyWith(type: sample.$1);
        final models = await http.runWithClient(
          () => fetchProviderModels(provider, kind: AiModelKind.audio),
          () => MockClient((_) => throw StateError('no network needed')),
        );
        expect(models, sample.$2);
      }
    },
  );

  test(
    'OpenRouter audio discovery requests speech and excludes chat/music models',
    () async {
      final provider = aiProviderBuiltinById('openai')!.copyWith(
        type: 'openrouter',
        baseUrl: 'https://proxy.example/api/v1',
        apiKey: 'key',
      );
      final models = await http.runWithClient(
        () => fetchProviderModels(provider, kind: AiModelKind.audio),
        () => MockClient((r) async {
          expect(
            r.url.toString(),
            'https://openrouter.ai/api/v1/models?output_modalities=speech',
          );
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'id': 'minimax/speech-2.8-hd',
                  'architecture': {
                    'output_modalities': ['speech'],
                  },
                },
                {
                  'id': 'qwen/qwen-audio-3.0-tts-plus',
                  'architecture': {
                    'output_modalities': ['speech'],
                  },
                },
                {
                  'id': 'music-only',
                  'architecture': {
                    'output_modalities': ['audio'],
                  },
                },
                {
                  'id': 'chat',
                  'architecture': {
                    'output_modalities': ['text'],
                  },
                },
              ],
            }),
            200,
          );
        }),
      );
      expect(models, ['minimax/speech-2.8-hd', 'qwen/qwen-audio-3.0-tts-plus']);
    },
  );

  const formatter = ProviderBaseUrlInputFormatter();
  TextEditingValue value(String text, {TextSelection? selection}) =>
      TextEditingValue(
        text: text,
        selection: selection ?? TextSelection.collapsed(offset: text.length),
      );

  test(
    'paste removes known endpoint suffixes while preserving URL prefixes',
    () {
      for (final suffix in [
        'chat/completions',
        'completions',
        'responses',
        'messages',
        'models',
        'embeddings',
        'images/generations',
        'images/edits',
      ]) {
        final result = formatter.formatEditUpdate(
          value(''),
          value('  https://example.com/proxy/v1/$suffix/  '),
        );
        expect(result.text, 'https://example.com/proxy/v1');
        expect(result.selection.baseOffset, result.text.length);
      }
    },
  );

  test('select-all paste of a shorter URL is also normalized', () {
    const original = 'https://a-very-long-host.example.com/proxy/v1';
    final result = formatter.formatEditUpdate(
      value(
        original,
        selection: const TextSelection(
          baseOffset: 0,
          extentOffset: original.length,
        ),
      ),
      value('https://x.com/v1/models'),
    );
    expect(result.text, 'https://x.com/v1');
  });

  test(
    'typing, deletion, selection changes and IME retain the original input',
    () {
      const url = 'https://example.com/v1/models';
      var current = value('');
      for (var i = 1; i <= url.length; i++) {
        final next = value(url.substring(0, i));
        expect(formatter.formatEditUpdate(current, next), next);
        current = next;
      }
      final deletion = value(url);
      expect(formatter.formatEditUpdate(value('${url}x'), deletion), deletion);
      final selected = value(
        url,
        selection: const TextSelection(baseOffset: 0, extentOffset: url.length),
      );
      expect(formatter.formatEditUpdate(current, selected), selected);
      final composing = value(
        url,
      ).copyWith(composing: TextRange(start: 0, end: url.length));
      expect(formatter.formatEditUpdate(value(''), composing), composing);
      expect(formatter.formatEditUpdate(composing, value(url)), value(url));
    },
  );

  test('version paths, custom paths and queries are preserved', () {
    for (final url in [
      'https://example.com/v1',
      'https://example.com/v1beta',
      'https://example.com/proxy/custom',
      'https://example.com/my-models',
      'https://example.com/v1/chat/completions-extra',
      'not a URL/models',
    ]) {
      expect(formatter.formatEditUpdate(value(''), value(url)).text, url);
    }
    expect(
      formatter
          .formatEditUpdate(
            value(''),
            value('https://example.com/v1beta/models?region=cn'),
          )
          .text,
      'https://example.com/v1beta?region=cn',
    );
  });

  test(
    'HTTP failures have actionable translations and a server-error default',
    () {
      final expected = {
        400: LocaleKeys.providerFetchModelsBadRequest,
        401: LocaleKeys.providerFetchModelsAuthFailed,
        403: LocaleKeys.providerFetchModelsAuthFailed,
        404: LocaleKeys.providerFetchModelsNotFound,
        429: LocaleKeys.providerFetchModelsRateLimited,
      };
      for (final entry in expected.entries) {
        expect(modelsFetchErrorKey(entry.key), entry.value);
      }
      for (final status in [null, 402, 408, 500, 502, 503]) {
        expect(
          modelsFetchErrorKey(status),
          LocaleKeys.providerFetchModelsServerError,
        );
      }
      for (final locale in ['en', 'zh-CN']) {
        final translations =
            jsonDecode(
                  File(
                    'assets/translations/$locale/provider.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        for (final key in [
          ...expected.values,
          LocaleKeys.providerFetchModelsServerError,
          LocaleKeys.providerBaseUrlEndpointHint,
        ]) {
          expect(
            translations[key],
            isA<String>().having((s) => s.isNotEmpty, 'nonempty', true),
          );
        }
        for (final key in expected.values.toSet()) {
          expect(translations[key], contains('{status}'));
        }
        if (locale == 'zh-CN') {
          expect(
            translations[LocaleKeys.providerFetchModelsServerError],
            '服务端内部错误，请稍后重试',
          );
        }
      }
    },
  );

  test(
    'fetch models preserves proxy paths and does not duplicate Anthropic v1',
    () async {
      for (final example in [
        ('openai', 'https://example.com/proxy/v1/', '/proxy/v1/models'),
        ('anthropic', 'https://example.com/proxy/v1/', '/proxy/v1/models'),
        ('anthropic', 'https://example.com/proxy/', '/proxy/v1/models'),
        (
          'gemini',
          'https://example.com/proxy/v1beta?region=cn',
          '/proxy/v1beta/models',
        ),
      ]) {
        final provider = aiProviderBuiltinById(
          example.$1,
        )!.copyWith(baseUrl: example.$2, apiKey: 'test-key');
        final models = await http.runWithClient(
          () => fetchProviderModels(provider),
          () => MockClient((request) async {
            expect(request.url.path, example.$3);
            if (example.$1 == 'gemini') {
              expect(request.url.queryParameters, {
                'region': 'cn',
                'key': 'test-key',
              });
              return http.Response(
                '{"models":[{"name":"models/b"},{"name":"models/a"}]}',
                200,
              );
            }
            return http.Response('{"data":[{"id":"b"},{"id":"a"}]}', 200);
          }),
        );
        expect(models, ['a', 'b']);
      }
    },
  );
}
