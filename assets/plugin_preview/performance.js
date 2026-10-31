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

  // sdk/fixtures/performance.tsx
  var performance_exports = {};
  __export(performance_exports, {
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

  // sdk/fixtures/performance.tsx
  function mount2(context) {
    return mount(() => {
      const count = signal(0), values = Array.from({ length: 40 }, (_, index) => ({ id: String(index), value: signal(0) }));
      const query = signal(0), result = resource(() => query(), async (value) => {
        await context.storage.get(`search.${value}`);
        return value;
      });
      const rows = signal(Array.from({ length: 1e3 }, (_, index) => ({ id: String(index), label: `Row ${index}` })));
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
                  return Array.from({ length: 200 }, (_, index) => ({ id: String(index) }));
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
    }, context.root);
  }
  return __toCommonJS(performance_exports);
})();
//# sourceMappingURL=data:application/json;base64,ewogICJ2ZXJzaW9uIjogMywKICAic291cmNlcyI6IFsiLi4vLi4vcGx1Z2lucy9zZGsvZml4dHVyZXMvcGVyZm9ybWFuY2UudHN4IiwgInJldmVyaWMtdWk6cmV2ZXJpYy91aSJdLAogICJzb3VyY2VzQ29udGVudCI6IFsiaW1wb3J0IHtCdXR0b24sQ29sdW1uLEVhY2gsTGlzdCxTY3JvbGwsVGV4dCxXcmFwLGJhdGNoLHNpZ25hbCxyZXNvdXJjZSxtb3VudCBhcyByZW5kZXIsdHlwZSBQYWdlQ29udGV4dH0gZnJvbSAncmV2ZXJpYy91aSc7XG5leHBvcnQgZnVuY3Rpb24gbW91bnQoY29udGV4dDpQYWdlQ29udGV4dCl7XG4gcmV0dXJuIHJlbmRlcigoKT0+e1xuICBjb25zdCBjb3VudD1zaWduYWwoMCksdmFsdWVzPUFycmF5LmZyb20oe2xlbmd0aDo0MH0sKF8saW5kZXgpPT4oe2lkOlN0cmluZyhpbmRleCksdmFsdWU6c2lnbmFsKDApfSkpO1xuICBjb25zdCBxdWVyeT1zaWduYWwoMCkscmVzdWx0PXJlc291cmNlKCgpPT5xdWVyeSgpLGFzeW5jIHZhbHVlPT57YXdhaXQgY29udGV4dC5zdG9yYWdlLmdldChgc2VhcmNoLiR7dmFsdWV9YCk7cmV0dXJuIHZhbHVlO30pO1xuICBjb25zdCByb3dzPXNpZ25hbChBcnJheS5mcm9tKHtsZW5ndGg6MTAwMH0sKF8saW5kZXgpPT4oe2lkOlN0cmluZyhpbmRleCksbGFiZWw6YFJvdyAke2luZGV4fWB9KSkpO1xuICByZXR1cm4gPFNjcm9sbD48Q29sdW1uIGdhcD1cInhzXCI+XG4gICA8VGV4dCB0ZXh0PXtgQ291bnRlciAke2NvdW50KCl9YH0gdGVzdElkPVwiY291bnRlclwiLz5cbiAgIDxUZXh0IHRleHQ9e2BTZWFyY2ggJHtyZXN1bHQudmFsdWUoKT8/LTF9YH0vPlxuICAgPEJ1dHRvbiBsYWJlbD1cIlNlYXJjaCBuZXh0XCIgb25QcmVzcz17KCk9PnF1ZXJ5LnVwZGF0ZShuPT5uKzEpfS8+XG4gICA8V3JhcCBnYXA9XCJzbVwiPjxCdXR0b24gbGFiZWw9XCJJbmNyZW1lbnRcIiBvblByZXNzPXsoKT0+Y291bnQudXBkYXRlKG49Pm4rMSl9Lz5cbiAgICA8QnV0dG9uIGxhYmVsPVwiVXBkYXRlIGZvcnR5XCIgb25QcmVzcz17KCk9PmJhdGNoKCgpPT57Y291bnQudXBkYXRlKG49Pm4rMSk7Zm9yKGNvbnN0IHZhbHVlIG9mIHZhbHVlcyl2YWx1ZS52YWx1ZS51cGRhdGUobj0+bisxKTt9KX0vPlxuICAgIDxCdXR0b24gbGFiZWw9XCJSZXZlcnNlXCIgb25QcmVzcz17KCk9PnJvd3MudXBkYXRlKHByZXZpb3VzPT5bLi4ucHJldmlvdXNdLnJldmVyc2UoKSl9Lz48L1dyYXA+XG4gICA8RWFjaCBpdGVtcz17dmFsdWVzfSBrZXk9e2l0ZW09Pml0ZW0uaWR9Pnt2YWx1ZT0+PFRleHQgdGV4dD17YER5bmFtaWMgJHt2YWx1ZSgpLnZhbHVlKCl9YH0vPn08L0VhY2g+XG4gICA8TGlzdCBpdGVtcz17cm93cygpfSBrZXk9e3Jvdz0+cm93LmlkfSBpdGVtRXh0ZW50PXsyOH0gaGVpZ2h0PXsxODB9IHJlbmRlckl0ZW09e3Jvdz0+PFRleHQgdGV4dD17cm93KCkubGFiZWx9Lz59Lz5cbiAgIDxFYWNoIGl0ZW1zPXtBcnJheS5mcm9tKHtsZW5ndGg6MjAwfSwoXyxpbmRleCk9Pih7aWQ6U3RyaW5nKGluZGV4KX0pKX0ga2V5PXtyb3c9PnJvdy5pZH0+e3Jvdz0+PEJ1dHRvbiBsYWJlbD17YENvbnRyb2wgJHtyb3coKS5pZH1gfSBvblByZXNzPXsoKT0+Y291bnQudXBkYXRlKG49Pm4rMSl9Lz59PC9FYWNoPlxuICA8L0NvbHVtbj48L1Njcm9sbD47XG4gfSxjb250ZXh0LnJvb3QpO1xufVxuIiwgImV4cG9ydCBjb25zdCBzaWduYWw9Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5zaWduYWw7XG5leHBvcnQgY29uc3QgY29tcHV0ZWQ9Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5jb21wdXRlZDtcbmV4cG9ydCBjb25zdCBlZmZlY3Q9Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lZmZlY3Q7XG5leHBvcnQgY29uc3QgYmF0Y2g9Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5iYXRjaDtcbmV4cG9ydCBjb25zdCB1bnRyYWNrZWQ9Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS51bnRyYWNrZWQ7XG5leHBvcnQgY29uc3QgY2xlYW51cD1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmNsZWFudXA7XG5leHBvcnQgY29uc3QgcmVzb3VyY2U9Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5yZXNvdXJjZTtcbmV4cG9ydCBjb25zdCBtb3VudD1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLm1vdW50O1xuZXhwb3J0IGNvbnN0IElmPWdsb2JhbFRoaXMuX19yZXZlcmljVWkuSWY7XG5leHBvcnQgY29uc3QgRWFjaD1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLkVhY2g7XG5leHBvcnQgY29uc3QgRXJyb3JCb3VuZGFyeT1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLkVycm9yQm91bmRhcnk7XG5leHBvcnQgY29uc3QgTGlzdD1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLkxpc3Q7XG5leHBvcnQgY29uc3QgVGFicz1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLlRhYnM7XG5leHBvcnQgY29uc3QgQ29sdW1uPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJDb2x1bW5cIixwcm9wcyk7XG5leHBvcnQgY29uc3QgUm93PXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJSb3dcIixwcm9wcyk7XG5leHBvcnQgY29uc3QgV3JhcD1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiV3JhcFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBCb3g9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIkJveFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBTY3JvbGw9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIlNjcm9sbFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBHYXA9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIkdhcFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBUZXh0PXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJUZXh0XCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IE1hcmtkb3duPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJNYXJrZG93blwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBJY29uPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJJY29uXCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IENhcmQ9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIkNhcmRcIixwcm9wcyk7XG5leHBvcnQgY29uc3QgRGl2aWRlcj1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiRGl2aWRlclwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBCYWRnZT1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiQmFkZ2VcIixwcm9wcyk7XG5leHBvcnQgY29uc3QgTG9hZGluZz1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiTG9hZGluZ1wiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBFbXB0eVN0YXRlPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJFbXB0eVN0YXRlXCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IEJ1dHRvbj1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiQnV0dG9uXCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IEljb25CdXR0b249cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIkljb25CdXR0b25cIixwcm9wcyk7XG5leHBvcnQgY29uc3QgVGV4dEZpZWxkPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJUZXh0RmllbGRcIixwcm9wcyk7XG5leHBvcnQgY29uc3QgU2VhcmNoRmllbGQ9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIlNlYXJjaEZpZWxkXCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IFNlbGVjdD1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiU2VsZWN0XCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IENoZWNrYm94PXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJDaGVja2JveFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBTd2l0Y2g9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIlN3aXRjaFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBDb2xsYXBzaWJsZT1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiQ29sbGFwc2libGVcIixwcm9wcyk7XG5leHBvcnQgY29uc3QgTWVudT1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiTWVudVwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBEaWFsb2c9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIkRpYWxvZ1wiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBQb3BvdmVyPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJQb3BvdmVyXCIscHJvcHMpOyJdLAogICJtYXBwaW5ncyI6ICI7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7OztBQUFBOztpQkFBQUE7Ozs7QUNBTyxNQUFNLFNBQU8sV0FBVyxZQUFZO0FBQ3BDLE1BQU0sV0FBUyxXQUFXLFlBQVk7QUFDdEMsTUFBTSxTQUFPLFdBQVcsWUFBWTtBQUNwQyxNQUFNLFFBQU0sV0FBVyxZQUFZO0FBQ25DLE1BQU0sWUFBVSxXQUFXLFlBQVk7QUFDdkMsTUFBTSxVQUFR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
