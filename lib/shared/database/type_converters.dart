// 职责: Drift TypeConverter 集中定义 — JSON 字段自动序列化/反序列化
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/database/novel_content_database.dart
// 遵循的 Rules:
//   .agents/rules/json.md
import 'dart:convert';

import 'package:drift/drift.dart';
import '../models/production/asset_content.dart';
import '../models/production/input.dart';
import '../models/generation/task.dart';

import '../logger/app_logger.dart';
import '../models/ai_message_block.dart';
import '../models/collections/filter.dart';
import '../models/chapter_comment.dart';
import '../models/character_behavior_tag.dart';
import '../models/subject_photo.dart';
import '../models/character_voice.dart';
import '../models/outline_draft.dart';
import '../models/entity_relation_history.dart';
import '../models/video/request.dart';
import '../models/editing/document.dart';

final _log = AppLogger.forModule('JsonMapConverter');

class ProductionInputsConverter
    extends TypeConverter<List<ProductionInput>, String> {
  const ProductionInputsConverter();
  @override
  List<ProductionInput> fromSql(String column) {
    final values = (jsonDecode(column) as List)
        .map((item) => ProductionInput.fromJson(item as Map<String, dynamic>))
        .toList();
    ProductionInput.validateList(values);
    return List.unmodifiable(values);
  }

  @override
  String toSql(List<ProductionInput> value) {
    ProductionInput.validateList(value);
    return jsonEncode(value.map((input) => input.toJson()).toList());
  }
}

class EditingDocumentConverter extends TypeConverter<EditingDocument, String> {
  const EditingDocumentConverter();
  @override
  EditingDocument fromSql(String column) =>
      EditingDocument.fromJson(jsonDecode(column) as Map<String, dynamic>);
  @override
  String toSql(EditingDocument value) => jsonEncode(value.toJson());
}

class GenerationRequestConverter
    extends TypeConverter<GenerationRequest, String> {
  const GenerationRequestConverter();
  @override
  GenerationRequest fromSql(String column) =>
      GenerationRequest.fromJson(jsonDecode(column) as Map<String, dynamic>);
  @override
  String toSql(GenerationRequest value) => jsonEncode(value.toJson());
}

class AssetContentConverter extends TypeConverter<AssetContent, String> {
  const AssetContentConverter();
  @override
  AssetContent fromSql(String column) =>
      AssetContent.fromJson(jsonDecode(column) as Map<String, dynamic>);
  @override
  String toSql(AssetContent value) => jsonEncode(value.toJson());
}

class VideoRequestConverter extends TypeConverter<VideoRequest, String> {
  const VideoRequestConverter();
  @override
  VideoRequest fromSql(String column) =>
      VideoRequest.fromJson(jsonDecode(column) as Map<String, dynamic>);
  @override
  String toSql(VideoRequest value) => jsonEncode(value.toJson());
}

class CharacterVoiceListConverter
    extends TypeConverter<List<CharacterVoice>, String>
    with JsonTypeConverter2<List<CharacterVoice>, String, List<Object?>> {
  const CharacterVoiceListConverter();
  @override
  List<CharacterVoice> fromSql(String column) =>
      fromJson(jsonDecode(column) as List);
  @override
  String toSql(List<CharacterVoice> value) => jsonEncode(toJson(value));
  @override
  List<CharacterVoice> fromJson(List<Object?> json) {
    final voices = json.map(CharacterVoice.fromJson).toList();
    if (voices.map((v) => v.assetId).toSet().length != voices.length) {
      throw const FormatException('Duplicate character voice');
    }
    return List.unmodifiable(voices);
  }

  @override
  List<Object?> toJson(List<CharacterVoice> value) {
    final json = value.map((v) => v.toJson()).toList();
    fromJson(json);
    return json;
  }
}

class SubjectPhotoListConverter
    extends TypeConverter<List<SubjectPhoto>, String>
    with JsonTypeConverter2<List<SubjectPhoto>, String, List<Object?>> {
  const SubjectPhotoListConverter();

  @override
  List<SubjectPhoto> fromSql(String column) =>
      fromJson(jsonDecode(column) as List);

  @override
  String toSql(List<SubjectPhoto> value) => jsonEncode(toJson(value));

  @override
  List<SubjectPhoto> fromJson(List<Object?> json) =>
      json.map(SubjectPhoto.fromJson).toList();

  @override
  List<Object?> toJson(List<SubjectPhoto> value) =>
      value.map((photo) => photo.toJson()).toList();
}

class StringListConverter extends TypeConverter<List<String>, String> {
  const StringListConverter();

  @override
  List<String> fromSql(String column) {
    final decoded = jsonDecode(column);
    if (decoded is! List) return const [];
    return decoded.map((e) => e.toString()).toList(growable: false);
  }

  @override
  String toSql(List<String> value) => jsonEncode(value);
}

class JsonMapConverter extends TypeConverter<Map<String, dynamic>, String> {
  const JsonMapConverter();

  @override
  Map<String, dynamic> fromSql(String column) {
    try {
      final decoded = jsonDecode(column);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } on FormatException {
      // 保留历史记录的可读性；不把可能含业务数据的 JSON 原文写进日志。
      _log.warning('Invalid stored JSON; using empty map');
    }
    return const {};
  }

  @override
  String toSql(Map<String, dynamic> value) => jsonEncode(value);
}

