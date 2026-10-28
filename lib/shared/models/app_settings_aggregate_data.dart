// 职责: 非编辑器应用设置聚合快照 — 定义领域 JSON、默认值与历史 key 映射。
// 关联文件:
//   lib/shared/providers/settings_providers.dart
//   lib/shared/database/daos/app_settings_dao.dart
// 遵循的 Rules:
//   .agents/rules/json.md

import 'dart:convert';

const defaultAiAgentIdentityText = '''
名称：Reveric
角色定位：小说创作工作台里的写作搭档，和作者一起规划、起草、打磨作品。
''';

const defaultAiAgentSoulText = '''
人格：务实、克制，不堆砌赞美，也不替作者拔高作品的意义。
语气：平等直接，少寒暄、少空话。
表达：简洁、具体，不绕弯子。
''';

class ReadingSettingsData {
  const ReadingSettingsData({
    required this.fontFamily,
    required this.fontSize,
    required this.letterSpacing,
    required this.lineHeight,
    required this.paragraphSpacing,
    required this.margin,
    required this.backgroundTheme,
    required this.pageTransition,
    required this.desktopMode,
    required this.mobileMode,
    required this.bold,
  });

  static const appSettingsKey = 'reading_settings';
  static const currentVersion = 1;

  final String fontFamily;
  final int fontSize;
  final double letterSpacing;
  final double lineHeight;
  final double paragraphSpacing;
  final double margin;
  final String backgroundTheme;
  final String pageTransition;
  final String desktopMode;
  final String mobileMode;
  final bool bold;

  factory ReadingSettingsData.defaultsForLanguage(String language) {
    return ReadingSettingsData(
      fontFamily: language.toLowerCase().startsWith('zh')
          ? 'LXGWWenKai'
          : 'Literata',
      fontSize: 18,
      letterSpacing: 0,
      lineHeight: 1.8,
      paragraphSpacing: 1,
      margin: 24,
      backgroundTheme: 'white',
      pageTransition: 'scroll',
      desktopMode: 'chapter',
      mobileMode: 'vertical_scroll',
      bold: false,
    );
  }

  factory ReadingSettingsData.decode(
    String raw, {
    required ReadingSettingsData fallback,
  }) {
    return ReadingSettingsData.fromJson(
      _decodeObject(raw, appSettingsKey),
      fallback: fallback,
    );
  }

  factory ReadingSettingsData.fromJson(
    Map<String, dynamic> json, {
    required ReadingSettingsData fallback,
  }) {
    final mobileMode = _string(json['mobileMode'], fallback.mobileMode);
    return ReadingSettingsData(
      fontFamily: _string(json['fontFamily'], fallback.fontFamily),
      fontSize: _integer(json['fontSize'], fallback.fontSize),
      letterSpacing: _double(json['letterSpacing'], fallback.letterSpacing),
      lineHeight: _double(json['lineHeight'], fallback.lineHeight),
      paragraphSpacing: _double(
        json['paragraphSpacing'],
        fallback.paragraphSpacing,
      ),
      margin: _double(json['margin'], fallback.margin),
      backgroundTheme: _enumString(json['backgroundTheme'], const {
        'white',
        'sepia',
        'cream',
        'eye_care',
        'dark',
        'night',
      }, fallback.backgroundTheme),
      pageTransition: _enumString(json['pageTransition'], const {
        'scroll',
        'horizontal',
        'fade',
      }, fallback.pageTransition),
      desktopMode: _enumString(json['desktopMode'], const {
        'chapter',
        'continuous_scroll',
      }, fallback.desktopMode),
      mobileMode: _enumString(mobileMode, const {
        'vertical_scroll',
        'horizontal_page',
      }, fallback.mobileMode),
      bold: _boolean(json['bold'], fallback.bold),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': currentVersion,
    'fontFamily': fontFamily,
    'fontSize': fontSize,
    'letterSpacing': letterSpacing,
    'lineHeight': lineHeight,
    'paragraphSpacing': paragraphSpacing,
    'margin': margin,
    'backgroundTheme': backgroundTheme,
    'pageTransition': pageTransition,
    'desktopMode': desktopMode,
    'mobileMode': mobileMode,
    'bold': bold,
  };

  String encode() => jsonEncode(toJson());
}

class AppearanceSettingsData {
  const AppearanceSettingsData({
    required this.theme,
    this.customThemeId,
    required this.themeMode,
    required this.backgroundImagePath,
    required this.backgroundFit,
    required this.backgroundTheme,
    this.uiTextScale = 1.0,
  });

