// 职责: AI Run 工具命令路由，负责解析结构化 command/subcommand/options 并分发到对应 handler。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/bundled_control_skills.dart
//   lib/shared/services/ai/subagents_run_command_handler.dart
//   lib/shared/services/ai/providers_run_command_handler.dart
//   lib/shared/agent/token_estimator.dart
//   lib/shared/localization/locale_keys.dart
// 遵循的 Rules:
//   .agents/rules/ai-calling.md
part of 'tools.dart';

const runToolName = 'Run';
const _agentSkillCatalogSources = {'official', 'marketplace'};

const _runDescription = '''Run a command.

Shape (placeholders): {"command":"<namespace>","subcommand":"<action>","options":{}}
`command` and `subcommand` are top-level fields — do NOT nest them inside `options`.

Use command `help` to inspect available command namespaces, detailed actions, and required options.''';

const _runInputSchema = {
  'type': 'object',
  'properties': {
    'command': {
      'type': 'string',
      'description':
          'Command namespace. Use "help" to inspect available commands.',
    },
    'subcommand': {
      'type': 'string',
      'description':
          'Command action, or the command name to inspect when command is "help".',
    },
    'options': {
      'type': 'object',
      'description':
          'Structured command options as JSON. Action parameters only.',
      'additionalProperties': true,
    },
  },
  'required': ['command'],
  'additionalProperties': false,
};

class _RunCommandException implements Exception {
  const _RunCommandException(this.message, {this.exitCode = 1});

  final String message;
  final int exitCode;
  final ToolErrorCode errorCode = ToolErrorCode.invalid_argument;

  @override
  String toString() => message;
}

typedef _RunCommandHandler =
    Future<Map<String, dynamic>> Function(
      RunCommandSpec spec,
      Map<String, dynamic> options,
      DateTime startedAt,
    );

/// One Run command group: permissions and execution binding live in the same record.
class _RunCommandDefinition {
  const _RunCommandDefinition(
    this.run, {
    this.subcommands,
    required this.codemode,
    this.media = false,
    this.session = false,
  });

  /// Per-subcommand declarations; unknown subcommands are rejected.
  /// null declares the whole group `none`, and the handler validates subcommands.
  final Map<String, RunPermission>? subcommands;

  /// Every action declares script access; missing actions are denied.
  final Map<String, _RunCodemodeAccess> codemode;

  /// Registered only when the host provides session media operations.
  final bool media;

  /// Requires the session operation host, including hosts without native media.
  final bool session;
  final _RunCommandHandler run;

  void validate() {
    final actions = subcommands;
    if (actions != null &&
        (actions.length != codemode.length ||
            actions.keys.any((action) => !codemode.containsKey(action)))) {
      throw StateError(
        'Every registered Run action must declare Codemode access.',
      );
    }
    if (codemode.isEmpty ||
        codemode.values.any((access) => access.deniedReason?.isEmpty == true)) {
      throw StateError(
        'Run actions need explicit access and a nonempty denial reason.',
      );
    }
  }

  RunPermission? permissionFor(String subcommand) {
    final declared = subcommands;
    if (declared == null) {
      return const RunPermission.none();
    }
    final permission = declared[subcommand];
    if (permission?.capability case final capability?
        when !toolPermissionActions.contains(capability)) {
      throw StateError('Unregistered permission $capability.');
    }
    return permission;
  }
}

/// Script access is independent of the existing user approval capability.
class _RunCodemodeAccess {
  const _RunCodemodeAccess.read() : mutating = false, deniedReason = null;
  const _RunCodemodeAccess.write() : mutating = true, deniedReason = null;
  const _RunCodemodeAccess.denied(String reason)
    : mutating = false,
      deniedReason = reason;

  final bool mutating;
  final String? deniedReason;
}

const _generateImage = RunPermission.required('generation.image');

/// Folder rows shown in a file removal approval; the rest are only counted.
const _approvalFolderLimit = 20;

