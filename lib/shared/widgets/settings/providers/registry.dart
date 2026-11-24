// 职责: 登记各供应商的专属展示（配置页介绍卡片、列表标语），按供应商类型查找。
// 关联文件:
//   lib/shared/widgets/settings/providers/metaso.dart
//   lib/shared/widgets/settings/provider_overview.dart
//   lib/shared/widgets/settings/ai_providers_section.dart
//   lib/shared/widgets/settings/mobile_provider_list.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/provider.json
//   assets/translations/zh-CN/provider.json

import 'package:flutter/widgets.dart';

import '../../../localization/app_localization.dart';
import '../../../localization/locale_keys.dart';
import 'api88.dart';
import 'apikey.dart';
import 'infistar.dart';
import 'metaso.dart';
import 'token91.dart';

/// 供应商专属展示；未登记的供应商使用通用的能力摘要与描述。
class ProviderShowcase {
  const ProviderShowcase({required this.card, this.listTagline});

  /// 配置页顶部的介绍卡片，替代通用的能力介绍。
  final WidgetBuilder card;

  /// 供应商列表中替代能力摘要的一行标语。
  final String Function(BuildContext context)? listTagline;
}

const providerShowcases = <String, ProviderShowcase>{
  'metaso': metasoShowcase,
  'api88': api88Showcase,
  'token91': token91Showcase,
  'apikey': apikeyShowcase,
  'infistar': infistarShowcase,
};

/// 供应商列表中的促销标语；未登记时回退到能力摘要。
const providerListTaglines = <String, String Function(BuildContext context)>{
  'purefox': _purefoxListTagline,
  'purefox_media': _purefoxMediaListTagline,
};

String _purefoxListTagline(BuildContext context) =>
    context.t(LocaleKeys.providerPurefoxPromoListTagline);

String _purefoxMediaListTagline(BuildContext context) =>
    context.t(LocaleKeys.providerPurefoxMediaPromoListTagline);
