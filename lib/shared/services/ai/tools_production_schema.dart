// 职责: 声明按集制片画布和片段生成记录的静态资源契约。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tools_production.dart
part of 'tools.dart';

const _productionJson = _ValueSchema(
  _ValueType.object,
  additionalProperties: true,
);
const _productionRead = _ResourceOperation(
  _ResourceTool.read,
  _ResourceTargetKind.resource,
);
const _productionList = _ResourceOperation(
  _ResourceTool.read,
  _ResourceTargetKind.listing,
);
const _productionWrite = _ResourceOperation(
  _ResourceTool.write,
  _ResourceTargetKind.resource,
  input: _ResourceInput(_ResourceInputKind.resource_fields),
);
const _productionCreate = _ResourceOperation(
  _ResourceTool.create,
  _ResourceTargetKind.listing,
  input: _ResourceInput(_ResourceInputKind.create_fields),
);
const _productionRemove = _ResourceOperation(
  _ResourceTool.remove,
  _ResourceTargetKind.resource,
);
const _productionId = _ResourceField(
  value: _ValueSchema(_ValueType.string),
  read: _FieldRead(listing: true, path: true),
);
const _productionNodes = _ResourceDefinition(
  segment: 'nodes',
  address: _ResourceAddress(_AddressKind.id, itemToken: 'node_id'),
  description: '制片节点',
  group: contentKindScreenplay,
  hidden: true,
  listing: _ResourceListing(),
  fields: {
    ..._productionNodeFields,
    'type': _ResourceField(
      value: _ValueSchema(
        _ValueType.string,
        enumValues: ['video', 'image', 'audio', 'staging', 'media', 'text'],
      ),
      read: _FieldRead(listing: true, path: true),
      create: _FieldInputUse(
        required: true,
        value: _ValueSchema(
          _ValueType.string,
          enumValues: ['video', 'image', 'audio', 'staging', 'media', 'text'],
        ),
      ),
    ),
  },
  operations: [
    _productionRead,
    _productionList,
    _productionCreate,
    _productionWrite,
    _productionRemove,
  ],
);
const _productionEdges = _ResourceDefinition(
  segment: 'edges',
  address: _ResourceAddress(_AddressKind.id, itemToken: 'edge_id'),
  description: '制片连线',
  group: contentKindScreenplay,
  hidden: true,
  listing: _ResourceListing(),
  fields: {
    'id': _productionId,
    'data': _ResourceField(
      value: _productionJson,
      read: _FieldRead(path: true),
    ),
  },
  operations: [_productionRead, _productionList],
);
const _productionCanvas = _ResourceDefinition(
  segment: 'canvas',
  optionalChild: true,
  address: _ResourceAddress(_AddressKind.singleton),
  description: '制片画布',
  group: contentKindScreenplay,
  hidden: true,
  fields: {
    'id': _productionId,
    'positions': _ResourceField(
      value: _ValueSchema(_ValueType.array, items: _productionJson),
      write: _FieldInputUse(),
    ),
    'remove_types': _ResourceField(
      value: _ValueSchema(
        _ValueType.array,
        items: _ValueSchema(
          _ValueType.string,
          enumValues: ['video', 'image', 'audio', 'staging', 'media', 'text'],
        ),
      ),
      write: _FieldInputUse(),
    ),
  },
  children: [_productionNodes, _productionEdges],
  operations: [_productionRead, _productionWrite],
);
const _episodeProductionDefinition = _ResourceDefinition(
  segment: 'production',
  address: _ResourceAddress(_AddressKind.singleton),
  description: '制片',
  group: contentKindScreenplay,
  hidden: true,
  discoverable: false,
  fields: {'id': _productionId},
  children: [_productionCanvas],
  operations: [_productionRead],
);

