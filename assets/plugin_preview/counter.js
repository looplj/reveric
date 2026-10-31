"use strict";
var __revericView = (() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

  // sdk/fixtures/counter.tsx
  var counter_exports = {};
  __export(counter_exports, {
    mount: () => mount2
  });

  // reveric-ui:reveric/ui
  var signal = globalThis.__revericUi.signal;
  var computed = globalThis.__revericUi.computed;
  var effect = globalThis.__revericUi.effect;
  var batch = globalThis.__revericUi.batch;
  var untracked = globalThis.__revericUi.untracked;
  var cleanup = globalThis.__revericUi.cleanup;
  var resource = globalThis.__revericUi.resource;
  var mount = globalThis.__revericUi.mount;
  var If = globalThis.__revericUi.If;
  var Each = globalThis.__revericUi.Each;
  var ErrorBoundary = globalThis.__revericUi.ErrorBoundary;
  var List = globalThis.__revericUi.List;
  var Tabs = globalThis.__revericUi.Tabs;

  // sdk/fixtures/counter.tsx
  function mount2(context) {
    return mount(() => {
      const count = signal(0), name = signal("");
      const label = computed(() => `Count ${count()}`);
      const loaded = resource(() => count(), async (value) => {
        await context.storage.get("preview.delay");
        return value;
      });
      const rows = Array.from({ length: 1e3 }, (_, index) => ({ id: String(index), label: `Row ${index}` }));
      return globalThis.__revericUi.element("Scroll", {
        get children() {
          return globalThis.__revericUi.element("Column", {
            "gap": "sm",
            get children() {
              return [globalThis.__revericUi.element("Text", {
                get "text"() {
                  return label();
                }
              }), globalThis.__revericUi.element("Button", {
                "label": "Add",
                "onPress": () => count.update((value) => value + 1)
              }), globalThis.__revericUi.component(If, {
                get "when"() {
                  return count() > 0;
                },
                get children() {
                  return globalThis.__revericUi.element("Text", {
                    "text": "Positive"
                  });
                }
              }), globalThis.__revericUi.element("TextField", {
                "label": "Name",
                get "value"() {
                  return name();
                },
                "onChange": (event) => {
                  name.set(String(event.value));
                  void context.view.setDirty(true);
                }
              }), globalThis.__revericUi.element("Text", {
                get "text"() {
                  return loaded.loading() ? "Loading" : `Loaded ${loaded.value() ?? 0}`;
                }
              }), globalThis.__revericUi.component(Each, {
                get "items"() {
                  return [{ id: "a", label: "Stable row" }];
                },
                get "key"() {
                  return (item) => item.id;
                },
                get children() {
                  return (item) => globalThis.__revericUi.element("Text", {
                    get "text"() {
                      return item().label;
                    }
                  });
                }
              }), globalThis.__revericUi.component(List, {
                get "items"() {
                  return rows;
                },
                get "key"() {
                  return (item) => item.id;
                },
                "itemExtent": 32,
                "height": 160,
                get "renderItem"() {
                  return (item) => globalThis.__revericUi.element("Text", {
                    "variant": "caption",
                    get "text"() {
                      return item().label;
                    }
                  });
                }
              })];
            }
          });
        }
      });
    }, context.root);
  }
  return __toCommonJS(counter_exports);
})();
//# sourceMappingURL=data:application/json;base64,ewogICJ2ZXJzaW9uIjogMywKICAic291cmNlcyI6IFsiLi4vLi4vLi4vLi4vLi4vLi4vcGx1Z2lucy9zZGsvZml4dHVyZXMvY291bnRlci50c3giLCAicmV2ZXJpYy11aTpyZXZlcmljL3VpIl0sCiAgInNvdXJjZXNDb250ZW50IjogWyJpbXBvcnQge0J1dHRvbiwgQ29sdW1uLCBFYWNoLCBJZiwgTGlzdCwgU2Nyb2xsLCBUZXh0LCBUZXh0RmllbGQsIGNvbXB1dGVkLCBtb3VudCBhcyByZW5kZXIsIHJlc291cmNlLCBzaWduYWwsIHR5cGUgUGFnZUNvbnRleHR9IGZyb20gJ3JldmVyaWMvdWknO1xuZXhwb3J0IGZ1bmN0aW9uIG1vdW50KGNvbnRleHQ6IFBhZ2VDb250ZXh0KSB7XG4gIHJldHVybiByZW5kZXIoKCkgPT4ge1xuICAgIGNvbnN0IGNvdW50PXNpZ25hbCgwKSxuYW1lPXNpZ25hbCgnJyk7XG4gICAgY29uc3QgbGFiZWw9Y29tcHV0ZWQoKCk9PmBDb3VudCAke2NvdW50KCl9YCk7XG4gICAgY29uc3QgbG9hZGVkPXJlc291cmNlKCgpPT5jb3VudCgpLGFzeW5jIHZhbHVlPT57YXdhaXQgY29udGV4dC5zdG9yYWdlLmdldCgncHJldmlldy5kZWxheScpO3JldHVybiB2YWx1ZTt9KTtcbiAgICBjb25zdCByb3dzPUFycmF5LmZyb20oe2xlbmd0aDoxMDAwfSwoXyxpbmRleCk9Pih7aWQ6U3RyaW5nKGluZGV4KSxsYWJlbDpgUm93ICR7aW5kZXh9YH0pKTtcbiAgICByZXR1cm4gPFNjcm9sbD48Q29sdW1uIGdhcD1cInNtXCI+XG4gICAgICA8VGV4dCB0ZXh0PXtsYWJlbCgpfS8+XG4gICAgICA8QnV0dG9uIGxhYmVsPVwiQWRkXCIgb25QcmVzcz17KCk9PmNvdW50LnVwZGF0ZSh2YWx1ZT0+dmFsdWUrMSl9Lz5cbiAgICAgIDxJZiB3aGVuPXtjb3VudCgpPjB9PjxUZXh0IHRleHQ9XCJQb3NpdGl2ZVwiLz48L0lmPlxuICAgICAgPFRleHRGaWVsZCBsYWJlbD1cIk5hbWVcIiB2YWx1ZT17bmFtZSgpfSBvbkNoYW5nZT17ZXZlbnQ9PntuYW1lLnNldChTdHJpbmcoZXZlbnQudmFsdWUpKTt2b2lkIGNvbnRleHQudmlldy5zZXREaXJ0eSh0cnVlKTt9fS8+XG4gICAgICA8VGV4dCB0ZXh0PXtsb2FkZWQubG9hZGluZygpPydMb2FkaW5nJzpgTG9hZGVkICR7bG9hZGVkLnZhbHVlKCk/PzB9YH0vPlxuICAgICAgPEVhY2ggaXRlbXM9e1t7aWQ6J2EnLGxhYmVsOidTdGFibGUgcm93J31dfSBrZXk9e2l0ZW09Pml0ZW0uaWR9PlxuICAgICAgICB7aXRlbT0+PFRleHQgdGV4dD17aXRlbSgpLmxhYmVsfS8+fVxuICAgICAgPC9FYWNoPlxuICAgICAgPExpc3QgaXRlbXM9e3Jvd3N9IGtleT17aXRlbT0+aXRlbS5pZH0gaXRlbUV4dGVudD17MzJ9IGhlaWdodD17MTYwfSByZW5kZXJJdGVtPXtpdGVtPT48VGV4dCB2YXJpYW50PVwiY2FwdGlvblwiIHRleHQ9e2l0ZW0oKS5sYWJlbH0vPn0vPlxuICAgIDwvQ29sdW1uPjwvU2Nyb2xsPjtcbiAgfSxjb250ZXh0LnJvb3QpO1xufVxuIiwgImV4cG9ydCBjb25zdCBzaWduYWw9Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5zaWduYWw7XG5leHBvcnQgY29uc3QgY29tcHV0ZWQ9Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5jb21wdXRlZDtcbmV4cG9ydCBjb25zdCBlZmZlY3Q9Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lZmZlY3Q7XG5leHBvcnQgY29uc3QgYmF0Y2g9Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5iYXRjaDtcbmV4cG9ydCBjb25zdCB1bnRyYWNrZWQ9Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS51bnRyYWNrZWQ7XG5leHBvcnQgY29uc3QgY2xlYW51cD1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmNsZWFudXA7XG5leHBvcnQgY29uc3QgcmVzb3VyY2U9Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5yZXNvdXJjZTtcbmV4cG9ydCBjb25zdCBtb3VudD1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLm1vdW50O1xuZXhwb3J0IGNvbnN0IElmPWdsb2JhbFRoaXMuX19yZXZlcmljVWkuSWY7XG5leHBvcnQgY29uc3QgRWFjaD1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLkVhY2g7XG5leHBvcnQgY29uc3QgRXJyb3JCb3VuZGFyeT1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLkVycm9yQm91bmRhcnk7XG5leHBvcnQgY29uc3QgTGlzdD1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLkxpc3Q7XG5leHBvcnQgY29uc3QgVGFicz1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLlRhYnM7XG5leHBvcnQgY29uc3QgQ29sdW1uPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJDb2x1bW5cIixwcm9wcyk7XG5leHBvcnQgY29uc3QgUm93PXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJSb3dcIixwcm9wcyk7XG5leHBvcnQgY29uc3QgV3JhcD1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiV3JhcFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBCb3g9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIkJveFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBTY3JvbGw9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIlNjcm9sbFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBHYXA9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIkdhcFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBUZXh0PXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJUZXh0XCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IE1hcmtkb3duPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJNYXJrZG93blwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBJY29uPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJJY29uXCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IENhcmQ9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIkNhcmRcIixwcm9wcyk7XG5leHBvcnQgY29uc3QgRGl2aWRlcj1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiRGl2aWRlclwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBCYWRnZT1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiQmFkZ2VcIixwcm9wcyk7XG5leHBvcnQgY29uc3QgTG9hZGluZz1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiTG9hZGluZ1wiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBFbXB0eVN0YXRlPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJFbXB0eVN0YXRlXCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IEJ1dHRvbj1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiQnV0dG9uXCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IEljb25CdXR0b249cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIkljb25CdXR0b25cIixwcm9wcyk7XG5leHBvcnQgY29uc3QgVGV4dEZpZWxkPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJUZXh0RmllbGRcIixwcm9wcyk7XG5leHBvcnQgY29uc3QgU2VhcmNoRmllbGQ9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIlNlYXJjaEZpZWxkXCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IFNlbGVjdD1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiU2VsZWN0XCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IENoZWNrYm94PXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJDaGVja2JveFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBTd2l0Y2g9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIlN3aXRjaFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBDb2xsYXBzaWJsZT1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiQ29sbGFwc2libGVcIixwcm9wcyk7XG5leHBvcnQgY29uc3QgTWVudT1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiTWVudVwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBEaWFsb2c9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIkRpYWxvZ1wiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBQb3BvdmVyPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJQb3BvdmVyXCIscHJvcHMpOyJdLAogICJtYXBwaW5ncyI6ICI7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7OztBQUFBOztpQkFBQUE7Ozs7QUNBTyxNQUFNLFNBQU8sV0FBVyxZQUFZO0FBQ3BDLE1BQU0sV0FBUyxXQUFXLFlBQVk7QUFDdEMsTUFBTSxTQUFPLFdBQVcsWUFBWTtBQUNwQyxNQUFNLFFBQU0sV0FBVyxZQUFZO0FBQ25DLE1BQU0sWUFBVSxXQUFXLFlBQVk7QUFDdkMsTUFBTSxVQUFRLFdBQVcsWUFBWTtBQUNyQyxNQUFNLFdBQVMsV0FBVyxZQUFZO0FBQ3RDLE1BQU0sUUFBTSxXQUFXLFlBQVk7QUFDbkMsTUFBTSxLQUFHLFdBQVcsWUFBWTtBQUNoQyxNQUFNLE9BQUssV0FBVyxZQUFZO0FBQ2xDLE1BQU0sZ0JBQWMsV0FBVyxZQUFZO0FBQzNDLE1BQU0sT0FBSyxXQUFXLFlBQVk7QUFDbEMsTUFBTSxPQUFLLFdBQVcsWUFBWTs7O0FEWG5DLFdBQVVDLE9BQU0sU0FBb0I7QUFDeEMsV0FBTyxNQUFPLE1BQUs7QUFDakIsWUFBTSxRQUFNLE9BQU8sQ0FBQyxHQUFFLE9BQUssT0FBTyxFQUFFO0FBQ3BDLFlBQU0sUUFBTSxTQUFTLE1BQUksU0FBUyxNQUFLLENBQUUsRUFBRTtBQUMzQyxZQUFNLFNBQU8sU0FBUyxNQUFJLE1BQUssR0FBRyxPQUFNLFVBQU87QUFBQyxjQUFNLFFBQVEsUUFBUSxJQUFJLGVBQWU7QUFBRSxlQUFPO01BQU0sQ0FBQztBQUN6RyxZQUFNLE9BQUssTUFBTSxLQUFLLEVBQUMsUUFBTyxJQUFJLEdBQUUsQ0FBQyxHQUFFLFdBQVMsRUFBQyxJQUFHLE9BQU8sS0FBSyxHQUFFLE9BQU0sT0FBTyxLQUFLLEdBQUUsRUFBRTtBQUN4RixhQUFBLFdBQUEsWUFBQSxRQUFBLFVBQUE7OzttQkFBMkI7Ozs7eUJBQ2IsTUFBSzs7O3lCQUNIOzJCQUFlLE1BQUksTUFBTSxPQUFPLFdBQU8sUUFBTSxDQUFDO21EQUMzRCxJQUFFOzt5QkFBTyxNQUFLLElBQUc7Ozs7NEJBQWM7Ozs7eUJBQ2Y7O3lCQUFjLEtBQUk7OzRCQUFjLFdBQU87QUFBQyx1QkFBSyxJQUFJLE9BQU8sTUFBTSxLQUFLLENBQUM7QUFBRSx1QkFBSyxRQUFRLEtBQUssU0FBUyxJQUFJO2dCQUFFOzs7eUJBQzVHLE9BQU8sUUFBTyxJQUFHLFlBQVUsVUFBVSxPQUFPLE1BQUssS0FBSSxDQUFDOzttREFDakUsTUFBSTs7eUJBQVEsQ0FBQyxFQUFDLElBQUcsS0FBSSxPQUFNLGFBQVksQ0FBQzs7O3lCQUFRLFVBQU0sS0FBSzs7O3lCQUN6RCxVQUFNLFdBQUEsWUFBQSxRQUFBLFFBQUE7OzZCQUFZLEtBQUksRUFBRzs7OzttREFFM0IsTUFBSTs7eUJBQVE7Ozt5QkFBVyxVQUFNLEtBQUs7OzhCQUFnQjswQkFBWTs7eUJBQWlCLFVBQU0sV0FBQSxZQUFBLFFBQUEsUUFBQTsrQkFBYzs7NkJBQWdCLEtBQUksRUFBRzs7Ozs7Ozs7O0lBRS9ILEdBQUUsUUFBUSxJQUFJO0VBQ2hCOyIsCiAgIm5hbWVzIjogWyJtb3VudCIsICJtb3VudCJdCn0K