mixin _AiToolManagerRunMixin
    on _AiToolManagerImageMixin, _AiToolManagerAgentRulesRunMixin {
  bool get _mediaOperations => operationHost?.media == true;
  bool get _sessionOperations => operationHost != null;

  Map<String, _RunCommandDefinition> get _runCommands => {
    if (mcpRunHandler != null && mcpAllowed?.call() == true)
      'mcp': _RunCommandDefinition(
        (spec, options, _) => mcpRunHandler!.execute(
          spec.subcommand,
          options,
          _currentToolExecutionContext,
        ),
        subcommands: const {
          'list': RunPermission.none(),
          'search': RunPermission.none(),
          'describe': RunPermission.none(),
          'call': RunPermission.none(),
        },
        codemode: const {
          'list': _RunCodemodeAccess.denied('Use listMcpServers or listTools.'),
          'search': _RunCodemodeAccess.denied('Use searchTool.'),
          'describe': _RunCodemodeAccess.denied('Use describeTool.'),
          'call': _RunCodemodeAccess.denied('Use tools[name](arguments).'),
        },
      ),
    'assets': _RunCommandDefinition(
      codemode: const {
        'list': _RunCodemodeAccess.read(),
        'read': _RunCodemodeAccess.read(),
        'view-image': _RunCodemodeAccess.denied(
          'Image content must be viewed through a direct Run call.',
        ),
        'certify': _RunCodemodeAccess.write(),
      },
      media: true,
      (spec, options, _) => _runAssetsCommand(spec.subcommand, options),
    ),
    'stagings': _RunCommandDefinition(
      codemode: const {
        'schema': _RunCodemodeAccess.read(),
        'presets': _RunCodemodeAccess.read(),
        'sample': _RunCodemodeAccess.read(),
        'list': _RunCodemodeAccess.read(),
        'read': _RunCodemodeAccess.read(),
        'create': _RunCodemodeAccess.write(),
        'apply': _RunCodemodeAccess.write(),
        'write': _RunCodemodeAccess.write(),
        'restore': _RunCodemodeAccess.write(),
        'remove': _RunCodemodeAccess.write(),
        'preview': _RunCodemodeAccess.write(),
        'frames': _RunCodemodeAccess.denied(
          'Frame images must be viewed through a direct Run call.',
        ),
      },
      media: true,
      subcommands: const {
        'schema': RunPermission.none(),
        'presets': RunPermission.none(),
        'sample': RunPermission.none(),
        'frames': RunPermission.none(),
        'list': RunPermission.none(),
        'create': RunPermission.none(),
        'read': RunPermission.none(),
        'apply': RunPermission.none(),
        'write': RunPermission.none(),
        'restore': RunPermission.none(),
        'remove': RunPermission.none(),
        'preview': RunPermission.none(),
      },
      (spec, options, _) => _runStagingsCommand(spec.subcommand, options),
    ),
    'styles': _RunCommandDefinition(
      codemode: const {
        'list': _RunCodemodeAccess.read(),
        'read': _RunCodemodeAccess.read(),
        'create': _RunCodemodeAccess.write(),
        'update': _RunCodemodeAccess.write(),
      },
      media: true,
      subcommands: const {
        'list': RunPermission.none(),
        'read': RunPermission.none(),
        'create': RunPermission.none(),
        'update': RunPermission.none(),
      },
      (spec, options, _) async => StylesRunCommandHandler(
        await _productionStyleService(),
      ).run(spec.subcommand, options),
    ),
    'settings': _RunCommandDefinition(
      session: true,
      subcommands: const {'open': RunPermission.none()},
      codemode: const {
        'open': _RunCodemodeAccess.denied(
          'Open settings through a direct Run call.',
        ),
      },
      (spec, options, _) => _runSettingsCommand(options),
    ),
    'providers': _RunCommandDefinition(
      codemode: const {
        'list': _RunCodemodeAccess.read(),
        'read': _RunCodemodeAccess.read(),
        'models': _RunCodemodeAccess.read(),
      },
      (spec, options, _) => ProvidersRunCommandHandler(
        reader: providerReader,
      ).run(spec.subcommand, options),
    ),
    'operations': _RunCommandDefinition(
      codemode: const {
        'list': _RunCodemodeAccess.read(),
        'read': _RunCodemodeAccess.read(),
        'wait': _RunCodemodeAccess.read(),
        'cancel': _RunCodemodeAccess.write(),
      },
      session: true,
      subcommands: const {
        'list': RunPermission.none(),
        'read': RunPermission.none(),
        'wait': RunPermission.none(),
        'cancel': RunPermission.none(),
      },
      (spec, options, _) => _runOperationsCommand(spec.subcommand, options),
    ),
    'files': _RunCommandDefinition(
      codemode: const {
        'list': _RunCodemodeAccess.read(),
        'read-text': _RunCodemodeAccess.read(),
        'read-video-metadata': _RunCodemodeAccess.read(),
        'read-audio-metadata': _RunCodemodeAccess.read(),
        'remove': _RunCodemodeAccess.write(),
        'view-image': _RunCodemodeAccess.denied(
          'Image content must be viewed through a direct Run call.',
        ),
      },
      session: true,
      subcommands: const {
        'read-text': RunPermission.required('files.read'),
        'view-image': RunPermission.required('files.read'),
        'read-video-metadata': RunPermission.required('files.read'),
        'read-audio-metadata': RunPermission.required('files.read'),
        'list': RunPermission.required('files.read'),
        'remove': RunPermission.required('files.remove'),
      },
      (spec, options, _) => _runFilesCommand(spec, options),
    ),
    'ffmpeg': _RunCommandDefinition(
      codemode: const {
        'capabilities': _RunCodemodeAccess.read(),
        'probe': _RunCodemodeAccess.read(),
        'execute': _RunCodemodeAccess.write(),
        'frames': _RunCodemodeAccess.denied(
          'Frame images must be viewed through a direct Run call.',
        ),
      },
      media: true,
      subcommands: const {
        'capabilities': RunPermission.none(),
        'probe': RunPermission.required('files.read'),
        'frames': RunPermission.required('files.read'),
        'execute': RunPermission.required('files.read'),
      },
      (spec, options, _) => _runFfmpegCommand(spec, options),
    ),
    'production': _RunCommandDefinition(
      codemode: const {
        'image-preset': _RunCodemodeAccess.read(),
        'capture-panorama': _RunCodemodeAccess.write(),
        'derive-view': _RunCodemodeAccess.write(),
        'split-grid': _RunCodemodeAccess.write(),
        'capture-frame': _RunCodemodeAccess.write(),
        'separate-audio': _RunCodemodeAccess.write(),
        'mute-video': _RunCodemodeAccess.write(),
        'trim-video': _RunCodemodeAccess.write(),
        'generate-image': _RunCodemodeAccess.write(),
        'generate-video': _RunCodemodeAccess.write(),
        'generate-audio': _RunCodemodeAccess.write(),
      },
      media: true,
      subcommands: const {
        'capture-panorama': RunPermission.none(),
        'derive-view': RunPermission.required('generation.image'),
        'image-preset': RunPermission.none(),
        // 本地节点操作无需文件权限；split-grid 的高清分支单独申请生成权限。
        'split-grid': RunPermission.none(),
        'capture-frame': RunPermission.none(),
        'separate-audio': RunPermission.none(),
        'mute-video': RunPermission.none(),
        'trim-video': RunPermission.none(),
        'generate-image': _generateImage,
        'generate-video': RunPermission.required('generation.video'),
        'generate-audio': RunPermission.required('generation.audio'),
      },
      (spec, options, _) => _runProductionCommand(spec, options),
    ),
    'editing': _RunCommandDefinition(
      codemode: const {
        'list': _RunCodemodeAccess.read(),
        'read': _RunCodemodeAccess.read(),
        'create': _RunCodemodeAccess.write(),
        'apply': _RunCodemodeAccess.write(),
        'undo': _RunCodemodeAccess.write(),
        'redo': _RunCodemodeAccess.write(),
        'preview': _RunCodemodeAccess.write(),
        'cleanup': _RunCodemodeAccess.write(),
        'frames': _RunCodemodeAccess.denied(
          'Frame images must be viewed through a direct Run call.',
        ),
      },
      media: true,
      subcommands: const {
        'list': RunPermission.none(),
        'create': RunPermission.none(),
        'read': RunPermission.none(),
        'apply': RunPermission.none(),
        'undo': RunPermission.none(),
        'redo': RunPermission.none(),
        'preview': RunPermission.none(),
        'frames': RunPermission.none(),
        'cleanup': RunPermission.none(),
      },
      (spec, options, _) => _runEditingCommand(spec.subcommand, options),
    ),
    'character': _RunCommandDefinition(
      codemode: const {
        'generate-avatar': _RunCodemodeAccess.write(),
        'generate-photo': _RunCodemodeAccess.write(),
      },
      subcommands: const {
        'generate-avatar': _generateImage,
        'generate-photo': _generateImage,
      },
      _runSubjectImageCommand,
    ),
    'item': _RunCommandDefinition(
      codemode: const {'generate-photo': _RunCodemodeAccess.write()},
      subcommands: const {'generate-photo': _generateImage},
      _runSubjectImageCommand,
    ),
    'agent-skills': _RunCommandDefinition(
      codemode: const {
        'list': _RunCodemodeAccess.read(),
        'search': _RunCodemodeAccess.read(),
        'get': _RunCodemodeAccess.read(),
        'reference-list': _RunCodemodeAccess.read(),
        'reference-get': _RunCodemodeAccess.read(),
        'create': _RunCodemodeAccess.write(),
        'update': _RunCodemodeAccess.write(),
        'delete': _RunCodemodeAccess.write(),
        'install': _RunCodemodeAccess.write(),
        'reference-create': _RunCodemodeAccess.write(),
        'reference-update': _RunCodemodeAccess.write(),
        'reference-move': _RunCodemodeAccess.write(),
        'reference-delete': _RunCodemodeAccess.write(),
      },
      (spec, options, startedAt) =>
          _runAgentSkillsCommand(spec.subcommand, options, startedAt),
    ),
    'themes': _RunCommandDefinition(
      codemode: const {
        'list': _RunCodemodeAccess.read(),
        'read': _RunCodemodeAccess.read(),
        'create': _RunCodemodeAccess.write(),
        'update': _RunCodemodeAccess.write(),
        'delete': _RunCodemodeAccess.write(),
        'apply': _RunCodemodeAccess.write(),
      },
      (spec, options, startedAt) =>
          _runThemesCommand(spec.subcommand, options, startedAt),
    ),
    'subagents': _RunCommandDefinition(
      codemode: const {
        'list': _RunCodemodeAccess.read(),
        'create': _RunCodemodeAccess.write(),
        'update': _RunCodemodeAccess.write(),
        'delete': _RunCodemodeAccess.write(),
      },
      (spec, options, startedAt) =>
          _runSubagentsCommand(spec.subcommand, options, startedAt),
    ),

    'novel': _RunCommandDefinition(
      codemode: const {'add-to-library': _RunCodemodeAccess.write()},
      (spec, _, startedAt) => _runNovelCommand(spec.subcommand, startedAt),
    ),
    'agent-rules': _RunCommandDefinition(
      codemode: const {
        'list': _RunCodemodeAccess.read(),
        'read': _RunCodemodeAccess.read(),
        'create': _RunCodemodeAccess.write(),
        'update': _RunCodemodeAccess.write(),
        'delete': _RunCodemodeAccess.write(),
      },
      (spec, options, startedAt) =>
          _runAgentRulesCommand(spec.subcommand, options, startedAt),
    ),
    'sessions': _RunCommandDefinition(
      codemode: const {
        'list': _RunCodemodeAccess.read(),
        'read': _RunCodemodeAccess.read(),
        'search': _RunCodemodeAccess.read(),
        'get': _RunCodemodeAccess.read(),
      },
      (spec, options, startedAt) =>
          _runSessionsCommand(spec.subcommand, options, startedAt),
    ),
    'map': _RunCommandDefinition(
      codemode: const {
        'draft': _RunCodemodeAccess.denied(
          'Map drafts require user review in Cartographer.',
        ),
      },
      (spec, options, startedAt) =>
          _runMapCommand(spec.subcommand, options, startedAt),
    ),
    'notify': _RunCommandDefinition(
      codemode: const {
        'progress': _RunCodemodeAccess.denied(
          'Notifications require a direct Run call.',
        ),
        'question': _RunCodemodeAccess.denied(
          'Notifications require a direct Run call.',
        ),
        'complete': _RunCodemodeAccess.denied(
          'Notifications require a direct Run call.',
        ),
        'error': _RunCodemodeAccess.denied(
          'Notifications require a direct Run call.',
        ),
      },
      (spec, options, startedAt) =>
          _runNotifyCommand(spec.subcommand, options, startedAt),
    ),
  };

  Future<Map<String, dynamic>> _handleRun(Map<String, dynamic> input) async {
    final startedAt = DateTime.now();
    var command = _parseStringArgument(input['command']);
    var subcommand = _parseStringArgument(input['subcommand']);
    var options =
        _parseMapArgument(input['options']) ?? const <String, dynamic>{};
    // 防呆：模型偶尔把 command/subcommand 误嵌进 options（实测出现过
    // {"options":{"command":"novel","subcommand":"add-to-library"}}），导致顶层
    // command 为空、被误判成「Run requires command」而回退到通用 help。
    // 顶层缺失但 options 里有时，从 options 回捞，并把这两个键从 options 剥离，
    // 避免它们被后续 handler 当成真正的命令参数。
    if (command.isEmpty && options['command'] != null) {
      command = _parseStringArgument(options['command']);
      if (subcommand.isEmpty) {
        subcommand = _parseStringArgument(options['subcommand']);
      }
      options = Map<String, dynamic>.of(options)
        ..remove('command')
        ..remove('subcommand');
    }
    if (command.isEmpty) {
      return _runTextResult(
        stdout: _runContextHelp(null),
        exitCode: 1,
        startedAt: startedAt,
        error: 'Run requires command.',
        errorCode: ToolErrorCode.invalid_argument.name,
      );
    }

    try {
      if (command == 'help' || command == '--help') {
        return _runTextResult(
          stdout: _runContextHelp(subcommand.isEmpty ? null : subcommand),
          exitCode: 0,
          startedAt: startedAt,
        );
      }

      final definition = _runCommands[command];
      if (definition == null ||
          (definition.media && !_mediaOperations) ||
          (definition.session && !_sessionOperations)) {
        return _runTextResult(
          stdout: _unknownCommandText(command),
          exitCode: 127,
          startedAt: startedAt,
          error: 'unknown command: $command',
          errorCode: ToolErrorCode.invalid_argument.name,
        );
      }
      final scriptContext = _currentToolExecutionContext;
      if (scriptContext?.parentToolCallId != null) {
        final access = definition.codemode[subcommand];
        if (access == null) {
          // Groups without declared subcommands let handlers accept actions
          // outside the script allowlist, so unknown actions stop here.
          throw FormatException('unknown $command action: $subcommand');
        }
        if (access.deniedReason != null) {
          return {
            'ok': false,
            'error_code': 'permission_denied',
            'error': access.deniedReason,
            'hint':
                'Call Run directly, or use Run help inside Codemode to inspect allowed actions.',
          };
        }
        scriptContext!.lifecycleObserver?.onStarted?.call({
          'codemode_mutating': access.mutating,
          'run_command': '$command $subcommand',
        });
      }
      final permission = definition.permissionFor(subcommand);
      if (permission == null) {
        // Skill-owned commands keep their usage in the bundled skill only.
        if (bundledControlRunCommandToCallName.containsKey(command)) {
          if (subcommand.isEmpty || subcommand == '--help') {
            return _missingBundledSkillSubcommand(
              command,
              startedAt,
              contentKind: contentKind,
            );
          }
          throw _RunCommandException(
            '[error] unknown $command command: $subcommand\n'
            '${_bundledSkillCommandGuidance(command, contentKind: contentKind)}',
            exitCode: 127,
          );
        }
        throw FormatException(
          '$command requires ${definition.subcommands!.keys.join(', ')}',
        );
      }
      return await definition.run(
        RunCommandSpec(command, subcommand, permission),
        options,
        startedAt,
      );
    } on ToolOperationException catch (error) {
      return {
        'ok': false,
        'error_code': error.code,
        'error': error.message,
        if (error.hint != null) 'hint': error.hint,
      };
    } on FileSystemException catch (error, stack) {
      _log.error(
        'Run local file access failed',
        error: error,
        stackTrace: stack,
      );
      return {
        'ok': false,
        'error_code': 'not_found',
        'error': 'The local file is missing or cannot be read.',
      };
    } on _RunCommandException catch (e) {
      return _runTextResult(
        stdout: e.message,
        exitCode: e.exitCode,
        startedAt: startedAt,
        error: e.message,
        errorCode: e.errorCode.name,
      );
    } on FormatException catch (e) {
      final hint = _runContextHelp(command);
      return {
        ..._runTextResult(
          stdout: '[error] ${e.message}\n[hint] $hint',
          exitCode: 1,
          startedAt: startedAt,
          error: e.message,
          errorCode: ToolErrorCode.invalid_argument.name,
        ),
        'hint': hint,
      };
    }
  }

  String _runContextHelp(String? command) {
    if (mcpRunHandler != null &&
        mcpAllowed?.call() == true &&
        command == 'mcp') {
      return mcpRunHelp;
    }
    if (_currentToolExecutionContext?.parentToolCallId == null) {
      return '${mcpRunHandler != null && mcpAllowed?.call() == true && (command == null || command.isEmpty) ? 'mcp: discover and call enabled MCP tools. Use Run help mcp.\n' : ''}${_helpFor(command, operations: _mediaOperations, sessionOperations: _sessionOperations, contentKind: contentKind)}';
    }
    final lines = <String>[];
    for (final entry in _runCommands.entries) {
      final definition = entry.value;
      if ((command != null && command != entry.key) ||
          (definition.media && !_mediaOperations) ||
          (definition.session && !_sessionOperations)) {
        continue;
      }
      final actions = definition.codemode.entries
          .where((action) => action.value.deniedReason == null)
          .map((action) => action.key)
          .toList();
      if (actions.isEmpty) {
        continue;
      }
      lines.add('${entry.key}: ${actions.join(', ')}');
      if (command != null) {
        // These groups have no excluded actions, so their existing usage is safe.
        if (entry.key == 'assets') {
          lines.add(
            'list options={type?, search?}; read options={id}; certify options={id, provider_id}. Returns asset metadata.',
          );
        } else {
          lines.add(
            _helpFor(
              entry.key,
              contentKind: contentKind,
              operations: _mediaOperations,
              sessionOperations: _sessionOperations,
            ),
          );
        }
      }
    }
    return lines.isEmpty
        ? 'No Codemode actions are available for this command. Use Run help inside Codemode.'
        : 'Available Codemode Run actions:\n${lines.join('\n')}';
  }

  Future<Map<String, dynamic>> _runEditingCommand(
    String subcommand,
    Map<String, dynamic> options,
  ) async {
    final build = operationHost?.production,
        manager = operationHost?.operations,
        context = _currentToolExecutionContext;
    if (build == null || manager == null || context == null) {
      throw const ToolOperationException(
        'unavailable',
        'Editing requires an active work session.',
      );
    }
    return EditingToolHost(
      await build(),
    ).run(subcommand, options, context, manager, _activeRunCallId ?? '');
  }

  Future<Map<String, dynamic>> _runSettingsCommand(
    Map<String, dynamic> options,
  ) async {
    final section = options['section'];
    if (options.length != 1 ||
        section is! String ||
        section.isEmpty ||
        section == 'debug') {
      throw const FormatException(
        'settings open requires a non-empty section; debug is not supported.',
      );
    }
    final open = operationHost?.openSettings;
    if (open == null) {
      throw const ToolOperationException(
        'unavailable',
        'Settings navigation requires an application session.',
      );
    }
    open(section);
    return {'ok': true};
  }

  Future<Map<String, dynamic>> _runProductionCommand(
    RunCommandSpec spec,
    Map<String, dynamic> options,
  ) async {
    final build = operationHost?.production,
        manager = operationHost?.operations,
        context = _currentToolExecutionContext;
    if (build == null || manager == null || context == null) {
      throw const ToolOperationException(
        'unavailable',
        'Production tools require an active work session.',
      );
    }
    return (await build()).run(
      spec,
      options,
      context,
      manager,
      _activeRunCallId ?? '',
    );
  }

  Future<Map<String, dynamic>> _runFfmpegCommand(
    RunCommandSpec spec,
    Map<String, dynamic> options,
  ) async {
    final subcommand = spec.subcommand;
    final command = FfmpegCommand(
      SessionFiles(novelId: workId),
      FfmpegRunner(),
    );
    if (subcommand == 'capabilities') {
      if (options.keys.any((key) => key != 'component') ||
          (options['component'] != null && options['component'] is! String)) {
        throw const FormatException(
          'capabilities accepts an optional component string',
        );
      }
      try {
        return await command.capabilities(
          MediaCancellation(),
          component: options['component'] as String?,
        );
      } on UnsupportedError {
        throw const ToolOperationException(
          'unsupported',
          'FFmpeg processing requires Windows or macOS.',
        );
      }
    }
    final extracting = subcommand == 'frames';
    final allowed = extracting ? {'path', 'timestamps_ms'} : {'args'};
    if (options.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('Unsupported FFmpeg option');
    }
    final timestamps = extracting
        ? contactSheetPositions(options['timestamps_ms'], 'timestamps_ms')
        : null;
    final source = extracting ? _productionCommandText(options, 'path') : null;
    final parsed = FfmpegArguments.parse(
      extracting ? [source!] : options['args'],
      probe: extracting || subcommand == 'probe',
    );
    final context = _currentToolExecutionContext;
    final manager = operationHost?.operations;
    final id = context?.sessionId ?? sessionId;
    if (id == null || context == null || manager == null) {
      throw const FormatException('FFmpeg requires an active chat session');
    }
    await command.validateOutputs(id, parsed);
    final target = 'ffmpeg/$subcommand';
    return manager.start(
      context: context,
      callId: _activeRunCallId ?? '',
      workId: workId ?? '',
      kind: spec.operation,
      targetPath: target,
      toolName: 'Run',
      // 抽帧与 probe 很快且结果要立即查看；任意命令耗时不定，固定后台。
      background: subcommand == 'execute',
      input: options,
      verifyTarget: () => command.validateOutputs(id, parsed),
      execute: (operation) async {
        final cancellation = MediaCancellation()
          ..onProgress = (processed) => operation.report(
            progress: {'processed_ms': processed.inMilliseconds},
          );
        final unlink = operation.cancellation.onCancel(
          () => unawaited(cancellation.cancel()),
        );
        try {
          final plan = await command.inspect(
            parsed,
            authorizeExternal: (paths) async {
              final label = paths.take(3).map(p.basename).join(', ');
              final shortLabel = String.fromCharCodes(label.runes.take(160));
              await operation.authorize(
                ToolActionRequest(
                  action: spec.capability,
                  context: ToolPermissionContext(
                    workId: workId ?? '',
                    sessionId: context.sourceSessionId ?? id,
                    episodeId: currentEpisodeId,
                  ),
                  targetPath: target,
                  targetLabel:
                      '$shortLabel${paths.length > 3 || label != shortLabel ? '…' : ''}',
                  summary: {
                    'inputs': paths,
                    'input_count': paths.length,
                    'args': parsed.args,
                  },
                ),
                () async {},
              );
            },
          );
          await plan.verify();
          operation.checkCancelled();
          return extracting
              ? commandFileResult(
                  await command.frames(id, source!, timestamps!, cancellation),
                  command.files,
                )
              : await command.run(id, plan, cancellation);
        } on FileSystemException catch (error) {
          throw ToolOperationException(
            'file_unavailable',
            error.toString(),
            hint:
                'Use Run files list to find the exact input path, then retry. '
                'Do not construct filenames from asset IDs.',
          );
        } on UnsupportedError {
          throw const ToolOperationException(
            'unsupported',
            'FFmpeg processing requires Windows or macOS.',
          );
        } on FormatException catch (error) {
          throw ToolOperationException(
            'invalid_argument',
            error.message.toString(),
          );
        } finally {
          unlink();
        }
      },
    );
  }

  Future<Map<String, dynamic>> _runFilesCommand(
    RunCommandSpec spec,
    Map<String, dynamic> options,
  ) async {
    if (spec.subcommand == 'list' || spec.subcommand == 'remove') {
      return _runManagedFilesCommand(spec, options);
    }
    final mode = switch (spec.subcommand) {
      'read-text' => 'text',
      'view-image' => 'image',
      'read-video-metadata' => 'video',
      'read-audio-metadata' => 'audio',
      _ => throw const FormatException('Unknown file reading command.'),
    };
    final accepted = {
      'path',
      if (mode == 'text') ...['offset', 'limit', 'continuation'],
    };
    if (options.keys.any((key) => !accepted.contains(key))) {
      throw const FormatException('Unsupported files option.');
    }
    final context = _currentToolExecutionContext;
    final manager = operationHost?.operations;
    final id = context?.sessionId ?? sessionId;
    final path = options['path'];
    if (id == null || manager == null || context == null) {
      throw const FormatException(
        'File reading requires an active chat session',
      );
    }
    if (path is! String || path.isEmpty) {
      throw const FormatException('path is required');
    }
    final files = SessionFiles(novelId: workId);
    final source = await CommandPaths(files).resolve(path);
    final before = await source.stat();
    return manager.start(
      context: context,
      callId: _activeRunCallId ?? context.approvalHostCallId ?? '',
      workId: workId ?? '',
      kind: spec.operation,
      targetPath: path,
      toolName: 'Run',
      // 本地读取很快，内容要在本轮直接交给模型，固定同步。
      background: false,
      input: options,
      permission: !CommandPaths.isAbsolute(path)
          ? null
          : ToolActionRequest(
              action: spec.capability,
              targetLabel: p.basename(path),
              context: ToolPermissionContext(
                workId: workId ?? '',
                sessionId: context.sourceSessionId ?? id,
                episodeId: currentEpisodeId,
              ),
              targetPath: path,
              summary: options,
            ),
      verifyTarget: () async {
        final current = await CommandPaths(files).resolve(path);
        final stat = await current.stat();
        if (current.path != source.path ||
            stat.size != before.size ||
            stat.modified != before.modified) {
          throw const ToolOperationException(
            'conflict',
            'The file changed before reading. Try again.',
          );
        }
      },
      execute: (operation) async {
        final elapsed = Stopwatch()..start();
        final cancellation = MediaCancellation();
        final unlink = operation.cancellation.onCancel(
          () => unawaited(cancellation.cancel()),
        );
        try {
          final result = await FileReader(files, FfmpegRunner())
              .read(id, {
                ...operation.input,
                'path': source.path,
                'mode': mode,
              }, cancellation)
              .timeout(
                const Duration(seconds: 30) - elapsed.elapsed,
                onTimeout: () async {
                  await cancellation.cancel();
                  throw const ToolOperationException(
                    'timeout',
                    'File reading exceeded 30 seconds.',
                  );
                },
              );
          return commandFileResult(result, files);
        } on FormatException catch (error) {
          throw ToolOperationException(
            'invalid_argument',
            error.message.toString(),
          );
        } on UnsupportedError {
          throw const ToolOperationException(
            'unsupported',
            'Media inspection requires Windows or macOS.',
          );
        } on FileSystemException catch (error, stack) {
          _log.error('File snapshot failed', error: error, stackTrace: stack);
          throw const ToolOperationException(
            'unavailable',
            'The file could not be read or copied.',
          );
        } finally {
          unlink();
        }
      },
    );
  }

  Future<Map<String, dynamic>> _runManagedFilesCommand(
    RunCommandSpec spec,
    Map<String, dynamic> options,
  ) async {
    final removing = spec.subcommand == 'remove';
    final allowed = {
      'path',
      'recursive',
      if (!removing) ...['offset', 'limit'],
    };
    if (options.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('Unsupported files option.');
    }
    final path = options['path'];
    final recursive = options['recursive'] ?? false;
    final offset = options['offset'] ?? 0;
    final limit = options['limit'] ?? 200;
    if (path is! String ||
        recursive is! bool ||
        offset is! int ||
        offset < 0 ||
        limit is! int ||
        limit < 1 ||
        limit > 1000) {
      throw const FormatException(
        'Use path, boolean recursive, nonnegative offset and limit 1..1000.',
      );
    }
    final context = _currentToolExecutionContext;
    final manager = operationHost?.operations;
    final id = context?.sessionId ?? sessionId;
    if (context == null || manager == null || id == null) {
      throw const FormatException(
        'File management requires an active chat session.',
      );
    }
    final files = ManagedFiles(SessionFiles(novelId: workId), id);
    final external = CommandPaths.isAbsolute(path);
    if (removing && external) {
      throw const FormatException('Removal requires a work-relative path.');
    }
    // An absolute directory may contain private names; enumerate only after approval.
    final verifyExternal = external ? await files.freezeExternal(path) : null;
    final selection = external
        ? null
        : await files.select(path, remove: removing, recursive: recursive);
    // Nothing to delete: skip the approval prompt instead of asking the user
    // to authorize a no-op.
    if (removing && selection!.paths.isEmpty) {
      return {'ok': true, 'matched_count': 0, 'removed': <String>[]};
    }
    final folders = removing ? selection!.folderCounts : const <String, int>{};
    return manager.start(
      context: context,
      callId: _activeRunCallId ?? context.approvalHostCallId ?? '',
      workId: workId ?? '',
      kind: spec.operation,
      targetPath: path,
      toolName: 'Run',
      background: false,
      input: options,
      permission: !removing && !external
          ? null
          : ToolActionRequest(
              action: spec.capability,
              context: ToolPermissionContext(
                workId: workId ?? '',
                sessionId: context.sourceSessionId ?? id,
                episodeId: currentEpisodeId,
              ),
              targetPath: path,
              targetLabel: path,
              // Removal plans can hold thousands of entries; the approval shows
              // per-folder counts while execution still uses the frozen selection.
              summary: {
                if (selection != null) 'matched_count': selection.paths.length,
                if (external) 'path': path,
                if (recursive) 'recursive': true,
                if (folders.isNotEmpty)
                  'folders': [
                    for (final MapEntry(:key, :value) in folders.entries.take(
                      _approvalFolderLimit,
                    ))
                      {'path': '$key/', 'count': value},
                  ],
                if (folders.length > _approvalFolderLimit)
                  'folder_count': folders.length,
              },
            ),
      verifyTarget: selection?.verify ?? verifyExternal!,
      execute: (operation) async {
        final approved =
            selection ??
            await files.select(path, remove: false, recursive: recursive);
        return removing
            ? approved.remove(
                cancelled: () => operation.cancellation.isCancellationRequested,
              )
            : approved.listing(offset: offset, limit: limit);
      },
    );
  }

  Future<Map<String, dynamic>> _runOperationsCommand(
    String subcommand,
    Map<String, dynamic> options,
  ) async {
    final manager = operationHost?.operations;
    final context = _currentToolExecutionContext;
    if (manager == null || context == null) {
      return {
        'ok': false,
        'error_code': 'unavailable',
        'error': 'Session operation control is unavailable.',
      };
    }
    try {
      int number(String key, int fallback) {
        final value = options[key];
        if (value == null) {
          return fallback;
        }
        final parsed = value is int ? value : int.tryParse('$value');
        if (parsed == null) {
          throw FormatException('$key must be an integer.');
        }
        return parsed;
      }

      if (subcommand == 'list') {
        final statusName = options['status'];
        final status = statusName == null
            ? null
            : ToolOperationStatus.values
                  .where((value) => value.name == statusName)
                  .firstOrNull;
        if (statusName != null && status == null) {
          throw const FormatException('Invalid operation status.');
        }
        return manager.list(
          context,
          status: status,
          offset: number('offset', 0),
          limit: number('limit', 50),
        );
      }
      if (!const {'read', 'wait', 'cancel'}.contains(subcommand)) {
        throw const FormatException(
          'operations requires list, read, wait, or cancel.',
        );
      }
      if (subcommand == 'cancel' && options['task_id'] != null) {
        if (options['run_id'] != null ||
            options.keys.any((key) => key != 'task_id')) {
          throw const FormatException('Use task_id or run_id, not both.');
        }
        final build = operationHost?.production;
        if (build == null || options['task_id'] is! String) {
          throw const FormatException(
            'A valid production task_id is required.',
          );
        }
        final host = await build();
        final task = await host.database.generationTaskDao.getById(
          options['task_id'] as String,
        );
        if (task == null ||
            task.novelId != host.canvas.novelId ||
            task.sourceType != 'production_clip') {
          throw const ToolOperationException(
            'not_found',
            'Production task not found.',
          );
        }
        final receipt = await host.results.requestCancellation(task.id);
        return {
          ...await host.summary(
            (await host.database.generationTaskDao.getById(task.id))!,
          ),
          'ok': true,
          'accepted': receipt.accepted,
          'result_applied': receipt.resultApplied,
          'upstream_may_continue':
              receipt.accepted && task.status != GenerationTaskStatus.prepared,
        };
      }
      final id = options['run_id'];
      if (id is! String || id.trim().isEmpty) {
        throw const FormatException('run_id is required.');
      }
      return switch (subcommand) {
        'read' => manager.read(id, context),
        'wait' => await manager.wait(
          id,
          context,
          timeoutMs: number('timeout_ms', 30000),
        ),
        _ => manager.cancel(id, context),
      };
    } on ToolOperationException catch (error) {
      return {'ok': false, 'error_code': error.code, 'error': error.message};
    }
  }

  /// 把完整的地图提示词和生成参数提交到制图师供用户审阅。
  /// 此命令不调用图片模型，也不创建或更新地图记录。
  Future<Map<String, dynamic>> _runMapCommand(
    String subcommand,
    Map<String, dynamic> options,
    DateTime startedAt,
  ) async {
    if (subcommand.isEmpty || subcommand == '--help') {
      return _runTextResult(
        stdout: _mapHelpText(),
        exitCode: 0,
        startedAt: startedAt,
      );
    }
    if (subcommand != 'draft') {
      return _runTextResult(
        stdout:
            'Unknown map command: $subcommand\n'
            'Available: draft',
        exitCode: 127,
        startedAt: startedAt,
        error: 'unknown map command: $subcommand',
        errorCode: ToolErrorCode.invalid_argument.name,
      );
    }

    final callback = mapDraftCommandCallback;
    if (callback == null) {
      return _runTextResult(
        stdout: '[error] Map cartographer is unavailable in this session.',
        exitCode: 1,
        startedAt: startedAt,
        error: 'map cartographer unavailable',
        errorCode: ToolErrorCode.unavailable.name,
      );
    }

    final usage = _usageForMapDraft();
    final unsupported = options.keys
        .where((key) => !_mapDraftOptions.contains(key))
        .toList();
    if (unsupported.isNotEmpty) {
      throw _RunCommandException(
        '[error] unsupported map option: ${unsupported.join(', ')}\n$usage',
      );
    }
    final locationId = _requiredOption(options, 'location', usage: usage);
    final prompt = _requiredOption(options, 'prompt', usage: usage);
    final styleId = _validatedMapOption(
      options,
      name: 'style',
      supported: mapDesignStyleIds,
      defaultValue: mapDesignDefaultStyleId,
      usage: usage,
    );
    final customStyleWord = _optionalOption(options, 'custom_style').trim();
    if (styleId == mapCustomStyleId && customStyleWord.isEmpty) {
      throw _RunCommandException(
        '[error] map custom style requires option "custom_style"\n$usage',
      );
    }
    final resolutionId = _validatedMapOption(
      options,
      name: 'resolution',
      supported: mapDesignResolutionIds,
      defaultValue: mapDesignDefaultResolutionId,
      usage: usage,
    );
    final qualityId = _validatedMapOption(
      options,
      name: 'quality',
      supported: mapDesignQualityIds,
      defaultValue: mapDesignDefaultQualityId,
      usage: usage,
    );
    final includeLocations = _strictOptionalBool(
      options,
      name: 'include_locations',
      defaultValue: true,
      usage: usage,
    );
    final referenceCurrentImage = _strictOptionalBool(
      options,
      name: 'reference_current_image',
      defaultValue: false,
      usage: usage,
    );

    try {
      final result = await callback(
        MapDesignDraft(
          worldId: locationId,
          prompt: prompt,
          styleId: styleId,
          customStyleWord: styleId == mapCustomStyleId ? customStyleWord : null,
          resolutionId: resolutionId,
          qualityId: qualityId,
          includeLocations: includeLocations,
          referenceCurrentImage: referenceCurrentImage,
        ),
      );
      final ok = result['ok'] != false;
      return <String, dynamic>{
        ...result,
        'ok': ok,
        'command': 'map draft',
        'result_code': 'map_draft_ready',
        'exit_code': ok ? 0 : 1,
        'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
      };
    } catch (error, stackTrace) {
      _log.error('Run map draft failed', error: error, stackTrace: stackTrace);
      return _runTextResult(
        stdout: '[error] Failed to submit the map design draft.',
        exitCode: 1,
        startedAt: startedAt,
        error: 'map draft submission failed',
        errorCode: ToolErrorCode.internal.name,
      );
    }
  }

  String _validatedMapOption(
    Map<String, dynamic> options, {
    required String name,
    required Set<String> supported,
    required String defaultValue,
    required String usage,
  }) {
    final value = _optionalOption(options, name);
    if (value.isEmpty) {
      return defaultValue;
    }
    if (supported.contains(value)) {
      return value;
    }
    throw _RunCommandException(
      '[error] invalid map $name: $value\n'
      'Supported: ${supported.join(', ')}\n$usage',
    );
  }

  bool _strictOptionalBool(
    Map<String, dynamic> options, {
    required String name,
    required bool defaultValue,
    required String usage,
  }) {
    if (!options.containsKey(name)) {
      return defaultValue;
    }
    final raw = options[name];
    if (raw is bool) {
      return raw;
    }
    if (raw is num && (raw == 0 || raw == 1)) {
      return raw == 1;
    }
    if (raw is String) {
      final value = raw.trim().toLowerCase();
      if (value == 'true' || value == 'yes' || value == '1') {
        return true;
      }
      if (value == 'false' || value == 'no' || value == '0') {
        return false;
      }
    }
    throw _RunCommandException(
      '[error] map option "$name" must be true or false\n$usage',
    );
  }

  /// `command=novel subcommand=add-to-library`：把当前「快速开书」占位作品正式加入书架
  /// （清除 draft 标记）。仅供创作向导在与用户确认后调用，不耦合任何写入动作。
  Future<Map<String, dynamic>> _runNovelCommand(
    String subcommand,
    DateTime startedAt,
  ) async {
    if (subcommand.isEmpty || subcommand == '--help') {
      return _runTextResult(
        stdout: _novelHelpText(),
        exitCode: 0,
        startedAt: startedAt,
      );
    }
    if (subcommand != 'add-to-library') {
      return _runTextResult(
        stdout:
            'Unknown novel command: $subcommand\n'
            'Usage: command=novel subcommand=add-to-library',
        exitCode: 127,
        startedAt: startedAt,
        error: 'unknown novel command: $subcommand',
        errorCode: ToolErrorCode.invalid_argument.name,
      );
    }

    final clearDraft = novelDraftClearer;
    if (clearDraft == null) {
      return _runTextResult(
        stdout: '[error] Novel info is unavailable in this session',
        exitCode: 1,
        startedAt: startedAt,
        error: 'novel unavailable',
        errorCode: ToolErrorCode.unavailable.name,
      );
    }

    try {
      await clearDraft();
      return _runTextResult(
        stdout: 'Added to library.',
        exitCode: 0,
        startedAt: startedAt,
      );
    } on NovelTitleConflictException catch (error) {
      return _runTextResult(
        stdout:
            '[error] A library novel named "${error.title}" already exists. '
            'Rename this draft before adding it to the library.',
        exitCode: 1,
        startedAt: startedAt,
        error: 'library title conflict',
        errorCode: ToolErrorCode.already_exists.name,
      );
    } catch (error, stackTrace) {
      _log.error(
        'Run novel add-to-library failed',
        error: error,
        stackTrace: stackTrace,
      );
      return _runTextResult(
        stdout: '[error] Failed to add novel to library',
        exitCode: 1,
        startedAt: startedAt,
        error: error.toString(),
        errorCode: ToolErrorCode.internal.name,
      );
    }
  }

  Future<Map<String, dynamic>> _runNotifyCommand(
    String subcommand,
    Map<String, dynamic> options,
    DateTime startedAt,
  ) async {
    if (subcommand.isEmpty || subcommand == '--help') {
      return _runTextResult(
        stdout: _notifyHelpText(),
        exitCode: 0,
        startedAt: startedAt,
      );
    }
    if (notifyCallback == null) {
      return _runTextResult(
        stdout: '[error] notify command is not available in this context',
        exitCode: 1,
        startedAt: startedAt,
        error: 'notify command is not available',
        errorCode: ToolErrorCode.unavailable.name,
      );
    }

    // subcommand 即消息类型：progress / question / complete / error。
    if (!const {
      'progress',
      'question',
      'complete',
      'error',
    }.contains(subcommand)) {
      throw _RunCommandException(
        _unknownNotifySubcommandText(subcommand),
        exitCode: 127,
      );
    }

    final content = _requiredOption(
      options,
      'content',
      usage: _usageForNotify(subcommand),
    );

    final result = await notifyCallback!({
      'action': subcommand,
      'content': content,
      if (sourceSessionId != null) 'source_ref': sourceSessionId,
    });
    return <String, dynamic>{
      ...result,
      'ok': result['ok'] != false,
      'command': 'notify $subcommand',
      'exit_code': result['ok'] == false ? 1 : 0,
      'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
    };
  }

  Future<Map<String, dynamic>> _runAgentSkillsCommand(
    String subcommand,
    Map<String, dynamic> options,
    DateTime startedAt,
  ) async {
    if (subcommand.isEmpty || subcommand == '--help') {
      return _missingBundledSkillSubcommand('agent-skills', startedAt);
    }
    if (agentSkillsCommandCallback == null) {
      return _runTextResult(
        stdout: '[error] agent-skills command is not available in this context',
        exitCode: 1,
        startedAt: startedAt,
        error: 'agent-skills command is not available',
        errorCode: ToolErrorCode.unavailable.name,
      );
    }

    if (!const {
      'list',
      'create',
      'update',
      'delete',
      'search',
      'get',
      'install',
      'reference-list',
      'reference-get',
      'reference-create',
      'reference-update',
      'reference-move',
      'reference-delete',
    }.contains(subcommand)) {
      throw _RunCommandException(
        _unknownAgentSkillsSubcommandText(subcommand),
        exitCode: 127,
      );
    }

    final command = switch (subcommand) {
      'search' => _runAgentSkillsSearch(options),
      'get' => _runAgentSkillsGet(options),
      'install' => _runAgentSkillsInstall(options),
      'reference-list' ||
      'reference-get' ||
      'reference-create' ||
      'reference-update' ||
      'reference-move' ||
      'reference-delete' => _buildAgentSkillsReferenceCommand(
        subcommand,
        options,
      ),
      _ => _buildAgentSkillsCrudCommand(subcommand, options),
    };

    final result = await agentSkillsCommandCallback!(command);
    return <String, dynamic>{
      'ok': result['ok'] != false,
      'command': 'agent-skills $subcommand',
      'exit_code': result['ok'] == false ? 1 : 0,
      'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
      ...result,
    };
  }

  Future<Map<String, dynamic>> _runThemesCommand(
    String subcommand,
    Map<String, dynamic> options,
    DateTime startedAt,
  ) async {
    if (subcommand.isEmpty || subcommand == '--help') {
      return _missingBundledSkillSubcommand('themes', startedAt);
    }
    final callback = themesCommandCallback;
    if (callback == null) {
      throw const _RunCommandException(
        'themes command is not available in this context',
      );
    }
    final result = await callback({...options, 'action': subcommand});
    return {
      ...result,
      'command': 'themes $subcommand',
      'exit_code': result['ok'] == true ? 0 : 1,
      'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
    };
  }

  Future<Map<String, dynamic>> _runSubagentsCommand(
    String subcommand,
    Map<String, dynamic> options,
    DateTime startedAt,
  ) async {
    if (subcommand.isEmpty || subcommand == '--help') {
      return _missingBundledSkillSubcommand('subagents', startedAt);
    }
    if (subagentsCommandCallback == null) {
      return _runTextResult(
        stdout: '[error] subagents command is not available in this context',
        exitCode: 1,
        startedAt: startedAt,
        error: 'subagents command is not available',
        errorCode: ToolErrorCode.unavailable.name,
      );
    }
    if (!const {'list', 'create', 'update', 'delete'}.contains(subcommand)) {
      throw _RunCommandException(
        _unknownSubagentsSubcommandText(subcommand),
        exitCode: 127,
      );
    }
    final command = <String, dynamic>{'action': subcommand};
    for (final option in [
      'id',
      'slug',
      'name',
      'description',
      'prompt',
      'mode',
      'enabled',
      'confirm',
    ]) {
      if (options.containsKey(option)) {
        command[option] = _parseStringArgument(options[option]);
      }
    }
    final result = await subagentsCommandCallback!(command);
    return <String, dynamic>{
      'ok': result['ok'] != false,
      'command': 'subagents $subcommand',
      'exit_code': result['ok'] == false ? 1 : 0,
      'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
      ...result,
    };
  }

  /// 当前 AI 轮次 id，用于把一轮内的多次技能写入聚合成一条历史版本。
  /// 内部字段，不进入模型上下文。
  String? get _agentSkillTurnId => _currentToolExecutionContext?.sourceTurnId;

  Map<String, dynamic> _buildAgentSkillsCrudCommand(
    String subcommand,
    Map<String, dynamic> options,
  ) {
    final command = <String, dynamic>{
      'action': subcommand,
      if (_agentSkillTurnId != null) '_turn_id': _agentSkillTurnId,
    };
    for (final option in [
      'id',
      'name',
      'prompt',
      'when-to-use',
      'description',
      'enabled',
    ]) {
      if (options.containsKey(option)) {
        command[option] = _parseStringArgument(options[option]);
      }
    }
    if (_parseBoolArgument(options['disabled'])) {
      command['enabled'] = 'false';
    }
    if (subcommand == 'create' && options.containsKey('references')) {
      command['references'] = options['references'];
    }
    return command;
  }

  Map<String, dynamic> _buildAgentSkillsReferenceCommand(
    String subcommand,
    Map<String, dynamic> options,
  ) {
    final command = <String, dynamic>{
      'action': subcommand,
      if (_agentSkillTurnId != null) '_turn_id': _agentSkillTurnId,
      'name': _requiredOption(
        options,
        'name',
        usage: _usageForAgentSkills(subcommand),
      ),
    };
    switch (subcommand) {
      case 'reference-list':
        return command;
      case 'reference-get':
      case 'reference-delete':
        command['path'] = _requiredOption(
          options,
          'path',
          usage: _usageForAgentSkills(subcommand),
        );
        return command;
      case 'reference-create':
      case 'reference-update':
        command['path'] = _requiredOption(
          options,
          'path',
          usage: _usageForAgentSkills(subcommand),
        );
        command['content'] = _requiredOption(
          options,
          'content',
          usage: _usageForAgentSkills(subcommand),
        );
        return command;
      case 'reference-move':
        command['path'] = _requiredOption(
          options,
          'path',
          usage: _usageForAgentSkills(subcommand),
        );
        command['new_path'] = _requiredOption(
          options,
          'new_path',
          usage: _usageForAgentSkills(subcommand),
        );
        return command;
      default:
        throw StateError(
          'Unsupported AgentSkill reference action: $subcommand',
        );
    }
  }

  /// 组装 `agent-skills search` 命令参数。
  ///
  /// 临时：handler 侧会返回来源全量目录（不做 query 过滤），故此处 `query` /
  /// `limit` 均非必需；`query` 可选透传仅供意图标注。详见
  /// `AgentSkillsRunCommandHandler._search`。
  Map<String, dynamic> _runAgentSkillsSearch(Map<String, dynamic> options) {
    final command = <String, dynamic>{'action': 'search'};
    // query 可选：不参与过滤，仅透传。
    final query = _optionalOption(options, 'query');
    if (query.isNotEmpty) {
      command['query'] = query;
    }
    final source = _optionalOption(options, 'source');
    if (source.isNotEmpty) {
      command['source'] = _validateAgentSkillCatalogSource(source);
    }
    final category = _optionalOption(options, 'category');
    if (category.isNotEmpty) {
      command['category'] = category;
    }
    final tag = _optionalOption(options, 'tag');
    if (tag.isNotEmpty) {
      command['tag'] = tag;
    }
    return command;
  }

  Map<String, dynamic> _runAgentSkillsGet(Map<String, dynamic> options) {
    final source = _requiredOption(
      options,
      'source',
      usage: _usageForAgentSkills('get'),
    );
    final sourceId = _requiredOption(
      options,
      'source_id',
      usage: _usageForAgentSkills('get'),
    );
    return {
      'action': 'get',
      'source': _validateAgentSkillCatalogSource(source),
      'source_id': sourceId,
    };
  }

  Map<String, dynamic> _runAgentSkillsInstall(Map<String, dynamic> options) {
    final source = _requiredOption(
      options,
      'source',
      usage: _usageForAgentSkills('install'),
    );
    final sourceId = _requiredOption(
      options,
      'source_id',
      usage: _usageForAgentSkills('install'),
    );
    final command = <String, dynamic>{
      'action': 'install',
      'source': _validateAgentSkillCatalogSource(source),
      'source_id': sourceId,
    };
    final callName = _optionalOption(options, 'call_name');
    if (callName.isNotEmpty) {
      command['call_name'] = callName;
    }
    final conflictResolution = _optionalOption(options, 'conflict_resolution');
    if (conflictResolution.isNotEmpty) {
      command['conflict_resolution'] = conflictResolution;
    }
    return command;
  }

  /// Character and item images are one-off generation requests approved under `generation.image`.
  Future<Map<String, dynamic>> _runSubjectImageCommand(
    RunCommandSpec spec,
    Map<String, dynamic> options,
    DateTime startedAt,
  ) async {
    if (contentKind == contentKindCanvas) {
      throw const ToolOperationException(
        'unsupported',
        'Canvas works do not expose subjects. Use production clips.',
      );
    }
    final usage = _usageForSubjectImage(spec.operation);
    final prompt = _requiredOption(options, 'prompt', usage: usage);
    final subjectKey = spec.command == 'item' ? 'item' : 'character';
    if (options.keys.any(
      (key) => !{subjectKey, 'prompt', 'asset_id'}.contains(key),
    )) {
      throw const FormatException('Unsupported image generation option');
    }
    final assetId = _optionalOption(options, 'asset_id');
    if (options.containsKey('asset_id') &&
        (options['asset_id'] is! String || assetId.isEmpty)) {
      throw const FormatException('asset_id must be a nonempty image asset ID');
    }
    final subjectId = _requiredOption(options, subjectKey, usage: usage);
    final manager = operationHost?.operations;
    final context = _currentToolExecutionContext;
    if (manager == null || context == null) {
      throw const ToolOperationException(
        'unavailable',
        'Image generation requires an active chat session.',
      );
    }
    final subjectName = spec.command == 'item'
        ? await _subjectItemName(subjectId)
        : (await _contentService.getCharacterProfileById(subjectId))?.name;
    if (subjectName == null) {
      throw ToolOperationException('not_found', '$subjectKey not found.');
    }
    final files = SessionFiles(novelId: workId);
    final source = assetId.isEmpty
        ? null
        : await _resolveSubjectImageAsset(assetId);
    final avatar = spec.subcommand == 'generate-avatar';
    final request = {
      'prompt': prompt,
      '${subjectKey}_id': subjectId,
      if (source != null) 'asset_id': assetId,
    };
    final target = '/${subjectKey}s/$subjectId';
    final receipt = await manager.start(
      context: context,
      callId: _activeRunCallId ?? context.approvalHostCallId ?? '',
      workId: workId ?? '',
      kind: spec.operation,
      targetPath: target,
      toolName: runToolName,
      background: false,
      input: request,
      permission: ToolActionRequest(
        action: spec.capability,
        context: ToolPermissionContext(
          workId: workId ?? '',
          sessionId: context.sourceSessionId ?? context.sessionId,
        ),
        targetPath: target,
        targetLabel: subjectName,
        summary: {
          'size': avatar ? _avatarImageSize : _photoImageSize,
          'prompt': prompt,
          if (source != null) 'asset_id': assetId,
        },
      ),
      verifyTarget: () async {
        final current = spec.command == 'item'
            ? await _subjectItemName(subjectId)
            : (await _contentService.getCharacterProfileById(subjectId))?.name;
        if (current == null) {
          throw ToolOperationException('conflict', '$subjectKey was removed.');
        }
        if (source != null) {
          final currentSource = await _resolveSubjectImageAsset(assetId);
          if (currentSource.path != source.path) {
            throw const ToolOperationException(
              'conflict',
              'Reference image changed.',
            );
          }
        }
      },
      execute: (operation) async {
        final result = avatar
            ? await _handleGenerateAvatar(
                operation.input,
                referenceImagePath: source?.path,
              )
            : await _handleGeneratePhoto(
                operation.input,
                referenceImagePath: source?.path,
              );
        return {
          ...result,
          if (result['local_path'] is String)
            'local_path': commandFileResult({
              'file_path': result['local_path'],
            }, files)['file_path'],
          'ok': result['success'] != false,
        };
      },
    );
    final result = (receipt['result'] as Map?)?.cast<String, dynamic>();
    final failed = result == null || result['success'] == false;
    return <String, dynamic>{
      ...receipt,
      ...?result,
      'ok': !failed && receipt['ok'] != false,
      'command': '${spec.command} ${spec.subcommand}',
      'exit_code': failed ? 1 : 0,
      'duration_ms': DateTime.now().difference(startedAt).inMilliseconds,
      if (failed) 'success': false,
      // UI 辅助数据：标识图片场景与目标对象，便于 tool card 直接 apply。
      // `_metadata` 不会发送给模型（由 agent 在构造模型消息时剥离）。
      '_metadata': {'scene': spec.operation, '${subjectKey}_id': subjectId},
    };
  }

  Future<File> _resolveSubjectImageAsset(String assetId) async {
    final library = _contentService.imageLibraryService;
    if (library == null) {
      throw const ToolOperationException(
        'unavailable',
        'Image library is unavailable.',
      );
    }
    final asset = await library.getAsset(assetId);
    if (asset == null || workId == null || asset.novelId != workId) {
      throw ToolOperationException(
        'not_found',
        'Image asset not found in this work: $assetId',
      );
    }
    final path = asset.path;
    if (path == null || path.isEmpty) {
      throw ToolOperationException(
        'not_found',
        'Image asset has no local file: $assetId',
      );
    }
    return SessionFiles(novelId: workId).resolve(path);
  }

  Future<String?> _subjectItemName(String id) async {
    final item = await _contentService.getItemById(id);
    return item?.type == 'item' ? item!.title : null;
  }

  String _requiredOption(
    Map<String, dynamic> options,
    String name, {
    required String usage,
  }) {
    final value = _optionalOption(options, name);
    if (value.isEmpty) {
      throw _RunCommandException(
        '[error] Run command requires option "$name"\n$usage',
      );
    }
    return value;
  }

  String _validateAgentSkillCatalogSource(String source) {
    if (_agentSkillCatalogSources.contains(source)) {
      return source;
    }
    throw _RunCommandException(
      '[error] invalid agent skill source: $source\n'
      'Supported: official, marketplace',
    );
  }

  String _optionalOption(Map<String, dynamic> options, String name) {
    if (!options.containsKey(name)) {
      return '';
    }
    return _parseStringArgument(options[name]);
  }

  Future<Map<String, dynamic>> _runSessionsCommand(
    String subcommand,
    Map<String, dynamic> options,
    DateTime startedAt,
  ) async {
    if (subcommand.isEmpty || subcommand == '--help') {
      return _runTextResult(
        stdout: _sessionsHelpText(),
        exitCode: 0,
        startedAt: startedAt,
      );
    }
    final callback = sessionsCommandCallback;
    if (callback == null) {
      return _runTextResult(
        stdout: 'Saved session reading is unavailable.',
        exitCode: 1,
        startedAt: startedAt,
        error: 'Saved session reading is unavailable.',
        errorCode: ToolErrorCode.unavailable.name,
      );
    }
    final context = _currentToolExecutionContext;
    final result = await callback(
      subcommand,
      options,
      currentSessionId: context?.sessionId ?? sessionId,
      sourceSessionId: context == null
          ? sourceSessionId ?? sessionId
          : context.sourceSessionId ?? context.sessionId,
    );
    return {
      ...result,
      ..._runTextResult(
        stdout: result['output'] as String? ?? result['error'] as String? ?? '',
        exitCode: result['ok'] == true ? 0 : 1,
        startedAt: startedAt,
        error: result['error'] as String?,
        errorCode: result['error_code'] as String?,
      ),
    };
  }
}

