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

  // sdk/fixtures/counter.entry.js
  var counter_entry_exports = {};
  __export(counter_entry_exports, {
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

  // sdk/fixtures/counter.tsx
  function Page(context) {
    const count = signal(0), name = signal("");
    const label = computed(() => `Count ${count()}`);
    const loaded = resource(() => count(), async (value) => {
      await context.storage.get("preview.delay");
      return value;
    });
    const rows = Array.from({ length: 1e3 }, (_, index) => ({
      id: String(index),
      label: `Row ${index}`
    }));
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
                name.set(event.value);
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
  }

  // sdk/fixtures/counter.entry.js
  function mount(context) {
    return globalThis.__revericUi.mount(() => Page(context), context.root);
  }
  return __toCommonJS(counter_entry_exports);
})();
//# sourceMappingURL=data:application/json;base64,ewogICJ2ZXJzaW9uIjogMywKICAic291cmNlcyI6IFsiLi4vLi4vLi4vLi4vLi4vLi4vcGx1Z2lucy9zZGsvZml4dHVyZXMvY291bnRlci5lbnRyeS5qcyIsICJyZXZlcmljLXVpOnJldmVyaWMtcGx1Z2luLXNkay91aSIsICIuLi8uLi8uLi8uLi8uLi8uLi9wbHVnaW5zL3Nkay9maXh0dXJlcy9jb3VudGVyLnRzeCJdLAogICJzb3VyY2VzQ29udGVudCI6IFsiaW1wb3J0IFBhZ2UgZnJvbSBcIi9Vc2Vycy9TZXB0ZW1iZXJfMS9Qcm9qZWN0cy9GcmVlZG9tL3JldmVyaWMvcGx1Z2lucy9zZGsvZml4dHVyZXMvY291bnRlci50c3hcIjtcbmV4cG9ydCBmdW5jdGlvbiBtb3VudChjb250ZXh0KXtyZXR1cm4gZ2xvYmFsVGhpcy5fX3JldmVyaWNVaS5tb3VudCgoKT0+UGFnZShjb250ZXh0KSxjb250ZXh0LnJvb3QpO30iLCAiZXhwb3J0IGNvbnN0IHNpZ25hbD1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLnNpZ25hbDtcbmV4cG9ydCBjb25zdCBjb21wdXRlZD1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmNvbXB1dGVkO1xuZXhwb3J0IGNvbnN0IGVmZmVjdD1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVmZmVjdDtcbmV4cG9ydCBjb25zdCBiYXRjaD1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmJhdGNoO1xuZXhwb3J0IGNvbnN0IHVudHJhY2tlZD1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLnVudHJhY2tlZDtcbmV4cG9ydCBjb25zdCBjbGVhbnVwPWdsb2JhbFRoaXMuX19yZXZlcmljVWkuY2xlYW51cDtcbmV4cG9ydCBjb25zdCByZXNvdXJjZT1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLnJlc291cmNlO1xuZXhwb3J0IGNvbnN0IElmPWdsb2JhbFRoaXMuX19yZXZlcmljVWkuSWY7XG5leHBvcnQgY29uc3QgRWFjaD1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLkVhY2g7XG5leHBvcnQgY29uc3QgRXJyb3JCb3VuZGFyeT1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLkVycm9yQm91bmRhcnk7XG5leHBvcnQgY29uc3QgTGlzdD1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLkxpc3Q7XG5leHBvcnQgY29uc3QgVGFicz1nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLlRhYnM7XG5leHBvcnQgY29uc3QgQ29sdW1uPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJDb2x1bW5cIixwcm9wcyk7XG5leHBvcnQgY29uc3QgUm93PXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJSb3dcIixwcm9wcyk7XG5leHBvcnQgY29uc3QgV3JhcD1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiV3JhcFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBCb3g9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIkJveFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBTY3JvbGw9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIlNjcm9sbFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBHYXA9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIkdhcFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBUZXh0PXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJUZXh0XCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IE1hcmtkb3duPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJNYXJrZG93blwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBJY29uPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJJY29uXCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IENhcmQ9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIkNhcmRcIixwcm9wcyk7XG5leHBvcnQgY29uc3QgRGl2aWRlcj1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiRGl2aWRlclwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBCYWRnZT1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiQmFkZ2VcIixwcm9wcyk7XG5leHBvcnQgY29uc3QgTG9hZGluZz1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiTG9hZGluZ1wiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBFbXB0eVN0YXRlPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJFbXB0eVN0YXRlXCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IEJ1dHRvbj1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiQnV0dG9uXCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IEljb25CdXR0b249cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIkljb25CdXR0b25cIixwcm9wcyk7XG5leHBvcnQgY29uc3QgVGV4dEZpZWxkPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJUZXh0RmllbGRcIixwcm9wcyk7XG5leHBvcnQgY29uc3QgU2VhcmNoRmllbGQ9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIlNlYXJjaEZpZWxkXCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IFNlbGVjdD1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiU2VsZWN0XCIscHJvcHMpO1xuZXhwb3J0IGNvbnN0IENoZWNrYm94PXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJDaGVja2JveFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBTd2l0Y2g9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIlN3aXRjaFwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBDb2xsYXBzaWJsZT1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiQ29sbGFwc2libGVcIixwcm9wcyk7XG5leHBvcnQgY29uc3QgTWVudT1wcm9wcz0+Z2xvYmFsVGhpcy5fX3JldmVyaWNVaS5lbGVtZW50KFwiTWVudVwiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBEaWFsb2c9cHJvcHM9Pmdsb2JhbFRoaXMuX19yZXZlcmljVWkuZWxlbWVudChcIkRpYWxvZ1wiLHByb3BzKTtcbmV4cG9ydCBjb25zdCBQb3BvdmVyPXByb3BzPT5nbG9iYWxUaGlzLl9fcmV2ZXJpY1VpLmVsZW1lbnQoXCJQb3BvdmVyXCIscHJvcHMpOyIsICJpbXBvcnQge1xuICBCdXR0b24sXG4gIENvbHVtbixcbiAgRWFjaCxcbiAgSWYsXG4gIExpc3QsXG4gIFNjcm9sbCxcbiAgVGV4dCxcbiAgVGV4dEZpZWxkLFxuICBjb21wdXRlZCxcbiAgcmVzb3VyY2UsXG4gIHNpZ25hbCxcbiAgdHlwZSBQYWdlQ29udGV4dCxcbn0gZnJvbSBcInJldmVyaWMtcGx1Z2luLXNkay91aVwiO1xuZXhwb3J0IGRlZmF1bHQgZnVuY3Rpb24gUGFnZShjb250ZXh0OiBQYWdlQ29udGV4dCkge1xuICBjb25zdCBjb3VudCA9IHNpZ25hbCgwKSxcbiAgICBuYW1lID0gc2lnbmFsKFwiXCIpO1xuICBjb25zdCBsYWJlbCA9IGNvbXB1dGVkKCgpID0+IGBDb3VudCAke2NvdW50KCl9YCk7XG4gIGNvbnN0IGxvYWRlZCA9IHJlc291cmNlKFxuICAgICgpID0+IGNvdW50KCksXG4gICAgYXN5bmMgKHZhbHVlKSA9PiB7XG4gICAgICBhd2FpdCBjb250ZXh0LnN0b3JhZ2UuZ2V0KFwicHJldmlldy5kZWxheVwiKTtcbiAgICAgIHJldHVybiB2YWx1ZTtcbiAgICB9LFxuICApO1xuICBjb25zdCByb3dzID0gQXJyYXkuZnJvbSh7IGxlbmd0aDogMTAwMCB9LCAoXywgaW5kZXgpID0+ICh7XG4gICAgaWQ6IFN0cmluZyhpbmRleCksXG4gICAgbGFiZWw6IGBSb3cgJHtpbmRleH1gLFxuICB9KSk7XG4gIHJldHVybiAoXG4gICAgPFNjcm9sbD5cbiAgICAgIDxDb2x1bW4gZ2FwPVwic21cIj5cbiAgICAgICAgPFRleHQgdGV4dD17bGFiZWwoKX0gLz5cbiAgICAgICAgPEJ1dHRvblxuICAgICAgICAgIGxhYmVsPVwiQWRkXCJcbiAgICAgICAgICBvblByZXNzPXsoKSA9PiBjb3VudC51cGRhdGUoKHZhbHVlKSA9PiB2YWx1ZSArIDEpfVxuICAgICAgICAvPlxuICAgICAgICA8SWYgd2hlbj17Y291bnQoKSA+IDB9PlxuICAgICAgICAgIDxUZXh0IHRleHQ9XCJQb3NpdGl2ZVwiIC8+XG4gICAgICAgIDwvSWY+XG4gICAgICAgIDxUZXh0RmllbGRcbiAgICAgICAgICBsYWJlbD1cIk5hbWVcIlxuICAgICAgICAgIHZhbHVlPXtuYW1lKCl9XG4gICAgICAgICAgb25DaGFuZ2U9eyhldmVudCkgPT4ge1xuICAgICAgICAgICAgbmFtZS5zZXQoZXZlbnQudmFsdWUpO1xuICAgICAgICAgICAgdm9pZCBjb250ZXh0LnZpZXcuc2V0RGlydHkodHJ1ZSk7XG4gICAgICAgICAgfX1cbiAgICAgICAgLz5cbiAgICAgICAgPFRleHRcbiAgICAgICAgICB0ZXh0PXtsb2FkZWQubG9hZGluZygpID8gXCJMb2FkaW5nXCIgOiBgTG9hZGVkICR7bG9hZGVkLnZhbHVlKCkgPz8gMH1gfVxuICAgICAgICAvPlxuICAgICAgICA8RWFjaFxuICAgICAgICAgIGl0ZW1zPXtbeyBpZDogXCJhXCIsIGxhYmVsOiBcIlN0YWJsZSByb3dcIiB9XX1cbiAgICAgICAgICBrZXk9eyhpdGVtKSA9PiBpdGVtLmlkfVxuICAgICAgICA+XG4gICAgICAgICAgeyhpdGVtKSA9PiA8VGV4dCB0ZXh0PXtpdGVtKCkubGFiZWx9IC8+fVxuICAgICAgICA8L0VhY2g+XG4gICAgICAgIDxMaXN0XG4gICAgICAgICAgaXRlbXM9e3Jvd3N9XG4gICAgICAgICAga2V5PXsoaXRlbSkgPT4gaXRlbS5pZH1cbiAgICAgICAgICBpdGVtRXh0ZW50PXszMn1cbiAgICAgICAgICBoZWlnaHQ9ezE2MH1cbiAgICAgICAgICByZW5kZXJJdGVtPXsoaXRlbSkgPT4gPFRleHQgdmFyaWFudD1cImNhcHRpb25cIiB0ZXh0PXtpdGVtKCkubGFiZWx9IC8+fVxuICAgICAgICAvPlxuICAgICAgPC9Db2x1bW4+XG4gICAgPC9TY3JvbGw+XG4gICk7XG59XG4iXSwKICAibWFwcGluZ3MiOiAiOzs7Ozs7Ozs7Ozs7Ozs7Ozs7OztBQUFBO0FBQUE7QUFBQTtBQUFBOzs7QUNBTyxNQUFNLFNBQU8sV0FBVyxZQUFZO0FBQ3BDLE1BQU0sV0FBUyxXQUFXLFlBQVk7QUFDdEMsTUFBTSxTQUFPLFdBQVcsWUFBWTtBQUNwQyxNQUFNLFFBQU0sV0FBVyxZQUFZO0FBQ25DLE1BQU0sWUFBVSxXQUFXLFlBQVk7QUFDdkMsTUFBTSxVQUFRLFdBQVcsWUFBWTtBQUNyQyxNQUFNLFdBQVMsV0FBVyxZQUFZO0FBQ3RDLE1BQU0sS0FBRyxXQUFXLFlBQVk7QUFDaEMsTUFBTSxPQUFLLFdBQVcsWUFBWTtBQUNsQyxNQUFNLGdCQUFjLFdBQVcsWUFBWTtBQUMzQyxNQUFNLE9BQUssV0FBVyxZQUFZO0FBQ2xDLE1BQU0sT0FBSyxXQUFXLFlBQVk7OztBQ0czQixXQUFQLEtBQXNCLFNBQW9CO0FBQy9DLFVBQU0sUUFBUSxPQUFPLENBQUMsR0FDcEIsT0FBTyxPQUFPLEVBQUU7QUFDbEIsVUFBTSxRQUFRLFNBQVMsTUFBTSxTQUFTLE1BQUssQ0FBRSxFQUFFO0FBQy9DLFVBQU0sU0FBUyxTQUNiLE1BQU0sTUFBSyxHQUNYLE9BQU8sVUFBUztBQUNkLFlBQU0sUUFBUSxRQUFRLElBQUksZUFBZTtBQUN6QyxhQUFPO0lBQ1QsQ0FBQztBQUVILFVBQU0sT0FBTyxNQUFNLEtBQUssRUFBRSxRQUFRLElBQUksR0FBSSxDQUFDLEdBQUcsV0FBVztNQUN2RCxJQUFJLE9BQU8sS0FBSztNQUNoQixPQUFPLE9BQU8sS0FBSztNQUNuQjtBQUNGLFdBQU8sV0FBQSxZQUFBLFFBQUEsVUFBQTs7O2lCQUVTOzs7O3VCQUNFLE1BQUs7Ozt1QkFFVDt5QkFDRyxNQUFNLE1BQU0sT0FBTyxDQUFDLFVBQVUsUUFBUSxDQUFDO2lEQUVqRCxJQUFFOzt1QkFBTyxNQUFLLElBQUs7Ozs7MEJBQ1A7Ozs7dUJBR0w7O3VCQUNDLEtBQUk7OzBCQUNELENBQUMsVUFBUztBQUNsQixxQkFBSyxJQUFJLE1BQU0sS0FBSztBQUNwQixxQkFBSyxRQUFRLEtBQUssU0FBUyxJQUFJO2NBQ2pDOzs7dUJBR00sT0FBTyxRQUFPLElBQUssWUFBWSxVQUFVLE9BQU8sTUFBSyxLQUFNLENBQUM7O2lEQUVuRSxNQUFJOzt1QkFDSSxDQUFDLEVBQUUsSUFBSSxLQUFLLE9BQU8sYUFBWSxDQUFFOzs7dUJBQ25DLENBQUMsU0FBUyxLQUFLOzs7dUJBRW5CLENBQUMsU0FBUSxXQUFBLFlBQUEsUUFBQSxRQUFBOzsyQkFBYSxLQUFJLEVBQUc7Ozs7aURBRS9CLE1BQUk7O3VCQUNJOzs7dUJBQ0YsQ0FBQyxTQUFTLEtBQUs7OzRCQUNSO3dCQUNKOzt1QkFDSSxDQUFDLFNBQVEsV0FBQSxZQUFBLFFBQUEsUUFBQTs2QkFBZTs7MkJBQWdCLEtBQUksRUFBRzs7Ozs7Ozs7O0VBS3JFOzs7QUZsRU8sV0FBUyxNQUFNLFNBQVE7QUFBQyxXQUFPLFdBQVcsWUFBWSxNQUFNLE1BQUksS0FBSyxPQUFPLEdBQUUsUUFBUSxJQUFJO0FBQUEsRUFBRTsiLAogICJuYW1lcyI6IFtdCn0K
