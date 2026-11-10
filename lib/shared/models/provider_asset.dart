// 职责: 定义本地素材在渠道中的上传、认证用途与处理状态。
// 关联文件:
//   lib/shared/database/app_database.dart
//   lib/shared/database/daos/provider_asset_dao.dart
//   lib/shared/services/ai/assets/certification.dart

enum ProviderAssetKind { certification, upload }

enum ProviderAssetStatus { processing, active, failed }

/// 渠道素材库引用：生成请求里用它代替素材文件的 URL。
String providerAssetUri(String remoteId) => 'asset://$remoteId';