Map<String, dynamic> _runTextResult({
  required String stdout,
  required int exitCode,
  required DateTime startedAt,
  String? error,
  String? errorCode,
}) {
  final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
  final output = '$stdout\n[exit:$exitCode | ${elapsedMs}ms]';
  final result = <String, dynamic>{
    'ok': exitCode == 0,
    'output': output,
    'exit_code': exitCode,
    'duration_ms': elapsedMs,
  };
  if (error != null) {
    result['error'] = error;
    result['error_code'] = errorCode ?? ToolErrorCode.internal.name;
  }
  return result;
}

String _helpFor(
  String? command, {
  String contentKind = contentKindNovel,
  required bool operations,
  required bool sessionOperations,
}) {
  if (command == null || command.isEmpty) {
    return _runHelpText(
      contentKind: contentKind,
      operations: operations,
      sessionOperations: sessionOperations,
    );
  }
  if ((!operations && _operationRunCommands.contains(command)) ||
      (!sessionOperations && _sessionRunCommands.contains(command))) {
    return _unknownCommandText(command);
  }
  if (command == 'assets') {
    return _assetsHelp;
  }
  if (command == 'providers') {
    return ProvidersRunCommandHandler.helpText;
  }
  if (bundledControlRunCommandToCallName.containsKey(command)) {
    return _bundledSkillCommandGuidance(command, contentKind: contentKind);
  }
  if (command == 'novel') {
    return _novelHelpText();
  }
  if (command == 'sessions') {
    return _sessionsHelpText();
  }
  if (command == 'map') {
    return _mapHelpText();
  }
  if (command == 'character') {
    return _characterHelpText();
  }
  if (command == 'item') {
    return _itemHelpText();
  }
  if (command == 'notify') {
    return _notifyHelpText();
  }
  return _unknownCommandText(command);
}

