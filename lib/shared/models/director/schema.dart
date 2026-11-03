// 职责: 从导演领域定义生成静态能力合同和预设查询结果。
// 关联文件:
//   lib/shared/models/director/document.dart
//   lib/shared/models/director/entities.dart
//   lib/shared/models/director/pose.dart
//   lib/shared/models/director/properties.dart
//   lib/shared/models/director/path.dart
import 'document.dart';
import 'entities.dart';
import 'path.dart';
import 'pose.dart';
import 'presets.dart';
import 'properties.dart';
import '../production/settings.dart';

Json _shape(String required, Json properties, [String optional = '']) => {
  'type': 'object',
  'required': required.split(' '),
  'additionalProperties': false,
  'properties': {
    for (final name in [...required.split(' '), ...optional.split(' ')])
      if (name.isNotEmpty) name: properties[name],
  },
};
Json _number(num min, num max, [String unit = 'scalar']) => {
  'type': 'number',
  'finite': true,
  'minimum': min,
  'maximum': max,
  'unit': unit,
};
Json _vector(num limit, [String unit = 'meters']) => {
  'type': 'array',
  'length': 3,
  'items': _number(-limit, limit, unit),
};
const _quaternion = {
  'type': 'array',
  'length': 4,
  'items': 'finite number',
  'normalization': 'nonzero xyzw quaternion normalized to unit length',
};
const _direction = {
  'type': 'array',
  'length': 3,
  'items': 'finite number',
  'normalization': 'nonzero direction normalized to unit length',
};
const _id = {'type': 'string', 'format': 'UUID', 'globally_unique': true};
const _reference = {
  'type': 'string',
  'reference': 'existing document resource id',
};
const _color = {'type': 'string', 'pattern': r'^#[0-9A-Fa-f]{6}$'};
const _boolean = {'type': 'boolean'};
Json _enum(Iterable<dynamic> values) => {'enum': values.toList()};

