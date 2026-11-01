// 职责: 解析 New API 模型目录，并按模型名选择聊天协议。
// 关联文件:
//   lib/shared/services/ai/new_api.dart
//   lib/shared/models/ai_provider.dart

enum NewApiChatProtocol {
  responses,
  anthropic,
  gemini,
  openai;

  static NewApiChatProtocol forModel(String model) {
    final name = model.toLowerCase().split('/').last;
    return name.startsWith('claude-')
        ? NewApiChatProtocol.anthropic
        : name.startsWith('gemini-')
        ? NewApiChatProtocol.gemini
        : name.startsWith('gpt-') || RegExp(r'^o[134](?:-|$)').hasMatch(name)
        ? NewApiChatProtocol.responses
        : NewApiChatProtocol.openai;
  }
}

class NewApiModel {
  const NewApiModel({required this.id, required this.endpointTypes});
  final String id;
  final Set<String> endpointTypes;

  factory NewApiModel.fromJson(Map<String, dynamic> json) => NewApiModel(
    id: json['id'] as String,
    endpointTypes: (json['supported_endpoint_types'] as List? ?? [])
        .cast<String>()
        .toSet(),
  );
}
