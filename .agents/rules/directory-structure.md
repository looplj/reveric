# 目录结构

```
lib/
├── main.dart                      # 入口
├── desktop/                       # 桌面端专属
│   ├── pages/                     # 尚未归入 feature 的页面级 widget
│   ├── widgets/                   # 页面内子组件
│   └── features/                  # 功能模块（feature 内文件直接平铺）
│       ├── {feature_name}/
│       │   ├── detail_page.dart
│       │   └── item_card.dart
│       └── ...
├── mobile/                        # 移动端专属
│   ├── pages/
│   ├── widgets/
│   └── features/                  # 功能模块（同 desktop，内部平铺）
│       ├── {feature_name}/
│       └── ...
└── shared/                        # 跨平台共享
    ├── components/                # 标准/底层 UI 组件（如 RevericInput、RevericSelect）
    ├── hooks/                     # Hook 形式的局部 UI 状态封装
    ├── providers/                 # Riverpod providers（共享状态/依赖注入）
    ├── services/                  # 业务 service / action / side effects
    ├── theme/                     # 设计系统 token & theme
    └── widgets/                   # 共享业务组件（由 components 组合 + 领域逻辑）
```

## 目录归属规则

- **平台专属**代码放 `desktop/` 或 `mobile/`。尚未归入 feature 的整页与子组件分别沿用 `pages/`、`widgets/`。
- **功能模块优先**：当一个 feature 有多个页面或子组件时，使用 `desktop/features/{feature_name}/` 或 `mobile/features/{feature_name}/` 聚合。feature 内 Dart 文件直接平铺，不再建立 `pages/`、`widgets/` 二级目录；feature 粒度参考职责边界（如 `production`、`canvas`），不要过度拆分。
- 不在普通功能改动中顺带迁移既有 `pages/`、`widgets/`；只有任务明确要求重组目录时才迁移。
- **跨平台共享**代码放 `shared/`：
  - `shared/components/` — 标准/底层 UI 组件（如 RevericInput、RevericSelect），纯展示，无业务逻辑
  - `shared/widgets/` — 共享业务组件（由 components 组合 + 领域逻辑），如 collections/ 系列
  - 其他共享层（theme、model、service、provider、hook 等）按已有规则放入对应子目录
- 新增 widget 时，默认使用独立文件；只有非常短、且只服务当前文件、抽离后反而降低可读性的私有小片段，才允许内联在原文件中。
- 当某个内联 widget 已经包含独立状态、动画、交互逻辑、复用价值，或让宿主文件明显变长时，应尽快拆成独立文件，不要长期堆在单个 page / panel 文件里。
- `lib/desktop/widgets/settings/settings_dialog.dart` 的每个导航项必须对应一个独立的 `settings_*_section.dart` section 文件；新增、删除或重命名 settings 导航时，同步新增、删除或重命名对应 section 文件，不要把导航内容内联在 `settings_dialog.dart`。
- 共享层常见归属：
  - Provider 放 `lib/shared/providers/`
  - 业务 service / action 放 `lib/shared/services/`
  - 可复用局部状态 hook 放 `lib/shared/hooks/`
  - 数据库 schema / DAO / drift database 放 `lib/shared/database/`
  - 设计系统 token / theme 放 `lib/shared/theme/`
- import theme 统一使用 `import '../../shared/theme/theme.dart'`（根据深度调整 `../`）。

## 文档保护

- `docs/` 是方案与历史决策的归档目录，不属于项目运行时依赖或默认开发上下文。
- 除非用户明确要求查看、修改或同步其中的具体文档，否则不要读取、搜索或修改 `docs/`。
- 常规代码任务的引用扫描、残留检查和文档清理默认排除 `docs/`。

## 文件命名 — 目录即命名空间

- 放入命名目录（如 `assistant/`、`pricing/`、`prompts/`）的 Dart 文件**不要**再在文件名前加目录名前缀。
- 由目录路径承担命名空间职责，文件名保持简洁。
- 正确：`lib/shared/services/ai/assistant/tool_dispatcher.dart`
- 错误：`lib/shared/services/ai/assistant/assistant_tool_dispatcher.dart`
