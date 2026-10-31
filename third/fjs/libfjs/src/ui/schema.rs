// Generated from plugins/sdk/ui.schema.json.
use crate::api::ui::UiValue;
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Component {
    Column,
    Row,
    Wrap,
    Box,
    Scroll,
    Gap,
    List,
    Text,
    Markdown,
    Icon,
    Card,
    Divider,
    Badge,
    Loading,
    EmptyState,
    Button,
    IconButton,
    TextField,
    SearchField,
    Select,
    Checkbox,
    Switch,
    Tabs,
    Collapsible,
    Menu,
    Dialog,
    Popover,
    Fragment,
}
impl Component {
    pub(crate) fn parse(value: &str) -> Option<Self> {
        match value {
            "Column" => Some(Self::Column),
            "Row" => Some(Self::Row),
            "Wrap" => Some(Self::Wrap),
            "Box" => Some(Self::Box),
            "Scroll" => Some(Self::Scroll),
            "Gap" => Some(Self::Gap),
            "List" => Some(Self::List),
            "Text" => Some(Self::Text),
            "Markdown" => Some(Self::Markdown),
            "Icon" => Some(Self::Icon),
            "Card" => Some(Self::Card),
            "Divider" => Some(Self::Divider),
            "Badge" => Some(Self::Badge),
            "Loading" => Some(Self::Loading),
            "EmptyState" => Some(Self::EmptyState),
            "Button" => Some(Self::Button),
            "IconButton" => Some(Self::IconButton),
            "TextField" => Some(Self::TextField),
            "SearchField" => Some(Self::SearchField),
            "Select" => Some(Self::Select),
            "Checkbox" => Some(Self::Checkbox),
            "Switch" => Some(Self::Switch),
            "Tabs" => Some(Self::Tabs),
            "Collapsible" => Some(Self::Collapsible),
            "Menu" => Some(Self::Menu),
            "Dialog" => Some(Self::Dialog),
            "Popover" => Some(Self::Popover),
            "Fragment" => Some(Self::Fragment),
            _ => None,
        }
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Event {
    Viewport,
    OnPress,
    OnChange,
    OnSubmit,
    OnOpenChange,
    OnSelect,
}
impl Event {
    pub(crate) fn parse(value: &str) -> Option<Self> {
        match value {
            "viewport" => Some(Self::Viewport),
            "onPress" => Some(Self::OnPress),
            "onChange" => Some(Self::OnChange),
            "onSubmit" => Some(Self::OnSubmit),
            "onOpenChange" => Some(Self::OnOpenChange),
            "onSelect" => Some(Self::OnSelect),
            _ => None,
        }
    }
}

pub(crate) fn slot(component: &str, slot: &str) -> Option<bool> {
    match (component, slot) {
        ("Column", "children") => Some(false),
        ("Row", "children") => Some(false),
        ("Wrap", "children") => Some(false),
        ("Box", "child") => Some(true),
        ("Scroll", "child") => Some(true),
        ("List", "children") => Some(false),
        ("Card", "child") => Some(true),
        ("EmptyState", "actions") => Some(false),
        ("Tabs", "content") => Some(true),
        ("Collapsible", "children") => Some(false),
        ("Menu", "trigger") => Some(true),
        ("Dialog", "body") => Some(true),
        ("Dialog", "actions") => Some(false),
        ("Popover", "trigger") => Some(true),
        ("Popover", "body") => Some(true),
        ("Fragment", "children") => Some(false),
        _ => None,
    }
}

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
        ("Column", "gap") => Some((
            Kind::Str,
            &[
                "none", "xxs", "xs", "sm", "md", "lg", "xl", "x2l", "x3l", "x4l",
            ],
        )),
        ("Column", "align") => Some((Kind::Str, &["start", "center", "end", "stretch"])),
        ("Column", "justify") => Some((Kind::Str, &["start", "center", "end", "spaceBetween"])),
        ("Row", "gap") => Some((
            Kind::Str,
            &[
                "none", "xxs", "xs", "sm", "md", "lg", "xl", "x2l", "x3l", "x4l",
            ],
        )),
        ("Row", "align") => Some((Kind::Str, &["start", "center", "end", "stretch"])),
        ("Row", "justify") => Some((Kind::Str, &["start", "center", "end", "spaceBetween"])),
        ("Wrap", "gap") => Some((
            Kind::Str,
            &[
                "none", "xxs", "xs", "sm", "md", "lg", "xl", "x2l", "x3l", "x4l",
            ],
        )),
        ("Wrap", "runGap") => Some((
            Kind::Str,
            &[
                "none", "xxs", "xs", "sm", "md", "lg", "xl", "x2l", "x3l", "x4l",
            ],
        )),
        ("Wrap", "align") => Some((Kind::Str, &["start", "center", "end"])),
        ("Box", "padding") => Some((
            Kind::Str,
            &[
                "none", "xxs", "xs", "sm", "md", "lg", "xl", "x2l", "x3l", "x4l",
            ],
        )),
        ("Box", "surface") => Some((Kind::Str, &["transparent", "base", "elevated"])),
        ("Box", "radius") => Some((Kind::Str, &["none", "small", "medium", "large", "card"])),
        ("Box", "width") => Some((Kind::Nonnegative, &[])),
        ("Box", "height") => Some((Kind::Nonnegative, &[])),
        ("Box", "minWidth") => Some((Kind::Nonnegative, &[])),
        ("Box", "maxWidth") => Some((Kind::Nonnegative, &[])),
        ("Box", "minHeight") => Some((Kind::Nonnegative, &[])),
        ("Box", "maxHeight") => Some((Kind::Nonnegative, &[])),
        ("Scroll", "direction") => Some((Kind::Str, &["vertical", "horizontal"])),
        ("Scroll", "maxHeight") => Some((Kind::Nonnegative, &[])),
        ("Gap", "size") => Some((
            Kind::Str,
            &[
                "none", "xxs", "xs", "sm", "md", "lg", "xl", "x2l", "x3l", "x4l",
            ],
        )),
        ("List", "itemExtent") => Some((Kind::Positive, &[])),
        ("List", "height") => Some((Kind::Positive, &[])),
        ("List", "itemCount") => Some((Kind::Integer, &[])),
        ("List", "firstIndex") => Some((Kind::Integer, &[])),
        ("Text", "text") => Some((Kind::Str, &[])),
        ("Text", "variant") => Some((Kind::Str, &["body", "caption", "heading"])),
        ("Text", "tone") => Some((
            Kind::Str,
            &["default", "muted", "accent", "success", "warning", "danger"],
        )),
        ("Text", "maxLines") => Some((Kind::PositiveInteger, &[])),
        ("Markdown", "text") => Some((Kind::Str, &[])),
        ("Icon", "name") => Some((Kind::Str, &[])),
        ("Icon", "size") => Some((Kind::Str, &["small", "standard", "large"])),
        ("Icon", "tone") => Some((
            Kind::Str,
            &["default", "muted", "accent", "success", "warning", "danger"],
        )),
        ("Card", "padding") => Some((
            Kind::Str,
            &[
                "none", "xxs", "xs", "sm", "md", "lg", "xl", "x2l", "x3l", "x4l",
            ],
        )),
        ("Divider", "direction") => Some((Kind::Str, &["horizontal", "vertical"])),
        ("Badge", "text") => Some((Kind::Str, &[])),
        ("Badge", "tone") => Some((
            Kind::Str,
            &["default", "muted", "accent", "success", "warning", "danger"],
        )),
        ("Loading", "label") => Some((Kind::Str, &[])),
        ("EmptyState", "label") => Some((Kind::Str, &[])),
        ("EmptyState", "message") => Some((Kind::Str, &[])),
        ("Button", "label") => Some((Kind::Str, &[])),
        ("Button", "variant") => Some((Kind::Str, &["primary", "secondary", "text", "danger"])),
        ("Button", "size") => Some((Kind::Str, &["standard", "prominent", "compact"])),
        ("Button", "disabled") => Some((Kind::Bool, &[])),
        ("Button", "loading") => Some((Kind::Bool, &[])),
        ("Button", "icon") => Some((Kind::Str, &[])),
        ("IconButton", "icon") => Some((Kind::Str, &[])),
        ("IconButton", "tooltip") => Some((Kind::Str, &[])),
        ("IconButton", "disabled") => Some((Kind::Bool, &[])),
        ("TextField", "value") => Some((Kind::Str, &[])),
        ("TextField", "label") => Some((Kind::Str, &[])),
        ("TextField", "placeholder") => Some((Kind::Str, &[])),
        ("TextField", "error") => Some((Kind::Str, &[])),
        ("TextField", "disabled") => Some((Kind::Bool, &[])),
        ("TextField", "multiline") => Some((Kind::Bool, &[])),
        ("SearchField", "value") => Some((Kind::Str, &[])),
        ("SearchField", "label") => Some((Kind::Str, &[])),
        ("SearchField", "placeholder") => Some((Kind::Str, &[])),
        ("SearchField", "error") => Some((Kind::Str, &[])),
        ("SearchField", "disabled") => Some((Kind::Bool, &[])),
        ("SearchField", "debounceMs") => Some((Kind::Nonnegative, &[])),
        ("Select", "value") => Some((Kind::NullableStr, &[])),
        ("Select", "options") => Some((Kind::SelectOptions, &[])),
        ("Select", "disabled") => Some((Kind::Bool, &[])),
        ("Checkbox", "value") => Some((Kind::Bool, &[])),
        ("Checkbox", "label") => Some((Kind::Str, &[])),
        ("Checkbox", "disabled") => Some((Kind::Bool, &[])),
        ("Switch", "value") => Some((Kind::Bool, &[])),
        ("Switch", "label") => Some((Kind::Str, &[])),
        ("Switch", "disabled") => Some((Kind::Bool, &[])),
        ("Tabs", "items") => Some((Kind::Tabs, &[])),
        ("Tabs", "value") => Some((Kind::Str, &[])),
        ("Collapsible", "title") => Some((Kind::Str, &[])),
        ("Collapsible", "open") => Some((Kind::Bool, &[])),
        ("Menu", "items") => Some((Kind::MenuItems, &[])),
        ("Dialog", "open") => Some((Kind::Bool, &[])),
        ("Dialog", "title") => Some((Kind::Str, &[])),
        ("Popover", "open") => Some((Kind::Bool, &[])),
        (_, "key") => Some((Kind::Str, &[])),
        (_, "testId") => Some((Kind::Str, &[])),
        (_, "accessibleLabel") => Some((Kind::Str, &[])),
        (_, "flex") => Some((Kind::Integer, &[])),
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
    ok && (choices.is_empty()
        || matches!(value, UiValue::String(v) if choices.contains(&v.as_str())))
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
            && ["disabled", "danger"].iter().all(|key| {
                item.get(*key)
                    .is_none_or(|v| matches!(v, UiValue::Boolean(_)))
            })
    })
}