const _clipGenerations = _ResourceDefinition(
  segment: 'generations',
  address: _ResourceAddress(_AddressKind.id, itemToken: 'task_id'),
  description: '生成记录',
  group: contentKindScreenplay,
  discoverable: false,
  listing: _ResourceListing(),
  fields: _clipGenerationFields,
  operations: [_productionRead, _productionList],
);

const _productionNodeFields = {
  'id': _productionId,
  'content': _ResourceField(
    value: _ValueSchema(_ValueType.string),
    read: _FieldRead(path: true),
    create: _FieldInputUse(),
    write: _FieldInputUse(field: true),
  ),
  'asset_id': _ResourceField(
    value: _ValueSchema(_ValueType.string),
    create: _FieldInputUse(),
  ),
  'path': _ResourceField(
    value: _ValueSchema(_ValueType.string),
    create: _FieldInputUse(),
  ),
  'ref_type': _ResourceField(
    value: _ValueSchema(_ValueType.string),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(),
  ),
  'ref_id': _ResourceField(
    value: _ValueSchema(_ValueType.string),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(),
  ),
  'panorama': _ResourceField(
    value: _ValueSchema(
      _ValueType.object,
      nullable: true,
      additionalProperties: true,
    ),
    read: _FieldRead(listing: true, path: true),
  ),
  'image_method': _ResourceField(
    value: _ValueSchema(_ValueType.string, nullable: true),
    read: _FieldRead(listing: true, path: true),
  ),
  'group': _ResourceField(
    value: _productionJson,
    read: _FieldRead(listing: true, path: true),
  ),
  'title': _ResourceField(
    value: _ValueSchema(_ValueType.string),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(),
    write: _FieldInputUse(field: true),
  ),
  'x': _ResourceField(
    value: _ValueSchema(_ValueType.number),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(),
    write: _FieldInputUse(field: true),
  ),
  'y': _ResourceField(
    value: _ValueSchema(_ValueType.number),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(),
    write: _FieldInputUse(field: true),
  ),
  'width': _ResourceField(
    value: _ValueSchema(_ValueType.number, nullable: true),
    read: _FieldRead(listing: true, path: true),
  ),
  'height': _ResourceField(
    value: _ValueSchema(_ValueType.number, nullable: true),
    read: _FieldRead(listing: true, path: true),
  ),
};