Json directorSchema() {
  final frame = {
    'type': 'integer',
    'minimum': 0,
    'maximum': 'duration_frames',
    'unit': 'frame',
  };
  final easing = _enum(TrackEasing.values.map((e) => e.name));
  final pose = _shape(poseParameters.map((p) => p.id).join(' '), {
    for (final p in poseParameters)
      p.id: {
        ..._number(
          p.min,
          p.max,
          p.id == 'root_offset_y'
              ? 'local meters before object scale/rotation'
              : 'degrees',
        ),
        'default': p.initial,
      },
  });
  final targets = {
    for (final kind in cameraTargetRequiredFields.keys)
      kind: _shape(cameraTargetRequiredFields[kind]!, {
        'type': _enum([kind]),
        'position': _vector(cameraPositionLimit),
        'object_id': _reference,
        'actor_id': _reference,
        'offset': _vector(cameraPositionLimit, 'target local meters'),
        'bone': _enum(humanoidBones),
      }),
  };
  final propertyValues = <String, Json>{
    for (final property in directorProperties.values)
      property.id: {
        ...switch (property.kind) {
          PropertyKind.vector => {
            ..._vector(objectPositionLimit),
            'camera_limit': cameraPositionLimit,
          },
          PropertyKind.rotation => _quaternion,
          PropertyKind.scale => {
            'type': 'array',
            'length': 3,
            'items': _number(property.min!, property.max!),
            'actor_uniform': true,
          },
          PropertyKind.color => _color,
          PropertyKind.visible => _boolean,
          PropertyKind.pose => pose,
          PropertyKind.target => {'type': 'object', 'variants': targets},
          PropertyKind.scalar => _number(
            property.min!,
            property.max!,
            property.id == 'roll'
                ? 'unwrapped degrees'
                : property.id == 'focal_length_mm'
                ? 'millimeters'
                : property.id == 'focus_distance_m'
                ? 'meters'
                : property.id == 'aperture_fstop'
                ? 'f-number; zero disables depth of field'
                : 'intensity',
          ),
          PropertyKind.direction => _direction,
        },
        'interpolation': switch (property.kind) {
          PropertyKind.rotation => 'shortest-arc quaternion slerp',
          PropertyKind.direction =>
            'shortest great-circle direction slerp; dot <= -0.999999 requires hold or intermediate key',
          PropertyKind.color => 'linear-sRGB',
          PropertyKind.visible => 'hold only',
          PropertyKind.target =>
            'resolve both references at sampled frame, then interpolate world points',
          PropertyKind.pose =>
            'all 26 scalars together, no angle wrapping or automatic grounding',
          _ =>
            'numeric linear; smoothstep eases time; hold switches at next key',
        },
      },
  };
  final cameraFields = <String, dynamic>{
    'id': _id,
    'name': {
      'type': 'string',
      'minLength': 1,
      'maxLength': 40,
      'trimmed': true,
    },
    'position': _vector(cameraPositionLimit),
    'orientation_mode': _enum(sceneCameraRequiredFields.keys),
    'focal_length_mm': propertyValues['focal_length_mm'],
    'focus_distance_m': {
      ...propertyValues['focus_distance_m']!,
      'default': 10.0,
    },
    'aperture_fstop': {...propertyValues['aperture_fstop']!, 'default': 0.0},
    for (final entry in cameraOpticsRanges.entries)
      entry.key: _number(
        entry.value.$1,
        entry.value.$2,
        entry.key == 'sensor_height_mm' ? 'millimeters' : 'meters',
      ),
    'rotation': _quaternion,
    'camera_target': propertyValues['camera_target'],
    'reference_up': _direction,
    'roll': propertyValues['roll'],
    'deleted_at': {'type': 'metadata'},
  };
  final geometryValues = <String, dynamic>{
    for (final key in ['start', 'end', 'center'])
      key: _vector(objectPositionLimit),
    for (final key in ['radius', 'width', 'depth'])
      key: _number(pathMinDimension, pathMaxDimension, 'meters'),
    'plane_rotation': _quaternion,
    'start_angle': _number(-pathAngleLimit, pathAngleLimit, 'degrees'),
    'start_corner': {'type': 'integer', 'minimum': 0, 'maximum': 3},
    'clockwise': _boolean,
    'closed': _boolean,
    'points': {
      'type': 'array',
      'minItems': 2,
      'maxItems': DirectorDocument.maxUnits,
      'items': _vector(objectPositionLimit),
    },
    'nodes': {
      'type': 'array',
      'minItems': 2,
      'maxItems': DirectorDocument.maxUnits,
      'items': _shape('position smooth', {
        'position': _vector(objectPositionLimit),
        'smooth': _boolean,
        'in_handle': _vector(objectPositionLimit),
        'out_handle': _vector(objectPositionLimit),
      }, 'in_handle out_handle'),
      'smooth_rule':
          'present nonzero handles point in opposite collinear directions',
    },
  };
  final objectFields = <String, dynamic>{
    'id': _id,
    'kind': _enum(['actor', 'prop']),
    'name': cameraFields['name'],
    'geometry_key': {'actor': actorGeometries, 'prop': propGeometries},
    for (final key in ['position', 'rotation', 'scale', 'color', 'visible'])
      key: propertyValues[key],
    'pose': {
      'actor': pose,
      'prop': _enum(['none']),
    },
    'catalog_id': {
      'type': ['string', 'null'],
      'reference': 'work character; unique among actors',
    },
    'deleted_at': cameraFields['deleted_at'],
  };
  return {
    'document': _shape(DirectorDocument.requiredFields, {
      'format': _enum(['reveric.director']),
      'version': _enum([1]),
      'id': _id,
      'revision': {
        'type': 'integer',
        'minimum': 0,
        'maximum': 9007199254740991,
      },
      'title': {
        'type': 'string',
        'minLength': 1,
        'maxLength': 80,
        'trimmed': true,
      },
      'units': _enum(['meters']),
      'up_axis': _enum(['Y']),
      'fps': _enum([DirectorDocument.frameRate]),
      'duration_frames': {
        'type': 'integer',
        'minimum': DirectorDocument.minFrames,
        'maximum': DirectorDocument.maxFrames,
      },
      'output': _shape('width height background', {
        'width': {'type': 'integer'},
        'height': {'type': 'integer'},
        'background': _color,
        'aspect_mode': _enum(['auto']),
      }, 'aspect_mode'),
      'lighting': _shape('ambient_intensity key_intensity key_direction', {
        for (final key in [
          'ambient_intensity',
          'key_intensity',
          'key_direction',
        ])
          key: propertyValues['lighting.$key'],
      }),
      'objects': {'type': 'array', 'items': 'object'},
      'cameras': {'type': 'array', 'items': 'camera'},
      'tracks': {'type': 'array', 'items': 'track'},
      'motion_paths': {'type': 'array', 'items': 'path'},
      'camera_moves': {'type': 'array', 'items': 'move'},
      'camera_cuts': {'type': 'array', 'items': 'cut'},
      'default_camera_id': _reference,
    }),
    'object': _shape(
      sceneObjectRequiredFields,
      objectFields,
      sceneObjectOptionalFields,
    ),
    'camera': {
      for (final mode in sceneCameraRequiredFields.keys)
        mode: _shape(
          sceneCameraRequiredFields[mode]!,
          cameraFields,
          sceneCameraOptionalFields,
        ),
    },
    'pose': pose,
    'camera_target': targets,
    'properties': propertyValues,
    'properties_by_target': {
      'actor': propertiesFor(object: {'kind': 'actor'}),
      'prop': propertiesFor(object: {'kind': 'prop'}),
      for (final mode in sceneCameraRequiredFields.keys)
        'camera_$mode': propertiesFor(camera: {'orientation_mode': mode}),
      'document_id': propertiesFor(lighting: true),
    },
    'track': _shape(PropertyTrack.requiredFields, {
      'id': _id,
      'target_id': _reference,
      'property': _enum(directorProperties.keys),
      'keys': {
        'type': 'array',
        'minItems': 1,
        'items': _shape(PropertyKey.requiredFields, {
          'frame': frame,
          'value': {'schema': 'properties[property]'},
          'easing': easing,
        }),
      },
    }),
    'path': _shape(MotionPath.requiredFields, {
      'id': _id,
      'target_id': _reference,
      'kind': _enum(pathKinds),
      'start_frame': frame,
      'end_frame': frame,
      'easing': easing,
      'orient_to_path': _boolean,
      'geometry': {
        'variants': {
          for (final kind in pathKinds)
            kind: _shape(MotionPath.geometryFields[kind]!, geometryValues),
        },
      },
    }),
    'move': _shape(CameraMove.requiredFields, {
      'id': _id,
      'camera_id': _reference,
      'kind': _enum(moveKinds),
      'start_frame': frame,
      'end_frame': frame,
    }),
    'cut': _shape(cameraCutRequiredFields, {
      'id': _id,
      'frame': frame,
      'camera_id': _reference,
    }),
    'output_sizes': {
      'auto': 'even width and height between 2 and 1920',
      'fixed': [
        for (final ratio in ProductionSettings.ratios)
          for (final resolution in ProductionSettings.resolutions)
            [
              ProductionSettings.dimensions(ratio, resolution).$1,
              ProductionSettings.dimensions(ratio, resolution).$2,
            ],
      ],
    },
    'limits': {
      'bytes': DirectorDocument.maxBytes,
      'actors': DirectorDocument.maxActors,
      'props': DirectorDocument.maxProps,
      'cameras': DirectorDocument.maxCameras,
      'tracks': DirectorDocument.maxTracks,
      'paths': DirectorDocument.maxPaths,
      'moves': DirectorDocument.maxMoves,
      'shared_units': DirectorDocument.maxUnits,
      'unit_count':
          'one per key/cut/path point/pen anchor or present handle; circle/rectangle four each; full pose one',
    },
    'control_rules': [
      'Integer frames. Intervals [start_frame,end_frame), start < end. Endpoint is editable/audited, MP4 excludes it.',
      'One track per target/property, ordered unique frames. Before first key use base; after last hold. Removing last key removes track.',
      'Paths control actor position and optionally upright rotation; constant arc-length progress after easing. No automatic gait.',
      'Pencil simplification <= $pencilTolerance meters; pen arc subdivision <= $pathArcTolerance meters. Nonzero path length; coordinates remain within world bounds.',
      'Same-target paths and same-camera moves cannot overlap. Manual interpolation cannot cross a controlled channel. Use replace=true explicitly or bake before editing.',
      'Control endpoints hold until next explicit control. Replacement preserves outside frames. Bake checks all frames including endpoint and fails atomically on capacity/error.',
      'Pose root_offset_y is local Y before object scale/rotation, applied once. Presets do not change object position.',
      'Moves use smoothstep and derive starts from preceding controls. Subject moves require object/bone camera_target in look_at mode.',
      'Camera orientation mode is whole-camera configuration; mode change preserves framing and requires existing direction animation to be removed explicitly.',
      'far must be greater than near. Target must exist, differ from camera position, and produce a finite direction. Reference up starts a continuous orientation frame.',
      'Cut takes effect immediately at its frame; before first cut use default_camera_id. Deletion must handle all external references in the same raw edits batch.',
      'Unknown fields and removed action collections are rejected; no scene templates. Numerical validation does not certify visual quality.',
    ],
    'move_channels': {
      for (final mode in sceneCameraRequiredFields.keys)
        mode: {
          for (final kind in moveKinds) kind: moveChannels(kind, mode).toList(),
        },
    },
  };
}

