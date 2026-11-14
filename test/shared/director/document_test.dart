// 职责: 验证工程合同拒绝非法输入并保持有效快照。
// 关联文件:
//   lib/shared/models/director/document.dart
import 'dart:io';
import 'dart:math' as math;

import 'package:reveric/shared/models/director/sampling.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/director/document.dart';

void main() {
  final text = File(
    'test/fixtures/director/scene.director.json',
  ).readAsStringSync();
  test('fixtures round trip without losing identity', () {
    for (final name in ['scene', 'motion']) {
      final d = DirectorDocument.parse(
        File('test/fixtures/director/$name.director.json').readAsStringSync(),
      );
      expect(DirectorDocument.parse(d.encode()).toJson(), d.toJson());
    }
  });
  test(
    'editing returned samples cannot mutate the document or later frames',
    () {
      final document = DirectorDocument.parse(text);
      final original = document.encode();
      final sample = sampleDocument(document, 0);
      sample.objects.first['position'][0] = 999;
      sample.objects.first['pose']['head_yaw'] = 999;
      sample.cameras.values.first['position'][0] = 999;
      sample.cameras.values.first['camera_target']['position'][0] = 999;

      final fresh = DirectorDocument.parse(original);
      for (final frame in [0, 24, 0]) {
        final expected = sampleDocument(fresh, frame);
        final actual = sampleDocument(document, frame);
        expect(actual.objects, expected.objects);
        expect(actual.cameras, expected.cameras);
      }
      expect(document.encode(), original);
    },
  );
  test('wire fields are snake_case and legacy nested fields are rejected', () {
    final document = DirectorDocument.parse(text);
    void inspect(Object? value) {
      if (value is Map) {
        for (final entry in value.entries) {
          expect(entry.key, matches(RegExp(r'^[a-z][a-z0-9_]*$')));
          inspect(entry.value);
        }
      } else if (value is List) {
        for (final child in value) {
          inspect(child);
        }
      }
    }

    inspect(document.toJson());
    expect(document.durationFrames, document.toJson()['duration_frames']);
    expect(
      () => document.mutate((json) {
        json['durationFrames'] = json.remove('duration_frames');
      }),
      throwsA(isA<DocumentError>()),
    );
    expect(
      () => document.mutate((json) {
        final camera = json['cameras'][0] as Map;
        camera['focalLengthMm'] = camera.remove('focal_length_mm');
      }),
      throwsA(isA<DocumentError>()),
    );
  });
  test(
    'duplicate key, unknown version, missing field, bad quaternion, reference rejected',
    () {
      expect(
        () => DirectorDocument.parse(
          text.replaceFirst('"version": 1', '"version": 1, "version": 1'),
        ),
        throwsA(isA<DocumentError>()),
      );
      for (final edit in <void Function(Json)>[
        (j) => j['version'] = 2,
        (j) => j.remove('title'),
        (j) => j['objects'][0]['rotation'] = [0, 0, 0, 0],
        (j) => j['cameras'][0]['target'] = j['cameras'][0]['position'],
        (j) => j['cameras'][0]['look_at_id'] = j['objects'][2]['id'],
        (j) => j['cameras'].clear(),
        (j) => j['camera_moves'].add({
          'id': '60000000-0000-4000-8000-000000000009',
          'camera_id': j['cameras'][0]['id'],
          'kind': 'orbit',
          'start_frame': 0,
          'end_frame': 0,
        }),
        (j) => j['objects'][1]['id'] = j['objects'][0]['id'],
        (j) => j['objects'][0]['pose'] = 'unknown',
      ]) {
        expect(
          () => DirectorDocument.parse(text).mutate(edit),
          throwsA(isA<DocumentError>()),
        );
      }
      expect(
        () => DirectorDocument.parse(' ' * (5 * 1024 * 1024 + 1)),
        throwsA(isA<DocumentError>()),
      );
      expect(
        () => DirectorDocument.parse('${'[' * 1100}0${']' * 1100}'),
        throwsA(isA<DocumentError>()),
      );
    },
  );
  test(
    'actors and props accept height and full rotation, but reject invalid values',
    () {
      final base = DirectorDocument.parse(text);
      final rotated = base.mutate((j) {
        for (final o in j['objects']) {
          o['position'] = [1, 2.5, -3];
          o['rotation'] = eulerQuaternion([
            math.pi / 3,
            math.pi / 4,
            -math.pi / 2,
          ]);
        }
      });
      expect(
        DirectorDocument.parse(rotated.encode()).toJson(),
        rotated.toJson(),
      );
      for (final edit in <void Function(Json)>[
        (j) => j['objects'][0]['position'][1] = double.nan,
        (j) => j['objects'][0]['position'][1] = double.infinity,
        (j) => j['objects'][0]['rotation'] = [0, 0, 0, 0],
        (j) => j['objects'][0]['rotation'] = [0, 0, 1],
        (j) => j['objects'][0]['rotation'] = [0, 0, '0', 1],
        (j) => j['objects'][0]['rotation'] = [double.nan, 0, 0, 1],
        (j) => j['objects'][0]['rotation'] = [0, double.infinity, 0, 1],
      ]) {
        expect(() => rotated.mutate(edit), throwsA(isA<DocumentError>()));
      }
    },
  );
  test(
    'normalizes finite nonzero object rotations without changing caller input',
    () {
      final base = DirectorDocument.parse(text);
      for (final q in <List<num>>[
        [-0.34, 0, 0, 0.94],
        [-0.707, 0, 0, 0.707],
        [0, 0, 0, 2],
        [0.5, 0.5, 0, 0],
        [1e308, -1e308, 1e308, -1e308],
        [1e-308, -1e-308, 1e-308, -1e-308],
      ]) {
        final input = base.toJson();
        for (final o in input['objects']) {
          o['rotation'] = [...q];
        }
        final before = cloneJson(input);
        final document = DirectorDocument.fromJson(input);
        expect(input, before);
        final scale = q.map((v) => v.abs()).reduce((a, b) => a > b ? a : b);
        final scaled = q.map((v) => v / scale).toList();
        final length = math.sqrt(scaled.fold<double>(0, (s, v) => s + v * v));
        for (final o in document.objects) {
          final normalized = (o['rotation'] as List).cast<num>();
          expect(
            normalized.fold<double>(0, (s, v) => s + v * v),
            closeTo(1, 1e-14),
          );
          for (var i = 0; i < 4; i++) {
            expect(normalized[i], closeTo(scaled[i] / length, 1e-14));
          }
        }
        var reopened = document;
        for (var i = 0; i < 10; i++) {
          reopened = DirectorDocument.parse(reopened.encode());
        }
        expect(reopened.businessContent, document.businessContent);
      }
    },
  );

  test(
    'normalizes rounded rotation keys before playback and serialization',
    () {
      final input = DirectorDocument.parse(text).toJson();
      final actor = input['objects'][0]['id'];
      input['tracks'] = [
        {
          'id': '40000000-0000-4000-8000-000000000001',
          'target_id': actor,
          'property': 'rotation',
          'keys': [
            {
              'frame': 0,
              'value': [-0.34, 0, 0, 0.94],
              'easing': 'linear',
            },
            {
              'frame': 54,
              'value': [-0.707, 0, 0, 0.707],
              'easing': 'hold',
            },
          ],
        },
      ];
      final document = DirectorDocument.fromJson(input);
      final keys = document.tracks.single['keys'] as List;
      expect(keys[0]['value'][0], closeTo(-0.3401360816544381, 1e-14));
      expect(keys[1]['value'][0], closeTo(-math.sqrt(0.5), 1e-14));
      for (final frame in [0, 27, 54, 120]) {
        final q =
            (sampleDocument(document, frame).objects.first['rotation'] as List)
                .cast<num>();
        expect(q.fold<double>(0, (s, v) => s + v * v), closeTo(1, 1e-14));
      }
      expect(
        DirectorDocument.parse(document.encode()).businessContent,
        document.businessContent,
      );
      for (final invalid in <dynamic>[
        [0, 0, 0, 0],
        [0, 0, 1],
        [0, 0, '0', 1],
        [double.nan, 0, 0, 1],
        [0, double.infinity, 0, 1],
      ]) {
        expect(
          () => document.mutate(
            (j) => j['tracks'][0]['keys'][1]['value'] = invalid,
          ),
          throwsA(isA<DocumentError>()),
        );
      }
    },
  );
  test('300 actors round trip and remain in sampled frames', () {
    final d = DirectorDocument.parse(text);
    final crowd = d.mutate((j) {
      for (var i = 4; i < 302; i++) {
        final o = cloneJson(j['objects'][0]);
        o['id'] = '20000000-0000-4000-8000-${i.toString().padLeft(12, '0')}';
        j['objects'].add(o);
      }
    });
    final reopened = DirectorDocument.parse(crowd.encode());
    expect(reopened.toJson(), crowd.toJson());
    expect(reopened.objects.where((o) => o['kind'] == 'actor'), hasLength(300));
    expect(sampleDocument(reopened, 0).objects, hasLength(301));
  });
  test('prop capacity and dangling track still fail', () {
    final d = DirectorDocument.parse(text);
    expect(
      () => d.mutate((j) {
        for (var i = 4; i < 24; i++) {
          final o = cloneJson(j['objects'][2]);
          o['id'] = '20000000-0000-4000-8000-${i.toString().padLeft(12, '0')}';
          j['objects'].add(o);
        }
      }),
      throwsA(
        isA<DocumentError>().having((e) => e.reason, 'reason', 'capacity'),
      ),
    );
    final entry = DirectorDocument.parse(
      File('test/fixtures/director/motion.director.json').readAsStringSync(),
    );
    expect(
      () => entry.mutate((j) => j['tracks'][0]['target_id'] = 'missing'),
      throwsA(isA<DocumentError>()),
    );
  });
}
