// Faithful reproduction of the AI providers settings page (desktop two-column).
// Mirrors lib/shared/widgets/settings/ai_providers_section.dart +
// provider_config_panel.dart: provider list (left) + config panel (right).
// 全部是自带 key 的外部供应商，没有托管模型。

// 添加自定义：底部按钮弹出类型 popover → 选中即生成一条未落库的草稿并选中，
// 右侧面板进入草稿态（保存 / 放弃）；保存后才写入列表，之后回到自动保存。
// 有草稿时切换到别的提供商，先确认是否放弃。
function ProvidersSection() {
  const [providers, setProviders] = React.useState(PROVIDERS);
  const [selectedId, setSelectedId] = React.useState(PROVIDERS[0].id);
  const [draft, setDraft] = React.useState(null);
  const [pickerOpen, setPickerOpen] = React.useState(false);
  const [pendingLeave, setPendingLeave] = React.useState(null);

  const startDraft = (type) => {
    setPickerOpen(false);
    setDraft({
      id: "draft", draft: true, custom: true, typeKey: type.key, type: type.name,
      name: type.name, kinds: type.kinds, fixedBaseUrl: !!type.fixed, baseUrl: type.baseUrl,
      apiKey: "", models: [], enabled: false, valid: false,
      temperature: 0.7, maxTokens: "32k", reasoning: "默认",
    });
    setSelectedId("draft");
  };
  const saveDraft = (values) => {
    const id = "prv_" + Math.random().toString(36).slice(2, 8);
    const valid = !!(values.apiKey && (values.baseUrl || values.fixedBaseUrl) && values.models.length);
    setProviders((list) => [...list, { ...values, id, draft: false, valid, enabled: false }]);
    setDraft(null);
    setSelectedId(id);
  };
  const select = (id) => {
    if (id === selectedId) return;
    if (draft && selectedId === "draft") { setPendingLeave(id); return; }
    setSelectedId(id);
  };
  const discardDraft = (nextId) => {
    setDraft(null);
    setPendingLeave(null);
    setSelectedId(nextId || providers[0].id);
  };

  const selected = selectedId === "draft" && draft
    ? draft
    : providers.find((p) => p.id === selectedId) || providers[0];

  return (
    <div className="sp-prov">
      <div className="sp-prov-list">
        <div className="sp-prov-list__scroll">
          {draft && (
            <button
              type="button"
              className={"sp-prov-item sp-prov-item--draft" + (selectedId === "draft" ? " is-selected" : "")}
              onClick={() => select("draft")}
            >
              <span className="sp-prov-dot" style={{ background: "var(--warning-text)" }} />
              <span style={{ flex: 1, minWidth: 0 }}>
                <span className="sp-prov-item__name" style={{ display: "block", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{draft.name || draft.type}</span>
                <span className="sp-badge sp-badge--draft">未保存</span>
              </span>
            </button>
          )}
          {providers.map((p) => (
            <button
              key={p.id}
              type="button"
              className={"sp-prov-item" + (p.id === selectedId ? " is-selected" : "")}
              onClick={() => select(p.id)}
            >
              <span className="sp-prov-dot" style={{ background: p.valid ? "var(--addition-border)" : "var(--border)" }} />
              <span style={{ flex: 1, minWidth: 0 }}>
                <span className="sp-prov-item__name" style={{ display: "block", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{p.name}</span>
                {p.custom && <span className="sp-badge sp-badge--custom">自定义</span>}
              </span>
            </button>
          ))}
        </div>
        <div className="sp-prov-list__foot">
          <button
            type="button"
            className={"sp-prov-add" + (pickerOpen ? " is-open" : "")}
            onClick={() => setPickerOpen((v) => !v)}
            disabled={!!draft}
            title={draft ? "先保存或放弃当前草稿" : null}
          >
            <Icon name="plus" size={14} />添加自定义
          </button>
          {pickerOpen && <ProviderTypePicker onPick={startDraft} onClose={() => setPickerOpen(false)} />}
        </div>
      </div>
      <div className="sp-prov-divider" />
      <ProviderConfigPanel
        key={selected.id}
        config={selected}
        onSaveDraft={saveDraft}
        onDiscardDraft={() => discardDraft()}
        onChangeDraftType={(type) => setDraft((d) => ({
          ...d, typeKey: type.key, type: type.name, kinds: type.kinds,
          fixedBaseUrl: !!type.fixed, baseUrl: type.baseUrl,
          name: d.name === d.type ? type.name : d.name,
        }))}
      />
      {pendingLeave && (
        <div className="m-dialog-scrim" onClick={() => setPendingLeave(null)}>
          <div className="m-dialog m-dialog--confirm sp-leave" onClick={(e) => e.stopPropagation()}>
            <div className="sp-leave__title">放弃未保存的提供商？</div>
            <div className="sp-leave__body">「{draft.name || draft.type}」尚未保存，离开后填写的内容不会保留。</div>
            <div className="sp-leave__actions">
              <button type="button" className="m-btn m-btn--secondary m-btn--sm" onClick={() => setPendingLeave(null)}>继续编辑</button>
              <button type="button" className="m-btn m-btn--danger m-btn--sm" onClick={() => discardDraft(pendingLeave)}>放弃</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

// 类型 popover：按能力筛选，每行列出能力标签；固定地址类型标注「固定地址」。
function ProviderTypePicker({ onPick, onClose }) {
  const [kind, setKind] = React.useState("all");
  const types = PROVIDER_TYPES.filter((t) => kind === "all" || t.kinds.includes(kind));
  return (
    <React.Fragment>
      <div className="sp-type-pop__backdrop" onClick={onClose} />
      <div className="sp-type-pop" role="dialog" aria-label="选择提供商类型">
        <div className="sp-type-pop__head">
          <span className="sp-type-pop__title">选择接口格式</span>
        </div>
        <div className="sp-type-pop__filters">
          {["all", "chat", "image", "video", "audio"].map((k) => (
            <button key={k} type="button" className={"sp-kind-filter" + (kind === k ? " is-selected" : "")} onClick={() => setKind(k)}>
              {k === "all" ? "全部" : PROVIDER_KIND_LABELS[k]}
            </button>
          ))}
        </div>
        <div className="sp-type-pop__list">
          {types.map((t) => (
            <button key={t.key} type="button" className="sp-type-row" onClick={() => onPick(t)}>
              <span className="sp-type-row__main">
                <span className="sp-type-row__name">{t.name}</span>
                {t.fixed && <span className="sp-type-row__fixed"><Icon name="lock-key" size={11} />固定地址</span>}
              </span>
              {t.note && <span className="sp-type-row__note">{t.note}</span>}
              <span className="sp-type-row__kinds">
                {t.kinds.map((k) => (
                  <span key={k} className={"sp-kind-tag" + (k === kind ? " is-hit" : "")}>{PROVIDER_KIND_LABELS[k]}</span>
                ))}
              </span>
            </button>
          ))}
        </div>
      </div>
    </React.Fragment>
  );
}

function StatusBadge({ on }) {
  return (
    <span className={"sp-status-badge " + (on ? "sp-status-badge--on" : "sp-status-badge--off")}>
      {on ? "启用" : "未启用"}
    </span>
  );
}

function Switch({ on, onToggle }) {
  return (
    <button type="button" className={"sp-switch " + (on ? "sp-switch--on" : "sp-switch--off")} onClick={onToggle} aria-pressed={on}>
      <span className="sp-switch__knob" />
    </button>
  );
}

function ProviderConfigPanel({ config, onSaveDraft, onDiscardDraft, onChangeDraftType }) {
  const [enabled, setEnabled] = React.useState(config.enabled);
  React.useEffect(() => setEnabled(config.enabled), [config.id]);
  const valid = config.valid && enabled;
  // 草稿态的输入只存在本地，点「保存」才交给列表。
  const [values, setValues] = React.useState(config);
  React.useEffect(() => {
    if (config.draft) setValues((v) => ({ ...v, ...pickType(config) }));
  }, [config.typeKey]);
  const patch = (p) => setValues((v) => ({ ...v, ...p }));
  const view = config.draft ? values : config;

  return (
    <div className="sp-prov-panel">
      <div className="sp-prov-head">
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ display: "flex", alignItems: "center", gap: "var(--space-sm)" }}>
            <span className="sp-prov-head__title">{view.name || view.type}</span>
            {config.draft
              ? <span className="sp-status-badge sp-status-badge--draft">未保存</span>
              : <StatusBadge on={valid} />}
          </div>
          <div className="sp-prov-head__type">{view.type}</div>
        </div>
        {config.draft ? (
          <React.Fragment>
            <button type="button" className="m-btn m-btn--text m-btn--sm" onClick={onDiscardDraft}>放弃</button>
            <button type="button" className="m-btn m-btn--primary m-btn--sm" disabled={!values.name.trim()} onClick={() => onSaveDraft(values)}>保存</button>
          </React.Fragment>
        ) : (
          <React.Fragment>
            <Switch on={enabled} onToggle={() => setEnabled((v) => !v)} />
            {config.custom && (
              <button type="button" className="sp-icon-btn" title="删除"><Icon name="trash" size={18} /></button>
            )}
          </React.Fragment>
        )}
      </div>

      <div className="sp-prov-body">
        {config.draft
          ? <DraftConfig values={values} patch={patch} onChangeType={onChangeDraftType} />
          : <EditableConfig config={config} />}
      </div>
    </div>
  );
}

function pickType(config) {
  return { typeKey: config.typeKey, type: config.type, kinds: config.kinds, fixedBaseUrl: config.fixedBaseUrl, baseUrl: config.baseUrl, name: config.name };
}

// 草稿表单：字段与已保存的自定义提供商一致，类型仍可更换；
// 模型区按类型能力出现，「获取模型」在填好密钥前显示为禁用并说明原因。
function DraftConfig({ values, patch, onChangeType }) {
  const [typeOpen, setTypeOpen] = React.useState(false);
  const hasKey = !!values.apiKey.trim();
  const modelSections = [
    values.kinds.includes("chat") && { key: "chat", label: "聊天模型", hint: "输入模型 ID，例如 gpt-4.1" },
    values.kinds.includes("video") && { key: "video", label: "视频模型", hint: "输入模型 ID，例如 MiniMax-Hailuo-02" },
    values.kinds.includes("audio") && { key: "audio", label: "音频模型", hint: "输入模型 ID" },
    values.kinds.includes("image") && { key: "image", label: "图片模型", hint: "输入模型 ID，例如 gpt-image-1" },
  ].filter(Boolean);
  return (
    <div>
      <Field label="名称" value={values.name} onChange={(v) => patch({ name: v })} />

      <div className="sp-field" style={{ position: "relative" }}>
        <label className="sp-field__label">提供商类型</label>
        <button type="button" className="sp-type-select" onClick={() => setTypeOpen((v) => !v)}>
          <span style={{ flex: 1, textAlign: "left" }}>{values.type}</span>
          <span className="sp-type-row__kinds" style={{ marginTop: 0 }}>
            {values.kinds.map((k) => <span key={k} className="sp-kind-tag">{PROVIDER_KIND_LABELS[k]}</span>)}
          </span>
          <Icon name="caret-down" size={14} />
        </button>
        <div className="sp-field__hint">保存后类型不可更改。</div>
        {typeOpen && (
          <div className="sp-type-pop-anchor">
            <ProviderTypePicker onPick={(t) => { setTypeOpen(false); onChangeType(t); }} onClose={() => setTypeOpen(false)} />
          </div>
        )}
      </div>

      {values.fixedBaseUrl
        ? <ReadOnlyField label="基础 URL" value={values.baseUrl} />
        : <Field label="基础 URL" value={values.baseUrl} mono placeholder="https://api.example.com/v1"
            onChange={(v) => patch({ baseUrl: v })}
            hint={!values.baseUrl ? "填写服务地址，例如中转站提供的 /v1 地址。" : null} />}

      <Field label="API 密钥" value={values.apiKey} obscure mono placeholder="sk-…"
        onChange={(v) => patch({ apiKey: v })}
        hint={!hasKey ? "填写 API Key 后才能启用该提供商。" : null} />

      {modelSections.map((s) => (
        <div key={s.key} className="sp-field">
          <div className="sp-row-between" style={{ marginBottom: "var(--space-xs)" }}>
            <label className="sp-field__label" style={{ margin: 0 }}>{s.label}</label>
            <button type="button" className="sp-fetch-btn" disabled={!hasKey} title={hasKey ? null : "先填写 API 密钥"}>
              <Icon name="download-simple" size={14} />获取模型
            </button>
          </div>
          <div className="sp-models-box">
            <div className="sp-field__hint" style={{ marginTop: 0, marginBottom: "var(--space-sm)" }}>暂无模型</div>
            <div className="sp-models-add">
              <input className="m-input" placeholder={s.hint} readOnly />
              <button type="button" className="m-btn m-btn--secondary m-btn--sm">添加</button>
            </div>
          </div>
        </div>
      ))}

      <button type="button" className="sp-collapse-head"><span>代理</span><Icon name="caret-down" size={14} /></button>
    </div>
  );
}

function Field({ label, value, hint, obscure, mono, placeholder, onChange }) {
  const controlled = !!onChange;
  return (
    <div className="sp-field">
      <label className="sp-field__label">{label}</label>
      <input className="m-input" type={obscure ? "password" : "text"} placeholder={placeholder}
        {...(controlled ? { value, onChange: (e) => onChange(e.target.value) } : { defaultValue: value, readOnly: true })}
        style={mono ? { fontFamily: "var(--font-mono)" } : null} />
      {hint && <div className="sp-field__hint">{hint}</div>}
    </div>
  );
}

function ReadOnlyField({ label, value }) {
  return (
    <div className="sp-field">
      <label className="sp-field__label">{label}</label>
      <div className="sp-readonly"><Icon name="lock-key" size={14} /><span style={{ flex: 1 }}>{value}</span></div>
    </div>
  );
}

function EditableConfig({ config }) {
  const effortOptions = ["默认", "低", "中", "高"];
  return (
    <div>
      {config.custom && (
        <React.Fragment>
          <Field label="名称" value={config.name} />
          <ReadOnlyField label="提供商类型" value={config.type} />
        </React.Fragment>
      )}

      <Field label="API 密钥" value={config.apiKey} obscure={!!config.apiKey} mono
        hint={!config.apiKey ? "填写 API Key 后才能启用该提供商。" : null} />

      {config.fixedBaseUrl
        ? <ReadOnlyField label="基础 URL" value={config.baseUrl} />
        : <Field label="基础 URL" value={config.baseUrl} mono />}

      {/* Models editor */}
      <div className="sp-field">
        <div className="sp-row-between" style={{ marginBottom: "var(--space-xs)" }}>
          <label className="sp-field__label" style={{ margin: 0 }}>聊天模型</label>
          {config.apiKey && (
            <button type="button" className="sp-fetch-btn"><Icon name="download-simple" size={14} />获取模型</button>
          )}
        </div>
        <div className="sp-models-box">
          {config.models.length === 0 && (
            <div className="sp-field__hint" style={{ marginTop: 0, marginBottom: "var(--space-sm)" }}>暂无模型，添加后才能启用默认模型选择。</div>
          )}
          {config.models.map((m) => (
            <div key={m} className="sp-models-row">
              <span className="sp-models-row__name">{m}</span>
              <button type="button" className="sp-icon-btn" style={{ width: 24, height: 24 }} title="删除模型"><Icon name="x" size={14} /></button>
            </div>
          ))}
          <div className="sp-models-add">
            <input className="m-input" placeholder="输入模型 ID，例如 gpt-4.1" readOnly />
            <button type="button" className="m-btn m-btn--secondary m-btn--sm">添加</button>
          </div>
        </div>
        {config.models.length === 0 && <div className="sp-field__hint">至少添加一个模型后才能启用该提供商。</div>}
      </div>

      {/* Temperature */}
      <div className="sp-field">
        <div className="sp-row-between"><label className="sp-field__label" style={{ margin: 0 }}>温度</label><span className="sp-value-accent">{config.temperature.toFixed(1)}</span></div>
        <div className="sp-slider"><div className="sp-slider__fill" style={{ width: `${(config.temperature / 2) * 100}%` }} /><div className="sp-slider__knob" style={{ left: `${(config.temperature / 2) * 100}%` }} /></div>
      </div>

      {/* Max tokens */}
      <div className="sp-field">
        <label className="sp-field__label">最大词元数</label>
        <div className="sp-maxtokens">
          <div className="sp-slider"><div className="sp-slider__fill" style={{ width: "70%" }} /><div className="sp-slider__knob" style={{ left: "70%" }} /></div>
          <input className="sp-maxtokens__field" defaultValue={config.maxTokens} readOnly />
        </div>
      </div>

      {/* Reasoning effort */}
      <div className="sp-field">
        <div className="sp-row-between"><label className="sp-field__label" style={{ margin: 0 }}>推理强度</label><span className="sp-value-accent">{config.reasoning}</span></div>
        <div className="sp-effort-chips">
          {effortOptions.map((o) => (
            <div key={o} className={"sp-effort-chip" + (o === config.reasoning ? " is-selected" : "")}>{o}</div>
          ))}
        </div>
      </div>

      {/* Proxy */}
      <div className="sp-subhead">代理</div>
      <Field label="代理 URL" value="" />
      <Field label="代理用户名" value="" />
      <Field label="代理密码" value="" obscure />
    </div>
  );
}

Object.assign(window, { ProvidersSection });
