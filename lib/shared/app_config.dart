// 职责: 应用级别编译期常量（版本号、产品线、匿名上报地址、反馈渠道、匿名诊断公共头）
// 关联文件:
//   lib/shared/providers/trace_providers.dart
//   lib/shared/providers/anonymous_reporting_providers.dart
//   lib/shared/logger/startup_failure_reporter.dart
//   lib/shared/widgets/ai/chat/feedback_dialog.dart
//   release.sh (版本号同步)
//

/// 应用版本号。
/// 与 pubspec.yaml 的 version 字段保持同步，由 release.sh 一同更新。
/// 供需要同步获取版本号的场景使用（如匿名上报），避免 PackageInfo 异步调用。
const appVersion = '0.6.1';

/// 匿名诊断接收地址，包含完整路径；请求不追加业务 API 后缀。
/// 为空表示本构建不接匿名诊断：不上报，也不展示 opt-in 入口。
const anonymousReportingBaseUrl = '';

/// 公开仓库地址；关于页与反馈的 GitHub Issue 都指向这里。
const revericGitHubRepoUrl = 'https://github.com/looplj/reveric';

/// 技能广场只读取公开链接目录，导入沿用各来源平台的现有流程。
const revericSkillsCatalogUrl =
    'https://raw.githubusercontent.com/looplj/reveric-skills/main/catalog.json';

/// AGPLv3 第 7 条附加条款要求修改版保留的作者署名，与 NOTICES 保持一致，不做本地化。
const revericAttribution = 'Based on Reveric by looplj.';

/// 接收私下反馈的邮箱；诊断文件含作品内容，只通过邮件而非公开 Issue 发送。
const revericFeedbackEmail = 'bababaa261@gmail.com';

/// 产品线编码，通过 X-Product-Code 请求头发送给匿名诊断接收端。
const revericProductCode = 'writer';

/// 匿名诊断 API 公共请求头。
final revericApiHeaders = <String, String>{
  'Content-Type': 'application/json',
  'X-Product-Code': revericProductCode,
};
