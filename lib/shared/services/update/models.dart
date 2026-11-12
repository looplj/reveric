// 职责: 自动升级数据模型 — 检查结果、版本信息、下载状态、进度
// 关联文件:
//   lib/shared/services/update/update_service.dart
//   lib/shared/services/update/update_source.dart
//   lib/shared/services/update/sources/github_releases_source.dart
// 遵循的 Rules:
//   .agents/rules/state-management.md

/// 版本比较 (semver 逐段比较, 忽略 build metadata)
bool isNewerVersion(String latest, String current) {
  String stripBuild(String v) => v.split('+').first;
  final latestParts = stripBuild(latest).split('.').map(int.tryParse).toList();
  final currentParts = stripBuild(
    current,
  ).split('.').map(int.tryParse).toList();

  for (var i = 0; i < latestParts.length && i < currentParts.length; i++) {
    final l = latestParts[i] ?? 0;
    final c = currentParts[i] ?? 0;
    if (l != c) return l > c;
  }
  return latestParts.length > currentParts.length;
}

/// 检查结果
sealed class UpdateCheckResult {
  const UpdateCheckResult();
}

final class UpdateAvailable extends UpdateCheckResult {
  final UpdateInfo info;
  const UpdateAvailable(this.info);
}

final class UpdateUpToDate extends UpdateCheckResult {
  const UpdateUpToDate();
}

final class UpdateCheckFailed extends UpdateCheckResult {
  final String error;
  const UpdateCheckFailed(this.error);
}

/// 单个版本更新信息
class UpdateInfo {
  final String version;
  final String downloadUrl;
  final String? fallbackDownloadUrl;
  final int? fileSize;
  final String? releaseNotes;

  const UpdateInfo({
    required this.version,
    required this.downloadUrl,
    this.fallbackDownloadUrl,
    this.fileSize,
    this.releaseNotes,
  });

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    return UpdateInfo(
      version: json['version'] as String,
      downloadUrl: json['download_url'] as String,
      fileSize: json['file_size'] as int?,
      releaseNotes: json['release_notes'] as String?,
    );
  }
}

/// 更新状态
enum UpdateDownloadState { idle, downloading, downloaded, applying }

/// 下载进度
class UpdateProgress {
  final UpdateDownloadState state;
  final double? progress;
  final String? error;

  const UpdateProgress({required this.state, this.progress, this.error});

  const UpdateProgress.idle() : this(state: UpdateDownloadState.idle);

  const UpdateProgress.downloading(double progress)
    : this(state: UpdateDownloadState.downloading, progress: progress);

  const UpdateProgress.downloaded()
    : this(state: UpdateDownloadState.downloaded);

  const UpdateProgress.applying() : this(state: UpdateDownloadState.applying);

  const UpdateProgress.error(String error)
    : this(state: UpdateDownloadState.idle, error: error);
}
