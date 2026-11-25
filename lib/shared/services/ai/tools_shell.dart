// 职责: 将顶层 Bash 和 PowerShell 工具接入现有审批，并运行和停止本机进程。
// 关联文件:
//   lib/shared/services/ai/tools.dart
//   lib/shared/services/ai/tool_operations.dart
//   lib/shared/services/ai/files/command_paths.dart
//   lib/shared/models/tool_permission.dart
part of 'tools.dart';

const _shellTimeoutMs = 120000;
const _shellOutputLimit = 32 * 1024;
const _shellStopTimeout = Duration(seconds: 3);
const _shellUsageGuideline =
    'Use this tool only when the user explicitly asks you to execute a shell '
    'command, or when completing the task requires a local program that no '
    'available dedicated tool can invoke.';
const _shellInputSchema = {
  'type': 'object',
  'properties': {
    'command': {
      'type': 'string',
      'description': 'Command or script to execute.',
    },
    'workdir': {
      'type': 'string',
      'description':
          'Working directory. Defaults to the current work’s file directory.',
    },
    'timeout': {
      'type': 'integer',
      'minimum': 1,
      'default': _shellTimeoutMs,
      'description': 'Process execution timeout in milliseconds.',
    },
  },
  'required': ['command'],
  'additionalProperties': false,
};

ToolDef? get _desktopShell {
  if (Platform.isWindows) {
    return ToolDef(
      name: powerShellToolName,
      outputSchema: _builtinToolOutputSchema(powerShellToolName),
      description:
          '$_shellUsageGuideline\n\n'
          'Execute a local PowerShell command on Windows. Use PowerShell syntax '
          'and Windows paths. To treat a file path literally with a cmdlet, '
          'use -LiteralPath when available. The completed run returns '
          'exit_code, stdout and stderr in result.',
      inputSchema: _shellInputSchema,
    );
  }
  if (Platform.isMacOS || Platform.isLinux) {
    return ToolDef(
      name: bashToolName,
      outputSchema: _builtinToolOutputSchema(bashToolName),
      description:
          '$_shellUsageGuideline\n\n'
          'Execute a local Bash command. Use Bash syntax and quote file paths '
          'as shell arguments. The completed run returns exit_code, stdout '
          'and stderr in result.',
      inputSchema: _shellInputSchema,
    );
  }
  return null;
}

bool _availableOnPlatform(String name) =>
    (name != bashToolName && name != powerShellToolName) ||
    name == _desktopShell?.name;

extension _ShellTool on AiToolManager {
  Future<Map<String, dynamic>> _runShell(
    ToolDef shell,
    Map<String, dynamic> input,
    String? callId,
  ) async {
    final context = _currentToolExecutionContext;
    final operations = operationHost?.operations;
    final activeWorkId = workId;
    if (context == null ||
        operations == null ||
        activeWorkId == null ||
        activeWorkId.isEmpty) {
      return {
        'ok': false,
        'error_code': 'unavailable',
        'error': 'Local commands require an active work session.',
      };
    }
    try {
      final command = input['command'];
      final workdirInput = input['workdir'];
      final timeout = input['timeout'] ?? _shellTimeoutMs;
      if (command is! String ||
          command.trim().isEmpty ||
          command.contains('\u0000') ||
          (input.containsKey('workdir') &&
              (workdirInput is! String || workdirInput.trim().isEmpty)) ||
          (input.containsKey('timeout') && input['timeout'] == null) ||
          timeout is! int ||
          timeout < 1 ||
          input.keys.any((key) => !_shellInputSchemaProperties.contains(key))) {
        throw const FormatException(
          'Use a nonempty command, an optional working directory and a positive timeout in milliseconds.',
        );
      }
      final paths = CommandPaths(SessionFiles(novelId: activeWorkId));
      final requestedDirectory = Directory(
        workdirInput is String ? paths.absolute(workdirInput) : paths.root,
      );
      final workdir = workdirInput == null
          ? requestedDirectory.path
          : await _resolveShellWorkdir(requestedDirectory);

      Future<void> verifyWorkdir() async {
        final current = await _resolveShellWorkdir(requestedDirectory);
        if (!p.equals(current, workdir)) {
          throw const ToolOperationException(
            'conflict',
            'The working directory changed while this command was pending. '
                'Request the command again to approve the new directory.',
          );
        }
      }

      return await operations.start(
        context: context,
        callId: _nextCallId(shell.name, ref: callId),
        workId: activeWorkId,
        kind: shellExecutePermission,
        targetPath: workdir,
        toolName: shell.name,
        background: false,
        input: input,
        permission: ToolActionRequest(
          action: shellExecutePermission,
          context: ToolPermissionContext(
            workId: activeWorkId,
            sessionId: context.sourceSessionId ?? context.sessionId,
            episodeId: currentEpisodeId,
          ),
          targetPath: workdir,
          summary: {'command': command},
        ),
        verifyTarget: () async {
          if (workdirInput == null) {
            if (!p.equals(paths.root, workdir)) {
              throw const ToolOperationException(
                'conflict',
                'The work file directory changed while this command was pending.',
              );
            }
            await paths.checkRelative('.');
            await requestedDirectory.create(recursive: true);
          }
          await verifyWorkdir();
        },
        execute: (operation) => _executeShell(
          operation,
          command: command,
          workdir: workdir,
          timeout: Duration(milliseconds: timeout),
          verifyWorkdir: verifyWorkdir,
        ),
      );
    } on FormatException catch (error) {
      return {
        'ok': false,
        'error_code': 'invalid_argument',
        'error': error.message,
      };
    } on ToolOperationException catch (error) {
      return {
        'ok': false,
        'error_code': error.code,
        'error': error.message,
        if (error.hint != null) 'hint': error.hint,
      };
    }
  }
}

