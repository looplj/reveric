// 职责: 持久化视频任务，独占提交与恢复下载，并在探测实际规格后登记结果资产。
// 关联文件:
//   lib/shared/database/daos/generation_task_dao.dart
//   lib/shared/providers/video_tasks.dart
//   lib/shared/services/ai/video/reference_storage_service.dart
//   lib/shared/models/video/task_result.dart
//   lib/shared/models/production/media.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json

import 'dart:async';
import 'package:reveric/shared/models/asset_purpose.dart';
import 'dart:convert';
import 'dart:io';
import '../../../utils/storage_paths.dart';
import 'package:reveric/shared/models/production/asset_content.dart';
import 'dart:math';

import '../../../models/production/media.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../../database/app_database.dart';
import '../../../database/daos/generation_task_dao.dart';
import '../../../logger/app_logger.dart';
import '../../../localization/locale_keys.dart';
import '../../../models/ai_provider.dart';
import '../../../models/provider_asset.dart';
import '../../../models/video/channels.dart';
import '../../../models/video/request.dart';
import '../../../models/video/task_result.dart';
import '../../../utils/short_entity_id.dart';
import '../../../utils/random_id.dart';
import '../../../utils/short_entity_id_allocator.dart';
import 'ark.dart';
import 'agnes.dart';
import 'atlascloud.dart';
import 'client.dart';
import 'draft.dart';
import 'minimax.dart';
import 'openrouter.dart';
import 'purefox.dart';
import '../new_api.dart';
import 'reference_storage_service.dart';
import 'wan.dart';

final _log = AppLogger.forModule('VideoTasks');

class VideoSourceInput {
  const VideoSourceInput({
    required this.file,
    required this.assetId,
    required this.role,
    required this.mimeType,
  });
  final File file;

  /// 快照只记资产；[file] 是提交前从资产解析出的文件。
  final String assetId;
  final VideoInputRole role;
  final String mimeType;
}

class VideoTaskService {
  VideoTaskService({
    required this.database,
    required this.rootDirectory,
    required this.references,
    required this.probeResult,
    this.beforeCreate,
    this.beforeSubmit,
    this.recoverSources,
    this.sourceName,
    http.Client Function(AiProvider)? providerTransport,
    http.Client Function(AiProvider)? downloadTransport,
    DateTime Function()? now,
    Random? random,
  }) : providerTransport =
           providerTransport ??
           ((provider) => provider.createProxyClient() ?? http.Client()),
       downloadTransport =
           downloadTransport ??
           ((provider) => provider.createProxyClient() ?? http.Client()),
       now = now ?? DateTime.now,
       random = random ?? Random();

  final Future<void> Function(String novelId, String type, String id)?
  beforeCreate;
  final Future<void> Function(GenerationTask task)? beforeSubmit;
  final Future<void> Function()? recoverSources;

  /// 结果入库时的资产名（不含扩展名）；为 null 或返回 null 时用任务 id。
  final Future<String?> Function(GenerationTask task)? sourceName;
  final Future<MediaInfo> Function(String path) probeResult;
  final AppDatabase database;
  final Directory rootDirectory;
  final ReferenceStorageService references;
  final http.Client Function(AiProvider) providerTransport;
  final http.Client Function(AiProvider) downloadTransport;
  final DateTime Function() now;
  final Random random;
  final _busy = <String>{};
  final _failures = <String, int>{};
  final _clients = <http.Client>{};
  final _creating = <String, Future<String>>{};
  Completer<void>? _idle;
  Future<void> _submissions = Future.value();
  Future<void>? _starting;
  Timer? _timer;
  bool _started = false;
  bool _disposed = false;
  bool _draining = false;
  bool _online = true;
  bool _foreground = true;
  static const _consentKey = 'video.reference_upload_acknowledged';
  static const maxResultBytes = 2 * 1024 * 1024 * 1024;

  Stream<GenerationTask?> watchTask(String id) =>
      database.generationTaskDao.watchTask(id);
  Future<GenerationTask?> getTask(String id) async {
    final task = await database.generationTaskDao.getById(id);
    if (task != null && task.kind != GenerationKind.video) {
      throw ArgumentError('Not a video task');
    }
    return task;
  }

  Stream<List<GenerationTask>> watchSource({
    required String novelId,
    required String sourceType,
    required String sourceId,
  }) => database.generationTaskDao.watchSource(
    novelId: novelId,
    sourceType: sourceType,
    sourceId: sourceId,
  );