/// 依赖原生媒体能力的命令。
const _operationRunCommands = {
  'assets',
  'stagings',
  'styles',
  'editing',
  'production',
  'ffmpeg',
};

const _sessionRunCommands = {'files', 'operations', 'settings'};

String _operationHelpLines(String contentKind) =>
    '''  assets          List, read, view and certify this work's media assets.
  stagings        Read and edit staging documents, inspect frames and refresh previews. Load AgentSkill "${bundledControlSkillForRun('stagings', contentKind: contentKind)}".
  styles          Query visual styles; create and edit custom styles. Load AgentSkill "${bundledControlSkillForRun('styles', contentKind: contentKind)}".
  editing         Read and edit shared timelines, undo, preview and clean up previews. Load AgentSkill "${bundledControlRunCommandToCallName['editing']}".
  production      Generate saved clips or derive media from production nodes. Load AgentSkill "${bundledControlSkillForRun('production', contentKind: contentKind)}".
  ffmpeg          Inspect or process local media with explicit input/output arguments. Load AgentSkill "${bundledControlRunCommandToCallName['ffmpeg']}".
''';

String get _sessionHelpLines =>
    '''  settings        Open application settings for the user. Load AgentSkill "系统管理".
  files           Read local files; list or remove managed files with glob patterns. Load AgentSkill "${bundledControlRunCommandToCallName['files']}".
  operations      List, read, wait for, or cancel session operations. Load AgentSkill "${bundledControlRunCommandToCallName['operations']}".
''';

