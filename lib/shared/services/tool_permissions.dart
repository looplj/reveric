// 职责: 校验作用域归属，解析最新四层工具权限并保存用户规则。
// 关联文件:
//   lib/shared/database/daos/tool_permission_dao.dart
//   lib/shared/models/tool_permission.dart
//   lib/shared/providers/tool_permissions.dart
// 遵循的 Rules:
//   .agents/rules/service-naming.md
import '../database/app_database.dart';
import '../models/tool_permission.dart';

class ToolPermissionService {
  const ToolPermissionService(this.database, {required this.episodeExists});
  final AppDatabase database;
  final Future<bool> Function(String workId, String episodeId) episodeExists;

  Future<void> validateScope(ToolPermissionScope scope) async {
    scope.validate();
    await _validateAppScope(scope);
    await _validateEpisode(scope);
  }

  Future<void> _validateAppScope(ToolPermissionScope scope) async {
    if (scope.type == ToolPermissionScopeType.global) {
      return;
    }
    if (await database.novelDao.get(scope.workId) == null) {
      throw const ToolOperationException(
        'not_found',
        'The permission work does not exist.',
      );
    }
    if (scope.type == ToolPermissionScopeType.session &&
        await database.aiChatSessionDao.getById(
              scope.id,
              novelId: scope.workId,
            ) ==
            null) {
      throw const ToolPermissionException(
        'permission_denied',
        'The session does not belong to this work.',
      );
    }
  }

  Future<void> _validateEpisode(ToolPermissionScope scope) async {
    if (scope.type == ToolPermissionScopeType.episode &&
        !await episodeExists(scope.workId, scope.id)) {
      throw const ToolPermissionException(
        'permission_denied',
        'The episode does not belong to this work.',
      );
    }
  }

  Future<EffectiveToolPermission> resolve(
    String action,
    ToolPermissionContext context,
  ) async {
    if (!toolPermissionActions.contains(action)) {
      throw const FormatException('Unknown permission action.');
    }
    for (final scope in context.scopes) {
      await validateScope(scope);
    }
    for (final scope in context.scopes) {
      final rule = (await database.toolPermissionDao.rules(
        scope,
      )).where((r) => r.action == action).firstOrNull;
      if (rule != null) {
        return EffectiveToolPermission(rule.decision, source: scope);
      }
    }
    return const EffectiveToolPermission(ToolPermissionDecision.ask);
  }

  Future<void> setRule(
    String action,
    ToolPermissionScope scope,
    ToolPermissionDecision? decision,
  ) async {
    scope.validate();
    if (scope.type == ToolPermissionScopeType.episode) {
      await _validateAppScope(scope);
      await _validateEpisode(scope);
    }
    await database.transaction(() async {
      await _validateAppScope(scope);
      await database.toolPermissionDao.setRule(action, scope, decision);
    });
  }
}