  Future<String> create({
    String? id,
    required String providerId,
    required String novelId,
    required String sourceType,
    required String sourceId,
    required VideoRequest request,
    List<VideoSourceInput> inputs = const [],
    bool draft = false,
  }) async {
    _requireActive();
    GenerationTaskDao.validateSource(novelId, sourceType, sourceId);
    if (id == null) {
      return insertWithShortEntityId(
        type: ShortEntityIdType.generationTask,
        tableName: 'generation_tasks',
        idExists: database.generationTaskDao.idExists,
        insert: (id) => create(
          id: id,
          providerId: providerId,
          novelId: novelId,
          sourceType: sourceType,
          sourceId: sourceId,
          request: request,
          inputs: inputs,
          draft: draft,
        ),
      );
    }
    final taskId = id;
    final pending = _creating[taskId];
    if (pending != null) {
      await pending;
    }
    if (await getTask(taskId) == null) {
      await beforeCreate?.call(novelId, sourceType, sourceId);
    }
    final operation = database.transaction(
      () => _create(
        taskId,
        providerId,
        novelId,
        sourceType,
        sourceId,
        request,
        inputs,
        draft,
      ),
    );
    _creating[taskId] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_creating[taskId], operation)) {
        _creating.remove(taskId);
      }
    }
  }

  Future<String> _create(
    String id,
    String providerId,
    String novelId,
    String sourceType,
    String sourceId,
    VideoRequest request,
    List<VideoSourceInput> sources,
    bool draft,
  ) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'task_id',
      );
    }
    final existing = await getTask(id);
    if (existing != null) {
      if (existing.novelId != novelId ||
          existing.sourceType != sourceType ||
          existing.sourceId != sourceId ||
          existing.providerId != providerId ||
          existing.draft != draft ||
          existing.draftTaskId != null ||
          sources.length != existing.videoInputs.length ||
          jsonEncode(existing.videoRequest.toJson()) !=
              jsonEncode(request.toJson())) {
        throw const VideoException(
          VideoErrorCode.invalid_request,
          field: 'task_id',
        );
      }
      for (var index = 0; index < sources.length; index++) {
        final source = sources[index];
        final saved = existing.videoInputs[index];
        if (source.role != saved.role ||
            source.mimeType != saved.mimeType ||
            source.assetId != saved.assetId) {
          throw const VideoException(
            VideoErrorCode.invalid_request,
            field: 'task_id',
          );
        }
      }
      return id;
    }
    await database.generationTaskDao.ensureSourceAvailable(
      novelId,
      sourceType,
      sourceId,
    );
    final provider = await database.aiProviderDao.getById(providerId);
    if (provider == null ||
        !provider.enabled ||
        !provider.videoModels.contains(request.modelId)) {
      throw const VideoException(VideoErrorCode.configuration_required);
    }
    if (draft &&
        (request.resolution != videoDraftResolution ||
            lookupVideoChannelModel(
                  provider.type,
                  request.modelId,
                )?.protocolOptions.supportsDraft !=
                true)) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'draft',
      );
    }
    final inputs = <VideoInput>[];
    for (final source in sources) {
      final size = await source.file.length();
      if (size <= 0 || size > 50 * 1024 * 1024) {
        throw const VideoException(
          VideoErrorCode.invalid_request,
          field: 'file_size',
        );
      }
      inputs.add(
        VideoInput(
          role: source.role,
          assetId: source.assetId,
          mimeType: source.mimeType,
        ),
      );
    }
    await database.generationTaskDao.create(
      GenerationTasksCompanion.insert(
        kind: GenerationKind.video,
        id: id,
        novelId: novelId,
        sourceType: sourceType,
        sourceId: sourceId,
        providerId: providerId,
        providerType: provider.type,
        modelId: request.modelId,
        status: GenerationTaskStatus.prepared,
        draft: Value(draft),
        requestJson: VideoGenerationRequest(request, inputs: inputs),
      ),
    );
    return id;
  }

  /// 只读校验当前草稿能否生成高清，供授权预览、能力查询与创建共用。
  Future<GenerationTask> inspectDraftCompletion(String draftTaskId) async {
    _requireActive();
    final source = await _requireDraft(draftTaskId);
    final provider = await _provider(source);
    if (!provider.videoModels.contains(source.modelId)) {
      throw const VideoException(VideoErrorCode.configuration_required);
    }
    await _ensureDraftAvailable(source);
    await database.generationTaskDao.ensureSourceAvailable(
      source.novelId,
      source.sourceType,
      source.sourceId,
    );
    return source;
  }

  /// 高清任务始终从原草稿派生，不读取当前编辑器的模型、提示词或参考素材。
  Future<String> createDraftCompletion(String draftTaskId) async {
    final source = await inspectDraftCompletion(draftTaskId);
    await beforeCreate?.call(
      source.novelId,
      source.sourceType,
      source.sourceId,
    );
    return insertWithShortEntityId(
      type: ShortEntityIdType.generationTask,
      tableName: 'generation_tasks',
      idExists: database.generationTaskDao.idExists,
      insert: (id) => database.transaction(() async {
        final source = await inspectDraftCompletion(draftTaskId);
        await database.generationTaskDao.create(
          GenerationTasksCompanion.insert(
            id: id,
            kind: GenerationKind.video,
            novelId: source.novelId,
            sourceType: source.sourceType,
            sourceId: source.sourceId,
            providerId: source.providerId,
            providerType: source.providerType,
            modelId: source.modelId,
            status: GenerationTaskStatus.prepared,
            draftTaskId: Value(source.id),
            requestJson: VideoGenerationRequest(
              source.videoRequest.withResolution(videoDraftFinalResolution),
              inputs: source.videoInputs,
            ),
          ),
        );
      }),
    );
  }

  Future<GenerationTask> _requireDraft(String id) async {
    final source = await getTask(id);
    if (source == null ||
        !source.supportsDraftCompletion ||
        source.status != GenerationTaskStatus.completed ||
        source.providerTaskId?.trim().isNotEmpty != true ||
        source.submittedAt == null) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'draft',
      );
    }
    if (source.isDraftExpired(now())) {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'draft_expired',
      );
    }
    return source;
  }

  Future<void> _ensureDraftAvailable(
    GenerationTask source, {
    String? except,
  }) async {
    final tasks = await database.generationTaskDao
        .watchSource(
          novelId: source.novelId,
          sourceType: source.sourceType,
          sourceId: source.sourceId,
        )
        .first;
    if (tasks.any(
      (task) =>
          task.id != except &&
          task.draftTaskId == source.id &&
          !task.status.isTerminal,
    )) {
      // A missing POST receipt must not allow another paid completion.
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'draft_active_task',
      );
    }
  }

  Future<void> submit(String id, {bool acknowledgeReferenceUpload = false}) {
    _requireActive();
    final result = Completer<void>();
    _submissions = _submissions.then((_) async {
      try {
        await _submit(id, acknowledgeReferenceUpload);
        result.complete();
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<void> _submit(String id, bool acknowledge) async {
    _requireActive();
    final preparedTask = await _task(id);
    if (await _cancelUnsubmitted(preparedTask)) {
      return;
    }
    if (preparedTask.status == GenerationTaskStatus.prepared) {
      try {
        await beforeSubmit?.call(preparedTask);
      } catch (_) {
        await database.generationTaskDao.transition(
          id,
          {GenerationTaskStatus.prepared},
          const GenerationTasksCompanion(
            errorCode: Value('source_state_pending'),
          ),
        );
        rethrow;
      }
    }
    if (!_online || !_busy.add(id)) {
      return;
    }
    try {
      var task = await _task(id);
      if (task.status != GenerationTaskStatus.prepared ||
          await _cancelUnsubmitted(task)) {
        return;
      }
      if (task.draftTaskId == null && task.videoInputs.isNotEmpty) {
        if (acknowledge) {
          await database.appSettingsDao.set(key: _consentKey, value: 'true');
        }
        if (await database.appSettingsDao.get(_consentKey) != 'true') {
          throw const VideoException(
            VideoErrorCode.configuration_required,
            field: 'reference_upload_consent',
          );
        }
      }
      if (!await _status(task, GenerationTaskStatus.uploading)) {
        return;
      }
      task = await _task(id);
      if (task.status != GenerationTaskStatus.uploading ||
          await _cancelUnsubmitted(task)) {
        return;
      }
      final prepared = await _prepare(task);
      final provider = await _provider(task);
      final transport = providerTransport(provider);
      _clients.add(transport);
      try {
        final client = _client(provider, transport);
        String? draftId;
        if (task.draftTaskId != null) {
          final source = await _requireDraft(task.draftTaskId!);
          await _ensureDraftAvailable(source, except: task.id);
          draftId = source.providerTaskId!;
        }
        // Complete capability validation before entering the uncertain POST window.
        client.encodeSubmission(
          task.videoRequest,
          prepared,
          draft: task.draft,
          draftId: draftId,
        );
        final submitting = await database.transaction(() async {
          final current = await _task(id);
          if (current.status != GenerationTaskStatus.uploading ||
              await _cancelUnsubmitted(current)) {
            return false;
          }
          return _status(current, GenerationTaskStatus.submitting);
        });
        if (!submitting) {
          return;
        }
        final receipt = await client.submit(
          task.videoRequest,
          prepared,
          draft: task.draft,
          draftId: draftId,
        );
        if (_disposed) {
          return;
        }
        final saved = await database.generationTaskDao.transition(
          id,
          {GenerationTaskStatus.submitting},
          GenerationTasksCompanion(
            providerTaskId: Value(receipt.taskId),
            pollingUrl: Value(receipt.pollingUrl.toString()),
            submittedAt: Value(now()),
            status: const Value(GenerationTaskStatus.running),
            nextPollAt: Value(now().add(const Duration(seconds: 10))),
            errorCode: const Value(null),
            errorMessage: const Value(null),
            errorDetail: const Value(null),
          ),
        );
        if (!saved) {
          await database.generationTaskDao.transition(
            id,
            {GenerationTaskStatus.action_required},
            GenerationTasksCompanion(
              providerTaskId: Value(receipt.taskId),
              pollingUrl: Value(receipt.pollingUrl.toString()),
              submittedAt: Value(now()),
            ),
          );
        }
      } finally {
        _clients.remove(transport);
        transport.close();
      }
    } catch (error, stack) {
      if (!_disposed) {
        await _failure(id, error, submitting: true);
      }
      _logFailure(id, 'submit', error, stack);
      rethrow;
    } finally {
      _releaseTask(id);
      _schedule();
    }
  }

  /// 提交时是否要把本地参考素材上传到存储；已认证进渠道素材库的素材直接引用，不需要上传。
  Future<bool> needsReferenceUpload({
    required String providerId,
    required String modelId,
    required Iterable<String> assetIds,
  }) async {
    final provider = await database.aiProviderDao.getById(providerId);
    final providerAssets =
        provider != null && _supportsProviderAssets(provider.type, modelId);
    for (final assetId in assetIds) {
      if (await _certifiedAsset(assetId, providerId, providerAssets) == null) {
        return true;
      }
    }
    return false;
  }

  // 同一渠道下只有 Seedance 模型认 `asset://`，其他模型仍上传文件。
  bool _supportsProviderAssets(String providerType, String modelId) =>
      lookupVideoChannelModel(
        providerType,
        modelId,
      )?.protocolOptions.supportsProviderAssets ==
      true;

  /// 已认证进渠道素材库、可直接引用素材库 id 的记录；否则返回 null。
  Future<ProviderAsset?> _certifiedAsset(
    String assetId,
    String providerId,
    bool providerAssets,
  ) async {
    if (!providerAssets) {
      return null;
    }
    final certified = await database.providerAssetDao.find(assetId, providerId);
    return certified?.status == ProviderAssetStatus.active &&
            certified!.remoteId != null
        ? certified
        : null;
  }

  Future<List<VideoReference>> _prepare(GenerationTask task) async {
    final prepared = <VideoReference>[];
    if (task.draftTaskId != null) {
      return prepared;
    }
    final providerAssets = _supportsProviderAssets(
      task.providerType,
      task.modelId,
    );
    for (final input in task.videoInputs) {
      _requireActive();
      final asset = await database.assetDao.getAsset(input.assetId);
      if (asset?.path == null) {
        throw const VideoException(
          VideoErrorCode.invalid_request,
          field: 'reference',
        );
      }
      final file = _file(asset!.path!);
      final certified = await _certifiedAsset(
        input.assetId,
        task.providerId,
        providerAssets,
      );
      if (certified != null) {
        final info = await probeResult(file.path);
        prepared.add(
          VideoReference(
            role: input.role,
            url: Uri.parse(providerAssetUri(certified.remoteId!)),
            mimeType: input.mimeType,
            fileSize: await file.length(),
            mediaInfo: VideoMediaInfo(
              width: info.width,
              height: info.height,
              durationMs: info.duration.inMilliseconds,
              frameRate: info.frameRate,
            ),
          ),
        );
        continue;
      }
      prepared.add(await references.ensure(input, file));
    }
    return prepared;
  }

  Future<void> start() => _starting ??= (() async {
    try {
      await _start();
    } catch (_) {
      _started = false;
      _starting = null;
      rethrow;
    }
  })();
  Future<void> _start() async {
    _requireActive();
    for (final task in await database.generationTaskDao.recoverable(
      kind: GenerationKind.video,
    )) {
      if (await _cancelUnsubmitted(task)) {
        continue;
      }
      if (task.status == GenerationTaskStatus.submitting &&
          task.providerTaskId == null) {
        await _status(
          task,
          GenerationTaskStatus.submission_unknown,
          error: 'submission_unknown',
        );
      } else if ((task.status == GenerationTaskStatus.saving ||
              task.status == GenerationTaskStatus.action_required) &&
          await _completeExisting(task)) {
        continue;
      } else if (task.status == GenerationTaskStatus.prepared ||
          task.status == GenerationTaskStatus.uploading) {
        try {
          if (_online &&
              task.status == GenerationTaskStatus.uploading &&
              await database.appSettingsDao.get(_consentKey) == 'true') {
            await _prepare(task);
          }
          await _status(
            task,
            GenerationTaskStatus.prepared,
            error: task.errorCode == 'source_state_pending'
                ? 'source_state_pending'
                : 'awaiting_submission_confirmation',
          );
        } catch (error) {
          await _failure(task.id, error, submitting: false);
        }
      }
    }
    _started = true;
    await refreshDue();
  }

  void setOnline(bool online) {
    _online = online;
    _schedule(immediate: true);
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    _schedule(immediate: true);
  }

  Future<void> refreshDue() async {
    if (_disposed || _draining) {
      return;
    }
    _draining = true;
    try {
      await recoverSources?.call();
      if (!_online) {
        return;
      }
      final due =
          (await database.generationTaskDao.recoverable(
                kind: GenerationKind.video,
              ))
              .where(
                (t) =>
                    {
                      GenerationTaskStatus.running,
                      GenerationTaskStatus.saving,
                      GenerationTaskStatus.submitting,
                    }.contains(t.status) &&
                    t.providerTaskId != null &&
                    (t.nextPollAt == null || !t.nextPollAt!.isAfter(now())),
              )
              .toList();
      for (var offset = 0; offset < due.length; offset += 2) {
        if (_disposed || !_online) {
          break;
        }
        await Future.wait(due.skip(offset).take(2).map((t) => refresh(t.id)));
        await recoverSources?.call();
      }
    } finally {
      _draining = false;
      _schedule();
    }
  }

  Future<void> refresh(String id) async {
    if (_disposed || !_online || _busy.length >= 2 || !_busy.add(id)) {
      return;
    }
    http.Client? transport;
    try {
      var task = await _task(id);
      if (!{
            GenerationTaskStatus.running,
            GenerationTaskStatus.saving,
            GenerationTaskStatus.submitting,
            GenerationTaskStatus.reconciliation_required,
          }.contains(task.status) ||
          task.providerTaskId == null ||
          task.pollingUrl == null) {
        return;
      }
      if (await _completeExisting(task)) {
        return;
      }
      final provider = await _provider(task);
      transport = providerTransport(provider);
      _clients.add(transport);
      final client = _client(provider, transport);
      final submission = VideoSubmission(
        taskId: task.providerTaskId!,
        modelId: task.modelId,
        pollingUrl: Uri.parse(task.pollingUrl!),
      );
      final result = await client.query(submission);
      if (_disposed) {
        return;
      }
      final current = await _task(id);
      if (current.status != task.status) {
        return;
      }
      _failures.remove(id);
      switch (result.status) {
        case VideoRemoteStatus.queued:
        case VideoRemoteStatus.running:
          await _status(
            task,
            GenerationTaskStatus.running,
            next: now().add(Duration(seconds: _foreground ? 10 : 60)),
          );
        case VideoRemoteStatus.succeeded:
          if (!await _status(task, GenerationTaskStatus.saving)) {
            return;
          }
          task = await _task(id);
          await _save(task, result.videoUrl!, client, submission, provider);
        case VideoRemoteStatus.failed:
          await _status(
            task,
            GenerationTaskStatus.failed,
            error: 'upstream_failed',
            message:
                result.providerMessage ??
                (result.messageKey == null ? null : tr(result.messageKey!)),
            detail: result.detail,
          );
        case VideoRemoteStatus.cancelled:
          await _status(task, GenerationTaskStatus.cancelled);
        case VideoRemoteStatus.expired:
          await _status(
            task,
            GenerationTaskStatus.expired,
            error: 'result_expired',
          );
        case VideoRemoteStatus.unknown:
          await _status(
            task,
            _outsideQueryWindow(task)
                ? GenerationTaskStatus.expired
                : GenerationTaskStatus.reconciliation_required,
            error: _outsideQueryWindow(task)
                ? 'result_expired'
                : 'upstream_unknown',
          );
      }
    } catch (error, stack) {
      if (!_disposed) {
        await _failure(id, error, submitting: false);
      }
      _logFailure(id, 'query/download', error, stack);
    } finally {
      if (transport != null) {
        _clients.remove(transport);
        transport.close();
      }
      _releaseTask(id);
    }
  }

  Future<void> _save(
    GenerationTask task,
    Uri url,
    VideoClient api,
    VideoSubmission submission,
    AiProvider provider,
  ) async {
    final relative = RevericPaths.mediaPath(
      task.novelId,
      'video',
      '${task.id}.mp4',
    );
    final target = _file(relative);
    await target.parent.create(recursive: true);
    final partial = File('${target.path}.part');

    final client = downloadTransport(provider);
    _clients.add(client);
    final sink = partial.openWrite();
    try {
      await (() async {
        final response = await api.download(client, url, submission);
        if (response.statusCode != 200) {
          throw VideoException(
            VideoErrorCode.unavailable,
            statusCode: response.statusCode,
          );
        }
        final declared = response.contentLength;
        if (declared != null && (declared <= 0 || declared > maxResultBytes)) {
          throw const VideoException(VideoErrorCode.invalid_response);
        }
        var bytes = 0;
        await for (final chunk in response.stream) {
          _requireActive();
          bytes += chunk.length;
          if (bytes > maxResultBytes) {
            throw const VideoException(VideoErrorCode.invalid_response);
          }
          sink.add(chunk);
        }
        await sink.flush();
        await sink.close();
        if (bytes == 0 || (declared != null && bytes != declared)) {
          throw const VideoException(VideoErrorCode.invalid_response);
        }
        if ((await _task(task.id)).status != GenerationTaskStatus.saving) {
          return;
        }

        await partial.rename(target.path);
        await _completeExisting(task);
      })().timeout(const Duration(minutes: 10));
    } finally {
      await sink.close();
      _clients.remove(client);
      client.close();
      if (await partial.exists()) {
        await partial.delete();
      }
    }
  }

  Future<bool> _completeExisting(GenerationTask task) async {
    if (task.status == GenerationTaskStatus.completed) {
      return task.resultAssetId != null;
    }
    if (task.status != GenerationTaskStatus.saving &&
        task.status != GenerationTaskStatus.action_required) {
      return false;
    }
    final relative = RevericPaths.mediaPath(
      task.novelId,
      'video',
      '${task.id}.mp4',
    );
    final file = _file(relative);
    if (!await file.exists() || await file.length() == 0) {
      return false;
    }
    final hash = (await sha256.bind(file.openRead()).first).toString();
    if (!await database.generationTaskDao.transition(
      task.id,
      {GenerationTaskStatus.saving, GenerationTaskStatus.action_required},
      GenerationTasksCompanion(
        status: const Value(GenerationTaskStatus.saving),
        path: Value(relative),
        outputHash: Value(hash),
        nextPollAt: const Value(null),
        errorCode: const Value(null),
        errorMessage: const Value(null),
        errorDetail: const Value(null),
      ),
    )) {
      return false;
    }
    final current = await _task(task.id);
    if (current.resultAssetId == null) {
      try {
        final media = await probeResult(file.path);
        if (!media.hasVideo ||
            media.duration <= Duration.zero ||
            media.width == null ||
            media.height == null) {
          throw const MediaException(MediaFailure.invalid_media);
        }
        final title = await sourceName?.call(task);
        await database.generationTaskDao.registerResult(
          task.id,
          AssetsCompanion.insert(
            id: buildRandomId('ast'),
            type: 'video',
            purpose: AssetPurpose.production_generated.value,
            name: Value(
              await database.assetDao.uniqueName(
                task.novelId,
                'video',
                title == null ? task.id : '$title.mp4',
              ),
            ),
            novelId: Value(task.novelId),
            source: const Value('generated'),
            path: Value(relative),
            content: Value(
              VideoAssetContent(
                mimeType: 'video/mp4',
                bytes: await file.length(),
                width: media.width,
                height: media.height,
                durationMs: media.duration.inMilliseconds,
              ),
            ),
          ),
        );
      } catch (error, stack) {
        _log.error(
          'result asset registration failed id=${task.id}',
          error: error,
          stackTrace: stack,
        );
        await database.generationTaskDao.transition(
          task.id,
          {GenerationTaskStatus.saving},
          const GenerationTasksCompanion(
            status: Value(GenerationTaskStatus.action_required),
            errorCode: Value('asset_registration_failed'),
          ),
        );
      }
    }
    return true;
  }

  /// 只补登记完整本地结果；无需联网或重新提交模型。
  Future<void> retryResultRegistration(String id) async {
    _requireActive();
    if (!_busy.add(id)) {
      return;
    }
    try {
      final task = await _task(id);
      if (!await _completeExisting(task)) {
        throw const VideoException(
          VideoErrorCode.invalid_request,
          field: 'local_result_missing',
        );
      }
    } finally {
      _releaseTask(id);
    }
  }

  Future<void> retryDownload(String id) async {
    if (_disposed || !_busy.add(id)) {
      return;
    }
    var refreshAfter = false;
    try {
      final task = await _task(id);
      if (await _completeExisting(task)) {
        return;
      }
      if (!_online) {
        return;
      }
      if (task.providerTaskId == null) {
        throw const VideoException(VideoErrorCode.configuration_required);
      }
      if (!{
        GenerationTaskStatus.completed,
        GenerationTaskStatus.action_required,
        GenerationTaskStatus.saving,
      }.contains(task.status)) {
        return;
      }
      if (task.errorCode?.startsWith('provider_configuration_changed') ==
          true) {
        throw const VideoException(VideoErrorCode.configuration_required);
      }
      refreshAfter = await _status(
        task,
        GenerationTaskStatus.saving,
        next: now(),
      );
    } finally {
      _releaseTask(id);
    }
    if (refreshAfter) {
      await refresh(id);
    }
  }

  Future<void> resumeAfterConfigurationFixed(String id) async {
    // A pending POST owns its receipt until it settles; an early resume leaves
    // the configuration pause intact and can be explicitly retried afterwards.
    if (_disposed || !_online || !_busy.add(id)) {
      return;
    }
    var refreshAfter = false;
    var submitAfter = false;
    try {
      final task = await _task(id);
      if (task.status != GenerationTaskStatus.action_required) {
        return;
      }
      await _provider(task);
      if (task.providerTaskId == null) {
        // A configuration edit during POST must never turn uncertainty into a retry.
        if (task.submittedAt != null ||
            task.errorCode == 'provider_configuration_changed') {
          await _status(
            task,
            GenerationTaskStatus.submission_unknown,
            error: 'confirm_original_submission',
          );
        } else {
          submitAfter = await _status(task, GenerationTaskStatus.prepared);
        }
      } else {
        refreshAfter = await _status(
          task,
          GenerationTaskStatus.running,
          next: now(),
        );
      }
    } finally {
      _releaseTask(id);
    }
    if (submitAfter) {
      // Explicit retry also confirms reference upload; reuse submission guards.
      await submit(id, acknowledgeReferenceUpload: true);
    } else if (refreshAfter) {
      await refresh(id);
    }
  }

  void _releaseTask(String id) {
    _busy.remove(id);
    if (_busy.isEmpty) {
      _idle?.complete();
      _idle = null;
    }
  }

  void _logFailure(
    String id,
    String operation,
    Object error,
    StackTrace stack,
  ) {
    if (error is VideoException) {
      _log.warning(
        '$operation failed id=$id code=${error.code.name} status=${error.statusCode}',
      );
    } else {
      _log.error('$operation failed id=$id', error: error, stackTrace: stack);
    }
  }

  Future<void> _failure(
    String id,
    Object error, {
    required bool submitting,
  }) async {
    final task = await _task(id);
    if (task.status == GenerationTaskStatus.action_required &&
        task.errorCode?.startsWith('provider_configuration_changed') == true) {
      return;
    }
    final code = error is VideoException
        ? error.code
        : VideoErrorCode.unavailable;
    final message = error is VideoException && error.providerMessage != null
        ? error.providerMessage
        : error is VideoException && error.messageKey != null
        ? tr(error.messageKey!)
        : error is VideoException && error.field == 'draft_expired'
        ? tr(LocaleKeys.productionDraftExpiredHint)
        : null;
    final detail = error is VideoException ? error.detail : null;
    if (task.draftTaskId != null &&
        error is VideoException &&
        error.field == 'draft_expired' &&
        task.providerTaskId == null &&
        task.status != GenerationTaskStatus.submitting) {
      await _status(
        task,
        GenerationTaskStatus.expired,
        error: 'draft_expired',
        message: message,
        detail: detail,
      );
      return;
    }
    if (task.status == GenerationTaskStatus.submitting) {
      await _status(
        task,
        error is VideoException &&
                error.statusCode != null &&
                error.statusCode! >= 500 &&
                error.statusCode! < 600
            ? GenerationTaskStatus.failed
            : {
                VideoErrorCode.authentication,
                VideoErrorCode.rejected,
                VideoErrorCode.rate_limited,
                VideoErrorCode.invalid_request,
              }.contains(code)
            ? GenerationTaskStatus.action_required
            : GenerationTaskStatus.submission_unknown,
        error: code.name,
        message: message,
        detail: detail,
      );
    } else if (submitting ||
        task.status == GenerationTaskStatus.prepared ||
        task.status == GenerationTaskStatus.uploading ||
        error is FileSystemException ||
        code == VideoErrorCode.authentication ||
        code == VideoErrorCode.configuration_required) {
      await _status(
        task,
        GenerationTaskStatus.action_required,
        error: code.name,
        message: message,
        detail: detail,
      );
    } else if (code == VideoErrorCode.not_found) {
      await _status(
        task,
        _outsideQueryWindow(task)
            ? GenerationTaskStatus.expired
            : GenerationTaskStatus.reconciliation_required,
        error: _outsideQueryWindow(task)
            ? 'result_expired'
            : 'upstream_not_found',
        message: message,
        detail: detail,
      );
    } else if (code == VideoErrorCode.invalid_response) {
      await _status(
        task,
        task.status == GenerationTaskStatus.saving
            ? GenerationTaskStatus.action_required
            : GenerationTaskStatus.reconciliation_required,
        error: code.name,
        message: message,
        detail: detail,
      );
    } else {
      final failures = (_failures[id] ?? 0) + 1;
      _failures[id] = failures;
      var delay = Duration(
        seconds: min(60, 10 * (1 << min(failures - 1, 3))) + random.nextInt(3),
      );
      if (error is VideoException &&
          error.retryAfter != null &&
          error.retryAfter! > delay) {
        delay = error.retryAfter!;
      }
      await _status(
        task,
        task.status,
        next: now().add(delay),
        error: code.name,
        message: message,
        detail: detail,
      );
    }
  }

  Future<AiProvider> _provider(GenerationTask task) async {
    final provider = await database.aiProviderDao.getById(task.providerId);
    if (provider == null ||
        !provider.enabled ||
        provider.type != task.providerType ||
        !provider.hasApiKey) {
      throw const VideoException(VideoErrorCode.configuration_required);
    }
    return provider;
  }

  bool _outsideQueryWindow(GenerationTask task) {
    final retention = switch (aiProviderTypeConfigFor(
      task.providerType,
    )?.videoProtocol) {
      VideoProtocol.wan_video => const Duration(hours: 24),
      VideoProtocol.minimax_video_v2 => const Duration(days: 7),
      _ => null,
    };
    return retention != null &&
        task.submittedAt != null &&
        !task.submittedAt!.add(retention).isAfter(now());
  }

  VideoClient _client(AiProvider provider, http.Client transport) {
    final type = provider.type;
    final endpoint = Uri.parse(provider.effectiveBaseUrl);
    final apiKey = provider.effectiveApiKey;
    return switch (aiProviderTypeConfigFor(type)?.videoProtocol) {
      VideoProtocol.atlascloud_video => AtlasCloudVideoClient(
        httpClient: transport,
        providerType: type,
        apiKey: apiKey,
      ),
      VideoProtocol.new_api_video => NewApiClient(provider).video(transport),
      VideoProtocol.openrouter_video => OpenRouterVideoClient(
        httpClient: transport,
        providerType: type,
        apiKey: apiKey,
      ),
      VideoProtocol.agnes_video => AgnesVideoClient(
        httpClient: transport,
        providerType: type,
        endpoint: endpoint,
        apiKey: apiKey,
      ),
      VideoProtocol.ark_video => ArkVideoClient(
        httpClient: transport,
        providerType: type,
        endpoint: endpoint,
        apiKey: apiKey,
      ),
      VideoProtocol.wan_video => WanVideoClient(
        httpClient: transport,
        providerType: type,
        endpoint: wanVideoEndpoint(provider.effectiveBaseUrl),
        apiKey: apiKey,
      ),
      VideoProtocol.minimax_video_v2 => MinimaxVideoClient(
        httpClient: transport,
        providerType: type,
        endpoint: endpoint,
        apiKey: apiKey,
      ),
      VideoProtocol.purefox_media => PurefoxVideoClient(
        httpClient: transport,
        providerType: type,
        endpoint: endpoint,
        apiKey: apiKey,
      ),
      null => throw const VideoException(VideoErrorCode.configuration_required),
    };
  }

  Future<GenerationTask> _task(String id) async =>
      await getTask(id) ??
      (throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'task_id',
      ));
  Future<bool> _cancelUnsubmitted(GenerationTask task) async {
    if (task.cancelRequestedAt == null ||
        task.providerTaskId != null ||
        !{
          GenerationTaskStatus.prepared,
          GenerationTaskStatus.uploading,
        }.contains(task.status)) {
      return false;
    }
    await _status(task, GenerationTaskStatus.cancelled);
    return true;
  }

  Future<bool> _status(
    GenerationTask task,
    GenerationTaskStatus status, {
    DateTime? next,
    String? error,
    String? message,
    String? detail,
  }) => database.generationTaskDao.transition(
    task.id,
    {task.status},
    GenerationTasksCompanion(
      status: Value(status),
      nextPollAt: Value(next),
      errorCode: Value(error),
      errorMessage: Value(message),
      errorDetail: Value(detail),
    ),
  );

  File _file(String relative) {
    final normalized = p.normalize(relative);
    if (p.isAbsolute(relative) ||
        normalized == '.' ||
        p.split(normalized).first == '..') {
      throw const VideoException(
        VideoErrorCode.invalid_request,
        field: 'file_path',
      );
    }
    return File(p.join(rootDirectory.path, normalized));
  }

  void _requireActive() {
    if (_disposed) {
      throw StateError('Video task service disposed');
    }
  }

  void _schedule({bool immediate = false}) {
    _timer?.cancel();
    if (!_started ||
        _disposed ||
        (!_online && recoverSources == null) ||
        _draining) {
      return;
    }
    _timer = Timer(
      immediate ? Duration.zero : const Duration(seconds: 1),
      () => unawaited(refreshDue()),
    );
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    for (final client in _clients) {
      client.close();
    }
    _clients.clear();
  }

  Future<void> shutdown() async {
    dispose();
    await _submissions;
    await Future.wait(_creating.values.toList());
    if (_busy.isNotEmpty) {
      _idle ??= Completer<void>();
      await _idle!.future;
    }
  }
}