String _runHelpText({
  String contentKind = contentKindNovel,
  required bool operations,
  required bool sessionOperations,
}) {
  return '''Available commands:
${operations ? _operationHelpLines(contentKind) : ''}${sessionOperations ? _sessionHelpLines : ''}  providers       List configured providers and inspect chat, image, video and audio models.
  novel           Add the current quick-start draft novel to the library after user confirmation.
  sessions        List, read, and search saved AI conversations.
  map             Submit a map design draft for review in Cartographer.
  notify          Notify the Assistant with progress/question/complete/error.
  agent-rules     Manage AI rules. Load AgentSkill "${bundledControlRunCommandToCallName['agent-rules']}".
  agent-skills    Manage AI skills and their references. Load AgentSkill "${bundledControlRunCommandToCallName['agent-skills']}".
  subagents       Manage agents. Load AgentSkill "${bundledControlRunCommandToCallName['subagents']}".
  themes          Manage application color themes. Load AgentSkill "${bundledControlRunCommandToCallName['themes']}".
  character       Generate character images: generate-avatar, generate-photo.
  item            Generate item images: generate-photo.

For usage, load the indicated AgentSkill; otherwise use command=help subcommand=<command>.''';
}

String _bundledSkillCommandGuidance(
  String command, {
  String contentKind = contentKindNovel,
}) {
  final callName = bundledControlSkillForRun(command, contentKind: contentKind);
  if (callName == null) {
    throw StateError('Run command has no bundled skill mapping: $command');
  }
  return 'Command "$command" is documented by bundled AgentSkill '
      '"$callName". Load that skill for supported calls.';
}

