// 职责: AI embedding 服务 — 章节文本分块、向量化、搜索、索引重建
// 关联文件:
//   lib/shared/app_config.dart
//   lib/shared/services/ai/chat.dart
//   lib/shared/services/ai/chapter_embedding_sync.dart
//   lib/shared/models/ai_chat_models.dart
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../models/ai_chat_models.dart';
import '../../models/ai_provider.dart';
import '../../logger/app_logger.dart';
import '../novel_content.dart';
import '../../agent/client.dart';
import '../../agent/client/gemini_client.dart' show geminiModelEndpoint;
import 'prompts/use_cases/task_prompt_use_case.dart';

final _log = AppLogger.forModule('Embedding');

class AiEmbeddingService {
  AiEmbeddingService({
    required this._providerClient,
    required this._config,
    required this._novelContentService,
    required this._embeddingModel,
    required this._segmenterModel,
    this.embeddingConfig = const AiEmbeddingConfig(),
  });

  final ProviderClient? _providerClient;
  final AiProvider _config;
  final NovelContentService? _novelContentService;
  final String? _embeddingModel;
  final String? _segmenterModel;
  final AiEmbeddingConfig embeddingConfig;

  String? get embeddingModel {
    final model = _embeddingModel?.trim();
    if (model != null && model.isNotEmpty) {
      return model;
    }
    final models = _config.availableEmbeddingModels;
    if (models.isEmpty) return null;
    return models.first;
  }

  String? get embeddingProviderId => _config.id;

  Future<void> rebuildEmbeddings() async {
    if (_novelContentService == null) return;
    final contentService = _novelContentService;
    final chapters = await contentService.getChapters();
    for (final chapter in chapters) {
      await rebuildChapterEmbeddings(chapter.id);
    }
  }

  Future<void> rebuildChapterEmbeddings(String chapterId) async {
    if (_novelContentService == null) return;
    final contentService = _novelContentService;
    final model = embeddingModel;
    if (model == null || model.isEmpty) return;
    final chapter = await contentService.getChapterById(chapterId);
    if (chapter == null) return;

    final jobs =
        <
          ({
            String sourceId,
            String sourceType,
            String path,
            String title,
            String text,
            Map<String, dynamic> metadata,
          })
        >[];

    if (chapter.outline.trim().isNotEmpty) {
      jobs.add((
        sourceId: '${chapter.id}:outline',
        sourceType: AiEmbeddingSourceType.chapter_outline.name,
        path: '/chapters/${chapter.id}/outline',
        title: chapter.title ?? 'Untitled Chapter',
        text: chapter.outline,
        metadata: {
          'chapter_id': chapter.id,
          'chapter_num': chapter.chapterNum,
          'field': 'outline',
        },
      ));
    } else {
      await contentService.deleteEmbeddingDocumentsBySource(
        '${chapter.id}:outline',
      );
    }

    if (chapter.content.trim().isNotEmpty) {
      jobs.add((
        sourceId: '${chapter.id}:content',
        sourceType: AiEmbeddingSourceType.chapter_content.name,
        path: '/chapters/${chapter.id}/content',
        title: chapter.title ?? 'Untitled Chapter',
        text: chapter.content,
        metadata: {
          'chapter_id': chapter.id,
          'chapter_num': chapter.chapterNum,
          'field': 'content',
        },
      ));
    } else {
      await contentService.deleteEmbeddingDocumentsBySource(
        '${chapter.id}:content',
      );
    }

    for (final job in jobs) {
      var chunks = await _chunkTextWithSegmenter(
        sourceId: job.sourceId,
        sourceType: job.sourceType,
        text: job.text,
        metadata: job.metadata,
      );
      if (chunks.isEmpty) {
        chunks = _chunkText(
          sourceId: job.sourceId,
          sourceType: job.sourceType,
          text: job.text,
          metadata: job.metadata,
        );
      }
      if (chunks.isEmpty) continue;
      final embeddings = await _embedTexts(
        chunks.map((e) => e.text).toList(),
        tag: chapter.id,
      );
      await contentService.replaceEmbeddingDocuments(
        sourceId: job.sourceId,
        sourceType: job.sourceType,
        path: job.path,
        title: job.title,
        embeddingModel: model,
        providerId: embeddingProviderId,
        chunks: chunks,
        vectors: embeddings,
      );
    }
  }

  Future<void> rebuildAllChapterEmbeddings() async {
    if (_novelContentService == null) return;
    final contentService = _novelContentService;
    final chapters = await contentService.getChapters();
    for (final chapter in chapters) {
      await rebuildChapterEmbeddings(chapter.id);
    }
  }