const _shellInputSchemaProperties = {'command', 'workdir', 'timeout'};

Future<String> _resolveShellWorkdir(Directory directory) async {
  try {
    final resolved = await directory.resolveSymbolicLinks();
    if (await Directory(resolved).exists()) {
      return resolved;
    }
  } on PathNotFoundException {
    throw const ToolOperationException(
      'not_found',
      'The working directory does not exist.',
    );
  } on FileSystemException catch (error) {
    throw ToolOperationException(
      'failed_precondition',
      'Could not resolve the working directory: ${error.osError?.message ?? error.message}',
    );
  }
  throw const ToolOperationException(
    'not_found',
    'The working directory does not exist.',
  );
}

// Job control gives the command its own process group, including any workers
// it starts. The outer Bash can then stop the group when the tool is cancelled.
const _bashLauncher = r'''
set -m
stop() { if [[ -n "$!" ]]; then kill -KILL -- "-$!" 2>/dev/null || :; fi; }
trap 'stop; exit 143' TERM
"$BASH" --noprofile --norc -c "$1" &
wait "$!" 2>/dev/null
status=$?
stop
exit "$status"
''';

@visibleForTesting
Future<String> resolveWindowsPowerShellExecutable(
  Map<String, String> environment, {
  required String windowsSystem,
  required Future<bool> Function(String) fileExists,
}) async {
  final programFiles = environment['ProgramFiles'];
  final directories = [
    ...?environment['PATH']?.split(';'),
    if (programFiles != null && programFiles.isNotEmpty)
      p.windows.join(programFiles, 'PowerShell', '7'),
  ];
  for (final entry in directories) {
    var directory = entry.trim();
    if (directory.length > 1 &&
        directory.startsWith('"') &&
        directory.endsWith('"')) {
      directory = directory.substring(1, directory.length - 1);
    }
    // Resolve only full paths so the workdir cannot change the interpreter.
    if (!p.windows.isAbsolute(directory) ||
        p.windows.isRootRelative(directory)) {
      continue;
    }
    final executable = p.windows.join(directory, 'pwsh.exe');
    if (await fileExists(executable)) {
      return executable;
    }
  }
  return p.windows.join(
    windowsSystem,
    'System32',
    'WindowsPowerShell',
    'v1.0',
    'powershell.exe',
  );
}

