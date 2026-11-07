# Form Rules

## 表单禁止惰性回收字段

- **表单禁止惰性回收字段**：桌面与移动端的编辑表单不得使用 `ListView`（含 builder/separated）或 `SliverList` 承载字段、编辑卡片；即使有外部 controller，也不能依赖离屏字段继续参与 `Form.validate()`。固定字段表单统一使用 `SingleChildScrollView + Column`，让编辑态和校验随整个表单存活。与大量只读条目混排时，使用 `CustomScrollView`，将完整编辑区放在不惰性回收的 `SliverToBoxAdapter` 中，只读条目可用 `SliverList`。候选项、搜索结果、历史记录等展示／选择列表不受此限制；富文本编辑器内部的专用虚拟化不按普通表单处理，但必须由编辑器统一持有文档状态。不得用扩大 `cacheExtent` 代替生命周期修复。

此约束同样适用于未使用 `lib/third/form` 的编辑表单。

## `lib/third/form` 使用规则

- 需要“多字段编辑态 + 字段校验 + 提交/重置”的页面，优先使用 `lib/third/form`。
- 使用方式参考 `flutter_hook_form/example`：
  1. 先定义 `enum ...Fields<T> implements FieldSchema`
  2. 在字段上声明 `validators`
  3. 在 `HookWidget` / `HookConsumerWidget` 顶层通过 `useForm<...Fields>(initialValues: ...)` 创建 `FormFieldsController`
  4. 用 `HookedForm` 包裹表单区域
  5. 文本输入优先用 `HookedTextFormField`
  6. 自定义控件、下拉、开关、日期等用 `HookedFormField`
- 不走 `lib/third/form` 的输入控件同样不能裸写 `TextField` + `InputDecoration`；选型见 `.agents/rules/design-system.md` 的「输入控件选型」。
- `lib/third/form` 负责表单编辑态、校验、错误展示、`hasChanged` / `reset` / `validate` 等行为；Riverpod 仍负责共享状态、持久化状态和依赖注入。
- 不要把 `TextEditingController + useEffect 同步 provider + onChanged 直接写回` 作为复杂表单的默认方案；优先把编辑态放进 form，提交时统一写回 provider/service。
- 表单提交时统一走：
  1. `form.validate()`
  2. 必要的业务前置校验
  3. 调用 provider/service 持久化
  4. 服务端错误或业务错误通过 `form.setError(field, message)` 回填到字段
- 只有简单即时设置项才允许不套 form，例如纯开关、纯单选、无独立编辑态且改动应立即生效的项。
- 可复用的子组件如果处于 `HookedForm` 内部，可通过 `useFormContext` 读取当前 form；不要层层传递零散字段状态。
- 需要监听字段变化驱动界面时，优先使用 form 的值和 `notifyOnChange`，不要额外复制一份局部状态。
- **外部 `TextEditingController` + `HookedFormField` 自定义 builder**（Markdown 编辑器、非标准输入控件等）时，必须遵循 `.agents/rules/text-input-ime.md`：输入期静默 sync、`useForm(listen: false)`、本地 `hasEdits`、postFrame 通知父级；不要在该模式下用 `form.hasChanged` 或 `notifyOnChange: true` 驱动每键 rebuild。
- `initialValues` 来自 provider 当前值；当 provider 外部刷新时，必须谨慎同步，避免覆盖用户尚未提交的编辑内容。
- 设置类表单提交到持久层前，必须做基本业务校验，不能只依赖按钮禁用态。例如 AI provider 启用前必须校验 `apiKey`、`baseUrl`、`models`。
- `FieldSchema` 里的 `validators` 优先放字段本身稳定、可复用的规则，例如必填、长度、格式、跨字段匹配；依赖运行时上下文的校验才放在 widget 的 `validator:` 或提交阶段处理。

## 常驻编辑面板的 keys

- 保存后仍停留、或会使用“保存后的实体”重新渲染的常驻编辑面板调用 `useForm(initialValues: ..., keys: [...])` 时，keys 必须同时包含实体 `id` 和 `updatedAt`，例如 `keys: [rule.id, rule.updatedAt]`。
- `useForm` 会按 keys 缓存表单控制器；若 keys 只有 `id`，保存后实体内容变化但控制器不重建，旧 `initialValues` 会让 `form.hasChanged` 一直为 `true`。
- Provider 写入并刷新 `updatedAt` 后，keys 变化会重建表单控制器，使新的持久化值成为 baseline。
- 保存即 `Navigator.pop` 关闭的 dialog 不会用旧 baseline 重渲染，不受此规则约束，可只使用 `[id]` 或默认 keys。
- 参考实现：`agent_rule_edit_panel.dart`、`agent_skill_edit_panel.dart`、`map_inspector_panel.dart`。

