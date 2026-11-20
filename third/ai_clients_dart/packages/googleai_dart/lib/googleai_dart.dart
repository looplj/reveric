// 职责: 导出 Reveric 使用的 Gemini 内容生成、流式生成与嵌入 API。
// 关联文件:
//   third/ai_clients_dart/packages/googleai_dart/lib/src/client/googleai_client.dart
//   third/ai_clients_dart/packages/googleai_dart/lib/src/resources/models_resource.dart

library;

export 'src/auth/auth_provider.dart';
export 'src/client/config.dart';
export 'src/client/googleai_client.dart';
export 'src/errors/exceptions.dart';
export 'src/models/content/blob.dart';
export 'src/models/content/content.dart';
export 'src/models/content/part.dart';
export 'src/models/embeddings/embed_content_request.dart';
export 'src/models/embeddings/embed_content_response.dart';
export 'src/models/generation/generate_content_request.dart';
export 'src/models/generation/generate_content_response.dart';
export 'src/models/generation/generation_config.dart';
export 'src/models/generation/schema.dart';
export 'src/models/generation/thinking_config.dart';
export 'src/models/generation/thinking_level.dart';
export 'src/models/metadata/finish_reason.dart';
export 'src/models/metadata/usage_metadata.dart';
export 'src/models/tools/function_call.dart';
export 'src/models/tools/function_declaration.dart';
export 'src/models/tools/function_response.dart';
export 'src/models/tools/tool.dart';
export 'src/resources/models_resource.dart';
