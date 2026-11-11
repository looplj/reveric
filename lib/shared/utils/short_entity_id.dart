// 职责: 为模型可见的作品业务实体生成固定前缀的短持久化 ID。
// 关联文件:
//   lib/shared/utils/random_id.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/services/outline_service.dart
//   lib/shared/services/canvas_service.dart
//   lib/shared/services/screenplay_service.dart
import 'dart:math';

const String _shortEntityIdAlphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
const int shortEntityIdSuffixLength = 6;

final Random _shortEntityIdRandom = Random.secure();

typedef ShortEntityIdRandomIndex = int Function(int upperBound);
typedef ShortEntityIdBuilder = String Function(ShortEntityIdType type);

enum ShortEntityIdType {
  character,
  chapter,
  extra,
  volume,
  foreshadowing,
  location,
  skill,
  item,
  faction,
  creature,
  relation,
  relationChange,
  loreDocument,
  loreFolder,
  materialsDocument,
  materialsFolder,
  outline,
  outlineBeat,
  canvas,
  canvasNode,
  canvasEdge,
  novel,
  screenplay,
  canvas_work,
  screenplaySeason,
  screenplayEpisode,
  screenplayBeat,
  screenplayScene,
  screenplayElement,
  productionClip,
  productionInput,
  generationTask,
}

const Map<ShortEntityIdType, String> shortEntityIdPrefixes = {
  ShortEntityIdType.character: 'cha',
  ShortEntityIdType.chapter: 'chp',
  ShortEntityIdType.extra: 'ext',
  ShortEntityIdType.volume: 'vol',
  ShortEntityIdType.foreshadowing: 'fsh',
  ShortEntityIdType.location: 'loc',
  ShortEntityIdType.skill: 'ski',
  ShortEntityIdType.item: 'itm',
  ShortEntityIdType.faction: 'fac',
  ShortEntityIdType.creature: 'cre',
  ShortEntityIdType.relation: 'rel',
  ShortEntityIdType.relationChange: 'rch',
  ShortEntityIdType.loreDocument: 'lrd',
  ShortEntityIdType.loreFolder: 'lrf',
  ShortEntityIdType.materialsDocument: 'mtd',
  ShortEntityIdType.materialsFolder: 'mtf',
  ShortEntityIdType.outline: 'out',
  ShortEntityIdType.outlineBeat: 'obt',
  ShortEntityIdType.canvas: 'can',
  ShortEntityIdType.canvasNode: 'cnd',
  ShortEntityIdType.canvasEdge: 'ced',
  ShortEntityIdType.novel: 'nov',
  ShortEntityIdType.screenplay: 'scr',
  ShortEntityIdType.canvas_work: 'cnv',
  ShortEntityIdType.screenplaySeason: 'sea',
  ShortEntityIdType.screenplayEpisode: 'epi',
  ShortEntityIdType.screenplayBeat: 'sbt',
  ShortEntityIdType.screenplayScene: 'scn',
  ShortEntityIdType.screenplayElement: 'elm',
  ShortEntityIdType.productionClip: 'clip',
  ShortEntityIdType.productionInput: 'inp',
  ShortEntityIdType.generationTask: 'gen',
};

/// 生成作品内、模型可见业务实体的短持久化 ID。
///
/// 前缀契约：角色 `cha`；章节 `chp`；番外 `ext`；卷 `vol`；伏笔 `fsh`；
/// 地点 `loc`；技能 `ski`；物品 `itm`；势力 `fac`；生物 `cre`；关系 `rel`、
/// 关系变化记录 `rch`；
/// lore 文档 `lrd`、文件夹 `lrf`；materials 文档 `mtd`、文件夹 `mtf`；
/// 大纲 `out`、大纲节拍 `obt`；画布 `can`、节点 `cnd`、边 `ced`；
/// novel 作品 `nov`、screenplay 作品 `scr`、canvas 作品 `cnv`；剧本季 `sea`、集 `epi`、节拍
/// `sbt`、场次 `scn`、正文元素 `elm`；制片片段 `clip`、片段输入 `inp`、生成记录
/// `gen`。制片画布、节点与连线和小说画布同属画布实体，沿用 `can`/`cnd`/`ced`。
///
/// 前缀必须按模型可见的业务实体区分，不能按共用数据表、DAO 或内部存储模型
/// 合并；调用方必须显式选择 [ShortEntityIdType]，不得用 `substring` 从类型名
/// 推导前缀。通用 `buildRandomId` 服务于其他作用域和数据规模，必须保持原样。
///
/// 返回格式为注册的小写前缀、下划线和六位 `A-Z0-9` 后缀。存储层负责检查
/// 有效行、软删除行、同批候选，并以严格 INSERT 处理最终的并发碰撞。
String buildShortEntityId(
  ShortEntityIdType type, {
  ShortEntityIdRandomIndex? nextInt,
}) {
  final prefix = shortEntityIdPrefixes[type];
  if (prefix == null) {
    throw ArgumentError.value(type, 'type', 'Missing short entity ID prefix.');
  }
  final randomIndex = nextInt ?? _shortEntityIdRandom.nextInt;
  final buffer = StringBuffer(prefix)..write('_');
  for (var i = 0; i < shortEntityIdSuffixLength; i++) {
    final index = randomIndex(_shortEntityIdAlphabet.length);
    if (index < 0 || index >= _shortEntityIdAlphabet.length) {
      throw RangeError.range(
        index,
        0,
        _shortEntityIdAlphabet.length - 1,
        'nextInt result',
      );
    }
    buffer.write(_shortEntityIdAlphabet[index]);
  }
  return buffer.toString();
}
