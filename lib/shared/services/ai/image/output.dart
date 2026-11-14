// 职责: 在 Host 内下载、校验、暂存图片输出及裁切 Midjourney 四候选。
// 关联文件:
//   lib/shared/services/ai/image.dart
//   lib/shared/services/plugins/media_files.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:uuid/uuid.dart';
import '../../../models/ai_provider.dart';
import '../../../models/generation/provider_result.dart';
import 'package:mime/mime.dart';
import 'package:crypto/crypto.dart';
import '../../../models/production/image_request.dart'
    show ProductionImageReference;
import '../../../utils/storage_paths.dart';
import '../../plugins/files.dart';
import '../../plugins/runtime.dart' show PluginHostError;
import '../../plugins/media_files.dart';
import '../image.dart';

class ImageOutputContext {
  ImageOutputContext(this.provider, {String? taskId, PluginMediaFiles? files})
    : _files = files,
      inputScope =
          files?.scope ??
          PluginFileScope(
            pluginId: provider.pluginId ?? provider.type,
            providerId: provider.id,
            taskId: taskId ?? const Uuid().v4(),
          );
  final AiProvider provider;
  final PluginFileScope inputScope;
  PluginMediaFiles? _files;
  Directory? _inputDirectory;
  PluginMediaFiles get files => _files ??= PluginMediaFiles(
    directory: Directory('${RevericPaths.fileWorkspaceParent}/file_workspaces'),
    scope: inputScope,
  );

  Future<List<(ProductionImageReference, File, String)>> importReferenceFiles(
    List<String> inputs, {
    List<ProductionImageReference>? identities,
  }) async {
    if (identities != null && identities.length != inputs.length) {
      throw const ProviderFailure(
        code: 'invalid_request',
        message: 'Reference identities do not match files',
      );
    }
    final result = <(ProductionImageReference, File, String)>[];
    for (var index = 0; index < inputs.length; index++) {
      _active();
      final input = inputs[index].trim();
      if (input.startsWith('content://')) {
        throw const ProviderFailure(
          code: 'invalid_request',
          message: 'Import the reference into application storage first',
        );
      }
      final File file;
      final List<int> header;
      if (!input.startsWith('data:') &&
          !input.startsWith('http://') &&
          !input.startsWith('https://') &&
          await File(input).exists()) {
        file = File(input);
        final opened = await file.open();
        try {
          header = await opened.read(32);
        } finally {
          await opened.close();
        }
      } else {
        final data = input.startsWith('data:')
            ? UriData.parse(input).contentAsBytes()
            : input.startsWith('http://') || input.startsWith('https://')
            ? await download(ProviderUrlOutput(input))
            : base64Decode(input);
        _active();
        _inputDirectory ??= await Directory.systemTemp.createTemp(
          'reveric-image-input-',
        );
        final mime = lookupMimeType('', headerBytes: data);
        if (mime == null || !mime.startsWith('image/')) {
          throw const ProviderFailure(
            code: 'invalid_request',
            message: 'Invalid image reference',
          );
        }
        file = await File(
          '${_inputDirectory!.path}/reference-$index.${mime.split('/').last}',
        ).writeAsBytes(data);
        header = data;
      }
      final mime = lookupMimeType(file.path, headerBytes: header);
      if (mime == null || !mime.startsWith('image/')) {
        throw const ProviderFailure(
          code: 'invalid_request',
          message: 'Invalid image reference',
        );
      }
      _active();
      final identity = identities == null
          ? ProductionImageReference(
              assetId: 'inline-${(await sha256.bind(file.openRead()).first)}',
            )
          : identities[index];
      if (identity.assetId.trim().isEmpty) {
        throw const ProviderFailure(
          code: 'invalid_request',
          message: 'Reference identity is empty',
        );
      }
      result.add((identity, file, mime));
    }
    return result;
  }