Json directorPresets({Json options = const {}}) {
  const catalogs = ['props', 'poses', 'cameras', 'moves'];
  final catalog = options['catalog'];
  if (options.containsKey('catalog')) {
    choice(catalog, 'catalog', catalogs);
  }
  final available = <String, List<String>>{
    'props': [for (final prop in propPresets) prop.geometry],
    'poses': poseIds,
    'cameras': cameraPresets,
    'moves': moveKinds,
  };
  List<String>? ids;
  if (options.containsKey('ids')) {
    if (catalog == null) {
      invalid('catalog', 'required_with_ids');
    }
    final raw = options['ids'];
    if (raw is! List || raw.isEmpty) {
      invalid('ids', 'expected_nonempty_array');
    }
    for (var i = 0; i < raw.length; i++) {
      choice(raw[i], 'ids[$i]', available[catalog]!);
    }
    ids = raw.cast<String>();
  }

  Json detail(String category, String id) {
    switch (category) {
      case 'props':
        final prop = propPresets.firstWhere((p) => p.geometry == id);
        return {
          'id': id,
          'group': prop.group,
          'dimensions_m': prop.size,
          'bbox_min_m': prop.minimum,
          'bbox_max_m': prop.maximum,
          'origin': prop.origin,
          'direction': prop.direction,
          'default_scale': [1, 1, 1],
          'default_position': prop.defaultPosition,
          'support_heights_m': prop.supportHeights,
        };
      case 'poses':
        return {
          'id': id,
          'variants': [
            for (final geometry in actorGeometries)
              {
                'geometry_key': geometry,
                'pose': posePreset(id, geometry).toJson(),
              },
          ],
        };
      case 'moves':
        final move = movePreset(id);
        return {
          'id': id,
          'group': move.group,
          'subject_required': move.subject,
        };
      default:
        return {'id': id};
    }
  }

  return {
    for (final category in catalog == null ? catalogs : [catalog as String])
      category: [
        for (final id in ids ?? available[category]!)
          if (ids == null) {'id': id} else detail(category, id),
      ],
  };
}