const _productionClipFields = {
  'style_selection': _ResourceField(
    value: _ValueSchema(_ValueType.string, nullable: true),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(),
    write: _FieldInputUse(field: true),
  ),
  'kind': _ResourceField(
    value: _ValueSchema(
      _ValueType.string,
      enumValues: ['video', 'image', 'audio'],
    ),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(hasDefault: true, defaultValue: 'video'),
    query: _FieldQuery(),
  ),
  'id': _ResourceField(
    value: _ValueSchema(_ValueType.string),
    read: _FieldRead(listing: true, path: true),
  ),
  'title': _ResourceField(
    search: {_FieldSearch.short_text},
    value: _ValueSchema(_ValueType.string),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(),
    write: _FieldInputUse(field: true),
    edit: _FieldEdit(),
  ),
  'inputs': _ResourceField(
    value: _ValueSchema(
      _ValueType.array,
      items: _ValueSchema(
        _ValueType.object,
        properties: {
          'id': _ValueProperty(_ValueSchema(_ValueType.string), required: true),
          'ref_type': _ValueProperty(
            _ValueSchema(_ValueType.string, enumValues: ['asset', 'node']),
            required: true,
          ),
          'ref_id': _ValueProperty(
            _ValueSchema(_ValueType.string),
            required: true,
          ),
          'role': _ValueProperty(
            _ValueSchema(
              _ValueType.string,
              enumValues: [
                'prompt',
                'reference_image',
                'reference_video',
                'reference_audio',
                'first_frame',
                'middle_frame',
                'last_frame',
              ],
            ),
            required: true,
          ),
        },
      ),
    ),
    read: _FieldRead(path: true),
    create: _FieldInputUse(),
    write: _FieldInputUse(field: true),
  ),
  'adopted_asset_id': _ResourceField(
    value: _ValueSchema(_ValueType.string, nullable: true),
    read: _FieldRead(listing: true, path: true),
    write: _FieldInputUse(field: true),
  ),
  'prompt': _ResourceField(
    search: {_FieldSearch.body},
    value: _ValueSchema(_ValueType.string),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(),
    write: _FieldInputUse(field: true),
    edit: _FieldEdit(),
  ),
  'provider_id': _ResourceField(
    value: _ValueSchema(_ValueType.string, nullable: true),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(),
    write: _FieldInputUse(field: true),
  ),
  'model_id': _ResourceField(
    value: _ValueSchema(_ValueType.string, nullable: true),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(),
    write: _FieldInputUse(field: true),
  ),
  'reference_mode': _ResourceField(
    value: _ValueSchema(
      _ValueType.string,
      enumValues: ['reference', 'first_last_frame'],
    ),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(),
    write: _FieldInputUse(field: true),
  ),
  'duration_ms': _ResourceField(
    description: '视频生成的计划时长（毫秒），不是已生成媒体或整集成片的实测时长。',
    value: _ValueSchema(_ValueType.integer, nullable: true, minimum: 1),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(),
    write: _FieldInputUse(field: true),
  ),
  'generate_audio': _ResourceField(
    description: '是否生成音频；null 跟随模型默认。',
    value: _ValueSchema(_ValueType.boolean, nullable: true),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(),
    write: _FieldInputUse(field: true),
  ),
  'ratio': _ResourceField(
    value: _ValueSchema(_ValueType.string),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(),
    write: _FieldInputUse(field: true),
  ),
  'resolution': _ResourceField(
    value: _ValueSchema(_ValueType.string),
    read: _FieldRead(listing: true, path: true),
    create: _FieldInputUse(),
    write: _FieldInputUse(field: true),
  ),
};
const _productionClipOperations = [
  _ResourceOperation(
    _ResourceTool.read,
    _ResourceTargetKind.listing,
    result: _ResourceResult(
      _ResourceResultKind.listing,
      references: ['entries[].path'],
    ),
  ),
  _ResourceOperation(
    _ResourceTool.read,
    _ResourceTargetKind.resource,
    result: _ResourceResult(_ResourceResultKind.entity, references: ['path']),
  ),
  _ResourceOperation(
    _ResourceTool.create,
    _ResourceTargetKind.listing,
    input: _ResourceInput(_ResourceInputKind.create_fields),
  ),
  _ResourceOperation(
    _ResourceTool.write,
    _ResourceTargetKind.resource,
    input: _ResourceInput(_ResourceInputKind.resource_fields),
  ),
];

