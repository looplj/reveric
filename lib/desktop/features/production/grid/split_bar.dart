// 职责: 管理切分与高清提交，显示规格、选中计数及模型可用倍率。
// 关联文件:
//   lib/desktop/features/production/grid/session.dart
//   lib/shared/services/production/grid_orchestrator.dart
//   lib/shared/providers/production_images.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../../shared/components/reveric_button.dart';
import '../../../../shared/components/reveric_icon_button.dart';
import '../../../../shared/components/reveric_select.dart';
import '../../../../shared/database/novel_content_database.dart';
import '../../../../shared/localization/app_localization.dart';
import '../../../../shared/localization/locale_keys.dart';
import '../../../../shared/models/ai_provider.dart';
import '../../../../shared/models/production/image_request.dart';
import '../../../../shared/providers/settings_providers.dart';
import '../../../../shared/providers/production_images.dart';
import '../../../../shared/services/production/canvas_service.dart';
import '../../../../shared/services/production/grid_orchestrator.dart';
import '../../../../shared/theme/theme.dart';
import '../../canvas/widgets/glass.dart';
import '../support.dart';
import 'session.dart';
import '../history_region.dart';
import 'spec_picker.dart';

class ProductionSplitBar extends HookConsumerWidget {
  const ProductionSplitBar({
    super.key,
    required this.service,
    required this.node,
    required this.onCreated,
    required this.place,
  });
  final ProductionCanvasService service;
  final CanvasNode node;
  final ValueChanged<CanvasNode> onCreated;
  final ProductionNodePlacement Function(Size) place;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ProductionHistoryScope.maybeOf(context)?.history;
    final running = useState<String?>(null);
    final multiplier = useState(2);
    final busy = running.value != null;
    final session = ProductionGridSession.maybeOf(context)!;
    final spec = session.spec!;
    final typo = RevericTheme.typographyOf(context);
    final model = ref.watch(
      resolvedAiModelOptionForKindProvider(kind: AiModelKind.image),
    );
    final provider = ref
        .watch(aiSettingsProvider)
        .providers
        .where((p) => p.id == model?.providerId)
        .firstOrNull;
    final supported = model == null || provider == null
        ? <int>{}
        : gridUpscaleMultipliers(
            ProductionImageCapabilities(provider, model.model),
          );
    final unavailable = model == null
        ? LocaleKeys.productionViewImageModelRequired
        : !supported.contains(multiplier.value)
        ? LocaleKeys.productionGridUpscaleUnsupported
        : session.selected.isEmpty
        ? LocaleKeys.productionGridSelectRequired
        : null;
    void run(bool upscale) => productionRun(context, () async {
      if (busy) {
        return;
      }
      running.value = upscale ? 'upscale' : 'split';
      try {
        final operation = GridOrchestrator();
        final CanvasNode group;
        if (upscale) {
          final result = await operation.upscale(
            canvas: service,
            jobs: ref.read(imageTaskServiceProvider),
            sourceNodeId: node.id,
            rows: spec.rows,
            cols: spec.cols,
            selected: {...session.selected},
            model: model!,
            multiplier: multiplier.value,
            place: place,
          );
          group = result.group;
          if (context.mounted && result.failures.isNotEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  context.t(
                    LocaleKeys.productionGridUpscaleRejected,
                    namedArgs: {
                      'titles': result.failures.values
                          .map((failure) => failure.title)
                          .join(', '),
                    },
                  ),
                ),
              ),
            );
          }
        } else {
          group = await operation.split(
            canvas: service,
            history: history,
            sourceNodeId: node.id,
            rows: spec.rows,
            cols: spec.cols,
            selected: {...session.selected},
            place: place,
          );
        }
        if (context.mounted) {
          session.close();
          onCreated(group);
        }
      } finally {
        if (context.mounted) {
          running.value = null;
        }
      }
    });
    return Material(
      type: MaterialType.transparency,
      child: CanvasGlass(
        raised: true,
        padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.xs),
        child: SizedBox(
          height: 40,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RevericIconButton(
                icon: RevericIcons.close,
                tooltip: context.t(LocaleKeys.commonCancel),
                onPressed: busy ? null : session.close,
              ),
              ProductionGridSpecPicker(
                label: '${spec.rows}×${spec.cols}',
                enabled: !busy,
                onSelected: session.start,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.sm,
                ),
                child: Text(
                  context.t(
                    LocaleKeys.productionGridSelected,
                    namedArgs: {'count': '${session.selected.length}'},
                  ),
                  style: typo.uiSmall,
                ),
              ),
              RevericButton.text(
                label: context.t(LocaleKeys.productionGridCreate),
                size: RevericButtonSize.compact,
                loading: running.value == 'split',
                onPressed: busy ? null : () => run(false),
              ),
              Tooltip(
                message: unavailable == null ? '' : context.t(unavailable),
                child: RevericButton.text(
                  label: context.t(
                    LocaleKeys.productionGridUpscale,
                    namedArgs: {'count': '${session.selected.length}'},
                  ),
                  size: RevericButtonSize.compact,
                  loading: running.value == 'upscale',
                  onPressed: busy || unavailable != null
                      ? null
                      : () => run(true),
                ),
              ),
              ProductionUpscaleMultiplier(
                value: multiplier.value,
                supported: supported,
                enabled: !busy,
                onChanged: (value) => multiplier.value = value,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ProductionUpscaleMultiplier extends StatelessWidget {
  const ProductionUpscaleMultiplier({
    super.key,
    required this.value,
    required this.supported,
    required this.onChanged,
    this.enabled = true,
  });
  final int value;
  final Set<int> supported;
  final ValueChanged<int> onChanged;
  final bool enabled;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 80,
    child: RevericSelect<int>(
      value: value,
      onChanged: onChanged,
      enabled: enabled,
      compact: true,
      menuWidth: 260,
      items: [
        for (final factor in [2, 4])
          RevericSelectItem(
            value: factor,
            label: '$factor×',
            enabled: supported.contains(factor),
            subtitle: supported.contains(factor)
                ? null
                : context.t(LocaleKeys.productionGridUpscaleUnsupported),
          ),
      ],
    ),
  );
}