  Future<List<AiEmbeddingSearchResult>> searchEmbeddings(
    String query, {
    int? limit,
  }) async {
    if (_novelContentService == null) return const [];
    final contentService = _novelContentService;
    final model = embeddingModel;
    if (model == null || model.isEmpty || query.trim().isEmpty) {
      return const [];
    }

    final queryEmbedding = await _embedTexts([query]);
    if (queryEmbedding.isEmpty) return const [];
    final queryVector = queryEmbedding.first;

    final docs = await contentService.getEmbeddingDocuments();
    final scored = <AiEmbeddingSearchResult>[];
    for (final doc in docs) {
      final vector = doc.vector;
      if (vector.isEmpty) continue;
      final score = _cosineSimilarity(queryVector, vector);
      if (!score.isFinite) continue;
      scored.add(
        AiEmbeddingSearchResult(
          sourceId: doc.sourceId,
          sourceType: doc.sourceType,
          chunkId: doc.id,
          path: doc.path,
          title: doc.title,
          excerpt: _trimExcerpt(doc.content),
          score: score,
          chunkIndex: doc.chunkIndex,
          metadata: doc.metadata,
        ),
      );
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(limit ?? embeddingConfig.maxResults).toList();
  }

  Future<List<List<double>>> _embedTexts(
    List<String> texts, {
    String? tag,
  }) async {
    if (_log.isDebugEnabled) {
      _log.debug(
        '[Router]${tag != null ? " chapter=$tag" : ""}'
        ' provider=${_config.name} type=${_config.typeEnum.name}',
      );
    }
    if (_config.typeEnum == AiProviderType.doubao) {
      return _embedTextsDoubao(texts, tag: tag);
    }
    if (_config.typeEnum == AiProviderType.gemini) {
      return _embedTextsGemini(texts, tag: tag);
    }
    return _embedTextsOpenAICompatible(texts, tag: tag);
  }

  Future<List<List<double>>> _embedTextsGemini(
    List<String> texts, {
    String? tag,
  }) async {
    final model = embeddingModel;
    if (model == null || model.isEmpty) {
      throw Exception('No embedding model configured');
    }
    if (_providerClient == null) {
      throw Exception('AI service not initialized');
    }
    final results = <List<double>>[];
    for (final text in texts) {
      final vector = await _providerClient.embed(text, model: model);
      results.add(vector);
    }
    return results;
  }

  Future<List<List<double>>> _embedTextsDoubao(
    List<String> texts, {
    String? tag,
  }) async {
    final model = embeddingModel;
    if (model == null || model.isEmpty) {
      throw Exception('No embedding model configured');
    }
    final url = Uri.parse('${_config.effectiveBaseUrl}/embeddings/multimodal');
    final results = <List<double>>[];
    for (final text in texts) {
      final body = jsonEncode({
        'model': model,
        'input': [
          {'type': 'text', 'text': text},
        ],
        'encoding_format': 'float',
      });
      if (_log.isDebugEnabled) {
        _log.debug(
          '[Doubao]${tag != null ? " chapter=$tag" : ""}'
          ' provider=${_config.name} model=$model POST $url chars=${text.length}',
        );
      }
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${_config.effectiveApiKey}',
        },
        body: body,
      );
      if (response.statusCode != 200) {
        throw Exception(
          'Doubao embedding failed (${response.statusCode}): ${response.body}',
        );
      }
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final data = decoded['data'] as Map<String, dynamic>;
      final embedding = data['embedding'] as List;
      results.add(embedding.map((e) => (e as num).toDouble()).toList());
    }
    if (_log.isDebugEnabled) {
      _log.debug(
        '[Doubao]${tag != null ? " chapter=$tag" : ""} done vectors=${results.length}',
      );
    }
    return results;
  }

  Future<List<List<double>>> _embedTextsOpenAICompatible(
    List<String> texts, {
    String? tag,
  }) async {
    final model = embeddingModel;
    if (model == null || model.isEmpty) {
      throw Exception('No embedding model configured');
    }

    // If we have a ProviderClient for OpenAI, use it
    if (_providerClient != null && _config.typeEnum != AiProviderType.gemini) {
      final results = <List<double>>[];
      for (final text in texts) {
        final vector = await _providerClient.embed(text, model: model);
        results.add(vector);
      }
      return results;
    }

    // Fallback: direct HTTP call
    final url = Uri.parse('${_config.effectiveBaseUrl}/embeddings');
    final results = <List<double>>[];
    const batchSize = 20;
    for (var i = 0; i < texts.length; i += batchSize) {
      final batch = texts.sublist(i, (i + batchSize).clamp(0, texts.length));
      final body = jsonEncode({
        'model': model,
        'input': batch,
        'encoding_format': 'float',
      });
      if (_log.isDebugEnabled) {
        _log.debug(
          '[OpenAI]${tag != null ? " chapter=$tag" : ""}'
          ' provider=${_config.name} POST $url model=$model batch=${batch.length}',
        );
      }
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${_config.effectiveApiKey}',
        },
        body: body,
      );
      if (response.statusCode != 200) {
        throw Exception(
          'Embedding failed (${response.statusCode}): ${response.body}',
        );
      }
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final data = decoded['data'] as List<dynamic>;
      for (final item in data) {
        final embedding = (item as Map<String, dynamic>)['embedding'] as List;
        results.add(embedding.map((e) => (e as num).toDouble()).toList());
      }
    }
    if (_log.isDebugEnabled) {
      _log.debug(
        '[OpenAI]${tag != null ? " chapter=$tag" : ""} done vectors=${results.length}',
      );
    }
    return results;
  }

  Future<List<AiEmbeddingChunk>> _chunkTextWithSegmenter({
    required String sourceId,
    required String sourceType,
    required String text,
    required Map<String, dynamic> metadata,
  }) async {
    final normalized = text.trim();
    if (normalized.isEmpty ||
        _segmenterModel == null ||
        _segmenterModel.isEmpty) {
      return const [];
    }

    final segmenterModel = _segmenterModel;
    const taskPrompt = TaskPromptUseCase();
    final prompt = taskPrompt.chunkSegmentation(
      text: normalized,
      targetChunkChars: embeddingConfig.targetChunkChars,
      maxChunkChars: embeddingConfig.maxChunkChars,
      overlapChars: embeddingConfig.overlapChars,
    );

    String raw;
    try {
      raw = await _segmenterCall(segmenterModel, prompt);
    } catch (_) {
      return const [];
    }

    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const [];

    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(trimmed) as Map<String, dynamic>;
    } catch (_) {
      return const [];
    }

    final items = decoded['chunks'];
    if (items is! List) return const [];

    final chunks = <AiEmbeddingChunk>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is! Map) continue;
      final piece = (item['text'] as String? ?? '').trim();
      if (piece.isEmpty) continue;
      final startOffset = (item['start_offset'] as num?)?.toInt() ?? 0;
      final endOffset =
          (item['end_offset'] as num?)?.toInt() ?? (startOffset + piece.length);
      chunks.add(
        AiEmbeddingChunk(
          sourceId: sourceId,
          sourceType: sourceType,
          chunkId: '$sourceId:${chunks.length}',
          chunkIndex: chunks.length,
          startOffset: startOffset,
          endOffset: endOffset,
          text: piece,
          metadata: metadata,
        ),
      );
    }
    return chunks;
  }

  Future<String> _segmenterCall(String model, String prompt) async {
    switch (_config.typeEnum) {
      case AiProviderType.gemini:
        return _segmenterCallGemini(model, prompt);
      case AiProviderType.anthropic:
        return _segmenterCallAnthropic(model, prompt);
      default:
        return _segmenterCallOpenAICompatible(model, prompt);
    }
  }

  Future<String> _segmenterCallGemini(String model, String prompt) async {
    final url = geminiModelEndpoint(
      _config.effectiveBaseUrl,
      model,
      'generateContent',
    );
    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt},
          ],
        },
      ],
    });
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'x-goog-api-key': _config.effectiveApiKey,
      },
      body: body,
    );
    if (response.statusCode != 200) {
      throw Exception('Gemini segmenter error: ${response.statusCode}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = data['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) return '';
    final content = candidates[0]['content'] as Map<String, dynamic>?;
    if (content == null) return '';
    final parts = content['parts'] as List? ?? [];
    return parts
        .whereType<Map<String, dynamic>>()
        .map((p) => p['text'] as String? ?? '')
        .join();
  }

  Future<String> _segmenterCallAnthropic(String model, String prompt) async {
    final url = Uri.parse('${_config.effectiveBaseUrl}/v1/messages');
    final body = jsonEncode({
      'model': model,
      'max_tokens': 4096,
      'messages': [
        {'role': 'user', 'content': prompt},
      ],
    });
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': _config.effectiveApiKey,
        'anthropic-version': '2023-06-01',
      },
      body: body,
    );
    if (response.statusCode != 200) {
      throw Exception('Anthropic segmenter error: ${response.statusCode}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final content = data['content'] as List?;
    if (content == null || content.isEmpty) return '';
    return content
        .whereType<Map<String, dynamic>>()
        .where((b) => b['type'] == 'text')
        .map((b) => b['text'] as String? ?? '')
        .join();
  }

  Future<String> _segmenterCallOpenAICompatible(
    String model,
    String prompt,
  ) async {
    final url = Uri.parse('${_config.effectiveBaseUrl}/chat/completions');
    final body = jsonEncode({
      'model': model,
      'messages': [
        {'role': 'user', 'content': prompt},
      ],
      'max_tokens': 4096,
    });
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${_config.effectiveApiKey}',
      },
      body: body,
    );
    if (response.statusCode != 200) {
      throw Exception(
        'Segmenter error (${response.statusCode}): ${response.body}',
      );
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = data['choices'] as List?;
    if (choices == null || choices.isEmpty) return '';
    return (choices[0]['message']?['content'] as String? ?? '').trim();
  }

  List<AiEmbeddingChunk> _chunkText({
    required String sourceId,
    required String sourceType,
    required String text,
    required Map<String, dynamic> metadata,
  }) {
    final normalized = text.trim();
    if (normalized.isEmpty) return const [];

    final segments = embeddingConfig.strategy == AiChunkingStrategy.paragraph
        ? normalized.split(RegExp(r'\n\s*\n+'))
        : _splitHeadingAware(normalized);

    final chunks = <AiEmbeddingChunk>[];
    var offset = 0;
    var chunkIndex = 0;
    var buffer = StringBuffer();
    var bufferStart = 0;

    void flush() {
      final raw = buffer.toString().trim();
      if (raw.isEmpty) {
        buffer = StringBuffer();
        return;
      }
      final start = bufferStart;
      final end = start + raw.length;
      chunks.add(
        AiEmbeddingChunk(
          sourceId: sourceId,
          sourceType: sourceType,
          chunkId: '$sourceId:$chunkIndex',
          chunkIndex: chunkIndex,
          startOffset: start,
          endOffset: end,
          text: raw,
          metadata: metadata,
        ),
      );
      chunkIndex += 1;
      buffer = StringBuffer();
    }

    for (final segment in segments) {
      final part = segment.trim();
      if (part.isEmpty) {
        offset += segment.length + 2;
        continue;
      }
      if (buffer.isEmpty) {
        bufferStart = offset;
      }
      final candidate = buffer.isEmpty ? part : '${buffer.toString()}\n\n$part';
      if (candidate.length <= embeddingConfig.targetChunkChars) {
        if (buffer.isNotEmpty) buffer.write('\n\n');
        buffer.write(part);
      } else {
        flush();
        if (part.length <= embeddingConfig.maxChunkChars) {
          bufferStart = offset;
          buffer.write(part);
        } else {
          final pieces = _sliceLongSegment(part);
          for (final piece in pieces) {
            chunks.add(
              AiEmbeddingChunk(
                sourceId: sourceId,
                sourceType: sourceType,
                chunkId: '$sourceId:$chunkIndex',
                chunkIndex: chunkIndex,
                startOffset: offset,
                endOffset: offset + piece.length,
                text: piece,
                metadata: metadata,
              ),
            );
            chunkIndex += 1;
          }
        }
      }
      offset += segment.length + 2;
    }
    flush();
    return chunks;
  }

  List<String> _splitHeadingAware(String text) {
    final lines = text.split('\n');
    final segments = <String>[];
    final buffer = StringBuffer();
    final headingPattern = RegExp(
      r'^(#{1,6}\s+|第.{0,20}[章节幕卷集回]|[一二三四五六七八九十]+\s*[、.])',
    );

    void flush() {
      final value = buffer.toString().trim();
      if (value.isNotEmpty) {
        segments.add(value);
      }
      buffer.clear();
    }

    for (final line in lines) {
      final isHeading = headingPattern.hasMatch(line.trim());
      if (isHeading && buffer.isNotEmpty) {
        flush();
      }
      if (buffer.isNotEmpty) {
        buffer.writeln();
      }
      buffer.write(line);
    }
    flush();
    return segments.isEmpty ? [text] : segments;
  }

  List<String> _sliceLongSegment(String text) {
    final chunks = <String>[];
    final maxChars = embeddingConfig.maxChunkChars;
    final overlap = embeddingConfig.overlapChars;
    var start = 0;
    while (start < text.length) {
      final end = (start + maxChars).clamp(0, text.length);
      chunks.add(text.substring(start, end).trim());
      if (end >= text.length) break;
      start = end - overlap;
      if (start < 0) start = 0;
    }
    return chunks.where((item) => item.isNotEmpty).toList();
  }

  double _cosineSimilarity(List<double> left, List<double> right) {
    if (left.length != right.length || left.isEmpty) return double.nan;
    var dot = 0.0;
    var leftNorm = 0.0;
    var rightNorm = 0.0;
    for (var i = 0; i < left.length; i++) {
      final a = left[i];
      final b = right[i];
      dot += a * b;
      leftNorm += a * a;
      rightNorm += b * b;
    }
    if (leftNorm == 0 || rightNorm == 0) return double.nan;
    return dot / (sqrt(leftNorm) * sqrt(rightNorm));
  }

  String _trimExcerpt(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= 240) return normalized;
    return '${normalized.substring(0, 240)}...';
  }
}
