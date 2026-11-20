// 职责: 定义作品内容类型的稳定持久化值与校验。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/database/daos/novel_dao.dart
//   lib/shared/services/ai/tools_cross_work.dart

const String contentKindNovel = 'novel';
const String contentKindScreenplay = 'screenplay';
const String contentKindCanvas = 'canvas';

const Set<String> contentKinds = <String>{
  contentKindNovel,
  contentKindScreenplay,
  contentKindCanvas,
};

bool isValidContentKind(String value) => contentKinds.contains(value);

void validateContentKind(String value) {
  if (!isValidContentKind(value)) {
    throw ArgumentError.value(
      value,
      'contentKind',
      'Unsupported content kind.',
    );
  }
}
