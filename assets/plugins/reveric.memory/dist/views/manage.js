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

  // memory/src/views/manage.entry.js
  var manage_entry_exports = {};
  __export(manage_entry_exports, {
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

  // sdk/index.js
  var PluginError = class extends Error {
    constructor(code, message) {
      super(message);
      this.name = "PluginError";
      this.code = code;
    }
  };

  // memory/src/data.ts
  var categories = ["fact", "preference", "instruction"];
  function fail(code, message) {
    throw new PluginError(code, message);
  }
  function scopeWork(workId, scope) {
    if (scope === "global") return null;
    if (scope !== void 0 && scope !== "current")
      fail("invalid_argument", "scope must be current or global");
    if (!workId)
      fail("invalid_argument", "Choose global explicitly outside a work");
    return workId;
  }
  function checked(input) {
    const { content, category } = input, priority = input.priority ?? 0, enabled = input.enabled ?? true;
    if (typeof content !== "string" || !content.trim() || content.length > 4e3)
      fail("invalid_argument", "content must contain 1–4000 characters");
    if (!categories.includes(category))
      fail("invalid_argument", "Invalid category");
    if (priority !== 0 && priority !== 1)
      fail("invalid_argument", "priority must be 0 or 1");
    if (typeof enabled !== "boolean")
      fail("invalid_argument", "enabled must be boolean");
    return {
      content: content.trim(),
      category,
      priority,
      enabled: enabled ? 1 : 0
    };
  }
  function id() {
    return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}-${Math.random().toString(36).slice(2)}`;
  }
  var now = () => Math.floor(Date.now() / 1e3);
  async function search(db, workId, input = {}) {
    const scope = input.scope ?? "all", query = input.query ?? "", category = input.category ?? "", limit = input.limit ?? 20, offset = input.offset ?? 0;
    if (!["all", "global", "current"].includes(String(scope)) || typeof query !== "string" || query.length > 200 || typeof category !== "string" || category !== "" && !categories.includes(category) || !Number.isInteger(limit) || Number(limit) < 1 || Number(limit) > 50 || !Number.isInteger(offset) || Number(offset) < 0)
      fail("invalid_argument", "Invalid search filters or pagination");
    const where = scope === "all" ? "(work_id IS NULL OR work_id = ?)" : "work_id IS ?";
    const selected = scope === "all" ? workId : scopeWork(workId, scope);
    const rows = await db.query({
      sql: `SELECT * FROM memories WHERE deleted_at IS NULL AND ${where} AND (? = '' OR instr(lower(content),lower(?)) > 0) AND (? = '' OR category = ?) ORDER BY priority DESC, updated_at DESC, id LIMIT ? OFFSET ?`,
      params: [
        selected,
        query,
        query,
        category,
        category,
        Number(limit) + 1,
        Number(offset)
      ]
    });
    return {
      items: rows.slice(0, Number(limit)),
      hasMore: rows.length > Number(limit)
    };
  }
  async function get(db, workId, memoryId) {
    if (typeof memoryId !== "string" || !memoryId)
      fail("invalid_argument", "id is required");
    const rows = await db.query({
      sql: "SELECT * FROM memories WHERE id = ? AND deleted_at IS NULL AND (work_id IS NULL OR work_id = ?)",
      params: [memoryId, workId]
    });
    if (!rows.length) fail("not_found", "Memory is not accessible in this scope");
    return rows[0];
  }
  async function create(db, workId, input) {
    const value = checked(input), scope = scopeWork(workId, input.scope), key = id(), time = now();
    await db.execute({
      sql: "INSERT INTO memories (id,work_id,content,category,priority,enabled,revision,created_at,updated_at) VALUES (?,?,?,?,?,?,1,?,?)",
      params: [
        key,
        scope,
        value.content,
        value.category,
        value.priority,
        value.enabled,
        time,
        time
      ]
    });
    return get(db, workId, key);
  }
  async function update(db, workId, input, remove = false) {
    const original = await get(db, workId, input.id);
    if (input.scope !== void 0 && scopeWork(workId, input.scope) !== original.work_id)
      fail("invalid_scope", "scope does not match the memory");
    if (!Number.isInteger(input.revision) || Number(input.revision) < 1)
      fail("invalid_argument", "revision is required");
    const value = remove ? original : checked({ ...original, enabled: original.enabled === 1, ...input });
    const result = await db.execute({
      sql: "UPDATE memories SET content = ?, category = ?, priority = ?, enabled = ?, revision = revision + 1, updated_at = ?, deleted_at = ? WHERE id = ? AND revision = ? AND deleted_at IS NULL AND work_id IS ?",
      params: [
        value.content,
        value.category,
        value.priority,
        value.enabled,
        now(),
        remove ? now() : null,
        original.id,
        Number(input.revision),
        original.work_id
      ]
    });
    if (result.changes !== 1)
      fail("conflict", "Memory changed; search again before editing");
    return remove ? { id: original.id, deleted: true } : get(db, workId, original.id);
  }
  async function prompt(db, workId) {
    const rows = await db.query({
      sql: "SELECT id,content,category,priority FROM memories WHERE deleted_at IS NULL AND enabled = 1 AND (work_id IS NULL OR work_id = ?) ORDER BY priority DESC, updated_at DESC, id LIMIT 100",
      params: [workId]
    });
    let text = "";
    let count = 0;
    for (const row of rows) {
      const entry = `- [${row.category}${row.priority === 1 ? "; core" : ""}] ${row.content}
`;
      if (text.length + entry.length > 800) continue;
      text += entry;
      count++;
    }
    return {
      text: text ? `Memory references:
${text}` : "",
      count,
      budget: 800,
      used: text.length
    };
  }
  async function suggestions(db, workId) {
    return db.query({
      sql: "SELECT s.*, m.work_id, m.content AS original, m.revision AS current_revision FROM suggestions s JOIN memories m ON m.id = s.memory_id WHERE s.status = 'pending' AND m.deleted_at IS NULL AND (m.work_id IS NULL OR m.work_id = ?) ORDER BY s.created_at, s.id LIMIT 50",
      params: [workId]
    });
  }
  async function resolveSuggestion(db, workId, suggestionId, apply) {
    const rows = await db.query({
      sql: "SELECT s.*, m.work_id FROM suggestions s JOIN memories m ON m.id = s.memory_id WHERE s.id = ? AND s.status = 'pending' AND m.deleted_at IS NULL AND (m.work_id IS NULL OR m.work_id = ?)",
      params: [suggestionId, workId]
    });
    if (!rows.length) fail("not_found", "Suggestion is no longer available");
    const suggestion = rows[0];
    if (apply) {
      checked({
        content: suggestion.content,
        category: suggestion.category
      });
      const result = await db.execute({
        sql: "UPDATE memories SET content = ?, category = ?, revision = revision + 1, updated_at = ? WHERE id = ? AND revision = ? AND deleted_at IS NULL AND work_id IS ?",
        params: [
          suggestion.content,
          suggestion.category,
          now(),
          suggestion.memory_id,
          suggestion.source_revision,
          suggestion.work_id
        ]
      });
      if (result.changes !== 1)
        fail(
          "conflict",
          "Source memory changed; ignore this suggestion and review the current version"
        );
    }
    await db.execute({
      sql: "UPDATE suggestions SET status = ?, updated_at = ? WHERE id = ? AND status = 'pending'",
      params: [apply ? "applied" : "ignored", now(), suggestionId]
    });
  }

  // memory/src/views/manage.tsx
  var labels = { fact: "事实", preference: "偏好", instruction: "持续要求" };
  var options = categories.map((value) => ({ value, label: labels[value] }));
  function Page(context) {
    const scope = signal(context.page.workId ? "current" : "global"), category = signal(""), query = signal(""), offset = signal(0);
    const rows = signal([]), more = signal(false), preview = signal(""), budget = signal(""), candidates = signal([]);
    const loading = signal(false), busy = signal(false), error = signal(""), revision = signal(0), editing = signal(false), editId = signal("");
    const content = signal(""), editCategory = signal("fact"), editScope = signal("current"), priority = signal(false), enabled = signal(true);
    const refresh = signal(0);
    let sequence = 0;
    let alive = true;
    cleanup(() => {
      alive = false;
      sequence++;
    });
    effect(() => {
      const currentScope = scope(), currentCategory = category(), currentQuery = query(), page = offset();
      refresh();
      if (!context.environment.visible())
        return;
      const token = ++sequence;
      loading.set(true);
      Promise.all([
        search(context.sqlite, context.page.workId, {
          scope: currentScope,
          category: currentCategory,
          query: currentQuery,
          offset: page
        }),
        prompt(context.sqlite, context.page.workId),
        suggestions(context.sqlite, context.page.workId)
      ]).then(([result, injection, pending]) => {
        if (!alive || token !== sequence)
          return;
        rows.set(result.items);
        more.set(result.hasMore);
        preview.set(injection.text || "当前没有可注入的记忆");
        budget.set(`完整条目 ${injection.count} 条 · 保守字符预算 ${injection.used}/${injection.budget}`);
        candidates.set(pending.filter((row) => currentScope === "all" || (currentScope === "global" ? row.work_id === null : row.work_id === context.page.workId)));
      }).catch(() => {
        if (alive && token === sequence)
          error.set("读取失败，请刷新重试。");
      }).finally(() => {
        if (alive && token === sequence)
          loading.set(false);
      });
    });
    function reload() {
      refresh.update((value) => value + 1);
    }
    function filter(change) {
      change();
      offset.set(0);
    }
    async function close() {
      editing.set(false);
      await context.view.setDirty(false);
    }
    async function edit(row) {
      if (editing() && !await context.ui.dialog({ title: "放弃未保存的修改？" }))
        return;
      editId.set(row?.id ?? "");
      revision.set(row?.revision ?? 0);
      content.set(row?.content ?? "");
      editCategory.set(row?.category ?? "fact");
      editScope.set(row ? row.work_id === null ? "global" : "current" : context.page.workId ? "current" : "global");
      priority.set(row?.priority === 1);
      enabled.set(row ? row.enabled === 1 : true);
      editing.set(true);
      await context.view.setDirty(true);
    }
    async function act(action) {
      if (busy())
        return;
      busy.set(true);
      error.set("");
      try {
        await action();
        if (alive)
          reload();
      } catch (cause) {
        if (alive)
          error.set(cause instanceof PluginError && cause.code === "conflict" ? "记录已更新，请保留当前草稿并重新查看最新版本。" : "操作失败，请检查输入或刷新重试。");
      } finally {
        if (alive)
          busy.set(false);
      }
    }
    async function save() {
      await act(async () => {
        const value = {
          scope: editScope(),
          content: content(),
          category: editCategory(),
          priority: priority() ? 1 : 0,
          enabled: enabled()
        };
        if (editId())
          await update(context.sqlite, context.page.workId, {
            ...value,
            id: editId(),
            revision: revision()
          });
        else
          await create(context.sqlite, context.page.workId, value);
        if (alive)
          await close();
      });
    }
    const rowScope = (row) => row.work_id === null ? "global" : "current";
    async function choose(row, id2) {
      if (id2 === "edit")
        return edit(row);
      if (id2 === "toggle")
        return act(() => update(context.sqlite, context.page.workId, {
          id: row.id,
          revision: row.revision,
          scope: rowScope(row),
          enabled: !row.enabled
        }));
      if (id2 === "delete" && await context.ui.dialog({
        title: "删除这条记忆？",
        message: "删除后不再加入聊天参考。",
        confirmLabel: "删除",
        tone: "danger"
      }))
        await act(() => update(context.sqlite, context.page.workId, { id: row.id, revision: row.revision, scope: rowScope(row) }, true));
    }
    const compact = () => context.environment.width() < 600;
    return globalThis.__revericUi.element("Scroll", {
      get children() {
        return globalThis.__revericUi.element("Box", {
          get "padding"() {
            return compact() ? "lg" : "x2l";
          },
          "maxWidth": 960,
          get children() {
            return globalThis.__revericUi.element("Column", {
              "gap": "xl",
              "align": "stretch",
              get children() {
                return [globalThis.__revericUi.element("Text", {
                  "text": "记忆会在下一次模型请求中作为参考。整理建议只有在你应用后才会修改原记忆。",
                  "tone": "muted"
                }), globalThis.__revericUi.element("Column", {
                  "gap": "sm",
                  "align": "stretch",
                  get children() {
                    return [globalThis.__revericUi.element("Row", {
                      "gap": "sm",
                      "align": "center",
                      get children() {
                        return [globalThis.__revericUi.element("SearchField", {
                          "flex": 1,
                          "placeholder": "搜索记忆",
                          get "value"() {
                            return query();
                          },
                          "debounceMs": 300,
                          "onChange": (e) => filter(() => query.set(e.value))
                        }), globalThis.__revericUi.element("IconButton", {
                          "icon": "refresh",
                          "tooltip": "刷新",
                          get "disabled"() {
                            return loading();
                          },
                          get "onPress"() {
                            return reload;
                          }
                        }), globalThis.__revericUi.element("Button", {
                          "label": "新建",
                          "icon": "add",
                          get "disabled"() {
                            return busy();
                          },
                          "variant": "primary",
                          "onPress": () => edit()
                        })];
                      }
                    }), globalThis.__revericUi.element("Row", {
                      "gap": "sm",
                      "align": "center",
                      get children() {
                        return [globalThis.__revericUi.element("Box", {
                          "width": 168,
                          get children() {
                            return globalThis.__revericUi.element("Select", {
                              get "value"() {
                                return scope();
                              },
                              get "options"() {
                                return [
                                  { value: "all", label: "全局与当前作品" },
                                  { value: "global", label: "全局" },
                                  ...context.page.workId ? [{ value: "current", label: "当前作品" }] : []
                                ];
                              },
                              "onChange": (e) => filter(() => scope.set(e.value ?? "all"))
                            });
                          }
                        }), globalThis.__revericUi.element("Box", {
                          "width": 132,
                          get children() {
                            return globalThis.__revericUi.element("Select", {
                              get "value"() {
                                return category();
                              },
                              get "options"() {
                                return [{ value: "", label: "全部分类" }, ...options];
                              },
                              "onChange": (e) => filter(() => category.set(e.value ?? ""))
                            });
                          }
                        })];
                      }
                    })];
                  }
                }), globalThis.__revericUi.component(If, {
                  get "when"() {
                    return error() !== "";
                  },
                  get children() {
                    return globalThis.__revericUi.element("Text", {
                      get "text"() {
                        return error();
                      },
                      "tone": "warning"
                    });
                  }
                }), globalThis.__revericUi.component(If, {
                  get "when"() {
                    return editing();
                  },
                  get children() {
                    return globalThis.__revericUi.element("Card", {
                      "padding": "lg",
                      get children() {
                        return globalThis.__revericUi.element("Column", {
                          "gap": "md",
                          "align": "stretch",
                          get children() {
                            return [globalThis.__revericUi.element("Text", {
                              get "text"() {
                                return editId() ? "编辑记忆" : "新建记忆";
                              },
                              "variant": "heading"
                            }), globalThis.__revericUi.element("TextField", {
                              "testId": "memory-content",
                              "label": "内容",
                              "multiline": true,
                              get "value"() {
                                return content();
                              },
                              get "disabled"() {
                                return busy();
                              },
                              "onChange": (e) => content.set(e.value)
                            }), globalThis.__revericUi.element("Row", {
                              "gap": "sm",
                              "align": "center",
                              get children() {
                                return [globalThis.__revericUi.element("Box", {
                                  "width": 168,
                                  get children() {
                                    return globalThis.__revericUi.element("Select", {
                                      get "value"() {
                                        return editScope();
                                      },
                                      get "disabled"() {
                                        return editId() !== "" || busy();
                                      },
                                      get "options"() {
                                        return [
                                          { value: "global", label: "全局" },
                                          ...context.page.workId ? [{ value: "current", label: "当前作品" }] : []
                                        ];
                                      },
                                      "onChange": (e) => editScope.set(e.value ?? "global")
                                    });
                                  }
                                }), globalThis.__revericUi.element("Box", {
                                  "width": 132,
                                  get children() {
                                    return globalThis.__revericUi.element("Select", {
                                      get "value"() {
                                        return editCategory();
                                      },
                                      get "options"() {
                                        return options;
                                      },
                                      get "disabled"() {
                                        return busy();
                                      },
                                      "onChange": (e) => editCategory.set(e.value ?? "fact")
                                    });
                                  }
                                })];
                              }
                            }), globalThis.__revericUi.element("Wrap", {
                              "gap": "x2l",
                              "runGap": "sm",
                              get children() {
                                return [globalThis.__revericUi.element("Switch", {
                                  "label": "核心记忆",
                                  get "value"() {
                                    return priority();
                                  },
                                  get "disabled"() {
                                    return busy();
                                  },
                                  "onChange": (e) => priority.set(e.value)
                                }), globalThis.__revericUi.element("Switch", {
                                  "label": "加入聊天参考",
                                  get "value"() {
                                    return enabled();
                                  },
                                  get "disabled"() {
                                    return busy();
                                  },
                                  "onChange": (e) => enabled.set(e.value)
                                })];
                              }
                            }), globalThis.__revericUi.element("Row", {
                              "gap": "sm",
                              "justify": "end",
                              get children() {
                                return [globalThis.__revericUi.element("Button", {
                                  "label": "取消",
                                  get "disabled"() {
                                    return busy();
                                  },
                                  get "onPress"() {
                                    return close;
                                  }
                                }), globalThis.__revericUi.element("Button", {
                                  "testId": "memory-save",
                                  "label": "保存",
                                  "variant": "primary",
                                  get "loading"() {
                                    return busy();
                                  },
                                  get "onPress"() {
                                    return save;
                                  }
                                })];
                              }
                            })];
                          }
                        });
                      }
                    });
                  }
                }), globalThis.__revericUi.element("Column", {
                  "gap": "sm",
                  "align": "stretch",
                  get children() {
                    return [globalThis.__revericUi.component(If, {
                      get "when"() {
                        return !loading() && rows().length === 0;
                      },
                      get children() {
                        return globalThis.__revericUi.element("EmptyState", {
                          "message": "没有匹配的记忆"
                        });
                      }
                    }), globalThis.__revericUi.component(Each, {
                      get "items"() {
                        return rows();
                      },
                      get "key"() {
                        return (row) => row.id;
                      },
                      get children() {
                        return (row) => globalThis.__revericUi.element("Card", {
                          "padding": "lg",
                          get children() {
                            return globalThis.__revericUi.element("Column", {
                              "gap": "sm",
                              "align": "stretch",
                              get children() {
                                return [globalThis.__revericUi.element("Row", {
                                  "gap": "xs",
                                  "align": "center",
                                  get children() {
                                    return [globalThis.__revericUi.element("Badge", {
                                      get "text"() {
                                        return row().work_id === null ? "全局" : "当前作品";
                                      },
                                      "tone": "accent"
                                    }), globalThis.__revericUi.element("Badge", {
                                      get "text"() {
                                        return labels[row().category];
                                      },
                                      "tone": "muted"
                                    }), globalThis.__revericUi.component(If, {
                                      get "when"() {
                                        return row().priority === 1;
                                      },
                                      get children() {
                                        return globalThis.__revericUi.element("Badge", {
                                          "text": "核心",
                                          "tone": "success"
                                        });
                                      }
                                    }), globalThis.__revericUi.component(If, {
                                      get "when"() {
                                        return row().enabled !== 1;
                                      },
                                      get children() {
                                        return globalThis.__revericUi.element("Badge", {
                                          "text": "已停用",
                                          "tone": "warning"
                                        });
                                      }
                                    }), globalThis.__revericUi.element("Gap", {
                                      "flex": 1,
                                      "size": "none"
                                    }), globalThis.__revericUi.element("Text", {
                                      get "text"() {
                                        return `v${row().revision}`;
                                      },
                                      "variant": "caption",
                                      "tone": "muted"
                                    }), globalThis.__revericUi.element("Menu", {
                                      get "items"() {
                                        return [
                                          { id: "edit", label: "编辑", disabled: busy() },
                                          {
                                            id: "toggle",
                                            label: row().enabled ? "停用" : "启用",
                                            disabled: busy()
                                          },
                                          {
                                            id: "delete",
                                            label: "删除",
                                            danger: true,
                                            disabled: busy()
                                          }
                                        ];
                                      },
                                      "onSelect": (e) => choose(row(), e.id),
                                      get "trigger"() {
                                        return globalThis.__revericUi.element("IconButton", {
                                          "icon": "moreHoriz",
                                          "tooltip": "更多操作"
                                        });
                                      }
                                    })];
                                  }
                                }), globalThis.__revericUi.element("Text", {
                                  get "text"() {
                                    return row().content;
                                  },
                                  get "tone"() {
                                    return row().enabled === 1 ? "default" : "muted";
                                  }
                                })];
                              }
                            });
                          }
                        });
                      }
                    }), globalThis.__revericUi.component(If, {
                      get "when"() {
                        return offset() > 0 || more();
                      },
                      get children() {
                        return globalThis.__revericUi.element("Row", {
                          "gap": "sm",
                          "align": "center",
                          "justify": "center",
                          get children() {
                            return [globalThis.__revericUi.element("Button", {
                              "label": "上一页",
                              "size": "compact",
                              get "disabled"() {
                                return offset() === 0 || loading();
                              },
                              "onPress": () => offset.update((value) => Math.max(0, value - 20))
                            }), globalThis.__revericUi.element("Text", {
                              get "text"() {
                                return `第 ${offset() / 20 + 1} 页`;
                              },
                              "tone": "muted"
                            }), globalThis.__revericUi.element("Button", {
                              "label": "下一页",
                              "size": "compact",
                              get "disabled"() {
                                return !more() || loading();
                              },
                              "onPress": () => offset.update((value) => value + 20)
                            })];
                          }
                        });
                      }
                    })];
                  }
                }), globalThis.__revericUi.element("Column", {
                  "gap": "sm",
                  "align": "stretch",
                  get children() {
                    return [globalThis.__revericUi.element("Text", {
                      "text": "待确认的整理建议",
                      "variant": "heading"
                    }), globalThis.__revericUi.component(If, {
                      get "when"() {
                        return candidates().length === 0;
                      },
                      get children() {
                        return globalThis.__revericUi.element("Text", {
                          "text": "暂无整理建议",
                          "tone": "muted"
                        });
                      }
                    }), globalThis.__revericUi.component(Each, {
                      get "items"() {
                        return candidates();
                      },
                      get "key"() {
                        return (row) => String(row.id);
                      },
                      get children() {
                        return (row) => globalThis.__revericUi.element("Card", {
                          "padding": "lg",
                          get children() {
                            return globalThis.__revericUi.element("Column", {
                              "gap": "sm",
                              "align": "stretch",
                              get children() {
                                return [globalThis.__revericUi.element("Text", {
                                  get "text"() {
                                    return `原记忆：${row().original}`;
                                  },
                                  "tone": "muted"
                                }), globalThis.__revericUi.element("Text", {
                                  get "text"() {
                                    return `建议：${row().content}`;
                                  }
                                }), globalThis.__revericUi.component(If, {
                                  get "when"() {
                                    return row().source_revision !== row().current_revision;
                                  },
                                  get children() {
                                    return globalThis.__revericUi.element("Text", {
                                      "text": "原记忆已更新，此建议已过期。",
                                      "tone": "warning"
                                    });
                                  }
                                }), globalThis.__revericUi.element("Row", {
                                  "gap": "sm",
                                  "justify": "end",
                                  get children() {
                                    return [globalThis.__revericUi.element("Button", {
                                      "label": "忽略",
                                      "variant": "text",
                                      get "disabled"() {
                                        return busy();
                                      },
                                      "onPress": () => act(() => resolveSuggestion(context.sqlite, context.page.workId, String(row().id), false))
                                    }), globalThis.__revericUi.element("Button", {
                                      "label": "应用",
                                      "variant": "primary",
                                      get "disabled"() {
                                        return busy() || row().source_revision !== row().current_revision;
                                      },
                                      "onPress": () => act(() => resolveSuggestion(context.sqlite, context.page.workId, String(row().id), true))
                                    })];
                                  }
                                })];
                              }
                            });
                          }
                        });
                      }
                    })];
                  }
                }), globalThis.__revericUi.element("Card", {
                  "padding": "lg",
                  get children() {
                    return globalThis.__revericUi.element("Column", {
                      "gap": "sm",
                      "align": "stretch",
                      get children() {
                        return [globalThis.__revericUi.element("Text", {
                          "text": "聊天参考预览（全局与当前作品）",
                          "variant": "heading"
                        }), globalThis.__revericUi.element("Text", {
                          get "text"() {
                            return budget();
                          },
                          "variant": "caption",
                          "tone": "muted"
                        }), globalThis.__revericUi.element("Text", {
                          get "text"() {
                            return preview();
                          }
                        })];
                      }
                    });
                  }
                })];
              }
            });
          }
        });
      }
    });
  }

  // memory/src/views/manage.entry.js
  function mount(context) {
    return globalThis.__revericUi.mount(() => Page(context), context.root);
  }
  return __toCommonJS(manage_entry_exports);
})();
//# sourceMappingURL=manage.js.map
