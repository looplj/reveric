// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ai_run_failure.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

AiRunFailure _$AiRunFailureFromJson(Map<String, dynamic> json) => AiRunFailure(
  kind: $enumDecode(_$AiRunFailureKindEnumMap, json['kind']),
  statusCode: (json['status_code'] as num?)?.toInt(),
  providerId: json['provider_id'] as String?,
  providerMessage: json['provider_message'] as String?,
  providerCode: json['provider_code'] as String?,
);

Map<String, dynamic> _$AiRunFailureToJson(AiRunFailure instance) =>
    <String, dynamic>{
      'kind': _$AiRunFailureKindEnumMap[instance.kind]!,
      'status_code': instance.statusCode,
      'provider_id': instance.providerId,
      'provider_message': instance.providerMessage,
      'provider_code': instance.providerCode,
    };

const _$AiRunFailureKindEnumMap = {
  AiRunFailureKind.http: 'http',
  AiRunFailureKind.network: 'network',
  AiRunFailureKind.streamInterrupted: 'streamInterrupted',
  AiRunFailureKind.contextWindowExhausted: 'contextWindowExhausted',
  AiRunFailureKind.incompleteResponse: 'incompleteResponse',
  AiRunFailureKind.invalid_conversation_history: 'invalid_conversation_history',
  AiRunFailureKind.requestFailed: 'requestFailed',
};
