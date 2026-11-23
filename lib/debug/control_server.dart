// 职责: 调试用本地控制端点 —— 让外部脚本 / DSH 插件在应用内执行批量任务。
//       仅 debug 构建启动；只监听 loopback，带一次性 token。
// 关联文件:
//   lib/main.dart
//   lib/shared/providers/ai_providers.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/models/cover_style.dart
//   lib/shared/services/ai/image.dart
// 遵循的 Rules:
//   .agents/rules/error-handling.md
//   .agents/rules/service-naming.md
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:drift/drift.dart' show Value, Variable;

import '../shared/database/app_database.dart';
import '../shared/database/novel_content_database.dart'
    show CharacterProfile, ItemsCompanion, NovelContentDatabase;
import '../shared/logger/app_logger.dart';
import '../shared/models/ai_chat_models.dart';
import '../shared/models/screenplay_element.dart';
import '../shared/models/asset_purpose.dart';
import '../shared/models/subject_photo.dart';
import '../shared/models/narration.dart';
import '../shared/providers/ai_providers.dart';
import '../shared/providers/production_audio.dart';
import '../shared/providers/video_tasks.dart';
import '../shared/providers/storyboard.dart';
import '../shared/providers/production_media.dart';
import '../shared/providers/novel_providers.dart';
import '../shared/providers/screenplay_providers.dart';
import '../shared/services/ai/headless_session_turn.dart';
import '../shared/services/ai/image.dart';
import '../shared/services/novel_content.dart';
import '../shared/services/production/canvas_service.dart';
import '../shared/services/production/generate_orchestrator.dart';
import '../shared/services/production/ffmpeg_runner.dart';
import '../shared/services/screenplay/narration_service.dart';
import '../shared/services/screenplay_metrics.dart';
import '../shared/services/storyboard/service.dart';
import '../shared/utils/storage_paths.dart';

final _log = AppLogger.forModule('DebugControl');

/// 端点描述文件：外部工具从这里读取端口与 token。
const _descriptorDirectory = 'debug';
const _descriptorFile = 'control.json';

/// 批量生图的数量上限：每次请求最多生成这么多张，避免一次调用烧掉大量额度。
const _maxBatchSize = 20;

class DebugControlServer {
  DebugControlServer(this._container);

  static DebugControlServer? _instance;

  /// 由 main.dart 在 debug 构建下调用一次；重复调用不会重复监听。
  static Future<void> start(ProviderContainer container) async {
    final server = _instance ??= DebugControlServer(container);
    await server._start();
  }

  final ProviderContainer _container;
  HttpServer? _server;
  String _token = '';
  final String _startedAt = DateTime.now().toUtc().toIso8601String();
  final Map<String, Map<String, dynamic>> _jobs = <String, Map<String, dynamic>>{};
  int _jobSequence = 0;

  bool get isRunning => _server != null;
  int get port => _server?.port ?? 0;

  Future<void> _start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.autoCompress = true;
    _token = _randomToken();
    _server = server;
    await _writeDescriptor();
    server.listen(
      (request) => unawaited(_handle(request)),
      onError: (Object error, StackTrace stackTrace) {
        _log.warning('control server socket error: $error');
      },
    );
    _log.info('control endpoint listening on 127.0.0.1:${server.port}');
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    final file = _descriptorPath();
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// 描述文件里带齐端口、token 与 pid；插件据此访问，无需用户手工传参。
  Future<Map<String, Object?>> descriptor() async => {
        'version': 1,
        'port': port,
        'token': _token,
        'pid': pid,
        'startedAt': _startedAt,
      };

