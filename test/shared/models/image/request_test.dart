// 职责: 验证共用图片输入完整保留参考身份、来源、顺序及未知默认参数。
// 关联文件:
//   lib/shared/models/image/request.dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/image/request.dart';

void main() {
  test(
    'plugin wire mapping preserves every reference identity and frozen defaults',
    () {
      const input = SubmitImageInput(
        prompt: 'final prompt',
        modelId: 'workflow-42',
        aspectRatio: '9:13',
        resolution: 'custom',
        size: '900x1300',
        complexity: 'draft',
        defaults: {
          'node': {'sampler': 'custom', 'steps': 17},
        },
        references: [
          PreparedImageReference(
            assetId: 'a',
            clipId: 'clip-a',
            inputId: 'input-a',
            mimeType: 'image/png',
            source: ImageFileReference('file-handle'),
          ),
          PreparedImageReference(
            assetId: 'b',
            inputId: 'input-b',
            mimeType: 'image/jpeg',
            source: ImageUrlReference(
              'https://reference.example/b',
              expiresAt: '2030-01-01T00:00:00Z',
            ),
          ),
          PreparedImageReference(
            assetId: 'a',
            clipId: 'clip-c',
            inputId: 'input-c',
            mimeType: 'image/png',
            source: ImageUploadedReference('platform-token'),
          ),
        ],
      );
      final json = jsonDecode(jsonEncode(input.toJson())) as Map;
      expect(json['modelId'], 'workflow-42');
      expect(json['parameters'], {
        'ratio': '9:13',
        'resolution': 'custom',
        'size': '900x1300',
        'complexity': 'draft',
        'defaults': {
          'node': {'sampler': 'custom', 'steps': 17},
        },
      });
      final references = (json['references'] as List)
          .map(
            (value) => PreparedImageReference.fromJson(
              Map<String, dynamic>.from(value as Map),
            ),
          )
          .toList();
      expect(references.map((value) => value.assetId), ['a', 'b', 'a']);
      expect(references.map((value) => value.inputId), [
        'input-a',
        'input-b',
        'input-c',
      ]);
      expect(references.map((value) => value.source.toJson()['kind']), [
        'file',
        'url',
        'uploaded',
      ]);
      expect(references.last.source.toJson(), {
        'kind': 'uploaded',
        'ref': 'platform-token',
      });
      expect(references.first.clipId, 'clip-a');
      expect(
        references[1].source.toJson()['expiresAt'],
        '2030-01-01T00:00:00Z',
      );
    },
  );
}
