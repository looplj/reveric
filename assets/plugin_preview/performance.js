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

  // sdk/fixtures/performance.entry.js
  var performance_entry_exports = {};
  __export(performance_entry_exports, {
    mount: () => mount
  });

  // reveric-ui:reveric-plugin-sdk/ui
  var signal = globalThis.__revericUi.signal;
  var computed = globalThis.__revericUi.computed;
  var effect = globalThis.__revericUi.effect;
  var batch = globalThis.__revericUi.batch;
  var untracked = globalThis.__revericUi.untracked;
  var cleanup = globalThis.__revericUi.cleanup;
  var resource = globalThis.__revericUi.resource;
  var If = globalThis.__revericUi.If;
  var Each = globalThis.__revericUi.Each;
  var ErrorBoundary = globalThis.__revericUi.ErrorBoundary;
  var List = globalThis.__revericUi.List;
  var Tabs = globalThis.__revericUi.Tabs;

  // sdk/fixtures/performance.tsx
  function Page(context) {
    const count = signal(0), values = Array.from({ length: 40 }, (_, index) => ({
      id: String(index),
      value: signal(0)
    }));
    const query = signal(0), result = resource(() => query(), async (value) => {
      await context.storage.get(`search.${value}`);
      return value;
    });
    const rows = signal(Array.from({ length: 1e3 }, (_, index) => ({
      id: String(index),
      label: `Row ${index}`
    })));
    return globalThis.__revericUi.element("Scroll", {
      get children() {
        return globalThis.__revericUi.element("Column", {
          "gap": "xs",
          get children() {
            return [globalThis.__revericUi.element("Text", {
              get "text"() {
                return `Counter ${count()}`;
              },
              "testId": "counter"
            }), globalThis.__revericUi.element("Text", {
              get "text"() {
                return `Search ${result.value() ?? -1}`;
              }
            }), globalThis.__revericUi.element("Button", {
              "label": "Search next",
              "onPress": () => query.update((n) => n + 1)
            }), globalThis.__revericUi.element("Wrap", {
              "gap": "sm",
              get children() {
                return [globalThis.__revericUi.element("Button", {
                  "label": "Increment",
                  "onPress": () => count.update((n) => n + 1)
                }), globalThis.__revericUi.element("Button", {
                  "label": "Update forty",
                  "onPress": () => batch(() => {
                    count.update((n) => n + 1);
                    for (const value of values)
                      value.value.update((n) => n + 1);
                  })
                }), globalThis.__revericUi.element("Button", {
                  "label": "Reverse",
                  "onPress": () => rows.update((previous) => [...previous].reverse())
                })];
              }
            }), globalThis.__revericUi.component(Each, {
              get "items"() {
                return values;
              },
              get "key"() {
                return (item) => item.id;
              },
              get children() {
                return (value) => globalThis.__revericUi.element("Text", {
                  get "text"() {
                    return `Dynamic ${value().value()}`;
                  }
                });
              }
            }), globalThis.__revericUi.component(List, {
              get "items"() {
                return rows();
              },
              get "key"() {
                return (row) => row.id;
              },
              "itemExtent": 28,
              "height": 180,
              get "renderItem"() {
                return (row) => globalThis.__revericUi.element("Text", {
                  get "text"() {
                    return row().label;
                  }
                });
              }
            }), globalThis.__revericUi.component(Each, {
              get "items"() {
                return Array.from({ length: 200 }, (_, index) => ({
                  id: String(index)
                }));
              },
              get "key"() {
                return (row) => row.id;
              },
              get children() {
                return (row) => globalThis.__revericUi.element("Button", {
                  get "label"() {
                    return `Control ${row().id}`;
                  },
                  "onPress": () => count.update((n) => n + 1)
                });
              }
            })];
          }
        });
      }
    });
  }

  // sdk/fixtures/performance.entry.js
  function mount(context) {
    return globalThis.__revericUi.mount(() => Page(context), context.root);
  }
  return __toCommonJS(performance_entry_exports);
})();
//# sourceMappingURL=data:application/json;base64,ewogICJ2ZXJzaW9uIjogMywKICAic291cmNlcyI6IFsiLi4vLi4vcGx1Z2lucy9zZGsvZml4dHVyZXMvcGVyZm9ybWFuY2UuZW50cnkuanMiLCAicmV2ZXJpYy11aTpyZXZlcmljLXBsdWdpbi1zZGsvdWkiLCAiLi4vLi4vcGx1Z2lucy9zZGsvZml4dHVyZXMvcGVyZm9ybWFuY2UudHN4Il0sCiAgInNvdXJjZXNDb250ZW50IjogWyJpbXBvcnQgUGFnZSBmcm9tIFwiL1VzZXJzL1NlcHRlbWJlcl8xL1Byb2plY3RzL0ZyZWVkb20vcmV2ZXJpYy9wbHVnaW5zL3Nkay9maXh0dXJlcy9wZXJmb3JtYW5jZS50c3hcIjtcbmV4cG9ydCBmdW5jdGlvbiBtb3VudChjb250ZXh0KXtyZXR1cm4gZ2xvYmFsVGhpcy5fX3JldmVyaWNVaS5tb3VudCgoKT0+UGFnZShjb250ZXh0KSxjb250ZXh0LnJvb3QpO30iLCAiZXhwb3J0IGNvbnN0IHNpZ25hbD1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLnNpZ25hbDtcbmV4cG9ydCBjb25zdCBjb21wdXRlZD1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmNvbXB1dGVkO1xuZXhwb3J0IGNvbnN0IGVmZmVjdD1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVmZmVjdDtcbmV4cG9ydCBjb25zdCBiYXRjaD1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmJhdGNoO1xuZXhwb3J0IGNvbnN0IHVudHJhY2tlZD1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLnVudHJhY2tlZDtcbmV4cG9ydCBjb25zdCBjbGVhbnVwPWdsb2JhbFRoaXMuX19yZXZlcmljVWkuY2xlYW51cDtcbmV4cG9ydCBjb25zdCByZXNvdXJjZT1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLnJlc291cmNlO1xuZXhwb3J0IGNvbnN0IElmPWdsb2JhbFRoaXMuX19yZXZlcmljVWkuSWY7XG5leHBvcnQgY29uc3QgRWFjaD1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLkVhY2g7XG5leHBvcnQgY29uc3QgRXJyb3JCb3VuZGFyeT1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLkVycm9yQm91bmRhcnk7XG5leHBvcnQgY29uc3QgTGlzdD1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLkxpc3Q7XG5leHBvcnQgY29uc3QgVGFicz1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLlRhYnM7XG5leHBvcnQgY29uc3QgQ29sdW1uPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJDb2x1bW5cIixwcm9wcyk7XG5leHBvcnQgY29uc3QgUm93PXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJSb3dcIixwcm9wcyk7XG5leHBvcnQgY29uc3QgV3JhcD1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiV3JhcFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBCb3g9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIkJveFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBTY3JvbGw9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIlNjcm9sbFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBHYXA9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIkdhcFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBUZXh0PXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJUZXh0XCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IE1hcmtkb3duPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJNYXJrZG93blwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBJY29uPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJJY29uXCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IENhcmQ9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIkNhcmRcIixwcm9wcyk7XG5leHBvcnQgY29uc3QgRGl2aWRlcj1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiRGl2aWRlclwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBCYWRnZT1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiQmFkZ2VcIixwcm9wcyk7XG5leHBvcnQgY29uc3QgTG9hZGluZz1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiTG9hZGluZ1wiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBFbXB0eVN0YXRlPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJFbXB0eVN0YXRlXCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IEJ1dHRvbj1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiQnV0dG9uXCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IEljb25CdXR0b249cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIkljb25CdXR0b25cIixwcm9wcyk7XG5leHBvcnQgY29uc3QgVGV4dEZpZWxkPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJUZXh0RmllbGRcIixwcm9wcyk7XG5leHBvcnQgY29uc3QgU2VhcmNoRmllbGQ9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIlNlYXJjaEZpZWxkXCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IFNlbGVjdD1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiU2VsZWN0XCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IENoZWNrYm94PXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJDaGVja2JveFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBTd2l0Y2g9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIlN3aXRjaFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBDb2xsYXBzaWJsZT1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiQ29sbGFwc2libGVcIixwcm9wcyk7XG5leHBvcnQgY29uc3QgTWVudT1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiTWVudVwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBEaWFsb2c9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIkRpYWxvZ1wiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBQb3BvdmVyPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJQb3BvdmVyXCIscHJvcHMpOyIsICJpbXBvcnQge1xuICBCdXR0b24sXG4gIENvbHVtbixcbiAgRWFjaCxcbiAgTGlzdCxcbiAgU2Nyb2xsLFxuICBUZXh0LFxuICBXcmFwLFxuICBiYXRjaCxcbiAgc2lnbmFsLFxuICByZXNvdXJjZSxcbiAgdHlwZSBQYWdlQ29udGV4dCxcbn0gZnJvbSBcInJldmVyaWMtcGx1Z2luLXNkay91aVwiO1xuZXhwb3J0IGRlZmF1bHQgZnVuY3Rpb24gUGFnZShjb250ZXh0OiBQYWdlQ29udGV4dCkge1xuICBjb25zdCBjb3VudCA9IHNpZ25hbCgwKSxcbiAgICB2YWx1ZXMgPSBBcnJheS5mcm9tKHsgbGVuZ3RoOiA0MCB9LCAoXywgaW5kZXgpID0+ICh7XG4gICAgICBpZDogU3RyaW5nKGluZGV4KSxcbiAgICAgIHZhbHVlOiBzaWduYWwoMCksXG4gICAgfSkpO1xuICBjb25zdCBxdWVyeSA9IHNpZ25hbCgwKSxcbiAgICByZXN1bHQgPSByZXNvdXJjZShcbiAgICAgICgpID0+IHF1ZXJ5KCksXG4gICAgICBhc3luYyAodmFsdWUpID0+IHtcbiAgICAgICAgYXdhaXQgY29udGV4dC5zdG9yYWdlLmdldChgc2VhcmNoLiR7dmFsdWV9YCk7XG4gICAgICAgIHJldHVybiB2YWx1ZTtcbiAgICAgIH0sXG4gICAgKTtcbiAgY29uc3Qgcm93cyA9IHNpZ25hbChcbiAgICBBcnJheS5mcm9tKHsgbGVuZ3RoOiAxMDAwIH0sIChfLCBpbmRleCkgPT4gKHtcbiAgICAgIGlkOiBTdHJpbmcoaW5kZXgpLFxuICAgICAgbGFiZWw6IGBSb3cgJHtpbmRleH1gLFxuICAgIH0pKSxcbiAgKTtcbiAgcmV0dXJuIChcbiAgICA8U2Nyb2xsPlxuICAgICAgPENvbHVtbiBnYXA9XCJ4c1wiPlxuICAgICAgICA8VGV4dCB0ZXh0PXtgQ291bnRlciAke2NvdW50KCl9YH0gdGVzdElkPVwiY291bnRlclwiIC8+XG4gICAgICAgIDxUZXh0IHRleHQ9e2BTZWFyY2ggJHtyZXN1bHQudmFsdWUoKSA/PyAtMX1gfSAvPlxuICAgICAgICA8QnV0dG9uXG4gICAgICAgICAgbGFiZWw9XCJTZWFyY2ggbmV4dFwiXG4gICAgICAgICAgb25QcmVzcz17KCkgPT4gcXVlcnkudXBkYXRlKChuKSA9PiBuICsgMSl9XG4gICAgICAgIC8+XG4gICAgICAgIDxXcmFwIGdhcD1cInNtXCI+XG4gICAgICAgICAgPEJ1dHRvblxuICAgICAgICAgICAgbGFiZWw9XCJJbmNyZW1lbnRcIlxuICAgICAgICAgICAgb25QcmVzcz17KCkgPT4gY291bnQudXBkYXRlKChuKSA9PiBuICsgMSl9XG4gICAgICAgICAgLz5cbiAgICAgICAgICA8QnV0dG9uXG4gICAgICAgICAgICBsYWJlbD1cIlVwZGF0ZSBmb3J0eVwiXG4gICAgICAgICAgICBvblByZXNzPXsoKSA9PlxuICAgICAgICAgICAgICBiYXRjaCgoKSA9PiB7XG4gICAgICAgICAgICAgICAgY291bnQudXBkYXRlKChuKSA9PiBuICsgMSk7XG4gICAgICAgICAgICAgICAgZm9yIChjb25zdCB2YWx1ZSBvZiB2YWx1ZXMpIHZhbHVlLnZhbHVlLnVwZGF0ZSgobikgPT4gbiArIDEpO1xuICAgICAgICAgICAgICB9KVxuICAgICAgICAgICAgfVxuICAgICAgICAgIC8+XG4gICAgICAgICAgPEJ1dHRvblxuICAgICAgICAgICAgbGFiZWw9XCJSZXZlcnNlXCJcbiAgICAgICAgICAgIG9uUHJlc3M9eygpID0+IHJvd3MudXBkYXRlKChwcmV2aW91cykgPT4gWy4uLnByZXZpb3VzXS5yZXZlcnNlKCkpfVxuICAgICAgICAgIC8+XG4gICAgICAgIDwvV3JhcD5cbiAgICAgICAgPEVhY2ggaXRlbXM9e3ZhbHVlc30ga2V5PXsoaXRlbSkgPT4gaXRlbS5pZH0+XG4gICAgICAgICAgeyh2YWx1ZSkgPT4gPFRleHQgdGV4dD17YER5bmFtaWMgJHt2YWx1ZSgpLnZhbHVlKCl9YH0gLz59XG4gICAgICAgIDwvRWFjaD5cbiAgICAgICAgPExpc3RcbiAgICAgICAgICBpdGVtcz17cm93cygpfVxuICAgICAgICAgIGtleT17KHJvdykgPT4gcm93LmlkfVxuICAgICAgICAgIGl0ZW1FeHRlbnQ9ezI4fVxuICAgICAgICAgIGhlaWdodD17MTgwfVxuICAgICAgICAgIHJlbmRlckl0ZW09eyhyb3cpID0+IDxUZXh0IHRleHQ9e3JvdygpLmxhYmVsfSAvPn1cbiAgICAgICAgLz5cbiAgICAgICAgPEVhY2hcbiAgICAgICAgICBpdGVtcz17QXJyYXkuZnJvbSh7IGxlbmd0aDogMjAwIH0sIChfLCBpbmRleCkgPT4gKHtcbiAgICAgICAgICAgIGlkOiBTdHJpbmcoaW5kZXgpLFxuICAgICAgICAgIH0pKX1cbiAgICAgICAgICBrZXk9eyhyb3cpID0+IHJvdy5pZH1cbiAgICAgICAgPlxuICAgICAgICAgIHsocm93KSA9PiAoXG4gICAgICAgICAgICA8QnV0dG9uXG4gICAgICAgICAgICAgIGxhYmVsPXtgQ29udHJvbCAke3JvdygpLmlkfWB9XG4gICAgICAgICAgICAgIG9uUHJlc3M9eygpID0+IGNvdW50LnVwZGF0ZSgobikgPT4gbiArIDEpfVxuICAgICAgICAgICAgLz5cbiAgICAgICAgICApfVxuICAgICAgICA8L0VhY2g+XG4gICAgICA8L0NvbHVtbj5cbiAgICA8L1Njcm9sbD5cbiAgKTtcbn1cbiJdLAogICJtYXBwaW5ncyI6ICI7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7O0FBQUE7QUFBQTtBQUFBO0FBQUE7OztB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