  static const appSettingsKey = 'appearance_settings';
  static const currentVersion = 1;

  final String theme;
  final String? customThemeId;
  final String themeMode;
  final String backgroundImagePath;
  final String backgroundFit;
  final String? backgroundTheme;

  /// 界面文字全局缩放倍率，1.0 表示不缩放。
  final double uiTextScale;

  static const defaults = AppearanceSettingsData(
    theme: 'classic',
    themeMode: 'light',
    backgroundImagePath: '',
    backgroundFit: 'cover',
    backgroundTheme: null,
  );

  factory AppearanceSettingsData.decode(
    String raw, {
    AppearanceSettingsData fallback = defaults,
  }) {
    return AppearanceSettingsData.fromJson(
      _decodeObject(raw, appSettingsKey),
      fallback: fallback,
    );
  }

  factory AppearanceSettingsData.fromJson(
    Map<String, dynamic> json, {
    AppearanceSettingsData fallback = defaults,
  }) {
    final theme = _string(json['theme'], fallback.theme);
    final backgroundTheme = json.containsKey('backgroundTheme')
        ? _optionalString(json['backgroundTheme'])
        : fallback.backgroundTheme;
    return AppearanceSettingsData(
      customThemeId: _optionalString(json['customThemeId']),
      theme: _enumString(theme, _themeValues, fallback.theme),
      themeMode: _enumString(json['themeMode'], const {
        'light',
        'dark',
        'system',
      }, fallback.themeMode),
      backgroundImagePath: _string(
        json['backgroundImagePath'],
        fallback.backgroundImagePath,
      ),
      backgroundFit: _enumString(json['backgroundFit'], const {
        'cover',
        'contain',
        'fill',
      }, fallback.backgroundFit),
      backgroundTheme: _nullableEnumString(
        backgroundTheme,
        _themeValues,
        fallback.backgroundTheme,
      ),
      uiTextScale: _double(
        json['uiTextScale'],
        fallback.uiTextScale,
      ).clamp(0.5, 2.0).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': currentVersion,
    'theme': theme,
    'customThemeId': customThemeId,
    'themeMode': themeMode,
    'backgroundImagePath': backgroundImagePath,
    'backgroundFit': backgroundFit,
    'backgroundTheme': backgroundTheme,
    'uiTextScale': uiTextScale,
  };

  String encode() => jsonEncode(toJson());
}

class MemorySettingsData {
  const MemorySettingsData({
    required this.autoExtract,
    required this.extractionIntervalMinutes,
  });

  static const appSettingsKey = 'memory_settings';
  static const currentVersion = 1;

  final bool autoExtract;
  final int extractionIntervalMinutes;

  static const defaults = MemorySettingsData(
    autoExtract: true,
    extractionIntervalMinutes: 60,
  );

  factory MemorySettingsData.decode(
    String raw, {
    MemorySettingsData fallback = defaults,
  }) {
    return MemorySettingsData.fromJson(
      _decodeObject(raw, appSettingsKey),
      fallback: fallback,
    );
  }

  factory MemorySettingsData.fromJson(
    Map<String, dynamic> json, {
    MemorySettingsData fallback = defaults,
  }) {
    return MemorySettingsData(
      autoExtract: _boolean(json['autoExtract'], fallback.autoExtract),
      extractionIntervalMinutes: _integer(
        json['extractionIntervalMinutes'],
        fallback.extractionIntervalMinutes,
      ),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': currentVersion,
    'autoExtract': autoExtract,
    'extractionIntervalMinutes': extractionIntervalMinutes,
  };

  String encode() => jsonEncode(toJson());
}

class AiAgentSettingsData {
  const AiAgentSettingsData({
    required this.identity,
    required this.soul,
    required this.avatarPath,
    required this.nextActionSuggestions,
  });