Map<String, dynamic> _missingBundledSkillSubcommand(
  String command,
  DateTime startedAt, {
  String contentKind = contentKindNovel,
}) {
  return _runTextResult(
    stdout:
        '[error] command "$command" requires a subcommand\n'
        '${_bundledSkillCommandGuidance(command, contentKind: contentKind)}',
    exitCode: 1,
    startedAt: startedAt,
    error: '$command requires subcommand',
    errorCode: ToolErrorCode.invalid_argument.name,
  );
}

String _mapHelpText() {
  return '''Map commands:
  command=map subcommand=draft options={location, prompt, style?, custom_style?, resolution?, quality?, include_locations?, reference_current_image?}

draft submits a complete design to Cartographer for user review. It does not generate or adopt an image; submit once per design.
location is the id of the location that owns the map: a top-level world or any of its descendant locations (sub-map), copied from Read /locations; never invent ids. A sub-map covers only that location's descendants.
prompt must be a complete map-content prompt written in Chinese; it replaces the default content prompt and must not include the visual style. Keep place names verbatim; do not write "no text" when the map needs Chinese labels.
Submit the visual style separately with style; Cartographer appends the current selection when generating.
style: parchment | inkmap | engraving | realistic | woodcut | watercolor | atlas | custom (default: parchment)
custom_style is required when style=custom and contains the free-form visual style.
resolution: 1k | 2k | 4k (default: 2k)
quality: low | medium | high (default: medium)
include_locations (boolean, default: true): false only drops ordinary location candidates; territories still apply, and names already written in prompt stay.
reference_current_image (boolean, default: false): true attaches the current map image so its layout is kept; state the changes and what must stay in prompt.
No other options are accepted; Cartographer chooses any parent-map reference itself.''';
}

