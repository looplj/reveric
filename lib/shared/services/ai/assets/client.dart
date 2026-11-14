// 职责: 定义各渠道私域素材库客户端的公共契约与错误类型。
// 关联文件:
//   lib/shared/services/ai/assets/certification.dart
//   lib/shared/services/ai/assets/volcengine.dart
//   lib/shared/services/ai/assets/atlascloud.dart
//   lib/shared/models/provider_asset.dart

import 'dart:io';
import '../../../models/provider_asset.dart';

/// 本地素材身份与 MIME 由 Host 校验；协议适配层负责取得远端可用引用。
typedef ProviderAssetFile = ({File file, String assetId, String mimeType});
typedef ProviderAssetUrl = Future<Uri> Function(ProviderAssetFile file);

/// 渠道素材库调用失败；[code] 是渠道错误码或本地分类，[message] 是原始错误信息。
class ProviderAssetException implements Exception {
  const ProviderAssetException(this.code, [this.message = '']);
  final String code;
  final String message;
  @override
  String toString() => 'ProviderAssetException($code: $message)';
}

/// 提交结果：[remoteId] 用于生成请求里的 `asset://`；[remoteTaskId] 是查询进度用的 id，
/// 与 [remoteId] 相同的渠道留空。
typedef ProviderAssetSubmission = ({
  String remoteId,
  String? remoteTaskId,
  String? remoteGroupId,
});

typedef ProviderAssetState = ({
  ProviderAssetStatus status,
  String? errorCode,
  String? errorMessage,
});

abstract interface class ProviderAssetClient {
  /// 登记 Host 校验过的本地图片。
  Future<ProviderAssetSubmission> submit({
    required ProviderAssetFile file,
    required String name,
  });

  /// [id] 取 `remoteTaskId ?? remoteId`。
  Future<ProviderAssetState> state(String id);

  void close();
}