  static const appSettingsKey = 'ai_agent_settings';
  static const currentVersion = 1;

  final String identity;
  final String soul;
  final String avatarPath;

  /// 是否允许 AI 在回合结束时挂下一步建议。关闭后 SuggestNextAction 不下发。
  final bool nextActionSuggestions;

  static const defaults = AiAgentSettingsData(
    identity: defaultAiAgentIdentityText,
    soul: defaultAiAgentSoulText,
    avatarPath: '',
    nextActionSuggestions: true,
  );

  factory AiAgentSettingsData.decode(
    String raw, {
    AiAgentSettingsData fallback = defaults,
  }) {
    return AiAgentSettingsData.fromJson(
      _decodeObject(raw, appSettingsKey),
      fallback: fallback,
    );
  }

  factory AiAgentSettingsData.fromJson(
    Map<String, dynamic> json, {
    AiAgentSettingsData fallback = defaults,
  }) {
    return AiAgentSettingsData(
      identity: _string(json['identity'], fallback.identity),
      soul: _string(json['soul'], fallback.soul),
      avatarPath: _string(json['avatarPath'], fallback.avatarPath),
      nextActionSuggestions: _boolean(
        json['nextActionSuggestions'],
        fallback.nextActionSuggestions,
      ),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': currentVersion,
    'identity': identity,
    'soul': soul,
    'avatarPath': avatarPath,
    'nextActionSuggestions': nextActionSuggestions,
  };

  String encode() => jsonEncode(toJson());
}

class StorageSettingsData {
  const StorageSettingsData({
    required this.changeRecordRetentionDays,
    required this.backupDirectory,
    required this.backupFrequency,
    required this.backupWeekdays,
    required this.backupDayOfMonth,
    required this.backupHour,
    required this.backupMinute,
    this.webDavEnabled = false,
    this.webDavServerUrl = '',
    this.webDavUsername = '',
    this.webDavPassword = '',
    this.webDavRemoteDirectory = '/Reveric/Backups',
  });

  static const appSettingsKey = 'storage_settings';
  static const currentVersion = 4;

  final int changeRecordRetentionDays;
  final String backupDirectory;
  final String backupFrequency;
  final List<int> backupWeekdays;
  final int backupDayOfMonth;
  final int backupHour;
  final int backupMinute;
  final bool webDavEnabled;
  final String webDavServerUrl;
  final String webDavUsername;
  final String webDavPassword;
  final String webDavRemoteDirectory;

  static const defaults = StorageSettingsData(
    changeRecordRetentionDays: 30,
    backupDirectory: '',
    backupFrequency: 'manual',
    backupWeekdays: <int>[DateTime.monday],
    backupDayOfMonth: 1,
    backupHour: 2,
    backupMinute: 0,
    webDavEnabled: false,
    webDavServerUrl: '',
    webDavUsername: '',
    webDavPassword: '',
    webDavRemoteDirectory: '/Reveric/Backups',
  );

  factory StorageSettingsData.decode(
    String raw, {
    StorageSettingsData fallback = defaults,
  }) {
    return StorageSettingsData.fromJson(
      _decodeObject(raw, appSettingsKey),
      fallback: fallback,
    );
  }