const _mapDraftOptions = {
  'location',
  'prompt',
  'style',
  'custom_style',
  'resolution',
  'quality',
  'include_locations',
  'reference_current_image',
};

String _characterHelpText() {
  return '''Character commands:
  command=character subcommand=generate-avatar options={character, prompt, asset_id?}
  command=character subcommand=generate-photo options={character, prompt, asset_id?}

generate-avatar creates a 1:1 avatar; generate-photo creates a 9:16 portrait photo or illustration.
character is the character id copied from Read; never invent ids.
Read the character profile before writing prompt, and keep its appearance anchors (hair, outfit, signature accessories) across images.
To reference the character avatar, pass its avatar_asset_id as asset_id.
asset_id is an optional reference image asset ID belonging to this work.''';
}

String _itemHelpText() {
  return '''Item commands:
  command=item subcommand=generate-photo options={item, prompt, asset_id?}

generate-photo creates a 9:16 portrait photo or illustration of the item.
item is the item id copied from Read; never invent ids. Read the item before writing prompt.
asset_id is an optional reference image asset ID belonging to this work.''';
}

String _usageForMapDraft() {
  return 'Usage: command=map subcommand=draft '
      'options={location, prompt, style?, custom_style?, resolution?, quality?, '
      'include_locations?, reference_current_image?}';
}

