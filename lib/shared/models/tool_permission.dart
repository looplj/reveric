// 职责: 定义工具动作、Run 命令权限声明、可信作用域与四层权限的解析结果。
// 关联文件:
//   lib/shared/services/tool_permissions.dart
//   lib/shared/agent/tool_approval.dart
//   lib/shared/database/app_database.dart

enum ToolPermissionDecision { allow, ask, deny }

enum ToolPermissionScopeType { global, work, episode, session }

/// Approval master switch. Off: every capability runs as allowed without rule lookup or approval cards.
const toolApprovalEnabled = true;

const toolPermissionActions = <String>{
  'generation.image',
  'generation.video',
  'generation.audio',
  'files.read',
  'files.remove',
};

class ToolPermissionScope {
  const ToolPermissionScope(this.type, {this.workId = '', this.id = ''});
  const ToolPermissionScope.global()
    : type = ToolPermissionScopeType.global,
      workId = '',
      id = '';
  final ToolPermissionScopeType type;
  final String workId;
  final String id;
  @override
  bool operator ==(Object other) =>
      other is ToolPermissionScope &&
      other.type == type &&
      other.workId == workId &&
      other.id == id;
  @override
  int get hashCode => Object.hash(type, workId, id);

  void validate() {
    if (type == ToolPermissionScopeType.global) {
      if (workId.isNotEmpty || id.isNotEmpty) {
        throw const FormatException(
          'Global permission scope must not name a work.',
        );
      }
    } else if (workId.isEmpty ||
        id.isEmpty ||
        (type == ToolPermissionScopeType.work && id != workId)) {
      throw const FormatException('Permission scope identity is invalid.');
    }
  }
}

/// Only the host constructs this context after resolving the actual operation target.
class ToolPermissionContext {
  const ToolPermissionContext({
    required this.workId,
    this.sessionId,
    this.episodeId,
  });
  final String workId;
  final String? sessionId;
  final String? episodeId;

  /// Blank ids are absent scopes. Canvas works store an empty episode id.
  List<ToolPermissionScope> get scopes {
    final session = sessionId;
    final episode = episodeId;
    return [
      if (session != null && session.isNotEmpty)
        ToolPermissionScope(
          ToolPermissionScopeType.session,
          workId: workId,
          id: session,
        ),
      if (episode != null && episode.isNotEmpty)
        ToolPermissionScope(
          ToolPermissionScopeType.episode,
          workId: workId,
          id: episode,
        ),
      if (workId.isNotEmpty)
        ToolPermissionScope(
          ToolPermissionScopeType.work,
          workId: workId,
          id: workId,
        ),
      const ToolPermissionScope.global(),
    ];
  }
}

class EffectiveToolPermission {
  const EffectiveToolPermission(this.decision, {this.source});
  final ToolPermissionDecision decision;
  final ToolPermissionScope? source;
}

/// Tool operation failure with a stable code returned to the model.
class ToolOperationException implements Exception {
  const ToolOperationException(this.code, this.message, {this.hint});
  final String code;
  final String message;
  final String? hint;
}

/// Only for `permission_denied`: the action or target is not authorized.
class ToolPermissionException extends ToolOperationException {
  const ToolPermissionException(super.code, super.message, {super.hint});
}

/// Freeze nested inputs before approval so a later UI/model mutation cannot expand the request.
Map<String, dynamic> freezeToolArguments(Map<String, dynamic> value) {
  Object? freeze(Object? item) {
    if (item is Map<String, dynamic>) {
      return Map<String, dynamic>.unmodifiable(
        item.map((key, value) => MapEntry(key, freeze(value))),
      );
    }
    if (item is List) {
      return List<Object?>.unmodifiable(item.map(freeze));
    }
    return item;
  }

  return freeze(value)! as Map<String, dynamic>;
}

class ToolActionRequest {
  ToolActionRequest({
    required this.action,
    required this.context,
    required this.targetPath,
    required Map<String, dynamic> summary,
    this.targetLabel,
  }) : summary = freezeToolArguments(summary);
  final String action, targetPath;

  /// Display name of the real target (clip, character, file); never used for authorization.
  final String? targetLabel;
  final ToolPermissionContext context;
  final Map<String, dynamic> summary;
}

/// Explicit permission declaration of a Run command: `none` or one registered capability.
class RunPermission {
  const RunPermission.none() : capability = null;
  const RunPermission.required(String this.capability);
  final String? capability;
}

/// The command being executed, resolved from the command table.
class RunCommandSpec {
  const RunCommandSpec(this.command, this.subcommand, this.permission);
  final String command, subcommand;
  final RunPermission permission;

  /// Stable operation type, e.g. `production.generate-image`.
  String get operation => '$command.$subcommand';

  /// Permission declared by the command table; commands declared `none` cannot request one.
  String get capability =>
      permission.capability ??
      (throw StateError('$operation declares no permission.'));
}