Future<Map<String, dynamic>> _executeShell(
  ToolOperationContext operation, {
  required String command,
  required String workdir,
  required Duration timeout,
  required Future<void> Function() verifyWorkdir,
}) async {
  operation.checkCancelled();
  final windows = Platform.isWindows;
  final windowsSystem = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  final executable = windows
      ? await resolveWindowsPowerShellExecutable(
          Platform.environment,
          windowsSystem: windowsSystem,
          fileExists: (path) => File(path).exists(),
        )
      : Platform.isMacOS
      ? '/bin/bash'
      : 'bash';
  const powerShellUtf8 =
      r'[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)';
  final arguments = windows
      ? [
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-EncodedCommand',
          base64Encode([
            for (final unit in '$powerShellUtf8\n$command'.codeUnits) ...[
              unit & 0xff,
              unit >> 8,
            ],
          ]),
        ]
      : ['--noprofile', '--norc', '-c', _bashLauncher, 'bash', command];
  final Process process;
  try {
    await verifyWorkdir();
    operation.checkCancelled();
    process = await Process.start(
      executable,
      arguments,
      workingDirectory: workdir,
      environment: Platform.isMacOS
          ? {
              'PATH':
                  '${Platform.environment['PATH'] ?? '/usr/bin:/bin:/usr/sbin:/sbin'}:/opt/homebrew/bin:/usr/local/bin',
            }
          : null,
    );
  } on ProcessException catch (error) {
    throw ToolOperationException(
      'unavailable',
      'Could not start ${p.basename(executable)}: ${error.message}',
    );
  }
  final stdout = _ShellOutput();
  final stderr = _ShellOutput();
  final stdoutSub = process.stdout.listen(stdout.add);
  final stderrSub = process.stderr.listen(stderr.add);
  int? exitCode;
  final completed = Future.wait<void>([
    process.stdin.close().then<void>((_) {}),
    process.exitCode.then((code) {
      exitCode = code;
    }),
    stdoutSub.asFuture<void>(),
    stderrSub.asFuture<void>(),
  ]);
  final stopped = Completer<String?>();
  final unlink = operation.cancellation.onCancel(() {
    if (!stopped.isCompleted) {
      stopped.complete('cancelled');
    }
  });
  final timer = Timer(timeout, () {
    if (!stopped.isCompleted) {
      stopped.complete('timeout');
    }
  });
  try {
    final reason = await Future.any<String?>([
      completed.then((_) => null),
      stopped.future,
    ]);
    if (reason != null) {
      if (exitCode == null) {
        await _stopShell(process, windowsSystem);
      }
      try {
        await completed.timeout(_shellStopTimeout);
      } on TimeoutException {
        if (exitCode == null) {
          process.kill(ProcessSignal.sigkill);
        }
      }
    }
    return {
      'ok': reason == null,
      'exit_code': exitCode,
      'stdout': stdout.text,
      'stderr': stderr.text,
      if (stdout.truncated) 'stdout_truncated': true,
      if (stderr.truncated) 'stderr_truncated': true,
      if (reason == 'cancelled') ...{
        'error_code': 'cancelled',
        'error': 'The local command was cancelled.',
        'cancelled': true,
      } else if (reason == 'timeout') ...{
        'error_code': 'deadline_exceeded',
        'error': 'The local command timed out.',
        'timed_out': true,
      },
    };
  } finally {
    unlink();
    timer.cancel();
    await Future.wait<void>([stdoutSub.cancel(), stderrSub.cancel()]);
  }
}

Future<void> _stopShell(Process process, String windowsSystem) async {
  if (!Platform.isWindows) {
    process.kill();
    return;
  }
  try {
    final result = await Process.run(
      p.join(windowsSystem, 'System32', 'taskkill.exe'),
      ['/PID', '${process.pid}', '/T', '/F'],
    ).timeout(_shellStopTimeout);
    if (result.exitCode != 0 && !process.kill()) {
      _log.warning('Could not stop the Windows shell process tree.');
    }
  } on Exception catch (error, stackTrace) {
    if (!process.kill()) {
      _log.error(
        'Could not stop the Windows shell process tree.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

class _ShellOutput {
  final _bytes = BytesBuilder(copy: false);
  bool truncated = false;

  void add(List<int> bytes) {
    final remaining = _shellOutputLimit - _bytes.length;
    if (bytes.length <= remaining) {
      _bytes.add(bytes);
    } else {
      _bytes.add(bytes.sublist(0, remaining));
      truncated = true;
    }
  }

  String get text => utf8.decode(_bytes.takeBytes(), allowMalformed: true);
}