String _novelHelpText() {
  return '''Novel commands:
  command=novel subcommand=add-to-library options={}

add-to-library: add the current quick-start draft novel to the library
(clears the draft placeholder so it shows up on the shelf).''';
}

String _usageForAgentSkills(String subcommand) {
  return switch (subcommand) {
    'search' =>
      'Usage: command=agent-skills subcommand=search options={source?, query?, category?, tag?}',
    'get' =>
      'Usage: command=agent-skills subcommand=get options={source, source_id}',
    'install' =>
      'Usage: command=agent-skills subcommand=install options={source, source_id, call_name?, conflict_resolution?}',
    'reference-list' =>
      'Usage: command=agent-skills subcommand=reference-list options={name}',
    'reference-get' =>
      'Usage: command=agent-skills subcommand=reference-get options={name, path}',
    'reference-create' =>
      'Usage: command=agent-skills subcommand=reference-create options={name, path, content}',
    'reference-update' =>
      'Usage: command=agent-skills subcommand=reference-update options={name, path, content}',
    'reference-move' =>
      'Usage: command=agent-skills subcommand=reference-move options={name, path, new_path}',
    'reference-delete' =>
      'Usage: command=agent-skills subcommand=reference-delete options={name, path}',
    _ =>
      'Usage: command=agent-skills subcommand=list|create|update|delete|reference-list|reference-get|reference-create|reference-update|reference-move|reference-delete|search|get|install',
  };
}

String _notifyHelpText() {
  return '''Notify commands:
  command=notify subcommand=progress options={content}
  command=notify subcommand=question options={content}
  command=notify subcommand=complete options={content}
  command=notify subcommand=error options={content}

Notify the Assistant that launched this run. Use progress for milestones,
question when you need input, complete when finished, error on failure.''';
}

String _usageForSubjectImage(String operation) {
  return switch (operation) {
    'character.generate-avatar' =>
      'Usage: command=character subcommand=generate-avatar options={character, prompt, asset_id?}',
    'character.generate-photo' =>
      'Usage: command=character subcommand=generate-photo options={character, prompt, asset_id?}',
    _ =>
      'Usage: command=item subcommand=generate-photo options={item, prompt, asset_id?}',
  };
}

String _usageForNotify(String subcommand) {
  return switch (subcommand) {
    'progress' ||
    'question' ||
    'complete' ||
    'error' => 'Usage: command=notify subcommand=$subcommand options={content}',
    _ => 'Usage: command=notify subcommand=progress|question|complete|error',
  };
}

String _unknownCommandText(String command) {
  return '''[error] unknown command: $command
Use: command=help to list available commands.''';
}

String _unknownAgentSkillsSubcommandText(String subcommand) {
  return '''[error] unknown agent-skills command: $subcommand
${_bundledSkillCommandGuidance('agent-skills')}''';
}

String _unknownSubagentsSubcommandText(String subcommand) {
  return '''[error] unknown subagents command: $subcommand
${_bundledSkillCommandGuidance('subagents')}''';
}

String _sessionsHelpText() {
  return '''Sessions commands: list, read, search, get (read-only saved conversations).
  list options={work_id?, query?, mode?, parent_id?, limit?, cursor?}
  read options={work_id?, session_id?, scope?, kinds?, tool_name?, tool_status?, order?, limit?, cursor?, max_chars?}
  search options={query, work_id?, session_id?, scope?, kinds?, tool_name?, tool_status?, order?, limit?, cursor?, max_chars?}
  get options={id, block_id?, work_id?, session_id?, scope?, kinds?, tool_name?, tool_status?, cursor?, max_chars?}

work_id defaults to the current work. Cross-work reads require explicit work_id.
session_id overrides scope selection. scope: source (default) is the session that started this Agent run;
current is this Agent session, including a reused SubAgent. list and explicit IDs require no active session.
search also accepts scope=work to discover sessions by body content; do not combine with session_id.
list.query matches literal title substrings; search.query is required and matches literal filtered content.
mode: chat/council/monologue/theater/roleplay. parent_id selects direct children.
kinds: nonempty array of user/assistant/tool/summary/system, default ["user","assistant"].
user excludes internal reminders, summaries, and tool results. assistant excludes thinking.
tool includes saved block arguments/results/errors and legacy tool-result records.
tool_name is an exact registered name; tool_status: pending/rejected/cancelled/running/success/error.
Tool filters default kinds to ["tool"]; explicit kinds must include tool. Other kinds remain unaffected.
order: asc/desc (read defaults asc, search desc). list uses updated_at/id descending.
limit: distinct messages or sessions, default 20, range 1..100.
max_chars: total text Unicode code points, default 12000, range 1000..20000.
Results contain true message/block IDs, stable part_index, text_offset, and truncated flags.
Read data.items; output only reports counts. Work search adds session_id/session_title/session_mode.
Continue with next_cursor and unchanged options; only limit/max_chars may change.
A cursor whose target disappeared is invalid: restart the query. No snapshot or retention is created.
Examples:
  {"command":"sessions","subcommand":"search","options":{"scope":"work","query":"motivation"}}
  {"command":"sessions","subcommand":"read","options":{"session_id":"<real id>","kinds":["user"]}}
  {"command":"sessions","subcommand":"get","options":{"session_id":"<real id>","id":"<message id>","kinds":["tool"],"block_id":"<block id>"}}''';
}

String _unknownNotifySubcommandText(String subcommand) {
  return '''[error] unknown notify command: $subcommand
Available: progress, question, complete, error
Use: command=help subcommand=notify''';
}
