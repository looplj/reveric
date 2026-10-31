// Generated from ui.schema.json by generate_ui.mjs.
declare module "reveric/ui" {
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
  export interface CommonProps { key?: string; testId?: string; accessibleLabel?: string; flex?: number; }
  export interface ColumnProps extends CommonProps {
    gap?: "none" | "xxs" | "xs" | "sm" | "md" | "lg" | "xl" | "x2l" | "x3l" | "x4l";
    align?: "start" | "center" | "end" | "stretch";
    justify?: "start" | "center" | "end" | "spaceBetween";
    children?: UiNode | readonly UiNode[];
  }
  export function Column(props: ColumnProps): UiNode;
  export interface RowProps extends CommonProps {
    gap?: "none" | "xxs" | "xs" | "sm" | "md" | "lg" | "xl" | "x2l" | "x3l" | "x4l";
    align?: "start" | "center" | "end" | "stretch";
    justify?: "start" | "center" | "end" | "spaceBetween";
    children?: UiNode | readonly UiNode[];
  }
  export function Row(props: RowProps): UiNode;
  export interface WrapProps extends CommonProps {
    gap?: "none" | "xxs" | "xs" | "sm" | "md" | "lg" | "xl" | "x2l" | "x3l" | "x4l";
    runGap?: "none" | "xxs" | "xs" | "sm" | "md" | "lg" | "xl" | "x2l" | "x3l" | "x4l";
    align?: "start" | "center" | "end";
    children?: UiNode | readonly UiNode[];
  }
  export function Wrap(props: WrapProps): UiNode;
  export interface BoxProps extends CommonProps {
    padding?: "none" | "xxs" | "xs" | "sm" | "md" | "lg" | "xl" | "x2l" | "x3l" | "x4l";
    surface?: "transparent" | "base" | "elevated";
    radius?: "none" | "small" | "medium" | "large" | "card";
    width?: number;
    height?: number;
    minWidth?: number;
    maxWidth?: number;
    minHeight?: number;
    maxHeight?: number;
    child?: UiNode;
    children?: UiNode | readonly UiNode[];
  }
  export function Box(props: BoxProps): UiNode;
  export interface ScrollProps extends CommonProps {
    direction?: "vertical" | "horizontal";
    maxHeight?: number;
    child?: UiNode;
    children?: UiNode | readonly UiNode[];
  }
  export function Scroll(props: ScrollProps): UiNode;
  export interface GapProps extends CommonProps {
    size?: "none" | "xxs" | "xs" | "sm" | "md" | "lg" | "xl" | "x2l" | "x3l" | "x4l";
  }
  export function Gap(props: GapProps): UiNode;
  export function List<T>(props: { items: readonly T[]; key: (item: T) => string; itemExtent: number; height: number; renderItem: (item: Accessor<T>, index: Accessor<number>) => UiNode }): UiNode;
  export interface TextProps extends CommonProps {
    text: string;
    variant?: "body" | "caption" | "heading";
    tone?: "default" | "muted" | "accent" | "success" | "warning" | "danger";
    maxLines?: number;
  }
  export function Text(props: TextProps): UiNode;
  export interface MarkdownProps extends CommonProps {
    text: string;
  }
  export function Markdown(props: MarkdownProps): UiNode;
  export interface IconProps extends CommonProps {
    name: string;
    size?: "small" | "standard" | "large";
    tone?: "default" | "muted" | "accent" | "success" | "warning" | "danger";
  }
  export function Icon(props: IconProps): UiNode;
  export interface CardProps extends CommonProps {
    padding?: "none" | "xxs" | "xs" | "sm" | "md" | "lg" | "xl" | "x2l" | "x3l" | "x4l";
    child?: UiNode;
    children?: UiNode | readonly UiNode[];
  }
  export function Card(props: CardProps): UiNode;
  export interface DividerProps extends CommonProps {
    direction?: "horizontal" | "vertical";
  }
  export function Divider(props: DividerProps): UiNode;
  export interface BadgeProps extends CommonProps {
    text: string;
    tone?: "default" | "muted" | "accent" | "success" | "warning" | "danger";
  }
  export function Badge(props: BadgeProps): UiNode;
  export interface LoadingProps extends CommonProps {
    label?: string;
  }
  export function Loading(props: LoadingProps): UiNode;
  export interface EmptyStateProps extends CommonProps {
    label?: string;
    message: string;
    actions?: UiNode | readonly UiNode[];
    children?: UiNode | readonly UiNode[];
  }
  export function EmptyState(props: EmptyStateProps): UiNode;
  export interface ButtonProps extends CommonProps {
    label: string;
    variant?: "primary" | "secondary" | "text" | "danger";
    size?: "standard" | "prominent" | "compact";
    disabled?: boolean;
    loading?: boolean;
    icon?: string;
    onPress?: (event: UiEvent) => void | Promise<void>;
  }
  export function Button(props: ButtonProps): UiNode;
  export interface IconButtonProps extends CommonProps {
    icon: string;
    tooltip: string;
    disabled?: boolean;
    onPress?: (event: UiEvent) => void | Promise<void>;
  }
  export function IconButton(props: IconButtonProps): UiNode;
  export interface TextFieldProps extends CommonProps {
    value: string;
    label?: string;
    placeholder?: string;
    error?: string;
    disabled?: boolean;
    multiline?: boolean;
    onChange?: (event: UiEvent) => void | Promise<void>;
    onSubmit?: (event: UiEvent) => void | Promise<void>;
  }
  export function TextField(props: TextFieldProps): UiNode;
  export interface SearchFieldProps extends CommonProps {
    value: string;
    label?: string;
    placeholder?: string;
    error?: string;
    disabled?: boolean;
    debounceMs?: number;
    onChange?: (event: UiEvent) => void | Promise<void>;
    onSubmit?: (event: UiEvent) => void | Promise<void>;
  }
  export function SearchField(props: SearchFieldProps): UiNode;
  export interface SelectProps extends CommonProps {
    value: string | null;
    options: readonly { value: string; label: string; disabled?: boolean }[];
    disabled?: boolean;
    onChange?: (event: UiEvent) => void | Promise<void>;
  }
  export function Select(props: SelectProps): UiNode;
  export interface CheckboxProps extends CommonProps {
    value: boolean;
    label?: string;
    disabled?: boolean;
    onChange?: (event: UiEvent) => void | Promise<void>;
  }
  export function Checkbox(props: CheckboxProps): UiNode;
  export interface SwitchProps extends CommonProps {
    value: boolean;
    label?: string;
    disabled?: boolean;
    onChange?: (event: UiEvent) => void | Promise<void>;
  }
  export function Switch(props: SwitchProps): UiNode;
  export interface TabsProps extends CommonProps {
    items: readonly { id: string; label: string }[];
    value: string;
    onChange?: (event: UiEvent) => void | Promise<void>;
    content?: (id: string) => UiNode;
    children?: (id: string) => UiNode;
  }
  export function Tabs(props: TabsProps): UiNode;
  export interface CollapsibleProps extends CommonProps {
    title: string;
    open: boolean;
    onOpenChange?: (event: UiEvent) => void | Promise<void>;
    children?: UiNode | readonly UiNode[];
  }
  export function Collapsible(props: CollapsibleProps): UiNode;
  export interface MenuProps extends CommonProps {
    items: readonly { id: string; label: string; disabled?: boolean; danger?: boolean }[];
    onSelect?: (event: UiEvent) => void | Promise<void>;
    trigger?: UiNode;
    children?: UiNode | readonly UiNode[];
  }
  export function Menu(props: MenuProps): UiNode;
  export interface DialogProps extends CommonProps {
    open: boolean;
    title: string;
    onOpenChange?: (event: UiEvent) => void | Promise<void>;
    body?: UiNode;
    actions?: UiNode | readonly UiNode[];
    children?: UiNode | readonly UiNode[];
  }
  export function Dialog(props: DialogProps): UiNode;
  export interface PopoverProps extends CommonProps {
    open: boolean;
    onOpenChange?: (event: UiEvent) => void | Promise<void>;
    trigger?: UiNode;
    body?: UiNode;
    children?: UiNode | readonly UiNode[];
  }
  export function Popover(props: PopoverProps): UiNode;
}
declare namespace JSX { type Element = import("reveric/ui").UiNode; interface ElementChildrenAttribute { children: {} } }
