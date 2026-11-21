// 职责: 验证地图地名识别上传前压缩超大成图，避免 base64 请求超过网关限制。
// 关联文件:
//   lib/shared/services/map_place_name_reader.dart
//   lib/shared/services/ai/image_reference_compression.dart
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:reveric/shared/services/map_place_name_reader.dart';
import 'package:reveric/shared/models/map_studio_models.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/models/ai_provider.dart';

void main() {
  test(
    'compresses an oversized map before embedding it in vision JSON',
    () async {
      expect(mapVisionMaxImageBytes, 1024 * 1024);
      final sourceBytes = Uint8List.fromList(
        img.encodePng(_noisyImage(width: 1200, height: 1200)),
      );
      late http.Request captured;
      final transport = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content':
                      '{"matches":[{"name":"临川","x":0.5,"y":0.4}],"unmatched":[]}',
                },
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      addTearDown(transport.close);
      final reader = MapPlaceNameReader(
        config: _provider,
        model: _visionModel,
        httpClient: transport,
      );

      final result = await reader.readPlacePositions(
        imageBytes: sourceBytes,
        mimeSubtype: 'png',
        imageWidth: 1200,
        imageHeight: 1200,
        candidates: const [
          MapPlaceNameCandidate(locationId: 'place-1', name: '临川'),
        ],
      );

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(captured.url.path, '/v1/chat/completions');
      expect(captured.headers['Authorization'], 'Bearer test-key');
      final messages = body['messages']! as List<dynamic>;
      final userMessage = messages.last as Map<String, dynamic>;
      final content = userMessage['content']! as List<dynamic>;
      final imagePart = content[1]! as Map<String, dynamic>;
      final imageUrl = imagePart['image_url']! as Map<String, dynamic>;
      final dataUrl = imageUrl['url']! as String;
      final compressedBytes = base64Decode(
        dataUrl.substring(dataUrl.indexOf(',') + 1),
      );

      expect(sourceBytes.length, greaterThan(3 * 1024 * 1024));
      expect(dataUrl, startsWith('data:image/jpeg;base64,'));
      expect(compressedBytes.length, lessThanOrEqualTo(mapVisionMaxImageBytes));
      expect(result.matches.single.locationId, 'place-1');
    },
  );
}

const _visionModel = 'vision-model';

final _provider = AiProvider(
  asrModels: const [],
  audioModels: const [],
  videoModels: const [],
  id: 'vision-test',
  name: 'Vision test',
  builtin: false,
  type: AiProviderType.openai_compatible.name,
  enabled: true,
  apiKey: 'test-key',
  baseUrl: 'https://example.test/v1',
  models: const [_visionModel],
  imageModels: const [],
  embeddingModels: const [],
  temperature: 0,
  maxTurns: 1,
  proxyUrl: '',
  proxyUsername: '',
  proxyPassword: '',
  updatedAt: DateTime(2026),
  deletedAt: notDeletedSentinel,
);

img.Image _noisyImage({required int width, required int height}) {
  final image = img.Image(width: width, height: height);
  var state = 0x12345678;
  for (final pixel in image) {
    state = (state * 1664525 + 1013904223) & 0x7fffffff;
    pixel
      ..r = state & 0xff
      ..g = (state >> 8) & 0xff
      ..b = (state >> 16) & 0xff;
  }
  return image;
}
