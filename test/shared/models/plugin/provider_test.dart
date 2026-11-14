// 职责: 验证插件模型声明的严格能力边界、模式组合及默认值透传。
// 关联文件:
//   lib/shared/models/plugin/provider.dart
//   lib/shared/models/image/config.dart
//   lib/shared/models/video/config.dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/plugin/provider.dart';
import 'package:reveric/shared/models/image/config.dart';
import 'package:reveric/shared/models/video/request.dart';

Map<String, dynamic> video() => {
  'kind': 'video',
  'id': 'workflow',
  'capabilities': {
    'ratios': ['16:9', 'adaptive'],
    'resolutions': ['720p', '1080p'],
    'durations': [5, 10],
    'modes': ['first_last_frame'],
    'frameRoles': ['first_frame', 'last_frame'],
    'maxMiddleFrames': 0,
    'maxReferences': 2,
    'references': {
      'image': {'maxCount': 2},
    },
    'supportsAudioOnlyReference': false,
    'supportsAdaptiveTextRatio': false,
    'supportsLastFrameOnly': false,
    'framesRequireAdaptiveRatio': true,
    'supportsCertifiedAssets': false,
    'draft': null,
  },
};
Map<String, dynamic> image() => {
  'kind': 'image',
  'id': 'gpt-image-2',
  'capabilities': {
    'ratios': ['7:5'],
    'resolutions': ['custom'],
    'minReferences': 0,
    'maxReferences': 2,
    'unlimitedReferences': false,
    'referenceTransport': 'uploaded',
    'sizes': {
      'custom': {'7:5': '1400x1000'},
    },
    'complexityLevels': ['fine', 'rough'],
  },
  'requestDefaults': {
    'complexity': 'fine',
    'workflow': {
      'node': '42',
      'values': [1, true, null],
    },
  },
};
void main() {
  test('quality levels round trip and reject an unsupported default', () {
    final raw = image();
    (raw['capabilities'] as Map)['qualityLevels'] = ['draft', 'best'];
    (raw['requestDefaults'] as Map)['quality'] = 'best';
    final parsed = parsePluginProviderModels([raw]).single;
    expect(parsed.image!.qualityLevels, {'draft', 'best'});
    expect(PluginProviderModel.fromJson(parsed.toJson()).image!.qualityLevels, {
      'draft',
      'best',
    });
    (raw['requestDefaults'] as Map)['quality'] = 'unsupported';
    expect(() => parsePluginProviderModels([raw]), throwsFormatException);
  });
  test(
    'custom capability is independent of built-in names and preserves unknown defaults',
    () {
      final raw = image();
      (raw['capabilities'] as Map)['futureConstraint'] = true;
      final parsed = parsePluginProviderModels([raw]).single;
      expect(parsed.image!.ratios, {'7:5'});
      expect(
        parsed.image!.referenceTransport,
        ImageReferenceTransport.uploaded,
      );
      expect(parsed.imageDefaults.complexity, 'fine');
      expect(parsed.requestDefaults['workflow'], {
        'node': '42',
        'values': [1, true, null],
      });
      expect(
        parsed.toJson()['capabilities'].containsKey('futureConstraint'),
        false,
      );
      final restored = PluginProviderModel.fromJson(
        jsonDecode(jsonEncode(parsed.toJson())) as Map<String, dynamic>,
      );
      expect(restored.toJson(), parsed.toJson());
    },
  );
  test(
    'same ID may identify image and video while chat declarations are ignored',
    () {
      final raw = video()..['id'] = 'gpt-image-2';
      final models = parsePluginProviderModels([
        image(),
        raw,
        {'kind': 'chat'},
      ]);
      expect(models, hasLength(2));
      expect(models.last.video!.modes, [VideoMode.first_last_frame]);
      expect(
        () => parsePluginProviderModels([raw, raw]),
        throwsFormatException,
      );
      expect(
        () => parsePluginProviderModels([
          {'kind': 'audio', 'id': 'voice'},
        ]),
        throwsFormatException,
      );
    },
  );
  for (final key in [
    'ratios',
    'resolutions',
    'durations',
    'modes',
    'frameRoles',
    'maxMiddleFrames',
    'maxReferences',
    'references',
    'supportsAudioOnlyReference',
    'supportsAdaptiveTextRatio',
    'supportsLastFrameOnly',
    'framesRequireAdaptiveRatio',
    'supportsCertifiedAssets',
    'draft',
  ]) {
    test('video requires explicit $key', () {
      final raw = video();
      (raw['capabilities'] as Map).remove(key);
      expect(() => parsePluginProviderModels([raw]), throwsFormatException);
    });
  }
  for (final (field, value) in <(String, Object?)>[
    ('modes', []),
    ('modes', ['unknown']),
    ('modes', ['first_last_frame', 'first_last_frame']),
    ('frameRoles', ['reference_image']),
    ('frameRoles', ['first_frame']),
    ('maxReferences', 1),
    ('maxReferences', -1),
    ('maxReferences', 2.5),
    ('maxMiddleFrames', 3),
    ('durations', [0]),
    ('durations', [5, 5]),
    ('durations', [double.infinity]),
    ('ratios', ['16:9']),
    ('maxDurationByResolution', {'4K': 5}),
    ('maxDurationByResolution', {'720p': 1}),
    (
      'references',
      {
        'image': {'maxCount': 1},
      },
    ),
    (
      'references',
      {
        'image': {'maxCount': 2, 'minDimension': 1000, 'maxDimension': 100},
      },
    ),
    (
      'references',
      {
        'image': {'maxCount': 2, 'maxSizeMb': double.nan},
      },
    ),
    (
      'draft',
      {'resolution': '360p', 'completionResolution': '720p', 'ttlHours': 0},
    ),
  ]) {
    test('reject inconsistent video $field=$value', () {
      final raw = video();
      (raw['capabilities'] as Map)[field] = value;
      expect(() => parsePluginProviderModels([raw]), throwsFormatException);
    });
  }
  test('text-only declaration has no implied frame or media inputs', () {
    final raw = video();
    (raw['capabilities'] as Map<String, dynamic>).addAll({
      'modes': ['text'],
      'frameRoles': [],
      'maxReferences': 0,
      'references': {},
      'framesRequireAdaptiveRatio': false,
    });
    expect(parsePluginProviderModels([raw]).single.video!.frameRoles, isEmpty);
    (raw['capabilities'] as Map)['supportsAudioOnlyReference'] = true;
    expect(() => parsePluginProviderModels([raw]), throwsFormatException);
  });
  for (final (field, value) in <(String, Object?)>[
    ('minReferences', 3),
    ('maxReferences', -1),
    ('referenceTransport', 'fallback'),
    ('ratios', ['7:5', '7:5']),
    ('maxAspectRatio', 0.5),
    (
      'sizes',
      {
        'unknown': {'7:5': '1400x1000'},
      },
    ),
    (
      'sizes',
      {
        'custom': {'7:5': 'invalid'},
      },
    ),
  ]) {
    test('reject invalid image $field', () {
      final raw = image();
      (raw['capabilities'] as Map)[field] = value;
      expect(() => parsePluginProviderModels([raw]), throwsFormatException);
    });
  }
  test(
    'defaults reject known type errors and unsupported complexity, retain future JSON',
    () {
      for (final defaults in [
        {'complexity': 'unknown'},
        {'size': 42},
        {'quality': false},
        {'watermark': 'yes'},
        {'future': DateTime(2026)},
      ]) {
        final raw = image()..['requestDefaults'] = defaults;
        expect(() => parsePluginProviderModels([raw]), throwsFormatException);
      }
      final raw = video()..['requestDefaults'] = {'audio': 'yes'};
      expect(() => parsePluginProviderModels([raw]), throwsFormatException);
    },
  );
  test(
    'omitted built-in image transport stays inline and JSON preserves all effective fields',
    () {
      const caps = ImageModelCapabilities(
        ratios: {'1:1'},
        resolutions: {'1K'},
        maxReferences: 3,
      );
      expect(caps.referenceTransport, ImageReferenceTransport.file);
      expect(
        ImageModelCapabilities.fromJson(caps.toJson()).toJson(),
        caps.toJson(),
      );
    },
  );
}