  factory StorageSettingsData.fromJson(
    Map<String, dynamic> json, {
    StorageSettingsData fallback = defaults,
  }) {
    return StorageSettingsData(
      changeRecordRetentionDays: _integer(
        json['changeRecordRetentionDays'],
        fallback.changeRecordRetentionDays,
      ).clamp(7, 365),
      backupDirectory: _string(
        json['backupDirectory'],
        fallback.backupDirectory,
      ),
      backupFrequency: _enumString(json['backupFrequency'], const {
        'manual',
        'daily',
        'weekly',
        'monthly',
      }, fallback.backupFrequency),
      backupWeekdays: _weekdayList(
        json['backupWeekdays'],
        fallback: fallback.backupWeekdays,
      ),
      backupDayOfMonth: _integerInRange(
        json['backupDayOfMonth'],
        min: 1,
        max: 28,
        fallback: fallback.backupDayOfMonth,
      ),
      backupHour: _integerInRange(
        json['backupHour'],
        min: 0,
        max: 23,
        fallback: fallback.backupHour,
      ),
      backupMinute: _integerInRange(
        json['backupMinute'],
        min: 0,
        max: 59,
        fallback: fallback.backupMinute,
      ),
      webDavEnabled: _boolean(json['webDavEnabled'], fallback.webDavEnabled),
      webDavServerUrl: _string(
        json['webDavServerUrl'],
        fallback.webDavServerUrl,
      ),
      webDavUsername: _string(json['webDavUsername'], fallback.webDavUsername),
      webDavPassword: _string(json['webDavPassword'], fallback.webDavPassword),
      webDavRemoteDirectory: _string(
        json['webDavRemoteDirectory'],
        fallback.webDavRemoteDirectory,
      ),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': currentVersion,
    'changeRecordRetentionDays': changeRecordRetentionDays.clamp(7, 365),
    'backupDirectory': backupDirectory,
    'backupFrequency': backupFrequency,
    'backupWeekdays': backupWeekdays,
    'backupDayOfMonth': backupDayOfMonth,
    'backupHour': backupHour,
    'backupMinute': backupMinute,
    'webDavEnabled': webDavEnabled,
    'webDavServerUrl': webDavServerUrl,
    'webDavUsername': webDavUsername,
    'webDavPassword': webDavPassword,
    'webDavRemoteDirectory': webDavRemoteDirectory,
  };

  String encode() => jsonEncode(toJson());
}

class LocalProfileSettingsData {
  const LocalProfileSettingsData({
    required this.username,
    required this.avatarPath,
  });

  static const appSettingsKey = 'local_profile';
  static const currentVersion = 1;

  final String username;
  final String avatarPath;

  static const defaults = LocalProfileSettingsData(
    username: '',
    avatarPath: '',
  );

  factory LocalProfileSettingsData.decode(
    String raw, {
    LocalProfileSettingsData fallback = defaults,
  }) {
    return LocalProfileSettingsData.fromJson(
      _decodeObject(raw, appSettingsKey),
      fallback: fallback,
    );
  }

  factory LocalProfileSettingsData.fromJson(
    Map<String, dynamic> json, {
    LocalProfileSettingsData fallback = defaults,
  }) {
    return LocalProfileSettingsData(
      username: _string(json['username'], fallback.username),
      avatarPath: _string(json['avatarPath'], fallback.avatarPath),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': currentVersion,
    'username': username,
    'avatarPath': avatarPath,
  };

  String encode() => jsonEncode(toJson());
}

class DebugSettingsData {
  const DebugSettingsData({
    required this.debugMode,
    required this.debugPageUnlocked,
  });

  static const appSettingsKey = 'debug_settings';
  static const currentVersion = 2;

  final bool debugMode;
  final bool debugPageUnlocked;

  static const defaults = DebugSettingsData(
    debugMode: false,
    debugPageUnlocked: false,
  );

  factory DebugSettingsData.decode(
    String raw, {
    DebugSettingsData fallback = defaults,
  }) {
    return DebugSettingsData.fromJson(
      _decodeObject(raw, appSettingsKey),
      fallback: fallback,
    );
  }

  factory DebugSettingsData.fromJson(
    Map<String, dynamic> json, {
    DebugSettingsData fallback = defaults,
  }) {
    return DebugSettingsData(
      debugMode: _boolean(json['debugMode'], fallback.debugMode),
      debugPageUnlocked: _boolean(
        json['debugPageUnlocked'],
        fallback.debugPageUnlocked,
      ),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': currentVersion,
    'debugMode': debugMode,
    'debugPageUnlocked': debugPageUnlocked,
  };

  String encode() => jsonEncode(toJson());
}

/// 用于区分「copyWith 未传 credentials」与「显式传 null 表示清除」。
const _unsetCredentials = Object();

/// 微信 bot 登录凭证的持久化形态 — 字段与 `WechatCredentials` 一一对应。
///
/// 单独建模而不是存 `WechatCredentials.toJson()` 原文：一来 models 层不必反向依赖
/// services 层的实现类型，二来读回时缺字段就是无效凭证，能在解析处直接判掉。
class RemoteBridgeWechatCredentialsData {
  const RemoteBridgeWechatCredentialsData({
    required this.token,
    required this.baseUrl,
    required this.accountId,
    required this.userId,
  });