class JsonMapListConverter
    extends TypeConverter<List<Map<String, dynamic>>, String> {
  const JsonMapListConverter();

  @override
  List<Map<String, dynamic>> fromSql(String column) {
    final decoded = jsonDecode(column);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map(
          (item) => item.map((key, value) => MapEntry(key.toString(), value)),
        )
        .toList(growable: false);
  }

  @override
  String toSql(List<Map<String, dynamic>> value) => jsonEncode(value);
}

class ChapterCommentListConverter
    extends TypeConverter<List<ChapterComment>, String> {
  const ChapterCommentListConverter();

  @override
  List<ChapterComment> fromSql(String column) {
    final decoded = jsonDecode(column);
    if (decoded is! List) {
      return const [];
    }
    final comments = <ChapterComment>[];
    for (final item in decoded.whereType<Map>()) {
      // 单条脏数据不该让整章批注一起消失。
      try {
        comments.add(
          ChapterComment.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
          ),
        );
      } on FormatException {
        continue;
      }
    }
    return List.unmodifiable(comments);
  }

  @override
  String toSql(List<ChapterComment> value) {
    return jsonEncode(
      value.map((comment) => comment.toJson()).toList(growable: false),
    );
  }
}

class CharacterBehaviorTagListConverter
    extends TypeConverter<List<CharacterBehaviorTag>, String> {
  const CharacterBehaviorTagListConverter();

  @override
  List<CharacterBehaviorTag> fromSql(String column) {
    final decoded = jsonDecode(column);
    if (decoded is! List) {
      return const [];
    }
    return decoded
        .whereType<Map>()
        .map(
          (item) => CharacterBehaviorTag.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
          ),
        )
        .toList(growable: false);
  }

  @override
  String toSql(List<CharacterBehaviorTag> value) {
    return jsonEncode(value.map((tag) => tag.toJson()).toList(growable: false));
  }
}

class DoubleListConverter extends TypeConverter<List<double>, String> {
  const DoubleListConverter();

  @override
  List<double> fromSql(String column) {
    final decoded = jsonDecode(column);
    if (decoded is! List) return const [];
    return decoded.map((e) => (e as num).toDouble()).toList(growable: false);
  }

  @override
  String toSql(List<double> value) => jsonEncode(value);
}

class AiMessageBlockListConverter
    extends TypeConverter<List<AiMessageBlock>, String> {
  const AiMessageBlockListConverter();

  @override
  List<AiMessageBlock> fromSql(String column) {
    final decoded = jsonDecode(column);
    if (decoded is! List) return const [];
    return decoded
        .map((e) => AiMessageBlock.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  @override
  String toSql(List<AiMessageBlock> value) {
    return jsonEncode(value.map((b) => b.toJson()).toList());
  }
}

class TimelineBeatListConverter
    extends TypeConverter<List<OutlineBeatDraft>, String> {
  const TimelineBeatListConverter();

  @override
  List<OutlineBeatDraft> fromSql(String column) {
    if (column == '[]') return const [];
    final decoded = jsonDecode(column);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map(
          (item) => OutlineBeatDraft.fromJson(
            item.map((k, v) => MapEntry(k.toString(), v)),
          ),
        )
        .toList(growable: false);
  }

  @override
  String toSql(List<OutlineBeatDraft> value) {
    return jsonEncode(value.map((b) => b.toJson()).toList());
  }
}

/// 主题颜色覆盖使用严格的字符串映射，损坏数据必须显式报错。
class StringMapConverter extends TypeConverter<Map<String, String>, String> {
  const StringMapConverter();

  @override
  Map<String, String> fromSql(String column) =>
      Map<String, String>.unmodifiable(
        Map<String, String>.from(jsonDecode(column) as Map),
      );

  @override
  String toSql(Map<String, String> value) => jsonEncode(value);
}

class RelationStateSnapshotListConverter
    extends TypeConverter<List<RelationStateSnapshot>, String> {
  const RelationStateSnapshotListConverter();
  @override
  List<RelationStateSnapshot> fromSql(String column) {
    final decoded = jsonDecode(column);
    if (decoded is! List) {
      throw const FormatException('Relation history must be an array');
    }
    final snapshots = decoded
        .map((item) {
          if (item is! Map<String, dynamic>) {
            throw const FormatException('Relation snapshot must be an object');
          }
          return RelationStateSnapshot.fromJson(item);
        })
        .toList(growable: false);
    validateRelationHistory(snapshots);
    return List.unmodifiable(snapshots);
  }

  @override
  String toSql(List<RelationStateSnapshot> value) {
    validateRelationHistory(value);
    return jsonEncode(
      value.map((item) => item.toJson()).toList(growable: false),
    );
  }
}

class CollectionFilterConverter
    extends TypeConverter<CollectionFilter, String> {
  const CollectionFilterConverter();
  @override
  CollectionFilter fromSql(String column) => CollectionFilter.parse(column);
  @override
  String toSql(CollectionFilter value) => value.raw;
}

class ImageTaskOutputsConverter
    extends TypeConverter<ImageTaskOutputs, String> {
  const ImageTaskOutputsConverter();
  @override
  ImageTaskOutputs fromSql(String column) =>
      ImageTaskOutputs.fromJson(jsonDecode(column) as Map<String, dynamic>);
  @override
  String toSql(ImageTaskOutputs value) => jsonEncode(value.toJson());
}
