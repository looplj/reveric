// 职责: 验证命令原子性、手势取消、硬删除及保存基线。
// 关联文件:
//   lib/shared/services/director/commands.dart
import 'dart:io';
import 'package:reveric/shared/models/director/rig.dart';
import 'dart:math' as math;
import 'package:reveric/shared/models/director/sampling.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/models/director/document.dart';
import 'package:reveric/shared/services/director/commands.dart';
import 'package:reveric/shared/services/screenplay/staging_changes.dart';

void main() {
  late CommandHistory h;
  setUp(
    () => h = CommandHistory(
      DirectorDocument.parse(
        File('test/fixtures/director/motion.director.json').readAsStringSync(),
      ),
    ),
  );
  tearDown(() => h.dispose());
  test('adding more than six actors supports undo and redo', () {
    h.replace(DirectorDocument.blank('Crowd'));
    for (var i = 0; i < 12; i++) {
      h.addObject('actor.male.v1', 'Actor $i');
    }
    expect(h.document.objects, hasLength(12));
    h.undo();
    expect(h.document.objects, hasLength(11));
    h.redo();
    expect(h.document.objects, hasLength(12));
  });
  test(
    'target keys retain references at held frames but sample blended points',
    () {
      h.replace(DirectorDocument.blank('Targets'));
      h.addObject('actor.male.v1', 'Actor');
      final id = h.document.cameras.single['id'],
          actor = h.document.objects.single['id'];
      h.setLookAt(id, actor);
      final reference = h.document.camera(id)!['camera_target'];
      h.toggleKey(id, 'camera_target', 24);
      expect(h.document.tracks.single['keys'].single['value'], reference);
      h.setKeyEasing(id, 'camera_target', 24, 'hold');
      h.toggleKey(id, 'camera_target', 48);
      expect(h.document.tracks.single['keys'].last['value'], reference);
      h.setKeyEasing(id, 'camera_target', 24, 'linear');
      expect(h.cameraTargetValue(id, 36), reference);
      h.setKeyEasing(id, 'camera_target', 24, 'hold');
      h.setValue(id, 'camera_target', {
        'type': 'point',
        'position': [2, 2, 0],
      }, 48);
      expect(h.cameraTargetValue(id, 36), reference);
      h.setKeyEasing(id, 'camera_target', 24, 'linear');
      final target = sampleDocument(h.document, 36).cameras[id]!['target'];
      h.toggleKey(id, 'camera_target', 36);
      expect(h.document.tracks.single['keys'][1]['value'], {
        'type': 'point',
        'position': target,
      });
      expect(h.cameraTargetValue(id, 24), reference);
    },
  );
  test(
    'cut edit duplicate is atomic and default/cut removal undo together',
    () {
      h.setCut(24, h.document.cameras.first['id']);
      h.setCut(48, h.document.cameras.last['id']);
      final before = h.document.businessContent;
      expect(
        () => h.editCut(
          h.document.cuts.first['id'],
          48,
          h.document.cameras.first['id'],
        ),
        throwsA(isA<DocumentError>()),
      );
      expect(h.document.businessContent, before);
      h.removeCut(h.document.cuts.first['id']);
      h.undo();
      expect(h.document.businessContent, before);
    },
  );
  test('stale field edits cannot recreate a removed actor', () {
    final before = h.document;
    final id = before.objects.first['id'];
    final edited = before.mutate((j) => j['objects'][0]['name'] = 'Renamed');
    h.remove(id);
    expect(
      () => applyStagingChanges(h.document, before, edited),
      throwsA(isA<DocumentError>()),
    );
    expect(h.document.objects.where((o) => o['id'] == id), isEmpty);
    // 完整撤销仍可恢复同一个对象及其依赖。
    h.undo();
    expect(h.document.businessContent, before.businessContent);
  });

  test(
    'removing a followed actor requires explicit reference handling and undo restores it',
    () {
      final actorId = h.document.objects.first['id'];
      final cameraId = h.document.cameras.first['id'];
      h.setLookAt(cameraId, actorId);
      final before = h.document;
      expect(() => h.remove(actorId), throwsA(isA<DocumentError>()));
      h.execute((j) {
        j['cameras'][0]['camera_target'] = {
          'type': 'point',
          'position': [0, 1, 0],
        };
        CommandHistory.removeObject(j, actorId);
      });
      expect(h.document.camera(cameraId)!['camera_target']['type'], 'point');
      h.undo();
      expect(h.document.businessContent, before.businessContent);
    },
  );
  test(
    'hard deletion and undo restore full identity with increasing revision',
    () {
      final original = h.document, id = original.objects.first['id'];
      h.remove(id);
      expect(h.document.objects.where((o) => o['id'] == id), isEmpty);
      expect(h.document.tracks.where((t) => t['target_id'] == id), isEmpty);
      expect(h.document.paths.where((c) => c['target_id'] == id), isEmpty);
      h.undo();
      expect(h.document.businessContent, original.businessContent);
      expect(h.document.revision, 2);
      expect(h.dirty, false);
      h.redo();
      expect(h.dirty, true);
      h.markSaved(h.document);
      expect(h.dirty, false);
    },
  );
  test('cancel gesture does not dirty or add history; commit once', () {
    for (var i = 0; i < 8; i++) {
      h.previewEdit((j) => j['objects'][1]['position'] = [i.toDouble(), 0, 0]);
    }
    expect(h.undoCount, 0);
    h.cancelGesture();
    expect(h.dirty, false);
    h.previewEdit((j) => j['objects'][1]['position'] = [2, 0, 0]);
    h.commitGesture();
    expect(h.undoCount, 1);
    h.undo();
    expect(h.dirty, false);
    h.execute((j) => j['title'] = 'Changed');
    expect(h.canRedo, false);
  });
  test(
    'external saved edits retain only the bounded most recent undo history',
    () {
      for (var i = 0; i < 105; i++) {
        h.synchronize(
          h.document.mutate((j) => j['title'] = 'External $i'),
          external: true,
        );
      }
      expect(h.undoCount, 100);
      h.undo();
      expect(h.document.title, 'External 103');
      for (var i = 0; i < 99; i++) {
        h.undo();
      }
      expect(h.document.title, 'External 4');
      expect(h.canUndo, isFalse);
    },
  );
  test('invalid mutation preserves document and dirty', () {
    final before = h.document;
    expect(
      () => h.execute((j) => j['duration_frames'] = 20),
      throwsA(isA<DocumentError>()),
    );
    expect(identical(h.document, before), true);
    expect(h.dirty, false);
  });
  test('interval insertion before start holds base orientation', () {
    final id = h.document.objects[1]['id'];
    h.intervalKeys(id, 'rotation', 24, 48, [0, 1, 0, 0]);
    final t = h.document.tracks.last;
    expect(t['keys'][0]['frame'], 24);
    expect(
      sampleDocument(h.document, 23).objects[1]['rotation'],
      h.document.objects[1]['rotation'],
    );
  });
  test('segment replacement is explicit and preserves outside curves', () {
    final id = h.document.cameras.last['id'];
    h.move(id, 'dolly_in', 0, 96);
    h.move(id, 'pan_l', 96, 120);
    final before = h.document;
    expect(() => h.move(id, 'zoom_in', 40, 60), throwsA(isA<DocumentError>()));
    expect(h.document.businessContent, before.businessContent);
    h.move(id, 'zoom_in', 40, 60, replace: true);
    expect(h.document.moves.map((m) => m['kind']), ['pan_l', 'zoom_in']);
    for (final frame in [0, 20, 39, 60, 80, 95]) {
      final a = sampleCamera(before, id, frame);
      final b = sampleCamera(h.document, id, frame);
      for (var i = 0; i < 3; i++) {
        expect(b['position'][i], closeTo(a['position'][i], .001));
      }
    }
    h.move(id, 'static', 0, 120, replace: true);
    expect(h.document.moves.where((c) => c['camera_id'] == id), hasLength(1));
  });
  test('key toggle adds, edits in place and removes keys', () {
    final id = h.document.objects[1]['id'];
    h.setValue(id, 'position', [1, 0, 0], 30);
    expect(h.document.tracks.where((t) => t['target_id'] == id), isEmpty);
    h.toggleKey(id, 'position', 30);
    final track = h.document.tracks.firstWhere((t) => t['target_id'] == id);
    expect([for (final k in track['keys']) k['frame']], [30]);
    h.setValue(id, 'position', [2, 0, 0], 30);
    expect(
      h.document.tracks.firstWhere(
        (t) => t['target_id'] == id,
      )['keys'][0]['value'],
      [2, 0, 0],
    );
    h.toggleKey(id, 'position', 30);
    expect(h.document.tracks.where((t) => t['target_id'] == id), isEmpty);
    expect(h.document.objects[1]['position'], [1, 0, 0]);
  });
  test('face path keeps keyed pitch and roll', () {
    final id = h.document.objects.first['id'];
    h.intervalKeys(id, 'rotation', 0, 96, eulerQuaternion([0.4, 0.7, -0.6]));
    h.facePath(id);
    final rotation = h.document.tracks.singleWhere(
      (t) => t['target_id'] == id && t['property'] == 'rotation',
    );
    final angles = quaternionEuler(sampleTrack(rotation, 96));
    expect(angles[0], closeTo(0.4, 1e-9));
    expect(angles[1], closeTo(0, 1e-9));
    expect(angles[2], closeTo(-0.6, 1e-9));
  });
  test('camera presets use the elevated subject and rotated target', () {
    final actorId = h.document.objects[1]['id'];
    h.execute((j) {
      j['objects'][1]['position'] = [1, 3, 2];
      j['objects'][1]['rotation'] = eulerQuaternion([0, 0, math.pi / 2]);
    });
    final id = h.addCamera('Airborne', 'front_close', actorId, 0);
    final camera = h.document.camera(id)!;
    expect(camera['position'][1], closeTo(4.55, 1e-9));
    final sampled = sampleCamera(h.document, id, 0);
    final actor = sampleDocument(h.document, 0).objects[1];
    expect(sampled['target'], boneWorldPoint(actor, 'head', [0, 0, 0]));
  });
  test('cameras: add from preset, look at, delete keeps one camera', () {
    final actor = h.document.objects[1]['id'];
    final id = h.addCamera('C', 'front_close', actor, 0);
    expect(h.document.activeCameras, hasLength(3));
    h.setLookAt(id, actor);
    expect(h.document.camera(id)!['camera_target']['actor_id'], actor);
    h.move(id, 'orbit', 0, 48);
    h.remove(id);
    expect(h.document.moves.where((m) => m['camera_id'] == id), isEmpty);
    h.undo();
    expect(h.document.moves, hasLength(1));
    for (final c in h.document.activeCameras.skip(1)) {
      h.remove(c['id']);
    }
    expect(
      () => h.remove(h.document.activeCameras.first['id']),
      throwsA(isA<DocumentError>()),
    );
  });
}