  void claimInputs() => inputScope.claim(
    pluginId: inputScope.pluginId,
    providerId: provider.id,
    taskId: inputScope.taskId,
  );
  Future<void> disposeInputs() async {
    inputScope.revoke();
    final directory = _inputDirectory;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  final _fileStores = <String, PluginMediaFiles>{};
  void adopt(ProviderSucceeded result, PluginMediaFiles store) {
    for (final output in result.outputs.whereType<ProviderFileOutput>()) {
      store.validateOutput(output.handle, output.mimeType, output.byteLength);
      _fileStores[output.handle] = store;
    }
  }

  File outputFile(String handle) =>
      (_fileStores[handle] ?? files).output(handle);
  Future<ProviderFileOutput> restoreFile(File file) async {
    final opened = await file.open();
    final List<int> header;
    try {
      header = await opened.read(32);
    } finally {
      await opened.close();
    }
    final mime = lookupMimeType(file.path, headerBytes: header);
    if (mime == null || !mime.startsWith('image/')) {
      throw const ProviderFailure(
        code: 'invalid_response',
        message: 'Stored image is invalid',
      );
    }
    return ProviderOutput.fromJson(
          files.bindRecovered(file, mime, await file.length()),
        )
        as ProviderFileOutput;
  }

  final _preserved = <int, ProviderFileOutput>{};
  void preserve(int index, ProviderFileOutput output) =>
      _preserved[index] = output;
  Future<ProviderSucceeded> mergePreserved(ProviderSucceeded result) async {
    if (_preserved.keys.any((index) => index >= result.outputs.length)) {
      throw const ProviderFailure(
        code: 'invalid_response',
        message: 'Candidate count changed',
      );
    }
    final values = result.outputs.toList();
    for (final entry in _preserved.entries) {
      final replaced = values[entry.key];
      if (replaced is ProviderFileOutput &&
          replaced.handle != entry.value.handle) {
        await (_fileStores[replaced.handle] ?? files).discard(replaced.handle);
      }
      values[entry.key] = entry.value;
    }
    return ProviderSucceeded(values);
  }

  Future<void> confirm(ProviderSucceeded result) async {
    // 鉴权下载头只在内存中使用，不写入暂存回执。
    final receipt = result.outputs
        .map(
          (output) => output is ProviderUrlOutput
              ? ProviderUrlOutput(output.url).toJson()
              : output.toJson(),
        )
        .toList();
    for (final output in result.outputs.whereType<ProviderFileOutput>()) {
      final store = _fileStores[output.handle] ?? files;
      store.validateOutput(output.handle, output.mimeType, output.byteLength);
      await store.confirm(output.handle, receipt);
    }
  }

  final _grids = <String>{};
  final _urlPrompts = <String, String?>{};
  bool hasGrid(ProviderSucceeded result) => result.outputs.any(
    (output) => _grids.contains(
      output is ProviderUrlOutput
          ? output.url
          : (output as ProviderFileOutput).handle,
    ),
  );
  final _metadata =
      <String, ({String? url, String? revised, String? base64})>{};
  bool _cancelled = false;
  final _clients = <http.Client>{};
  void cancel() {
    _cancelled = true;
    inputScope.revoke();
    for (final client in _clients) {
      client.close();
    }
  }

  void _active() {
    if (_cancelled) {
      throw const ProviderFailure(
        code: 'cancelled',
        message: 'Image processing cancelled',
      );
    }
  }

  Future<ProviderFileOutput> bytes(
    List<int> bytes, {
    String? url,
    String? revised,
    String? base64,
  }) async {
    _active();
    final staged =
        ProviderOutput.fromJson(await files.stage(bytes, ensureActive: _active))
            as ProviderFileOutput;
    _metadata[staged.handle] = (url: url, revised: revised, base64: base64);
    return staged;
  }

  Future<ProviderSucceeded> nativeImages(
    List<Map<String, dynamic>> images,
  ) async {
    try {
      final outputs = <ProviderOutput>[];
      for (final image in images) {
        final b64 = image['b64_json'];
        final url = image['url'];
        if (b64 is String && b64.isNotEmpty) {
          outputs.add(
            await bytes(
              base64Decode(b64),
              revised: image['revised_prompt'] as String?,
              base64: b64,
            ),
          );
        } else if (url is String && url.startsWith('data:')) {
          outputs.add(
            await bytes(
              UriData.parse(url).contentAsBytes(),
              revised: image['revised_prompt'] as String?,
            ),
          );
        } else if (url is String && url.isNotEmpty) {
          _urlPrompts[url] = image['revised_prompt'] as String?;
          outputs.add(ProviderUrlOutput(url));
        } else {
          throw const ProviderFailure(
            code: 'invalid_response',
            message: 'Image result has no image',
          );
        }
      }
      return ProviderSucceeded(outputs);
    } on FormatException catch (error) {
      throw invalidImageOutputs(error);
    } on PluginHostError catch (error) {
      if (error.code == 'invalid_response') {
        throw invalidImageOutputs(error);
      }
      rethrow;
    } on ProviderFailure catch (error) {
      if (error.code == 'invalid_response') {
        throw invalidImageOutputs(error);
      }
      rethrow;
    }
  }

  Future<Uint8List> download(ProviderUrlOutput output) async {
    _active();
    final client = provider.createProxyClient() ?? http.Client();
    _clients.add(client);
    Future<Uint8List> fetch() async {
      var uri = Uri.parse(output.url);
      var headers = output.headers;
      for (var redirects = 0; ; redirects++) {
        _active();
        final request = http.Request('GET', uri)
          ..followRedirects = false
          ..headers.addAll(headers);
        final response = await client.send(request);
        final location = response.headers['location'];
        if ({301, 302, 303, 307, 308}.contains(response.statusCode) &&
            location != null) {
          if (redirects >= 5) {
            throw const FormatException('Too many image redirects');
          }
          uri = uri.resolve(location);
          ProviderUrlOutput(uri.toString());
          headers = const {};
          await response.stream.drain<void>();
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw HttpException('Image download HTTP ${response.statusCode}');
        }
        final bytes = BytesBuilder(copy: false);
        var length = 0;
        await for (final chunk in response.stream) {
          length += chunk.length;
          if (length > 128 * 1024 * 1024) {
            throw const FormatException('Image exceeds 128 MB');
          }
          bytes.add(chunk);
        }
        return bytes.takeBytes();
      }
    }

    try {
      return await fetch().timeout(const Duration(minutes: 5));
    } finally {
      _clients.remove(client);
      client.close();
    }
  }

  Future<ProviderSucceeded> grid(String url) async {
    final ProviderOutput output;
    if (url.startsWith('data:')) {
      output = await bytes(UriData.parse(url).contentAsBytes());
    } else {
      output = ProviderUrlOutput(url);
    }
    _grids.add(
      output is ProviderUrlOutput
          ? output.url
          : (output as ProviderFileOutput).handle,
    );
    return ProviderSucceeded([output]);
  }

  Future<ProviderSucceeded> expand(ProviderSucceeded result) async {
    final candidates = <ProviderOutput>[];
    for (final output in result.outputs) {
      final key = output is ProviderUrlOutput
          ? output.url
          : (output as ProviderFileOutput).handle;
      if (_grids.contains(key)) {
        final data = output is ProviderUrlOutput
            ? await download(output)
            : await files.output(key).readAsBytes();
        for (final part in await compute(_splitGrid, data)) {
          candidates.add(await bytes(part));
        }
        if (output is ProviderFileOutput) {
          await files.discard(output.handle);
        }
      } else {
        candidates.add(output);
      }
    }
    return ProviderSucceeded(candidates);
  }

  Future<AiImageGenerationResult> materialize(
    ProviderSucceeded result, {
    Future<void> Function(int index, ProviderFileOutput output)? onCandidate,
  }) async {
    final images = <AiImageGenerationResult>[];
    for (final (index, output) in result.outputs.indexed) {
      _active();
      final ProviderFileOutput file;
      if (output is ProviderUrlOutput) {
        try {
          file = await bytes(
            await download(output),
            url: output.url,
            revised: _urlPrompts[output.url],
          );
        } catch (error) {
          throw AiImageFetchException(
            '图片下载失败，请稍后重试。',
            url: output.url,
            urls: result.outputs
                .whereType<ProviderUrlOutput>()
                .map((e) => e.url)
                .toList(),
            debugMessage: '$error',
          );
        }
      } else {
        file = output as ProviderFileOutput;
      }
      await onCandidate?.call(index, file);
      final metadata = _metadata[file.handle];
      images.add(
        AiImageGenerationResult(
          localFilePath: outputFile(file.handle).path,
          outputHandle: file.handle,
          imageUrl: metadata?.url,
          imageBase64: metadata?.base64,
          revisedPrompt: metadata?.revised,
          mimeSubtype: file.mimeType.split('/').last,
        ),
      );
    }
    return AiImageGenerationResult.group(images);
  }
}

List<Uint8List> _splitGrid(Uint8List bytes) {
  final image = img.decodeImage(bytes);
  if (image == null ||
      image.width < 2 ||
      image.height < 2 ||
      image.width.isOdd ||
      image.height.isOdd) {
    throw const FormatException('Invalid Midjourney grid');
  }
  final w = image.width ~/ 2;
  final h = image.height ~/ 2;
  return [
    for (var i = 0; i < 4; i++)
      img.encodePng(
        img.copyCrop(
          image,
          x: (i % 2) * w,
          y: (i ~/ 2) * h,
          width: w,
          height: h,
        ),
      ),
  ];
}
