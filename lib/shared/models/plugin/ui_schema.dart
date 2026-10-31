// 职责: 提供由插件 UI schema 生成的属性、事件与插槽校验定义。
// 关联文件:
//   plugins/sdk/ui.schema.json
//   plugins/sdk/generate_ui.mjs
// GENERATED CODE - DO NOT MODIFY BY HAND
const pluginUiSchema = <String, dynamic>{
  "protocol": "reveric-tsx-v1",
  "common": {
    "key": {"type": "string"},
    "testId": {"type": "string"},
    "accessibleLabel": {"type": "string"},
    "flex": {"type": "integer", "default": 0},
  },
  "components": {
    "Column": {
      "props": {
        "gap": {
          "type": "string",
          "enum": [
            "none",
            "xxs",
            "xs",
            "sm",
            "md",
            "lg",
            "xl",
            "x2l",
            "x3l",
            "x4l",
          ],
          "default": "md",
        },
        "align": {
          "type": "string",
          "enum": ["start", "center", "end", "stretch"],
          "default": "start",
        },
        "justify": {
          "type": "string",
          "enum": ["start", "center", "end", "spaceBetween"],
          "default": "start",
        },
      },
      "events": [],
      "slots": {"children": "many"},
    },
    "Row": {
      "props": {
        "gap": {
          "type": "string",
          "enum": [
            "none",
            "xxs",
            "xs",
            "sm",
            "md",
            "lg",
            "xl",
            "x2l",
            "x3l",
            "x4l",
          ],
          "default": "md",
        },
        "align": {
          "type": "string",
          "enum": ["start", "center", "end", "stretch"],
          "default": "start",
        },
        "justify": {
          "type": "string",
          "enum": ["start", "center", "end", "spaceBetween"],
          "default": "start",
        },
      },
      "events": [],
      "slots": {"children": "many"},
    },
    "Wrap": {
      "props": {
        "gap": {
          "type": "string",
          "enum": [
            "none",
            "xxs",
            "xs",
            "sm",
            "md",
            "lg",
            "xl",
            "x2l",
            "x3l",
            "x4l",
          ],
          "default": "md",
        },
        "runGap": {
          "type": "string",
          "enum": [
            "none",
            "xxs",
            "xs",
            "sm",
            "md",
            "lg",
            "xl",
            "x2l",
            "x3l",
            "x4l",
          ],
          "default": "md",
        },
        "align": {
          "type": "string",
          "enum": ["start", "center", "end"],
          "default": "start",
        },
      },
      "events": [],
      "slots": {"children": "many"},
    },
    "Box": {
      "props": {
        "padding": {
          "type": "string",
          "enum": [
            "none",
            "xxs",
            "xs",
            "sm",
            "md",
            "lg",
            "xl",
            "x2l",
            "x3l",
            "x4l",
          ],
          "default": "none",
        },
        "surface": {
          "type": "string",
          "enum": ["transparent", "base", "elevated"],
          "default": "transparent",
        },
        "radius": {
          "type": "string",
          "enum": ["none", "small", "medium", "large", "card"],
          "default": "none",
        },
        "width": {"type": "nonnegative"},
        "height": {"type": "nonnegative"},
        "minWidth": {"type": "nonnegative"},
        "maxWidth": {"type": "nonnegative"},
        "minHeight": {"type": "nonnegative"},
        "maxHeight": {"type": "nonnegative"},
      },
      "events": [],
      "slots": {"child": "one"},
    },
    "Scroll": {
      "props": {
        "direction": {
          "type": "string",
          "enum": ["vertical", "horizontal"],
          "default": "vertical",
        },
        "maxHeight": {"type": "nonnegative"},
      },
      "events": [],
      "slots": {"child": "one"},
    },
    "Gap": {
      "props": {
        "size": {
          "type": "string",
          "enum": [
            "none",
            "xxs",
            "xs",
            "sm",
            "md",
            "lg",
            "xl",
            "x2l",
            "x3l",
            "x4l",
          ],
          "default": "md",
        },
      },
      "events": [],
      "slots": {},
    },
    "List": {
      "props": {
        "itemExtent": {"type": "positive", "required": true},
        "height": {"type": "positive", "required": true},
        "itemCount": {"type": "integer", "default": 0},
        "firstIndex": {"type": "integer", "default": 0},
      },
      "events": ["viewport"],
      "slots": {"children": "many"},
    },
    "Text": {
      "props": {
        "text": {"type": "string", "required": true},
        "variant": {
          "type": "string",
          "enum": ["body", "caption", "heading"],
          "default": "body",
        },
        "tone": {
          "type": "string",
          "enum": [
            "default",
            "muted",
            "accent",
            "success",
            "warning",
            "danger",
          ],
          "default": "default",
        },
        "maxLines": {"type": "positiveInteger"},
      },
      "events": [],
      "slots": {},
    },
    "Markdown": {
      "props": {
        "text": {"type": "string", "required": true},
      },
      "events": [],
      "slots": {},
    },
    "Icon": {
      "props": {
        "name": {"type": "string", "required": true},
        "size": {
          "type": "string",
          "enum": ["small", "standard", "large"],
          "default": "standard",
        },
        "tone": {
          "type": "string",
          "enum": [
            "default",
            "muted",
            "accent",
            "success",
            "warning",
            "danger",
          ],
          "default": "default",
        },
      },
      "events": [],
      "slots": {},
    },
    "Card": {
      "props": {
        "padding": {
          "type": "string",
          "enum": [
            "none",
            "xxs",
            "xs",
            "sm",
            "md",
            "lg",
            "xl",
            "x2l",
            "x3l",
            "x4l",
          ],
          "default": "lg",
        },
      },
      "events": [],
      "slots": {"child": "one"},
    },
    "Divider": {
      "props": {
        "direction": {
          "type": "string",
          "enum": ["horizontal", "vertical"],
          "default": "horizontal",
        },
      },
      "events": [],
      "slots": {},
    },
    "Badge": {
      "props": {
        "text": {"type": "string", "required": true},
        "tone": {
          "type": "string",
          "enum": [
            "default",
            "muted",
            "accent",
            "success",
            "warning",
            "danger",
          ],
          "default": "default",
        },
      },
      "events": [],
      "slots": {},
    },
    "Loading": {
      "props": {
        "label": {"type": "string"},
      },
      "events": [],
      "slots": {},
    },
    "EmptyState": {
      "props": {
        "label": {"type": "string"},
        "message": {"type": "string", "required": true},
      },
      "events": [],
      "slots": {"actions": "many"},
    },
    "Button": {
      "props": {
        "label": {"type": "string", "required": true},
        "variant": {
          "type": "string",
          "enum": ["primary", "secondary", "text", "danger"],
          "default": "secondary",
        },
        "size": {
          "type": "string",
          "enum": ["standard", "prominent", "compact"],
          "default": "standard",
        },
        "disabled": {"type": "boolean", "default": false},
        "loading": {"type": "boolean", "default": false},
        "icon": {"type": "string"},
      },
      "events": ["onPress"],
      "slots": {},
    },
    "IconButton": {
      "props": {
        "icon": {"type": "string", "required": true},
        "tooltip": {"type": "string", "required": true},
        "disabled": {"type": "boolean", "default": false},
      },
      "events": ["onPress"],
      "slots": {},
    },
    "TextField": {
      "props": {
        "value": {"type": "string", "required": true},
        "label": {"type": "string"},
        "placeholder": {"type": "string"},
        "error": {"type": "string"},
        "disabled": {"type": "boolean", "default": false},
        "multiline": {"type": "boolean", "default": false},
      },
      "events": ["onChange", "onSubmit"],
      "slots": {},
    },
    "SearchField": {
      "props": {
        "value": {"type": "string", "required": true},
        "label": {"type": "string"},
        "placeholder": {"type": "string"},
        "error": {"type": "string"},
        "disabled": {"type": "boolean", "default": false},
        "debounceMs": {"type": "nonnegative", "default": 300},
      },
      "events": ["onChange", "onSubmit"],
      "slots": {},
    },
    "Select": {
      "props": {
        "value": {"type": "nullableString", "required": true},
        "options": {"type": "selectOptions", "required": true},
        "disabled": {"type": "boolean", "default": false},
      },
      "events": ["onChange"],
      "slots": {},
    },
    "Checkbox": {
      "props": {
        "value": {"type": "boolean", "required": true},
        "label": {"type": "string"},
        "disabled": {"type": "boolean", "default": false},
      },
      "events": ["onChange"],
      "slots": {},
    },
    "Switch": {
      "props": {
        "value": {"type": "boolean", "required": true},
        "label": {"type": "string"},
        "disabled": {"type": "boolean", "default": false},
      },
      "events": ["onChange"],
      "slots": {},
    },
    "Tabs": {
      "props": {
        "items": {"type": "tabs", "required": true},
        "value": {"type": "string", "required": true},
      },
      "events": ["onChange"],
      "slots": {"content": "one"},
    },
    "Collapsible": {
      "props": {
        "title": {"type": "string", "required": true},
        "open": {"type": "boolean", "required": true},
      },
      "events": ["onOpenChange"],
      "slots": {"children": "many"},
    },
    "Menu": {
      "props": {
        "items": {"type": "menuItems", "required": true},
      },
      "events": ["onSelect"],
      "slots": {"trigger": "one"},
    },
    "Dialog": {
      "props": {
        "open": {"type": "boolean", "required": true},
        "title": {"type": "string", "required": true},
      },
      "events": ["onOpenChange"],
      "slots": {"body": "one", "actions": "many"},
    },
    "Popover": {
      "props": {
        "open": {"type": "boolean", "required": true},
      },
      "events": ["onOpenChange"],
      "slots": {"trigger": "one", "body": "one"},
    },
    "Fragment": {
      "internal": true,
      "props": {},
      "events": [],
      "slots": {"children": "many"},
    },
  },
};