  Future<File> _writeDescriptor() async {
    final file = _descriptorPath();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(await descriptor()),
    );
    return file;
  }

  File _descriptorPath() => File(
        p.join(
          RevericPaths.supportRoot,
          _descriptorDirectory,
          _descriptorFile,
        ),
      );

  String _randomToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (!_isAuthorized(request)) {
        await _writeJson(response, HttpStatus.unauthorized, {
          'error': 'unauthorized',
          'hint': 'Send Authorization: Bearer <token> from debug/control.json',
        });
        return;
      }
      final body = await _readJsonBody(request);
      final path = request.uri.path;
      switch (path) {
        case '/status':
          await _writeJson(response, HttpStatus.ok, await _status());
          return;
        case '/characters':
          await _writeJson(response, HttpStatus.ok, await _characters(request));
          return;
        case '/avatar':
          await _writeJson(response, HttpStatus.ok, await _avatar(body));
          return;
        case '/avatars/batch':
          await _writeJson(response, HttpStatus.ok, await _avatarsBatch(body));
          return;
        case '/audio/tts':
          await _writeJson(response, HttpStatus.ok, await _speak(body));
          return;
        case '/production/item-clip':
          await _writeJson(response, HttpStatus.ok, await _itemClip(body));
          return;
        case '/production/prop':
          await _writeJson(response, HttpStatus.ok, await _createProp(body));
          return;
        case '/production/import-audio':
          await _writeJson(response, HttpStatus.ok, await _importAudio(body));
          return;
        case '/production/generate-video':
          await _writeJson(response, HttpStatus.ok, await _generateVideo(body));
          return;
        case '/production/shots':
          await _writeJson(response, HttpStatus.ok, await _createShots(body));
          return;
        case '/production/clip-image':
          await _writeJson(response, HttpStatus.ok, await _clipImage(body));
          return;
        case '/screenplay/check':
          await _writeJson(response, HttpStatus.ok, await _checkScreenplay(body));
          return;
        case '/screenplay/replace-text':
          await _writeJson(
            response,
            HttpStatus.ok,
            await _replaceScreenplayText(body),
          );
          return;
        case '/agent/turn':
          await _writeJson(response, HttpStatus.ok, await _agentTurn(body));
          return;
        case '/jobs':
          await _writeJson(response, HttpStatus.ok, {'jobs': _jobs.values.toList()});
          return;
        default:
          if (path.startsWith('/jobs/')) {
            final id = path.substring('/jobs/'.length);
            final job = _jobs[id];
            await _writeJson(
              response,
              job == null ? HttpStatus.notFound : HttpStatus.ok,
              job ?? {'error': 'job_not_found', 'id': id},
            );
            return;
          }
          await _writeJson(response, HttpStatus.notFound, {
            'error': 'not_found',
            'path': path,
          });
      }
    } on _ControlError catch (error) {
      await _writeJson(response, HttpStatus.badRequest, {
        'error': error.code,
        'message': error.message,
      });
    } catch (error, stackTrace) {
      _log.error('request failed ${request.uri}', error: error, stackTrace: stackTrace);
      await _writeJson(response, HttpStatus.internalServerError, {
        'error': 'internal_error',
        'message': '$error',
      });
    }
  }

  bool _isAuthorized(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    return header == 'Bearer $_token';
  }

  Future<Map<String, dynamic>> _readJsonBody(HttpRequest request) async {
    if (request.method == 'GET') return const {};
    final content = await utf8.decoder.bind(request).join();
    if (content.trim().isEmpty) return const {};
    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Request body must be a JSON object');
    }
    return decoded;
  }

  Future<void> _writeJson(
    HttpResponse response,
    int status,
    Map<String, dynamic> body,
  ) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  // ---------------------------------------------------------------- 路由实现

  Future<Map<String, dynamic>> _status() async {
    final database = _container.read(appDatabaseProvider);
    final rows = await database.select(database.novels).get();
    final imageModelConfigured = _container.read(isImageGenerationConfiguredProvider);
    return {
      'version': 1,
      'workCount': rows.length,
      'imageModelConfigured': imageModelConfigured,
      'works': [
        for (final row in rows)
          {
            'id': row.id,
            'title': row.title,
            'contentKind': row.contentKind,
            'wordCount': row.wordCount,
            'databasePath': row.contentDatabasePath,
            'updatedAt': row.updatedAt.toIso8601String(),
          },
      ],
      'jobs': _jobs.length,
      'startedAt': _startedAt,
    };
  }

  Future<Map<String, dynamic>> _characters(HttpRequest request) async {
    final workId = request.uri.queryParameters['workId'] ?? '';
    final work = await _requireWork(workId);
    final characters = await (_contentService(work.databasePath)).getCharacterProfiles();
    return {
      'workId': work.id,
      'title': work.title,
      'characters': [
        for (final character in characters)
          {
            'id': character.id,
            'name': character.name,
            'role': character.role,
            'gender': character.gender,
            'age': character.age,
            'hasAvatar': (character.avatarAssetId ?? '').isNotEmpty,
            'appearanceChars': character.appearance.length,
          },
      ],
    };
  }

  Future<Map<String, dynamic>> _avatar(Map<String, dynamic> body) async {
    final workId = _stringOption(body, 'workId');
    final characterId = _stringOption(body, 'characterId');
    final dryRun = body['dryRun'] == true;
    final work = await _requireWork(workId);
    final service = _contentService(work.databasePath);
    final character = await service.getCharacterProfileById(characterId);
    if (character == null) {
      throw _ControlError('character_not_found', 'No character $characterId in $workId');
    }
    final style = _resolveStyle(body);
    final prompt = _stringOption(body, 'prompt', fallback: '').trim().isEmpty
        ? _buildAvatarPrompt(character, style)
        : _stringOption(body, 'prompt');
    if (dryRun) {
      return {'dryRun': true, 'workId': workId, 'characterId': characterId, 'prompt': prompt};
    }
    final result = await _generateImage(workId, prompt);
    final assetId = result.assetId;
    if (assetId == null || assetId.isEmpty) {
      throw _ControlError('asset_missing', 'Image generation returned no registered asset');
    }
    if (body['apply'] != false) {
      await service.updateCharacterAvatarAndPhotos(
        entryId: characterId,
        avatarAssetId: assetId,
      );
    }
    return {
      'workId': workId,
      'characterId': characterId,
      'characterName': character.name,
      'assetId': assetId,
      'applied': body['apply'] != false,
      'prompt': prompt,
    };
  }

  Future<Map<String, dynamic>> _avatarsBatch(Map<String, dynamic> body) async {
    final workId = _stringOption(body, 'workId');
    final dryRun = body['dryRun'] == true;
    final apply = body['apply'] != false;
    final limit = _intOption(body, 'limit', fallback: _maxBatchSize, min: 1, max: _maxBatchSize);
    final work = await _requireWork(workId);
    final service = _contentService(work.databasePath);
    final style = _resolveStyle(body);

    final requested = (body['characterIds'] as List?)?.whereType<String>().toList() ??
        (body['names'] as List?)?.whereType<String>().toList() ??
        const <String>[];
    final profiles = await service.getCharacterProfiles();
    final selected = <CharacterProfile>[];
    if (requested.isEmpty) {
      selected.addAll(profiles.where((c) => (c.avatarAssetId ?? '').isEmpty));
    } else {
      for (final key in requested) {
        final match = profiles.where((c) => c.id == key || c.name == key).toList();
        if (match.isEmpty) {
          throw _ControlError('character_not_found', 'No character named $key in $workId');
        }
        selected.add(match.first);
      }
    }
    if (selected.length > limit) {
      throw _ControlError(
        'limit_exceeded',
        'Requested ${selected.length} characters, limit is $limit',
      );
    }

    final jobId = 'job_${++_jobSequence}_${DateTime.now().millisecondsSinceEpoch}';
    final job = <String, dynamic>{
      'id': jobId,
      'workId': workId,
      'state': dryRun ? 'planned' : 'running',
      'dryRun': dryRun,
      'startedAt': DateTime.now().toUtc().toIso8601String(),
      'items': <Map<String, dynamic>>[],
    };
    _jobs[jobId] = job;

    for (final character in selected) {
      final prompt = _buildAvatarPrompt(character, style);
      final item = <String, dynamic>{
        'characterId': character.id,
        'name': character.name,
        'prompt': prompt,
      };
      (job['items'] as List).add(item);
      if (dryRun) {
        item['state'] = 'planned';
        continue;
      }
      try {
        final result = await _generateImage(workId, prompt);
        final assetId = result.assetId;
        if (assetId == null || assetId.isEmpty) {
          throw _ControlError('asset_missing', 'No registered asset for ${character.name}');
        }
        if (apply) {
          await service.updateCharacterAvatarAndPhotos(
            entryId: character.id,
            avatarAssetId: assetId,
          );
        }
        item
          ..['state'] = 'done'
          ..['assetId'] = assetId
          ..['applied'] = apply;
      } catch (error, stackTrace) {
        _log.error(
          'batch avatar failed for ${character.name}',
          error: error,
          stackTrace: stackTrace,
        );
        item
          ..['state'] = 'failed'
          ..['error'] = '$error';
      }
    }
    job['state'] = dryRun ? 'planned' : 'completed';
    job['finishedAt'] = DateTime.now().toUtc().toIso8601String();
    return job;
  }

  static const _readOnlySeedPrefix =
      '【只读模式】本次是只读检查任务：只允许读取、检索、统计与核对，'
      '不要修改任何文件、设定或剧本，也不要生成图片、视频或音频。'
      '如果必须写入才能完成，请直接说明需要写权限，不要自行修改。\n\n任务：\n';

  /// 把一个自然语言任务交给应用内智能体跑一轮（复用 headless 会话）。
  ///
  /// 只读模式只是在 seed 里明确约束并依赖应用的工具权限流程；它不是硬沙箱，
  /// 需要硬隔离时用 DSH 侧的工具策略或人工确认。
  Future<Map<String, dynamic>> _agentTurn(Map<String, dynamic> body) async {
    final workId = _stringOption(body, 'workId');
    final message = _stringOption(body, 'message');
    if (message.trim().isEmpty) {
      throw const _ControlError('message_required', 'message is required');
    }
    final mode = _stringOption(body, 'mode', fallback: 'readOnly');
    final timeoutSeconds = _intOption(
      body,
      'timeoutSeconds',
      fallback: 180,
      min: 20,
      max: 900,
    );
    final work = await _requireWork(workId);
    final title = _stringOption(
      body,
      'title',
      fallback: '调试端点 · ${work.title}',
    );
    final started = await startHeadlessRun(
      _container,
      novelId: workId,
      seed: mode == 'write' ? message : '$_readOnlySeedPrefix$message',
      title: title,
      metadata: const {'source': 'debug_control_endpoint'},
    );
    final sessionId = started.sessionId;
    if (sessionId == null || started.outcome != HeadlessRunOutcome.started) {
      return {
        'dispatched': false,
        'outcome': started.outcome.name,
        'error': started.error,
      };
    }

    // 会话 provider 是 autoDispose：先持订阅，保证轮询与取结果期间不被回收。
    final keepAlive = _container.listen(aiChatSessionProvider(sessionId), (_, _) {});
    try {
      final deadline = DateTime.now().add(Duration(seconds: timeoutSeconds));
      while (DateTime.now().isBefore(deadline)) {
        final runtime = _container.read(aiChatRuntimeProvider(sessionId));
        if (!runtime.isRequestInFlight) break;
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      final timedOut = DateTime.now().isAfter(deadline);
      final session = _container.read(aiChatSessionProvider(sessionId));
      final messages = session.messages;
      String? reply;
      for (final message in messages.reversed) {
        if (message.role == AiMessageRole.assistant &&
            message.content.trim().isNotEmpty) {
          reply = message.content;
          break;
        }
      }
      return {
        'dispatched': true,
        'mode': mode,
        'workId': workId,
        'sessionId': sessionId,
        'timedOut': timedOut,
        'messageCount': messages.length,
        'reply': reply,
      };
    } finally {
      keepAlive.close();
    }
  }

  static const _backupDirectoryName = 'backups';

  /// 只读体检：场次结构、元素顺序、统计一致性、出场名单覆盖。
  Future<Map<String, dynamic>> _checkScreenplay(Map<String, dynamic> body) async {
    final workId = _stringOption(body, 'workId');
    final work = await _requireWork(workId);
    final database = _container.read(
      novelContentDatabaseProvider(work.databasePath),
    );
    final episodes = await _selectEpisodes(database, body);
    final issues = <Map<String, dynamic>>[];
    final perEpisode = <Map<String, dynamic>>[];

    for (final episode in episodes) {
      final episodeId = episode['id'] as String;
      final number = episode['episode_number'] as int;
      final scenes = await database.screenplayDao.getSceneRows(episodeId);
      final elements = await database.screenplayDao.getDocumentElements(episodeId);

      // 同一集内 sort_order 重复：元素表用 (episode_id, sort_order) 唯一索引。
      final duplicates = await database.customSelect(
        'SELECT sort_order, COUNT(*) AS c FROM screenplay_scene_elements '
        'WHERE episode_id = ? AND deleted_at = 0 '
        'GROUP BY sort_order HAVING c > 1',
        variables: [Variable.withString(episodeId)],
      ).get();
      for (final row in duplicates) {
        issues.add({
          'episode': number,
          'kind': 'duplicate_sort_order',
          'sortOrder': row.read<int>('sort_order'),
          'count': row.read<int>('c'),
        });
      }

      final byScene = <String, List<ScreenplayElement>>{};
      for (final element in elements) {
        final sceneId = element.sceneId;
        if (sceneId == null) continue;
        byScene.putIfAbsent(sceneId, () => []).add(element);
      }

      var emptyScenes = 0;
      var metricMismatches = 0;
      var castMisses = 0;
      for (final scene in scenes) {
        final sceneElements = byScene[scene.id] ?? const <ScreenplayElement>[];
        final body = sceneElements
            .where((element) => element.type != ScreenplayElementType.scene_heading)
            .toList();
        if (body.isEmpty) {
          emptyScenes += 1;
          issues.add({'episode': number, 'kind': 'empty_scene', 'sceneId': scene.id});
        }
        final headings = sceneElements.where(
          (element) => element.type == ScreenplayElementType.scene_heading,
        );
        if (headings.length != 1) {
          issues.add({
            'episode': number,
            'kind': 'heading_count',
            'sceneId': scene.id,
            'count': headings.length,
          });
        }
        final metrics = ScreenplayMetrics.calculate(body);
        if (metrics.pageEighths != scene.pageEighths ||
            metrics.dialogueLineCount != scene.dialogueLineCount ||
            metrics.wordCount != scene.wordCount) {
          metricMismatches += 1;
          issues.add({
            'episode': number,
            'kind': 'metrics_mismatch',
            'sceneId': scene.id,
            'stored': {
              'pageEighths': scene.pageEighths,
              'dialogueLineCount': scene.dialogueLineCount,
              'wordCount': scene.wordCount,
            },
            'computed': {
              'pageEighths': metrics.pageEighths,
              'dialogueLineCount': metrics.dialogueLineCount,
              'wordCount': metrics.wordCount,
            },
          });
        }
        // 对白/括注必须紧跟角色提示；角色提示必须出现在出场名单里。
        final cast = await database.screenplayDao.getSceneCharacters(scene.id);
        final castIds = cast.map((row) => row.characterId).toSet();
        var active = false;
        for (final element in body) {
          switch (element.type) {
            case ScreenplayElementType.character:
              active = true;
              final characterId = element.characterId;
              if (characterId != null && !castIds.contains(characterId)) {
                castMisses += 1;
                issues.add({
                  'episode': number,
                  'kind': 'cast_missing',
                  'sceneId': scene.id,
                  'characterId': characterId,
                });
              }
            case ScreenplayElementType.dialogue:
            case ScreenplayElementType.parenthetical:
              if (!active) {
                issues.add({
                  'episode': number,
                  'kind': 'orphan_dialogue',
                  'sceneId': scene.id,
                  'elementId': element.id,
                });
              }
              if (element.type == ScreenplayElementType.dialogue) active = false;
            default:
              active = false;
          }
        }
      }

      perEpisode.add({
        'episode': number,
        'title': episode['title'],
        'scenes': scenes.length,
        'elements': elements.length,
        'emptyScenes': emptyScenes,
        'metricMismatches': metricMismatches,
        'castMisses': castMisses,
      });
    }

    return {
      'workId': workId,
      'title': work.title,
      'episodes': perEpisode,
      'issueCount': issues.length,
      'issues': issues.take(200).toList(),
      'truncated': issues.length > 200,
    };
  }

  /// 批量文本替换：默认 dry-run，只有 apply:true 才写库，写前先备份内容库。
  Future<Map<String, dynamic>> _replaceScreenplayText(
    Map<String, dynamic> body,
  ) async {
    final workId = _stringOption(body, 'workId');
    final find = _stringOption(body, 'find');
    final replace = _stringOption(body, 'replace', fallback: '');
    if (find.isEmpty) {
      throw const _ControlError('find_required', 'find must not be empty');
    }
    final apply = body['apply'] == true;
    final work = await _requireWork(workId);
    final database = _container.read(
      novelContentDatabaseProvider(work.databasePath),
    );
    final service = _container.read(screenplayServiceProvider(work.databasePath));
    final episodes = await _selectEpisodes(database, body);

    final matches = <Map<String, dynamic>>[];
    final pending = <({String sceneId, List<ScreenplayElement> elements})>[];
    for (final episode in episodes) {
      final episodeId = episode['id'] as String;
      final number = episode['episode_number'] as int;
      final scenes = await database.screenplayDao.getSceneRows(episodeId);
      for (final scene in scenes) {
        final elements = await database.screenplayDao.getDocumentElements(
          episodeId,
        );
        final sceneElements = elements
            .where((element) => element.sceneId == scene.id)
            .toList();
        var changed = false;
        final updated = <ScreenplayElement>[];
        for (final element in sceneElements) {
          if (element.type == ScreenplayElementType.scene_heading) continue;
          final text = element.text;
          if (text.contains(find)) {
            changed = true;
            final next = text.replaceAll(find, replace);
            matches.add({
              'episode': number,
              'sceneId': scene.id,
              'elementId': element.id,
              'type': element.type.name,
              'before': _snippet(text, find),
              'after': _snippet(next, replace.isEmpty ? find : replace),
            });
            updated.add(element.copyWith(text: next));
          } else {
            updated.add(element);
          }
        }
        if (changed) {
          pending.add((sceneId: scene.id, elements: updated));
        }
      }
    }

    final result = <String, dynamic>{
      'workId': workId,
      'title': work.title,
      'find': find,
      'replace': replace,
      'apply': apply,
      'episodes': episodes.map((e) => e['episode_number']).toList(),
      'matchCount': matches.length,
      'sceneCount': pending.length,
      'matches': matches.take(100).toList(),
      'truncated': matches.length > 100,
    };
    if (!apply || pending.isEmpty) {
      return result;
    }

    final backup = await _backupDatabase(database, workId);
    for (final item in pending) {
      await service.writeElements(sceneId: item.sceneId, elements: item.elements);
    }
    result['backup'] = backup;
    result['writtenScenes'] = pending.length;
    return result;
  }

  String _snippet(String text, String needle) {
    final index = text.indexOf(needle);
    final start = index < 0 ? 0 : (index - 20).clamp(0, text.length);
    final end = index < 0
        ? text.length.clamp(0, 80)
        : (index + needle.length + 20).clamp(0, text.length);
    final head = start > 0 ? '…' : '';
    final tail = end < text.length ? '…' : '';
    return '$head${text.substring(start, end)}$tail';
  }

  /// VACUUM INTO 生成一致性快照；路径内单引号会被转义。
  Future<String> _backupDatabase(
    NovelContentDatabase database,
    String workId,
  ) async {
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('.', '');
    final directory = Directory(
      p.join(RevericPaths.supportRoot, _descriptorDirectory, _backupDirectoryName),
    );
    await directory.create(recursive: true);
    final file = p.join(directory.path, '$workId-$stamp.sqlite');
    final escaped = file.replaceAll("'", "''");
    await database.customStatement("VACUUM INTO '$escaped'");
    return file;
  }

  Future<List<Map<String, Object?>>> _selectEpisodes(
    NovelContentDatabase database,
    Map<String, dynamic> body,
  ) async {
    final requested = (body['episodeNumbers'] as List?)
        ?.map((value) => value is int ? value : int.tryParse('$value'))
        .whereType<int>()
        .toList();
    final rows = await database.customSelect(
      'SELECT id, episode_number, title FROM screenplay_episodes '
      'WHERE deleted_at = 0 ORDER BY episode_number',
    ).get();
    final episodes = [
      for (final row in rows)
        {
          'id': row.read<String>('id'),
          'episode_number': row.read<int>('episode_number'),
          'title': row.read<String>('title'),
        },
    ];
    if (requested == null || requested.isEmpty) {
      return episodes;
    }
    final filtered = episodes
        .where((episode) => requested.contains(episode['episode_number']))
        .toList();
    if (filtered.isEmpty) {
      throw _ControlError(
        'episodes_not_found',
        'No episodes matched $requested',
      );
    }
    return filtered;
  }

  /// 为画布上的一个 production clip 生成参考图并采用。
  ///
  /// 角色 clip 默认以该角色头像作为图生图参考，地点 clip 用地点名与描述走文生图，
  /// 两者都拼上统一的风格文本（默认 3D 半写实 CG），保证与角色头像风格一致。
  Future<Map<String, dynamic>> _clipImage(Map<String, dynamic> body) async {
    final workId = _stringOption(body, 'workId');
    final clipId = _stringOption(body, 'clipId');
    final dryRun = body['dryRun'] == true;
    final apply = body['apply'] != false;
    final work = await _requireWork(workId);
    final database = _container.read(
      novelContentDatabaseProvider(work.databasePath),
    );
    final clip = await database.customSelect(
      "SELECT c.id, c.title, c.character_id, c.location_id, c.ratio, "
      "(SELECT id FROM canvas_nodes n WHERE n.ref_id = c.id "
      " AND n.ref_type = 'production_clip' AND n.deleted_at = 0 LIMIT 1) AS node_id "
      "FROM production_clips c WHERE c.id = ? AND c.deleted_at = 0",
      variables: [Variable.withString(clipId)],
    ).getSingleOrNull();
    if (clip == null) {
      throw _ControlError('clip_not_found', 'No production clip $clipId');
    }
    final nodeId = clip.read<String?>('node_id');
    final characterId = clip.read<String?>('character_id');
    final locationId = clip.read<String?>('location_id');
    final ratio = _stringOption(body, 'ratio', fallback: clip.read<String?>('ratio') ?? '1:1');
    final style = _resolveStyle(body);

    String? referenceAssetId = _stringOption(body, 'referenceAssetId', fallback: '');
    if (referenceAssetId.isEmpty) referenceAssetId = null;

    final buffer = StringBuffer();
    final given = _stringOption(body, 'prompt');
    if (given.isNotEmpty) {
      buffer.write(given);
    } else if (characterId != null) {
      final service = _contentService(work.databasePath);
      final character = await service.getCharacterProfileById(characterId);
      if (character == null) {
        throw _ControlError('character_not_found', 'No character $characterId');
      }
      // 图生图在该网关上很容易超时（5 分钟），默认走文生图；需要严格同一张脸时
      // 传 useReference=true 再强制用头像做参考。
      if (referenceAssetId == null && body['useReference'] == true) {
        final avatar = character.avatarAssetId;
        if (avatar != null && avatar.isNotEmpty) referenceAssetId = avatar;
      }
      final appearance = _sentence(character.appearance.split('\n').first);
      final identity = _sentence(character.identity);
      buffer
        ..write('「${character.name}」角色参考图，与项目中的角色头像为同一人物，')
        ..write('保持脸型、发型、发色与常穿服装一致。')
        ..write(appearance);
      if (identity.isNotEmpty) buffer.write('身份：$identity');
      buffer.write('半身到膝上定妆参考照，纯深灰背景，柔和三点布光，画面干净。');
    } else if (locationId != null) {
      final row = await database.customSelect(
        'SELECT name, description FROM locations WHERE id = ? AND deleted_at = 0',
        variables: [Variable.withString(locationId)],
      ).getSingleOrNull();
      if (row == null) {
        throw _ControlError('location_not_found', 'No location $locationId');
      }
      final name = row.read<String>('name');
      final description = _sentence(row.read<String?>('description') ?? '');
      buffer.write('「$name」场景空镜参考图：无人物的环境全景，电影级布景与真实材质细节。');
      if (description.isNotEmpty) buffer.write(description);
      buffer.write('画面干净，柔和自然光，留出人物站位空间。');
    } else {
      throw _ControlError(
        'clip_has_no_subject',
        'Clip $clipId has neither character nor location',
      );
    }
    buffer.write(style);
    final prompt = buffer.toString();

    if (dryRun) {
      return {
        'dryRun': true,
        'clipId': clipId,
        'title': clip.read<String>('title'),
        'nodeId': nodeId,
        'referenceAssetId': referenceAssetId,
        'ratio': ratio,
        'prompt': prompt,
      };
    }

    final result = await _generateImage(
      workId,
      prompt,
      ratio: ratio,
      referenceAssetId: referenceAssetId,
    );
    final assetId = result.assetId;
    if (assetId == null || assetId.isEmpty) {
      throw const _ControlError('asset_missing', 'Image generation returned no registered asset');
    }
    var adopted = false;
    if (apply && nodeId != null) {
      final production = ProductionCanvasService(
        StoryboardService(database, contentKind: work.contentKind),
        _container.read(mediaLibraryServiceProvider),
        workId,
      );
      await production.adopt(nodeId, assetId);
      adopted = true;
    }
    return {
      'clipId': clipId,
      'title': clip.read<String>('title'),
      'nodeId': nodeId,
      'assetId': assetId,
      'adopted': adopted,
      'referenceAssetId': referenceAssetId,
      'ratio': ratio,
      'prompt': prompt,
    };
  }

  /// 用应用自己的音频通道合成一句台词，返回落盘路径与实测时长。
  Future<Map<String, dynamic>> _speak(Map<String, dynamic> body) async {
    final text = _stringOption(body, 'text');
    if (text.trim().isEmpty) {
      throw const _ControlError('text_required', 'text is required');
    }
    final voice = _stringOption(body, 'voice', fallback: 'longanhuan_v3.6');
    final instruction = _stringOption(body, 'instruction');
    final database = _container.read(appDatabaseProvider);
    var providerId = _stringOption(body, 'providerId');
    var modelId = _stringOption(body, 'modelId');
    final providers = await (database.select(
      database.aiProviders,
    )..where((table) => table.enabled.equals(true))).get();
    final provider = providerId.isEmpty
        ? providers.firstWhere(
            (row) => _audioModelsOf(row).isNotEmpty,
            orElse: () => throw const _ControlError(
              'audio_model_not_configured',
              'No enabled provider with an audio model',
            ),
          )
        : providers.firstWhere(
            (row) => row.id == providerId,
            orElse: () => throw _ControlError(
              'provider_not_found',
              'No enabled provider $providerId',
            ),
          );
    providerId = provider.id;
    if (modelId.isEmpty) modelId = _audioModelsOf(provider).first;
    final service = NarrationService(
      database: database,
      invoke: _container.read(productionAudioInvokeProvider),
    );
    final audio = await service.generate(
      NarrationSettings(providerId: providerId, modelId: modelId),
      NarrationSegment(
        text: text,
        voice: voice,
        sceneId: '',
        instructions: instruction,
      ),
      Completer<void>().future,
    );
    final directory = Directory(
      p.join(RevericPaths.supportRoot, 'debug', 'tts'),
    );
    await directory.create(recursive: true);
    final path = p.join(
      directory.path,
      'tts_${DateTime.now().microsecondsSinceEpoch}.${audio.extension}',
    );
    await File(path).writeAsBytes(audio.bytes, flush: true);
    return {
      'path': path,
      'bytes': audio.bytes.length,
      'extension': audio.extension,
      'voice': voice,
      'modelId': modelId,
      'providerId': providerId,
      'characters': text.runes.length,
      'durationMs': _waveDurationMs(audio.bytes),
    };
  }


  List<String> _audioModelsOf(AiProvider row) => row.audioModels;

  /// 解析 WAV 头得到毫秒时长；非 WAV 返回 null。
  int? _waveDurationMs(Uint8List bytes) {
    if (bytes.length < 44 ||
        !_asciiEquals(bytes, 0, 'RIFF') ||
        !_asciiEquals(bytes, 8, 'WAVE')) {
      return null;
    }
    var offset = 12;
    var byteRate = 0;
    while (offset + 8 <= bytes.length) {
      final size = ByteData.sublistView(
        bytes,
        offset + 4,
        offset + 8,
      ).getUint32(0, Endian.little);
      if (_asciiEquals(bytes, offset, 'fmt ') && offset + 20 <= bytes.length) {
        byteRate = ByteData.sublistView(
          bytes,
          offset + 16,
          offset + 20,
        ).getUint32(0, Endian.little);
      } else if (_asciiEquals(bytes, offset, 'data')) {
        if (byteRate == 0) return null;
        final available = bytes.length - (offset + 8);
        final dataSize = size < available ? size : available;
        return (dataSize * 1000 / byteRate).round();
      }
      offset += 8 + size + (size & 1);
    }
    return null;
  }

  bool _asciiEquals(Uint8List bytes, int offset, String expected) {
    if (offset + expected.length > bytes.length) return false;
    for (var i = 0; i < expected.length; i++) {
      if (bytes[offset + i] != expected.codeUnitAt(i)) return false;
    }
    return true;
  }

  /// 在指定场次下批量创建分镜（video 类 production clip），并放到画布上。
  Future<Map<String, dynamic>> _createShots(Map<String, dynamic> body) async {
    final workId = _stringOption(body, 'workId');
    final shots = body['shots'];
    if (shots is! List || shots.isEmpty) {
      throw const _ControlError('shots_required', 'shots is required');
    }
    final work = await _requireWork(workId);
    final episodeId = _stringOption(body, 'episodeId');
    final service = _container.read(
      storyboardServiceProvider(work.databasePath),
    );
    final created = <Map<String, dynamic>>[];
    for (final raw in shots) {
      if (raw is! Map) continue;
      final shot = Map<String, dynamic>.from(raw);
      final sceneId = _stringOption(shot, 'sceneId');
      if (sceneId.isEmpty) {
        throw const _ControlError('scene_required', 'shot.sceneId is required');
      }
      final kind = _stringOption(shot, 'kind', fallback: 'video');
      final values = <String, dynamic>{
        'kind': kind,
        'title': _stringOption(shot, 'title'),
        'prompt': _stringOption(shot, 'prompt'),
        if (shot['durationMs'] is num)
          'duration_ms': (shot['durationMs'] as num).round(),
        if (shot['characterId'] is String) 'character_id': shot['characterId'],
        if (shot['locationId'] is String) 'location_id': shot['locationId'],
        if (shot['ratio'] is String) 'ratio': shot['ratio'],
        if (shot['resolution'] is String) 'resolution': shot['resolution'],
        if (shot['generateAudio'] is bool)
          'generate_audio': shot['generateAudio'],
      };
      final row = kind == 'image'
          ? await service.createImage(
              _stringOption(shot, 'episodeId', fallback: episodeId),
              values: values,
            )
          : await service.create(sceneId, values: values);
      final node = await service.ensureClipNode(row.id);
      created.add({
        'clipId': row.id,
        'nodeId': node.id,
        'sceneId': sceneId,
        'title': row.title,
        'durationMs': row.durationMs,
      });
    }
    return {'created': created, 'count': created.length};
  }

  /// 建一个图鉴道具条目并生成参考图，结果写回条目的照片集。
  Future<Map<String, dynamic>> _createProp(Map<String, dynamic> body) async {
    final workId = _stringOption(body, 'workId');
    final title = _stringOption(body, 'title');
    if (title.isEmpty) {
      throw const _ControlError('title_required', 'title is required');
    }
    final content = _stringOption(body, 'content');
    final prompt = _stringOption(body, 'prompt');
    final dryRun = body['dryRun'] == true;
    final work = await _requireWork(workId);
    final database = _container.read(
      novelContentDatabaseProvider(work.databasePath),
    );
    final existing = await database.customSelect(
      "SELECT id FROM items WHERE title = ? AND deleted_at = 0 LIMIT 1",
      variables: [Variable.withString(title)],
    ).getSingleOrNull();
    var itemId = existing?.read<String>('id');
    final fullPrompt = prompt.isEmpty
        ? '「$title」道具参考图：$content。单独静物，简洁深灰背景，柔和侧光，材质细节清晰。${_resolveStyle(body)}'
        : '$prompt${_resolveStyle(body)}';
    if (dryRun) {
      return {
        'dryRun': true,
        'title': title,
        'itemId': itemId,
        'prompt': fullPrompt,
      };
    }
    if (itemId == null) {
      itemId = 'itm_${_randomToken().substring(0, 10)}';
      await database.into(database.items).insert(
        ItemsCompanion.insert(
          id: itemId,
          type: 'item',
          title: title,
          content: Value(content),
        ),
      );
    }
    final result = await _generateImage(workId, fullPrompt, ratio: '1:1');
    final assetId = result.assetId;
    if (assetId == null || assetId.isEmpty) {
      throw const _ControlError('asset_missing', 'Image generation returned no registered asset');
    }
    final row = await (database.select(
      database.items,
    )..where((table) => table.id.equals(itemId!))).getSingle();
    final photos = [
      ...row.photos ?? const <SubjectPhoto>[],
      SubjectPhoto(assetId: assetId, name: title),
    ];
    await (database.update(database.items)
          ..where((table) => table.id.equals(itemId!)))
        .write(ItemsCompanion(photos: Value(photos)));
    return {
      'itemId': itemId,
      'title': title,
      'assetId': assetId,
      'photoCount': photos.length,
    };
  }

  /// 把本地音频导入作品素材库，并建成该集的音频片段。
  Future<Map<String, dynamic>> _importAudio(Map<String, dynamic> body) async {
    final workId = _stringOption(body, 'workId');
    final episodeId = _stringOption(body, 'episodeId');
    final items = body['files'];
    if (items is! List || items.isEmpty) {
      throw const _ControlError('files_required', 'files is required');
    }
    final work = await _requireWork(workId);
    final library = _container.read(mediaLibraryServiceProvider);
    final service = _container.read(
      storyboardServiceProvider(work.databasePath),
    );
    final production = ProductionCanvasService(
      StoryboardService(
        _container.read(novelContentDatabaseProvider(work.databasePath)),
        contentKind: work.contentKind,
      ),
      library,
      workId,
    );
    final created = <Map<String, dynamic>>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final entry = Map<String, dynamic>.from(raw);
      final path = _stringOption(entry, 'path');
      final name = _stringOption(entry, 'name');
      final asset = await library.importFile(
        File(path),
        name: name,
        novelId: workId,
        purpose: AssetPurpose.production_upload,
        cancellation: MediaCancellation(),
        addToLibrary: true,
      );
      if (body['asClip'] == false) {
        created.add({'assetId': asset.id, 'title': name});
        continue;
      }
      final clip = await service.createAudio(
        episodeId,
        values: {
          'title': name,
          if (entry['durationMs'] is num)
            'duration_ms': (entry['durationMs'] as num).round(),
        },
      );
      final node = await service.ensureClipNode(clip.id);
      await production.adopt(node.id, asset.id);
      created.add({'clipId': clip.id, 'assetId': asset.id, 'title': name});
    }
    return {'created': created, 'count': created.length};
  }

  /// 为图鉴条目建一个画布图片节点（图鉴类素材），并采用它已有的照片。
  Future<Map<String, dynamic>> _itemClip(Map<String, dynamic> body) async {
    final workId = _stringOption(body, 'workId');
    final episodeId = _stringOption(body, 'episodeId');
    final itemId = _stringOption(body, 'itemId');
    final work = await _requireWork(workId);
    final database = _container.read(
      novelContentDatabaseProvider(work.databasePath),
    );
    final item = await database.customSelect(
      'SELECT id, title, photos FROM items WHERE id = ? AND deleted_at = 0',
      variables: [Variable.withString(itemId)],
    ).getSingleOrNull();
    if (item == null) {
      throw _ControlError('item_not_found', 'No compendium item $itemId');
    }
    final service = _container.read(
      storyboardServiceProvider(work.databasePath),
    );
    final clip = await service.createImage(
      episodeId,
      values: {'title': item.read<String>('title'), 'item_id': itemId},
    );
    final node = await service.ensureClipNode(clip.id);
    final photos = jsonDecode(item.read<String?>('photos') ?? '[]') as List;
    String? adopted;
    if (photos.isNotEmpty && photos.first is Map) {
      final assetId = (photos.first as Map)['asset_id'] as String?;
      if (assetId != null && assetId.isNotEmpty) {
        final production = ProductionCanvasService(
          StoryboardService(
            database,
            contentKind: work.contentKind,
          ),
          _container.read(mediaLibraryServiceProvider),
          workId,
        );
        await production.adopt(node.id, assetId);
        adopted = assetId;
      }
    }
    return {
      'clipId': clip.id,
      'nodeId': node.id,
      'itemId': itemId,
      'adoptedAssetId': adopted,
    };
  }

  /// 走真实制作管线提交一个分镜的视频生成并等待结果（参考上传→提交→轮询→采用）。
  Future<Map<String, dynamic>> _generateVideo(Map<String, dynamic> body) async {
    final workId = _stringOption(body, 'workId');
    final clipId = _stringOption(body, 'clipId');
    final timeoutSec = (body['timeoutSec'] as num?)?.toInt() ?? 600;
    final adopt = body['adopt'] != false;
    final work = await _requireWork(workId);
    final database = _container.read(
      novelContentDatabaseProvider(work.databasePath),
    );
    final service = ProductionCanvasService(
      StoryboardService(database, contentKind: work.contentKind),
      _container.read(mediaLibraryServiceProvider),
      workId,
    );
    final tasks = await _container.read(videoTaskServiceProvider.future);
    final node = await service.shots.ensureClipNode(clipId);
    final orchestrator = ProductionGenerateOrchestrator();
    final preview = await orchestrator.preview(service, node.id);
    final taskId = await orchestrator.submit(
      service,
      tasks,
      preview,
      acknowledgeReferenceUpload: true,
    );
    final appDb = _container.read(appDatabaseProvider);
    final deadline = DateTime.now().add(Duration(seconds: timeoutSec));
    GenerationTask? task;
    while (DateTime.now().isBefore(deadline)) {
      task = await appDb.generationTaskDao.getById(taskId);
      if (task != null && task.status.isTerminal) break;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    task ??= await appDb.generationTaskDao.getById(taskId);
    if (task == null) {
      throw _ControlError('task_missing', 'Generation task $taskId not found');
    }
    final done = task;
    String? path;
    var adopted = false;
    if (done.status == GenerationTaskStatus.completed &&
        done.resultAssetId != null) {
      if (adopt) {
        await service.adopt(node.id, done.resultAssetId!);
        adopted = true;
      }
      final asset = await (appDb.select(
        appDb.assets,
      )..where((t) => t.id.equals(done.resultAssetId!))).getSingleOrNull();
      if (asset?.path != null) {
        path = _container.read(mediaLibraryServiceProvider).resolvePath(asset!.path!);
      }
    }
    return {
      'taskId': taskId,
      'clipId': clipId,
      'status': done.status.name,
      'resultAssetId': done.resultAssetId,
      'adopted': adopted,
      'path': path,
      'errorCode': done.errorCode,
      'errorMessage': done.errorMessage,
    };
  }

  // ---------------------------------------------------------------- 内部工具

  /// 3D 半写实 CG 的完整风格文本；与 `cover_style.dart` 里的预设保持一致。
  /// 这里内联一份，保证本文件可以单独拷进任意 0.10.x 检出即编译通过。
  static const _cg3dStylePrompt =
      '3D 半写实 CG 三维动画风格，非真人实拍。影视级三维渲染：皮肤有克制的次表面散射与统一色调，'
      '头发分束建模、边缘干净，布料与金属有真实高光但整体收得住；柔和三点布光，浅景深，明暗层次干净；'
      '介于写实与风格化之间，保留人物辨识度，不追求真人照片质感。'
      '避免真人照片、真实毛孔与皮肤瑕疵、摄影棚人像写真、2D 平涂插画、Q 版卡通。';

  String _resolveStyle(Map<String, dynamic> body) {
    final style = _stringOption(body, 'style', fallback: 'cg3d').trim();
    if (style.isEmpty) return _cg3dStylePrompt;
    return switch (style) {
      'cg3d' || '3d' => _cg3dStylePrompt,
      'cinematic' => '电影感',
      'illustration' => '插画',
      'eastern' => '东方幻想',
      'minimal' => '极简',
      _ => style,
    };
  }

  String _buildAvatarPrompt(CharacterProfile character, String style) {
    final age = character.age.trim();
    // 年龄是自由文本（25 / 40 左右 / 30 岁上下），只在纯数字时补「岁」。
    final head = switch (age) {
      '' || '未知' => '',
      final value when RegExp(r'^\d+$').hasMatch(value) => '$value岁',
      final value => value,
    };
    final gender = switch (character.gender) {
      'male' => '男性',
      'female' => '女性',
      _ => '',
    };
    final appearance = _sentence(character.appearance.split('\n').first);
    final identity = _sentence(character.identity);
    final personality = _sentence(character.personality);
    final buffer = StringBuffer()
      ..write('$head$gender${character.name}，头肩特写半身头像，')
      ..write('正面略侧四分之三角度看向镜头。');
    if (appearance.isNotEmpty) buffer.write(appearance);
    if (identity.isNotEmpty) buffer.write('身份：$identity');
    if (personality.isNotEmpty) buffer.write('气质：$personality');
    buffer.write('背景为简洁的冷调纯色墙面，柔和虚化。构图仅头部与肩部，不要全身。');
    buffer.write(style);
    return buffer.toString();
  }

  /// 收尾成一句：去掉重复的句末标点，非空时补一个「。」。
  String _sentence(String value) {
    final text = value.trim();
    if (text.isEmpty) return '';
    final stripped = text.replaceFirst(RegExp(r'[。．.]+$'), '');
    return '$stripped。';
  }

  /// 生成一张图。autoDispose 的回调 provider 用订阅持有，避免异步中被销毁。
  ///
  /// [referenceAssetId] 非空时走图生图（把该资产作为参考图），用于保持同一人物/场景。
  Future<AiImageGenerationResult> _generateImage(
    String workId,
    String prompt, {
    String ratio = '1:1',
    String? referenceAssetId,
  }) async {
    final options = ImageInvocationOptions(preferredRatio: ratio);
    if (referenceAssetId != null && referenceAssetId.isNotEmpty) {
      final subscription = _container.listen(
        imageEditCallbackProvider(workId),
        (_, _) {},
      );
      try {
        final edit = subscription.read();
        if (edit == null) {
          throw const _ControlError(
            'image_model_not_configured',
            'No default image model; set one in 设置 → 模型设置',
          );
        }
        final path = await _assetFilePath(referenceAssetId);
        return await edit(prompt, imageData: path, options: options);
      } finally {
        subscription.close();
      }
    }
    final subscription = _container.listen(
      imageGenerationCallbackProvider(workId),
      (_, _) {},
    );
    try {
      final callback = subscription.read();
      if (callback == null) {
        throw const _ControlError(
          'image_model_not_configured',
          'No default image model; set one in 设置 → 模型设置',
        );
      }
      return await callback(prompt, options: options);
    } finally {
      subscription.close();
    }
  }

  /// 把作品资产解析成本机绝对路径，供图生图参考使用。
  Future<String> _assetFilePath(String assetId) async {
    final database = _container.read(appDatabaseProvider);
    final row = await (database.select(database.assets)
          ..where((table) => table.id.equals(assetId)))
        .getSingleOrNull();
    final stored = row?.path;
    if (stored == null || stored.isEmpty) {
      throw _ControlError('asset_file_missing', 'Asset $assetId has no local file');
    }
    final resolved = RevericPaths.resolveStored(stored);
    if (resolved == null) {
      throw _ControlError('asset_file_missing', 'Cannot resolve $stored');
    }
    return resolved;
  }

  Future<_WorkRef> _requireWork(String workId) async {
    if (workId.isEmpty) {
      throw _ControlError('work_required', 'workId is required');
    }
    final database = _container.read(appDatabaseProvider);
    final row = await (database.select(database.novels)
          ..where((table) => table.id.equals(workId)))
        .getSingleOrNull();
    if (row == null) {
      throw _ControlError('work_not_found', 'No work $workId');
    }
    final databasePath = row.contentDatabasePath;
    if (databasePath == null || databasePath.isEmpty) {
      throw _ControlError('work_has_no_content', 'Work $workId has no content database');
    }
    return _WorkRef(
      id: row.id,
      title: row.title,
      databasePath: databasePath,
      contentKind: row.contentKind,
    );
  }

  NovelContentService _contentService(String databasePath) =>
      _container.read(novelContentServiceProvider(databasePath));

  String _stringOption(
    Map<String, dynamic> body,
    String key, {
    String fallback = '',
  }) {
    final value = body[key];
    return value is String ? value : fallback;
  }

  int _intOption(
    Map<String, dynamic> body,
    String key, {
    required int fallback,
    required int min,
    required int max,
  }) {
    final value = body[key];
    final parsed = value is int ? value : int.tryParse('$value');
    if (parsed == null) return fallback;
    return parsed.clamp(min, max);
  }
}

class _WorkRef {
  const _WorkRef({
    required this.id,
    required this.title,
    required this.databasePath,
    required this.contentKind,
  });

  final String id;
  final String title;
  final String databasePath;
  final String contentKind;
}

/// 端点业务错误：带稳定 error code，方便外部脚本判断。
class _ControlError implements Exception {
  const _ControlError(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}