const _canvasProductionNodes = _ResourceDefinition(
  segment: 'nodes',
  address: _ResourceAddress(_AddressKind.id, itemToken: 'node_id'),
  description: '制作节点',
  group: contentKindCanvas,
  listing: _ResourceListing(),
  fields: {
    ..._productionNodeFields,
    'type': _ResourceField(
      value: _ValueSchema(
        _ValueType.string,
        enumValues: [
          'video',
          'image',
          'audio',
          'staging',
          'media',
          'text',
          'editing',
        ],
      ),
      read: _FieldRead(listing: true, path: true),
      create: _FieldInputUse(required: true),
    ),
  },
  operations: [
    _productionRead,
    _productionList,
    _productionCreate,
    _productionWrite,
    _productionRemove,
  ],
);
const _canvasProductionEdges = _ResourceDefinition(
  segment: 'edges',
  address: _ResourceAddress(_AddressKind.id, itemToken: 'edge_id'),
  description: '制作连线',
  group: contentKindCanvas,
  listing: _ResourceListing(),
  fields: {
    'id': _productionId,
    'data': _ResourceField(
      value: _productionJson,
      read: _FieldRead(path: true),
    ),
  },
  operations: [_productionRead, _productionList],
);
const _canvasProductionCanvas = _ResourceDefinition(
  segment: 'canvas',
  address: _ResourceAddress(_AddressKind.singleton),
  description: '制作画布',
  group: contentKindCanvas,
  fields: {
    'id': _productionId,
    'positions': _ResourceField(
      value: _ValueSchema(_ValueType.array, items: _productionJson),
      write: _FieldInputUse(),
    ),
    'remove_types': _ResourceField(
      value: _ValueSchema(
        _ValueType.array,
        items: _ValueSchema(
          _ValueType.string,
          enumValues: [
            'video',
            'image',
            'audio',
            'staging',
            'media',
            'editing',
            'text',
          ],
        ),
      ),
      write: _FieldInputUse(),
    ),
  },
  children: [_canvasProductionNodes, _canvasProductionEdges],
  operations: [_productionRead, _productionWrite],
);
const _canvasProductionSettings = _ResourceDefinition(
  segment: 'settings',
  address: _ResourceAddress(_AddressKind.singleton),
  description: '制作默认设置',
  group: contentKindCanvas,
  fields: {
    'id': _productionId,
    'style_id': _ResourceField(
      value: _ValueSchema(_ValueType.string, nullable: true),
      read: _FieldRead(path: true),
      write: _FieldInputUse(field: true),
      edit: _FieldEdit(),
    ),
    'ratio': _ResourceField(
      value: _ValueSchema(
        _ValueType.string,
        enumValues: ProductionSettings.ratios,
      ),
      read: _FieldRead(path: true),
      write: _FieldInputUse(field: true),
      edit: _FieldEdit(),
    ),
    'resolution': _ResourceField(
      value: _ValueSchema(
        _ValueType.string,
        enumValues: ProductionSettings.resolutions,
      ),
      read: _FieldRead(path: true),
      write: _FieldInputUse(field: true),
      edit: _FieldEdit(),
    ),
  },
  operations: [_productionRead, _productionWrite],
);
const _canvasProductionClips = _ResourceDefinition(
  segment: 'clips',
  address: _ResourceAddress(_AddressKind.id, itemToken: 'clip_id'),
  description: '制作片段',
  group: contentKindCanvas,
  listing: _ResourceListing(),
  fields: _productionClipFields,
  children: [_canvasClipGenerations],
  operations: _productionClipOperations,
);
const _canvasProductionDefinition = _ResourceDefinition(
  segment: 'production',
  address: _ResourceAddress(_AddressKind.singleton),
  description: '画布制作',
  group: contentKindCanvas,
  fields: {'id': _productionId},
  children: [
    _canvasProductionSettings,
    _canvasProductionCanvas,
    _canvasProductionClips,
  ],
  operations: [_productionRead],
);

const _clipGenerationFields = {
  'id': _productionId,
  'kind': _productionId,
  'status': _productionId,
  'cancel_requested_at': _ResourceField(
    value: _ValueSchema(_ValueType.string, nullable: true),
    read: _FieldRead(listing: true, path: true),
  ),
  'result_asset_id': _ResourceField(
    value: _ValueSchema(_ValueType.string, nullable: true),
    read: _FieldRead(listing: true, path: true),
  ),
  'result_file_path': _ResourceField(
    value: _ValueSchema(_ValueType.string, nullable: true),
    read: _FieldRead(listing: true, path: true),
  ),
  'result_applied': _ResourceField(
    value: _ValueSchema(_ValueType.boolean),
    read: _FieldRead(listing: true, path: true),
  ),
  'model_id': _productionId,
};
const _canvasClipGenerations = _ResourceDefinition(
  segment: 'generations',
  address: _ResourceAddress(_AddressKind.id, itemToken: 'task_id'),
  description: '生成记录',
  group: contentKindCanvas,
  discoverable: false,
  listing: _ResourceListing(),
  fields: _clipGenerationFields,
  operations: [_productionRead, _productionList],
);