## 校验器使用规范

### 声明校验器时必须指定泛型类型

在 `FieldSchema` 枚举中声明 `validators` 时，**必须**为校验器指定与字段类型匹配的泛型参数，否则表单框架无法正确解析错误消息。

```dart
// ✅ 正确：指定泛型类型
enum NovelFormField<T> implements FieldSchema {
  title<String>(validators: [RequiredValidator<String>()]),
  description<String>(validators: [RequiredValidator<String>(), MinLengthValidator<String>(10)]),
  chapterCount<int>(validators: [RequiredValidator<int>()]);
}

// ❌ 错误：缺少泛型类型，会导致运行时异常
enum NovelFormField<T> implements FieldSchema {
  title<String>(validators: [RequiredValidator()]),  // 抛出异常
}
```

### 常用校验器

| 校验器 | 用途 | 示例 |
|--------|------|------|
| `RequiredValidator<T>()` | 必填校验 | `RequiredValidator<String>()` |
| `MinLengthValidator<T>(length)` | 最小长度 | `MinLengthValidator<String>(5)` |
| `MaxLengthValidator<T>(length)` | 最大长度 | `MaxLengthValidator<String>(100)` |
| `EmailValidator()` | 邮箱格式 | `EmailValidator()` |
| `PatternValidator<T>(pattern)` | 正则匹配 | `PatternValidator<String>(RegExp(r'^\d+$'))` |
| `MinValidator<T>(min)` | 最小值（数字） | `MinValidator<int>(0)` |
| `MaxValidator<T>(max)` | 最大值（数字） | `MaxValidator<int>(100)` |

### 自定义错误消息

可以通过 `message` 参数覆盖默认错误消息：

```dart
title<String>(validators: [
  RequiredValidator<String>(message: '请输入标题'),
  MinLengthValidator<String>(5, message: '标题至少需要5个字符'),
]),
```

### 运行时/业务校验

依赖运行时上下文的校验（如异步校验、跨字段校验）应在提交阶段处理：

```dart
onPressed: () {
  // 1. 先执行字段级校验
  if (!form.validate()) return;
  
  // 2. 执行业务校验
  final count = form.getValue<int>(NovelFormField.chapterCount) ?? 0;
  if (count < 5) {
    form.setError(NovelFormField.chapterCount, '章节数不能少于5');
    return;
  }
  
  // 3. 提交
  // ...
}
```
- `HookedTextFormField` 适合标准文本输入；如果控件不是标准 `TextFormField` 语义，例如 tag editor、模型列表、日期选择器、checkbox、dropdown，自定义 `HookedFormField`，通过 `builder(value, onChanged, error)` 接入。
- 表单页面应优先使用 `form.hasChanged` 控制保存按钮、重置按钮、离开确认等交互，不要自己再维护一套 `isDirty` 布尔值。**例外**：UI 绑定外部 `TextEditingController` 时改由 baseline 比较维护本地 dirty（见 `.agents/rules/text-input-ime.md`）。
- 表单重置统一使用 `form.reset()`；不要手动逐个 controller 清空。
- 需要服务端返回字段级错误时，使用 `form.setError(field, message)` 显示，而不是只弹全局 snackbar。
- 在 `HookedFormField` / `HookedTextFormField` 中，字段值应以 form 当前值为准，不要再额外维护第二份同义局部状态，否则容易出现显示值和提交值不一致。
- 使用 `notifyOnChange: true` 时要有明确目的，例如实时字符计数、即时启用保存按钮、联动预览；默认不要无条件开启，避免不必要 rebuild。
- 多步骤或分区表单可以拆成多个子 widget，但同一个提交单元应共享同一个 `FormFieldsController`，不要每个局部区域各自维护独立 form，除非它们本来就是独立提交单元。
- 能通过 `form.getValue(field)` 推导出的显示状态，不要再复制到 provider；provider 只保存已提交或全局共享的数据。
- 如果页面只是展示 provider 数据并立即写回单个值，不需要强行引入 form；只有存在明确“编辑会话”的场景才使用 `lib/third/form`。
- 当前项目中，`settings_providers.dart` 负责设置持久化与提交入口；页面层应使用 `lib/third/form` 管理设置编辑态，而不是在 widget 内手写一套 controller 同步逻辑。
