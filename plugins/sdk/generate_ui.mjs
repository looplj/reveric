import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const schema = JSON.parse(await readFile(resolve(here, 'ui.schema.json'), 'utf8'));
const type = (p) => p.enum ? p.enum.map(JSON.stringify).join(' | ') : ({
  string: 'string', boolean: 'boolean', nullableString: 'string | null',
  nonnegative: 'number', positive: 'number', integer: 'number', positiveInteger: 'number',
  selectOptions: 'readonly { value: string; label: string; disabled?: boolean }[]',
  tabs: 'readonly { id: string; label: string }[]',
  menuItems: 'readonly { id: string; label: string; disabled?: boolean; danger?: boolean }[]',
}[p.type]);
let ts = `// Generated from ui.schema.json by generate_ui.mjs.\ndeclare module "reveric/ui" {
  export type Dispose = () => void;
  export type Accessor<T> = () => T;
  export interface UiNode { readonly __uiNode: unique symbol }
  export interface UiRoot { readonly __uiRoot: unique symbol }
  export interface Signal<T> { (): T; set(value: T): void; update(updater: (previous: T) => T): void }
  export interface Resource<T> { value: Accessor<T | undefined>; loading: Accessor<boolean>; error: Accessor<unknown | undefined>; refetch(): void; dispose(): void }
  export function signal<T>(initial: T): Signal<T>;
  export function computed<T>(read: Accessor<T>): Accessor<T>;
  export function effect(run: () => void): Dispose;
  export function batch<T>(run: () => T): T;
  export function untracked<T>(run: () => T): T;
  export function cleanup(run: Dispose): void;
  export function resource<K, T>(source: Accessor<K>, load: (key: K) => Promise<T>): Resource<T>;
  export function mount(view: () => UiNode, root: UiRoot): Dispose;
  export function If(props: { when: boolean; fallback?: UiNode; children: UiNode }): UiNode;
  export function Each<T>(props: { items: readonly T[]; key: (item: T) => string; children: (item: Accessor<T>, index: Accessor<number>) => UiNode }): UiNode;
  export function ErrorBoundary(props: { fallback: (error: unknown, reset: () => void) => UiNode; children: UiNode | readonly UiNode[] }): UiNode;
  export type PageContext = import("./index").ViewContext & {
    readonly root: UiRoot;
    readonly environment: Accessor<{readonly width:number;readonly height:number;readonly platform:string;readonly theme:string;readonly locale:string;readonly visible:boolean}>;
  };
  export interface UiEvent { value?: string | boolean | null; editRevision?: number; open?: boolean; id?: string }
  export interface CommonProps { ${Object.entries(schema.common).map(([k,v])=>`${k}?: ${type(v)};`).join(' ')} }
`;
for (const [name, component] of Object.entries(schema.components)) {
  if (component.internal) continue;
  if (name === 'List') {
    ts += `  export function List<T>(props: { items: readonly T[]; key: (item: T) => string; itemExtent: number; height: number; renderItem: (item: Accessor<T>, index: Accessor<number>) => UiNode }): UiNode;\n`;
    continue;
  }
  ts += `  export interface ${name}Props extends CommonProps {\n`;
  for (const [key, p] of Object.entries(component.props)) ts += `    ${key}${p.required ? '' : '?'}: ${type(p)};\n`;
  for (const event of component.events) ts += `    ${event}?: (event: UiEvent) => void | Promise<void>;\n`;
  for (const [slot, count] of Object.entries(component.slots)) ts += `    ${slot}?: ${slot === 'content' ? '(id: string) => UiNode' : count === 'many' ? 'UiNode | readonly UiNode[]' : 'UiNode'};\n`;
  if (!component.slots.children && Object.keys(component.slots).length) ts += `    children?: ${name === 'Tabs' ? '(id: string) => UiNode' : 'UiNode | readonly UiNode[]'};\n`;
  ts += `  }\n  export function ${name}(props: ${name}Props): UiNode;\n`;
}
ts += `}\ndeclare namespace JSX { type Element = import("reveric/ui").UiNode; interface ElementChildrenAttribute { children: {} } }\n`;
await writeFile(resolve(here, 'ui.d.ts'), ts);
const dart = resolve(here, '../../lib/shared/models/plugin/ui_schema.dart');
await writeFile(dart, `// 职责: 提供由插件 UI schema 生成的属性、事件与插槽校验定义。\n// 关联文件:\n//   plugins/sdk/ui.schema.json\n//   plugins/sdk/generate_ui.mjs\n// GENERATED CODE - DO NOT MODIFY BY HAND\nconst pluginUiSchema = <String, dynamic>${JSON.stringify(schema, null, 2)};\n`);
const rust = resolve(here, '../../third/fjs/libfjs/src/ui/schema.rs');
const components = Object.keys(schema.components);
const events = [...new Set(Object.values(schema.components).flatMap(c=>c.events))];
const enumText = (name, values) => `#[derive(Debug, Clone, Copy, PartialEq, Eq)]\npub(crate) enum ${name} {\n${values.map(v=>`    ${v[0].toUpperCase()+v.slice(1)},`).join('\n')}\n}\nimpl ${name} {\n    pub(crate) fn parse(value: &str) -> Option<Self> {\n        match value {\n${values.map(v=>`            ${JSON.stringify(v)} => Some(Self::${v[0].toUpperCase()+v.slice(1)}),`).join('\n')}\n            _ => None,\n        }\n    }\n}\n`;
await mkdir(dirname(rust), {recursive:true});
await writeFile(rust, '// Generated from plugins/sdk/ui.schema.json.\n' + enumText('Component',components)+enumText('Event',events));

