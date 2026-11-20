// 职责: 供应商 config 列的结构化配置，控制请求是否发送温度。
// 关联文件:
//   lib/shared/database/type_converters.dart
//   lib/shared/database/app_database.dart
//   lib/shared/models/ai_provider.dart

class AiProviderConfig {
  const AiProviderConfig({this.enableTemperature = false});

  /// 为 true 时，模型接受 temperature 的请求才会带上该参数。默认不发送。
  final bool enableTemperature;

  factory AiProviderConfig.fromJson(Object? value) {
    if (value is! Map) {
      return const AiProviderConfig();
    }
    return AiProviderConfig(
      enableTemperature: value['enableTemperature'] == true,
    );
  }

  Map<String, dynamic> toJson() => {'enableTemperature': enableTemperature};

  AiProviderConfig copyWith({bool? enableTemperature}) {
    return AiProviderConfig(
      enableTemperature: enableTemperature ?? this.enableTemperature,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AiProviderConfig &&
        other.enableTemperature == enableTemperature;
  }

  @override
  int get hashCode => enableTemperature.hashCode;
}
