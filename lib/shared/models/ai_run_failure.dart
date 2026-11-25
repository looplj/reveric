// 职责: AI 运行失败模型 — 以稳定错误类型、HTTP 状态码和供应商标识跨层传递失败原因。
// 关联文件:
//   lib/shared/agent/agent_event.dart
//   lib/shared/localization/ai_run_failure_localization.dart
//   lib/shared/widgets/ai/ai_mode_error_notice.dart

import 'package:json_annotation/json_annotation.dart';

part 'ai_run_failure.g.dart';

enum AiRunFailureKind {
  http,
  network,
  streamInterrupted,
  contextWindowExhausted,
  incompleteResponse,
  invalid_conversation_history,
  requestFailed,
}

@JsonSerializable(fieldRename: FieldRename.snake)
class AiRunFailure {
  const AiRunFailure({
    required this.kind,
    this.statusCode,
    this.providerId,
    this.providerMessage,
    this.providerCode,
  });

  const AiRunFailure.http({
    required int statusCode,
    String? providerId,
    String? providerMessage,
    String? providerCode,
  }) : this(
         kind: AiRunFailureKind.http,
         statusCode: statusCode,
         providerId: providerId,
         providerMessage: providerMessage,
         providerCode: providerCode,
       );

  const AiRunFailure.network({String? providerId})
    : this(kind: AiRunFailureKind.network, providerId: providerId);

  const AiRunFailure.streamInterrupted({
    String? providerId,
    String? providerMessage,
    String? providerCode,
  }) : this(
         kind: AiRunFailureKind.streamInterrupted,
         providerId: providerId,
         providerMessage: providerMessage,
         providerCode: providerCode,
       );

  const AiRunFailure.contextWindowExhausted({String? providerId})
    : this(
        kind: AiRunFailureKind.contextWindowExhausted,
        providerId: providerId,
      );

  const AiRunFailure.incompleteResponse({String? providerId})
    : this(kind: AiRunFailureKind.incompleteResponse, providerId: providerId);

  const AiRunFailure.requestFailed({
    String? providerId,
    String? providerMessage,
    String? providerCode,
  }) : this(
         kind: AiRunFailureKind.requestFailed,
         providerId: providerId,
         providerMessage: providerMessage,
         providerCode: providerCode,
       );

  final AiRunFailureKind kind;
  final int? statusCode;
  final String? providerId;

  /// 从 provider 响应提取的消息，不包含异常包装或完整响应体。
  final String? providerMessage;

  /// 供应商结构化错误码，仅用于分类，不直接展示给用户。
  final String? providerCode;

  bool get isPaymentRequired =>
      kind == AiRunFailureKind.http && statusCode == 402;

  AiRunFailure withProviderId(String? value) {
    if (providerId != null || value == null || value.isEmpty) {
      return this;
    }
    return AiRunFailure(
      kind: kind,
      statusCode: statusCode,
      providerId: value,
      providerMessage: providerMessage,
      providerCode: providerCode,
    );
  }

  factory AiRunFailure.fromJson(Map<String, dynamic> json) =>
      _$AiRunFailureFromJson(json);

  Map<String, dynamic> toJson() => _$AiRunFailureToJson(this);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiRunFailure &&
          kind == other.kind &&
          statusCode == other.statusCode &&
          providerId == other.providerId &&
          providerMessage == other.providerMessage &&
          providerCode == other.providerCode;

  @override
  int get hashCode =>
      Object.hash(kind, statusCode, providerId, providerMessage, providerCode);

  @override
  String toString() =>
      'AiRunFailure(kind: ${kind.name}, statusCode: $statusCode, '
      'providerId: $providerId, providerCode: $providerCode, providerMessage: $providerMessage)';
}