await writeFile(rust, (await readFile(rust,'utf8')) + '\npub(crate) fn slot(component: &str, slot: &str) -> Option<bool> {\n    match (component,slot) {\n' + Object.entries(schema.components).flatMap(([name,c])=>Object.entries(c.slots).map(([slot,count])=>`        (${JSON.stringify(name)},${JSON.stringify(slot)}) => Some(${count==='one'}),`)).join('\n') + '\n        _ => None,\n    }\n}\n');

const kinds = {string:'Str',boolean:'Bool',nullableString:'NullableStr',nonnegative:'Nonnegative',positive:'Positive',
  integer:'Integer',positiveInteger:'PositiveInteger',selectOptions:'SelectOptions',tabs:'Tabs',menuItems:'MenuItems'};
const arm = (component, key, p) => {
  if (!kinds[p.type]) throw new Error(`Unknown property type ${p.type}`);
  return `        (${component}, ${JSON.stringify(key)}) => Some((Kind::${kinds[p.type]}, &[${(p.enum ?? []).map(v=>JSON.stringify(v)).join(', ')}])),`;
};
const propertyArms = [
  ...Object.entries(schema.components).flatMap(([name,c])=>Object.entries(c.props).map(([key,p])=>arm(JSON.stringify(name),key,p))),
  ...Object.entries(schema.common).map(([key,p])=>arm('_',key,p)),
];
await writeFile(rust, (await readFile(rust,'utf8')) + `
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Kind {
    Str,
    Bool,
    NullableStr,
    Nonnegative,
    Positive,
    Integer,
    PositiveInteger,
    SelectOptions,
    Tabs,
    MenuItems,
}
impl Kind {
    pub(crate) fn expected(self) -> &'static str {
        match self {
            Kind::Str => "string",
            Kind::Bool => "boolean",
            Kind::NullableStr => "string or null",
            Kind::Nonnegative => "number >= 0",
            Kind::Positive => "number > 0",
            Kind::Integer => "integer >= 0",
            Kind::PositiveInteger => "integer > 0",
            Kind::SelectOptions => "unique select options",
            Kind::Tabs => "unique tab items",
            Kind::MenuItems => "unique menu items",
        }
    }
}
/// The value kind and allowed strings of a component property.
pub(crate) fn property(component: &str, key: &str) -> Option<(Kind, &'static [&'static str])> {
    match (component, key) {
${propertyArms.join('\n')}
        _ => None,
    }
}
pub(crate) fn valid(kind: Kind, choices: &[&str], value: &UiValue) -> bool {
    let number = match value {
        UiValue::Number(n) if n.is_finite() => Some(*n),
        _ => None,
    };
    let ok = match kind {
        Kind::Str => matches!(value, UiValue::String(_)),
        Kind::Bool => matches!(value, UiValue::Boolean(_)),
        Kind::NullableStr => matches!(value, UiValue::Null | UiValue::String(_)),
        Kind::Nonnegative => number.is_some_and(|n| n >= 0.0),
        Kind::Positive => number.is_some_and(|n| n > 0.0),
        Kind::Integer => number.is_some_and(|n| n >= 0.0 && n.fract() == 0.0),
        Kind::PositiveInteger => number.is_some_and(|n| n > 0.0 && n.fract() == 0.0),
        Kind::SelectOptions => options(value, "value", &["value", "label", "disabled"]),
        Kind::Tabs => options(value, "id", &["id", "label"]),
        Kind::MenuItems => options(value, "id", &["id", "label", "disabled", "danger"]),
    };
    ok && (choices.is_empty() || matches!(value, UiValue::String(v) if choices.contains(&v.as_str())))
}
fn options(value: &UiValue, identity: &str, keys: &[&str]) -> bool {
    let UiValue::Array(items) = value else {
        return false;
    };
    let mut seen = std::collections::HashSet::new();
    items.iter().all(|item| {
        let UiValue::Object(item) = item else {
            return false;
        };
        item.keys().all(|key| keys.contains(&key.as_str()))
            && matches!(item.get(identity), Some(UiValue::String(id)) if seen.insert(id.clone()))
            && matches!(item.get("label"), Some(UiValue::String(_)))
            && ["disabled", "danger"]
                .iter()
                .all(|key| item.get(*key).is_none_or(|v| matches!(v, UiValue::Boolean(_))))
    })
}
`);
await writeFile(rust, (await readFile(rust,'utf8')).replace('// Generated from plugins/sdk/ui.schema.json.\n', '// Generated from plugins/sdk/ui.schema.json.\nuse crate::api::ui::UiValue;\n'));

await writeFile(resolve(here,'../../third/fjs/libfjs/src/ui/components.js'), 'const __revericComponentSlots = '+JSON.stringify(Object.fromEntries(Object.entries(schema.components).map(([name,c])=>[name,Object.keys(c.slots)])))+';\n');