  final String token;
  final String baseUrl;
  final String accountId;
  final String userId;

  /// 任一字段缺失或为空都返回 null —— 半个凭证无法登录，等同未登录。
  static RemoteBridgeWechatCredentialsData? fromJsonOrNull(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final token = _optionalString(raw['token']);
    final baseUrl = _optionalString(raw['baseUrl']);
    final accountId = _optionalString(raw['accountId']);
    final userId = _optionalString(raw['userId']);
    if (token == null ||
        baseUrl == null ||
        accountId == null ||
        userId == null) {
      return null;
    }
    return RemoteBridgeWechatCredentialsData(
      token: token,
      baseUrl: baseUrl,
      accountId: accountId,
      userId: userId,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'token': token,
    'baseUrl': baseUrl,
    'accountId': accountId,
    'userId': userId,
  };
}

/// 微信单个会话的上下文 token —— 微信协议特有，其它渠道未必有对应概念。
class RemoteBridgeWechatChatContextData {
  const RemoteBridgeWechatChatContextData({
    required this.chatId,
    required this.contextToken,
  });

  final String chatId;
  final String contextToken;

  static RemoteBridgeWechatChatContextData? fromJsonOrNull(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final chatId = _optionalString(raw['chatId']);
    final contextToken = _optionalString(raw['contextToken']);
    if (chatId == null || contextToken == null) {
      return null;
    }
    return RemoteBridgeWechatChatContextData(
      chatId: chatId,
      contextToken: contextToken,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'chatId': chatId,
    'contextToken': contextToken,
  };
}

/// 微信渠道的桥接持久化条目 — 开关、登录凭证与各会话的上下文 token。
class RemoteBridgeWechatData {
  const RemoteBridgeWechatData({
    required this.enabled,
    required this.credentials,
    required this.chatContexts,
  });

  /// 该渠道的桥接开关。默认 true：有凭证即随 app 启动恢复消费循环。
  final bool enabled;

  /// 登录凭证；未登录或凭证已失效为 null。
  final RemoteBridgeWechatCredentialsData? credentials;

  /// 各会话的上下文 token。
  final List<RemoteBridgeWechatChatContextData> chatContexts;

  static const defaults = RemoteBridgeWechatData(
    enabled: true,
    credentials: null,
    chatContexts: <RemoteBridgeWechatChatContextData>[],
  );

  factory RemoteBridgeWechatData.fromJson(
    Map<String, dynamic> json, {
    RemoteBridgeWechatData fallback = defaults,
  }) {
    final rawContexts = json['chatContexts'];
    return RemoteBridgeWechatData(
      enabled: _boolean(json['enabled'], fallback.enabled),
      credentials:
          RemoteBridgeWechatCredentialsData.fromJsonOrNull(
            json['credentials'],
          ) ??
          fallback.credentials,
      chatContexts: rawContexts is List
          ? <RemoteBridgeWechatChatContextData>[
              for (final entry in rawContexts)
                ?RemoteBridgeWechatChatContextData.fromJsonOrNull(entry),
            ]
          : fallback.chatContexts,
    );
  }

  RemoteBridgeWechatData copyWith({
    bool? enabled,
    Object? credentials = _unsetCredentials,
    List<RemoteBridgeWechatChatContextData>? chatContexts,
  }) {
    return RemoteBridgeWechatData(
      enabled: enabled ?? this.enabled,
      credentials: identical(credentials, _unsetCredentials)
          ? this.credentials
          : credentials as RemoteBridgeWechatCredentialsData?,
      chatContexts: chatContexts ?? this.chatContexts,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'enabled': enabled,
    'credentials': credentials?.toJson(),
    'chatContexts': <dynamic>[
      for (final context in chatContexts) context.toJson(),
    ],
  };
}

/// 远程桥接持久化快照 — 所有渠道共用一个 app_settings key，每个渠道一个具名字段。
///
/// 读写在 `remote_bridge_providers.dart` 内完成，不进 [AppSettings] 状态：
/// 上下文 token 每条入站消息都会变，走 AppSettingsNotifier 会让全局设置状态随聊天
/// 频繁重建。
///
/// 渠道是固定的少数几个，各自的凭证与会话状态结构也不同（新渠道未必有上下文 token），
/// 所以每个渠道有自己的类型，不抽公共条目：新增渠道 = 加一个字段加一个类型，
/// key 与 schema 都不动。
class RemoteBridgeSettingsData {
  const RemoteBridgeSettingsData({required this.wechat});

  static const appSettingsKey = 'remote_bridge_settings';
  static const currentVersion = 1;

  /// 微信渠道条目。
  final RemoteBridgeWechatData wechat;

  static const defaults = RemoteBridgeSettingsData(
    wechat: RemoteBridgeWechatData.defaults,
  );

  factory RemoteBridgeSettingsData.decode(
    String raw, {
    RemoteBridgeSettingsData fallback = defaults,
  }) {
    return RemoteBridgeSettingsData.fromJson(
      _decodeObject(raw, appSettingsKey),
      fallback: fallback,
    );
  }

  factory RemoteBridgeSettingsData.fromJson(
    Map<String, dynamic> json, {
    RemoteBridgeSettingsData fallback = defaults,
  }) {
    final rawWechat = json['wechat'];
    return RemoteBridgeSettingsData(
      wechat: rawWechat is Map
          ? RemoteBridgeWechatData.fromJson(
              rawWechat.map((key, value) => MapEntry(key.toString(), value)),
              fallback: fallback.wechat,
            )
          : fallback.wechat,
    );
  }

  RemoteBridgeSettingsData copyWith({RemoteBridgeWechatData? wechat}) {
    return RemoteBridgeSettingsData(wechat: wechat ?? this.wechat);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': currentVersion,
    'wechat': wechat.toJson(),
  };

  String encode() => jsonEncode(toJson());
}

const _themeValues = <String>{'reveric', 'classic', 'ivory'};

Map<String, dynamic> _decodeObject(String raw, String settingsKey) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw FormatException('$settingsKey must be a JSON object');
  }
  return decoded.map((key, value) => MapEntry(key.toString(), value));
}

String _string(Object? value, String fallback) {
  return value is String ? value : fallback;
}

String? _optionalString(Object? value) {
  if (value is! String || value.isEmpty) {
    return null;
  }
  return value;
}

int _integer(Object? value, int fallback) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? fallback;
  }
  return fallback;
}

int _integerInRange(
  Object? value, {
  required int min,
  required int max,
  required int fallback,
}) {
  final parsed = _integer(value, fallback);
  if (parsed < min || parsed > max) {
    return fallback;
  }
  return parsed;
}

List<int> _weekdayList(Object? value, {required List<int> fallback}) {
  final values = value is List
      ? value
      : value == null
      ? const <Object?>[]
      : <Object?>[value];
  final weekdays = <int>{};
  for (final candidate in values) {
    final weekday = _integer(candidate, -1);
    if (weekday >= DateTime.monday && weekday <= DateTime.sunday) {
      weekdays.add(weekday);
    }
  }
  if (weekdays.isEmpty) {
    return List<int>.unmodifiable(fallback);
  }
  final sorted = weekdays.toList()..sort();
  return List<int>.unmodifiable(sorted);
}

double _double(Object? value, double fallback) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value) ?? fallback;
  }
  return fallback;
}

bool _boolean(Object? value, bool fallback) {
  if (value is bool) {
    return value;
  }
  if (value == 'true') {
    return true;
  }
  if (value == 'false') {
    return false;
  }
  return fallback;
}

String _enumString(Object? value, Set<String> values, String fallback) {
  final parsed = _string(value, fallback);
  return values.contains(parsed) ? parsed : fallback;
}

String? _nullableEnumString(
  String? value,
  Set<String> values,
  String? fallback,
) {
  if (value == null) {
    return null;
  }
  return values.contains(value) ? value : fallback;
}
