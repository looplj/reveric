/* ============================================================
   Settings tab — 设置
   结构对齐 lib/mobile/pages/settings_page.dart：分组列表，点行下钻到
   对应 section（语言 / 主题 / 编辑器 / 提供商 …）。
   ============================================================ */

/* ---------- 设置主页（分组列表） ---------- */
function SettingsScreen({onOpen}){
  const [ref, scrolled] = useScrolled();
  const [dream, setDream] = useState(true);
  const theme = RevericTheme.useTheme();
  const themeValue = (THEMES.find(t=>t.key===theme.palette)||THEMES[0]).label+' · '+
    (THEME_MODES.find(m=>m.key===theme.mode)||THEME_MODES[0]).label;

  const Group = ({title, children}) => (
    <div style={{marginBottom:22}}>
      <div style={{fontSize:11.5, fontWeight:700, color:'var(--text-subtle)', letterSpacing:.6, padding:'0 4px 8px'}}>{title}</div>
      <div className="slist">{children}</div>
    </div>
  );
  const Row = ({icon, iconBg, iconColor, label, value, right, onClick}) => {
    const Cmp = typeof icon==='string'?I[icon]:icon;
    return (
      <div className="srow" onClick={onClick}>
        <div className="sicon" style={{background:iconBg, color:iconColor}}><Cmp s={18}/></div>
        <div className="col" style={{flex:1, gap:2}}>
          <span style={{fontSize:14.5, fontWeight:500, color:'var(--text-primary)'}}>{label}</span>
        </div>
        {value && <span style={{fontSize:13, color:'var(--text-muted)'}}>{value}</span>}
        {right!==undefined ? right : <I.chevR s={18} c="var(--text-subtle)"/>}
      </div>
    );
  };

  return (
    <div className="screen" data-screen-label="settings">
      <PageHead title="设置" big scrolled={scrolled}/>
      <div className="viewport" ref={ref} style={{padding:'8px 18px 28px'}}>
        <Group title="偏好">
          <Row icon="globe"  iconBg="color-mix(in srgb, var(--text-muted) 12%, transparent)" iconColor="var(--text-muted)" label="语言"   value="中文简体" onClick={()=>onOpen('language')}/>
          <Row icon="palette" iconBg="color-mix(in srgb, var(--accent-warm) 14%, transparent)" iconColor="var(--accent-warm)" label="主题"   value={themeValue} onClick={()=>onOpen('appearance')}/>
          <Row icon="text"   iconBg="color-mix(in srgb, var(--text-secondary) 12%, transparent)" iconColor="var(--text-secondary)" label="编辑器" value="思源宋体 · 17px" onClick={()=>onOpen('editorSettings')}/>
        </Group>

        <Group title="AI">
          <Row icon="brain" iconBg="color-mix(in srgb, var(--info) 12%, transparent)" iconColor="var(--info)" label="AI 提供商" value="5 个 · 4 已连接" onClick={()=>onOpen('providers')}/>
          <Row icon="model" iconBg="color-mix(in srgb, var(--accent-amber) 14%, transparent)" iconColor="var(--accent-amber)" label="默认模型" value="mimo-v2.5"/>
          <Row icon="robot" iconBg="color-mix(in srgb, var(--accent-warm) 14%, transparent)" iconColor="var(--accent-warm)" label="智能体" value={SUBAGENTS.length+' 个'}/>
          <div className="srow">
            <div className="sicon" style={{background:'color-mix(in srgb, var(--accent) 12%, transparent)', color:'var(--accent)'}}><I.moon s={18}/></div>
            <div className="col" style={{flex:1}}>
              <span style={{fontSize:14.5, fontWeight:500}}>做梦</span>
              <span style={{fontSize:11, color:'var(--text-subtle)'}}>空闲时让 AI 自动整理伏笔与设定</span>
            </div>
            <Switch on={dream} onToggle={()=>setDream(v=>!v)}/>
          </div>
        </Group>

        <Group title="数据">
          <Row icon="chart" iconBg="color-mix(in srgb, var(--success) 13%, transparent)" iconColor="var(--success)" label="用量统计" value="本月 34.3 万词元" onClick={()=>onOpen('usage')}/>
          <Row icon="archive" iconBg="color-mix(in srgb, var(--text-muted) 12%, transparent)" iconColor="var(--text-muted)" label="存储与备份" value="248 MB"/>
        </Group>

        <Group title="系统">
          <Row icon="info" iconBg="var(--surface-dim)" iconColor="var(--text-muted)" label="关于 Reveric" value="v0.4.2"/>
        </Group>

        <div style={{textAlign:'center', fontSize:11, color:'var(--text-subtle)', padding:'8px 0 4px', fontFamily:'var(--display)'}}>
          Reveric · 为创作者打造的写作空间
        </div>
      </div>
    </div>
  );
}

/* ---------- 通用小组件 ---------- */
function SectHead({title, desc}){
  return (
    <div className="col" style={{gap:3, marginBottom:14, padding:'0 2px'}}>
      <span style={{fontSize:14, fontWeight:700, color:'var(--text-primary)'}}>{title}</span>
      {desc && <span style={{fontSize:12, color:'var(--text-muted)', lineHeight:1.5}}>{desc}</span>}
    </div>
  );
}
function ToggleChip({label, on, onTap, disabled}){
  return <span className={"tchip"+(on?' on':'')} onClick={disabled?undefined:onTap}
    style={{opacity:disabled?.5:1}}>{label}</span>;
}
function SettingSlider({value, min, max, step, fmt, onChange}){
  return (
    <div className="row gap12">
      <input type="range" className="mslider" min={min} max={max} step={step||1} value={value}
        onChange={e=>onChange(parseFloat(e.target.value))} style={{flex:1}}/>
      <span style={{minWidth:46, textAlign:'center', padding:'4px 10px', borderRadius:'var(--r-pill)',
        border:'1px solid var(--border)', background:'var(--surface)', fontSize:12.5, fontWeight:700, color:'var(--accent)'}}>
        {fmt?fmt(value):value}</span>
    </div>
  );
}
function ColorSwatches({colors, sel, onSel}){
  return (
    <div className="row gap8" style={{flexWrap:'wrap'}}>
      {colors.map(c=>(
        <span key={c} className="press" onClick={()=>onSel(c)} style={{width:24,height:24,borderRadius:'50%',background:c,
          border:(sel===c?'2.5px solid var(--accent)':'1px solid var(--border-subtle)'), cursor:'pointer'}}></span>
      ))}
    </div>
  );
}

/* ---------- 语言 ---------- */
function LanguageDetail({onBack}){
  const [sel, setSel] = useState('zh');
  const [ref, scrolled] = useScrolled();
  return (
    <div className="screen fade-in" data-screen-label="settings-language">
      <PageHead title="语言" onBack={onBack} scrolled={scrolled} center/>
      <div className="viewport" ref={ref} style={{padding:'14px 20px 28px'}}>
        <SectHead title="语言" desc="选择应用界面语言。"/>
        <div className="col gap10">
          {LANGUAGES.map(l=>{
            const on = sel===l.k;
            return (
              <div key={l.k} className="press" onClick={()=>setSel(l.k)} style={{display:'flex', alignItems:'center', gap:12,
                padding:'14px 16px', borderRadius:'var(--r-xl)', background:on?'var(--selected)':'var(--surface)',
                border:'1px solid '+(on?'var(--accent)':'var(--card-border)'), boxShadow:on?'none':'var(--shadow-card)'}}>
                <div className="col" style={{flex:1, gap:2}}>
                  <span style={{fontSize:14.5, fontWeight:600, color:'var(--text-primary)'}}>{l.label}</span>
                  <span style={{fontSize:11.5, color:'var(--text-muted)'}}>{l.sub}</span>
                </div>
                {on && <I.checkCircle s={20} c="var(--accent)"/>}
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}

/* ---------- 主题 / 外观 ----------
   对齐 appearance_settings_section.dart：主题模式 + 主题两段。
   Flutter 在 iOS / Android 上不显示「应用背景」，移动端这里也不画。
   选中项读写 ../theme.js（RevericTheme），切换后整个 mockup 跟着换 token。 */
function ThemePreview({t}){
  const p = t.preview;
  return (
    <div style={{width:64, height:48, borderRadius:'var(--r-md)', overflow:'hidden', flex:'0 0 auto',
      background:p.canvas, border:'1px solid var(--border-subtle)'}}>
      <div style={{height:16, background:p.accent}}></div>
      <div className="row gap4" style={{padding:4}}>
        <div style={{width:12, height:12, borderRadius:2, background:p.surface}}></div>
        <div style={{flex:1, height:4, borderRadius:1, background:tint(p.text,.3)}}></div>
      </div>
    </div>
  );
}
function AppearanceDetail({onBack}){
  const [ref, scrolled] = useScrolled();
  const {palette, mode} = RevericTheme.useTheme();

  return (
    <div className="screen fade-in" data-screen-label="settings-appearance">
      <PageHead title="主题" onBack={onBack} scrolled={scrolled} center/>
      <div className="viewport" ref={ref} style={{padding:'16px 20px 28px'}}>
        <SectHead title="主题模式" desc="选择浅色、深色或跟随系统。"/>
        <div className="col gap8" style={{marginBottom:24}}>
          {THEME_MODES.map(m=>{
            const Cmp = I[m.icon]; const on = mode===m.key;
            return (
              <div key={m.key} className="press" onClick={()=>RevericTheme.set({mode:m.key})} style={{display:'flex', alignItems:'center', gap:12,
                padding:'13px 14px', borderRadius:'var(--r-xl)', background:on?'var(--selected)':'var(--surface)',
                border:'1px solid '+(on?'var(--accent)':'var(--card-border)'), boxShadow:on?'none':'var(--shadow-card)'}}>
                <Cmp s={22} c={on?'var(--accent)':'var(--text-secondary)'}/>
                <span style={{flex:1, fontSize:14, fontWeight:600, color:'var(--text-primary)'}}>{m.label}</span>
                {on && <I.checkCircle s={20} c="var(--accent)"/>}
              </div>
            );
          })}
        </div>

        <SectHead title="主题" desc="选择应用主题风格。"/>
        <div className="col gap8">
          {THEMES.map(t=>{
            const on = palette===t.key;
            return (
              <div key={t.key} className="press" onClick={()=>RevericTheme.set({palette:t.key})} style={{display:'flex', alignItems:'center', gap:12,
                padding:'12px 14px', borderRadius:'var(--r-xl)', background:on?'var(--selected)':'var(--surface)',
                border:'1px solid '+(on?'var(--accent)':'var(--card-border)'), boxShadow:on?'none':'var(--shadow-card)'}}>
                <ThemePreview t={t}/>
                <div className="col" style={{flex:1, gap:2, minWidth:0}}>
                  <span style={{fontSize:14, fontWeight:700, color:'var(--text-primary)'}}>{t.label}</span>
                  <span style={{fontSize:11.5, color:'var(--text-muted)', lineHeight:1.45}}>{t.desc}</span>
                </div>
                {on && <I.checkCircle s={20} c="var(--accent)" style={{flex:'0 0 auto'}}/>}
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}

/* ---------- 编辑器 ---------- */
function EditorDetail({onBack}){
  const [ref, scrolled] = useScrolled();
  const [size, setSize] = useState(17);
  const [spacing, setSpacing] = useState(0.0);
  const [lineH, setLineH] = useState(1.9);
  const [entity, setEntity] = useState({italic:true, bold:false, underline:false, highlight:true});
  const [hl, setHl] = useState('#33FFD54F');
  const [indent, setIndent] = useState(2);
  const [paraSp, setParaSp] = useState('one');
  const [keepSp, setKeepSp] = useState(true);
  const [lineOn, setLineOn] = useState(true);
  const [lineStyle, setLineStyle] = useState('solid');
  const [lineColor, setLineColor] = useState('#FFFF0000');
  const tg = (k)=> setEntity(e=>({...e,[k]:!e[k]}));

  const hlPresets = ['#33FFD54F','#33FF8A65','#334FC3F7','#3381C784','#33BA68C8','#33F06292','#33A1887F','#335C6BC0'];
  const linePresets = ['#FFFF0000','#FF0000FF','#FF00AA00','#FFFF8800','#FF8800FF','#FF00CCCC','#FF444444','#FF000000'];
  const toCss = (h)=>{ // #AARRGGBB -> rgba
    if(h.length===9){const a=parseInt(h.slice(1,3),16)/255,r=parseInt(h.slice(3,5),16),g=parseInt(h.slice(5,7),16),b=parseInt(h.slice(7,9),16);return `rgba(${r},${g},${b},${a.toFixed(2)})`;}
    return h;
  };

  const Card = ({children}) => <div className="card" style={{padding:'4px 14px'}}>{children}</div>;
  const RowItem = ({label, desc, children, last}) => (
    <div style={{padding:'13px 0', borderBottom:last?'none':'1px solid var(--border-subtle)'}}>
      <div className="col" style={{gap:2, marginBottom:children?9:0}}>
        <span style={{fontSize:13.5, fontWeight:600, color:'var(--text-primary)'}}>{label}</span>
        {desc && <span style={{fontSize:11.5, color:'var(--text-muted)', lineHeight:1.5}}>{desc}</span>}
      </div>
      {children}
    </div>
  );

  return (
    <div className="screen fade-in" data-screen-label="settings-editor">
      <PageHead title="编辑器" onBack={onBack} scrolled={scrolled} center/>
      <div className="viewport" ref={ref} style={{padding:'16px 20px 28px'}}>
        {/* 字体 */}
        <SectHead title="编辑器" desc="配置编辑器的字体、间距和排版。"/>
        <Card>
          {/* preview */}
          <div style={{padding:'13px 0'}}>
            <div style={{border:'1px solid var(--border-subtle)', borderRadius:'var(--r-lg)', padding:'14px 16px', background:'var(--surface-container)'}}>
              <div className="serif" style={{fontSize:size, lineHeight:lineH, letterSpacing:spacing, color:'var(--text-primary)'}}>The quick brown fox jumps over the lazy dog.</div>
              <div className="serif" style={{fontSize:size, lineHeight:lineH, letterSpacing:spacing, color:'var(--text-primary)', marginTop:6}}>秋风萧瑟天气凉，草木摇落露为霜。</div>
            </div>
          </div>
          <RowItem label="编辑器字体" desc="从系统字体中选择，或输入自定义字体名称。">
            <div className="row press" style={{height:42, padding:'0 13px', border:'1px solid var(--border-input)', borderRadius:'var(--r-lg)', background:'var(--surface-high)'}}>
              <span style={{flex:1, fontSize:14, color:'var(--text-primary)', fontFamily:'var(--serif)'}}>思源宋体 Source Han Serif</span>
              <I.caretD s={15} c="var(--text-subtle)"/>
            </div>
          </RowItem>
          <RowItem label="编辑器字号" desc="设置编辑器内容区域的文字大小。">
            <SettingSlider value={size} min={10} max={32} onChange={setSize}/>
          </RowItem>
          <RowItem label="字间距" desc="设置编辑器内容的字间距。">
            <SettingSlider value={spacing} min={0} max={4} step={0.1} fmt={v=>v.toFixed(1)} onChange={setSpacing}/>
          </RowItem>
          <RowItem label="行间距" desc="设置编辑器内容的行高。" last>
            <SettingSlider value={lineH} min={1.2} max={2.4} step={0.05} fmt={v=>v.toFixed(2)} onChange={setLineH}/>
          </RowItem>
        </Card>

        {/* 实体标记 */}
        <div style={{height:24}}></div>
        <SectHead title="实体标记" desc="配置正文中识别到角色、物品等实体时使用的行内样式。"/>
        <Card>
          <div style={{padding:'14px 0', borderBottom:entity.highlight?'1px solid var(--border-subtle)':'none'}}>
            <div className="row gap8" style={{flexWrap:'wrap'}}>
              <ToggleChip label="斜体" on={entity.italic} onTap={()=>tg('italic')}/>
              <ToggleChip label="粗体" on={entity.bold} onTap={()=>tg('bold')}/>
              <ToggleChip label="划线" on={entity.underline} onTap={()=>tg('underline')}/>
              <ToggleChip label="高亮" on={entity.highlight} onTap={()=>tg('highlight')}/>
            </div>
            {/* sample */}
            <div style={{marginTop:12, fontSize:14, color:'var(--text-secondary)'}}>例：
              <span style={{fontStyle:entity.italic?'italic':'normal', fontWeight:entity.bold?700:400,
                textDecoration:entity.underline?'underline':'none',
                background:entity.highlight?toCss(hl):'transparent', borderRadius:3, padding:'0 2px'}}>周清远</span>
              推开酒馆的门。</div>
          </div>
          {entity.highlight && (
            <RowItem label="高亮颜色" last>
              <ColorSwatches colors={hlPresets} sel={hl} onSel={setHl}/>
            </RowItem>
          )}
        </Card>

        {/* 自动排版 */}
        <div style={{height:24}}></div>
        <SectHead title="自动排版" desc="配置章节正文的自动排版行为。"/>
        <Card>
          <RowItem label="段首缩进" desc="每段开头的全角空格数量（0–8）。">
            <SettingSlider value={indent} min={0} max={8} onChange={setIndent}/>
          </RowItem>
          <RowItem label="段落间距" desc="段落之间是否插入一个空行。">
            <div className="row gap8">
              <ToggleChip label="不空行" on={paraSp==='none'} onTap={()=>setParaSp('none')}/>
              <ToggleChip label="空一行" on={paraSp==='one'} onTap={()=>setParaSp('one')}/>
            </div>
          </RowItem>
          <RowItem label="保留空格" desc="关闭后将移除所有空格；开启后规范中英文间距。" last>
            <Switch on={keepSp} onToggle={()=>setKeepSp(v=>!v)}/>
          </RowItem>
        </Card>

        {/* 线条标注 */}
        <div style={{height:24}}></div>
        <div className="row" style={{justifyContent:'space-between', alignItems:'flex-start', marginBottom:14, padding:'0 2px'}}>
          <div className="col" style={{gap:3, flex:1}}>
            <span style={{fontSize:14, fontWeight:700, color:'var(--text-primary)'}}>线条标注</span>
            <span style={{fontSize:12, color:'var(--text-muted)', lineHeight:1.5}}>配置编辑器线条标注的显示、风格和颜色。</span>
          </div>
          <Switch on={lineOn} onToggle={()=>setLineOn(v=>!v)}/>
        </div>
        <Card>
          <RowItem label="线条风格">
            <div className="row gap8" style={{flexWrap:'wrap'}}>
              {[['solid','实线'],['sparse','稀疏虚线'],['dense','密集虚线']].map(([k,l])=>(
                <ToggleChip key={k} label={l} on={lineStyle===k} onTap={()=>setLineStyle(k)} disabled={!lineOn}/>
              ))}
            </div>
          </RowItem>
          <RowItem label="线条颜色" last>
            <div style={{opacity:lineOn?1:.5, pointerEvents:lineOn?'auto':'none'}}>
              <ColorSwatches colors={linePresets} sel={lineColor} onSel={setLineColor}/>
            </div>
          </RowItem>
        </Card>
      </div>
    </div>
  );
}

/* ---------- AI 提供商 ----------
   添加自定义：右上 + / 底部按钮 → 底部弹层选类型 → 进入未落库的草稿配置页
   （放弃 / 保存）；保存后才出现在列表里。草稿页返回时确认是否放弃。 */
function ProvidersScreen({onBack}){
  const [ref, scrolled] = useScrolled();
  const [list, setList] = useState(PROVIDERS);
  const [picker, setPicker] = useState(false);
  const [draft, setDraft] = useState(null);
  const tone = (k)=> k==='ok'?{c:'var(--success)',bg:'color-mix(in srgb, var(--success) 12%, transparent)'}:{c:'var(--warning)',bg:'color-mix(in srgb, var(--warning-text) 12%, transparent)'};

  if (draft) {
    return <ProviderDraftScreen draft={draft} onDiscard={()=>setDraft(null)}
      onChangeType={(t)=>setDraft(d=>({...d, type:t, name: d.name===d.type.name ? t.name : d.name}))}
      onSave={(v)=>{ setList(l=>[...l, {name:v.name, model:v.type.name, state: v.apiKey ? '未添加模型' : '未配置密钥', kind:'warn'}]); setDraft(null); }}/>;
  }

  return (
    <div className="screen fade-in" data-screen-label="providers">
      <PageHead title="AI 提供商" onBack={onBack} scrolled={scrolled} center right={<IconBtn icon="plus" ariaLabel="添加自定义提供商" onClick={()=>setPicker(true)}/>}/>
      <div className="viewport" ref={ref} style={{padding:'12px 18px 28px'}}>
        <p style={{margin:'0 0 14px', fontSize:12.5, color:'var(--text-muted)', lineHeight:1.65, padding:'0 4px'}}>
          主笔智能体会从已连接的提供商中，按你设定的优先级选择模型。</p>
        <div className="col gap10">
          {list.map(p=>{
            const tn = tone(p.kind);
            return (
              <div key={p.name} className="card" style={{padding:'13px 14px', display:'flex', gap:12, alignItems:'center'}}>
                <div style={{width:40,height:40,borderRadius:'var(--r-lg)',flex:'0 0 auto',background:'color-mix(in srgb, var(--info) 12%, transparent)',color:'var(--info)',display:'flex',alignItems:'center',justifyContent:'center'}}><I.brain s={20}/></div>
                <div className="col" style={{flex:1, gap:2, minWidth:0}}>
                  <span style={{fontSize:14.5, fontWeight:700}}>{p.name}</span>
                  <span style={{fontSize:11.5, color:'var(--text-muted)'}}>{p.model}</span>
                </div>
                <div className="col" style={{alignItems:'flex-end', gap:6}}>
                  <span className="chip" style={{height:20,fontSize:10.5,padding:'0 8px',color:tn.c,background:tn.bg,fontWeight:600}}>{p.state}</span>
                  <button className="btn-ghost press" style={{height:28, padding:'0 12px', fontSize:12}}>配置</button>
                </div>
              </div>
            );
          })}
        </div>
        <button className="btn-ghost press" onClick={()=>setPicker(true)}
          style={{width:'100%', height:44, marginTop:14, borderStyle:'dashed', color:'var(--accent-warm)', fontWeight:600}}>
          <I.plus s={16}/>添加自定义提供商
        </button>
      </div>
      {picker && <ProviderTypeSheet onClose={()=>setPicker(false)}
        onPick={(t)=>{ setPicker(false); setDraft({type:t, name:t.name}); }}/>}
    </div>
  );
}

function KindTag({k, hit}){
  return <span style={{padding:'1px 7px', borderRadius:'var(--r-sm)', fontSize:10.5, fontWeight:600,
    background: hit ? 'color-mix(in srgb, var(--accent-amber) 15%, transparent)' : 'var(--surface-dim)',
    color: hit ? 'var(--accent-amber)' : 'var(--text-muted)'}}>{PROVIDER_KIND_LABELS[k]}</span>;
}

/* 类型选择底部弹层：能力筛选 + 每行能力标签 / 固定地址标记 */
function ProviderTypeSheet({onPick, onClose, current}){
  const [kind, setKind] = useState('all');
  const types = PROVIDER_TYPES.filter(t=>kind==='all' || t.kinds.includes(kind));
  return (
    <Sheet onClose={onClose} max="80%">
      <SheetHeader title="选择接口格式"/>
      <div className="row gap6" style={{padding:'10px 18px', flex:'0 0 auto', overflowX:'auto'}}>
        {['all','chat','image','video','audio'].map(k=>(
          <span key={k} className="chip press" onClick={()=>setKind(k)}
            style={kind===k ? {background:'var(--accent)', color:'var(--on-accent)'} : {border:'1px solid var(--border)', color:'var(--text-secondary)'}}>
            {k==='all' ? '全部' : PROVIDER_KIND_LABELS[k]}
          </span>
        ))}
      </div>
      <div style={{flex:1, overflowY:'auto', padding:'0 12px 20px'}}>
        {types.map(t=>(
          <div key={t.key} className="press" onClick={()=>onPick(t)}
            style={{padding:'12px 10px', borderRadius:'var(--r-lg)', display:'flex', alignItems:'center', gap:10,
              background: current===t.key ? 'var(--surface)' : 'transparent'}}>
            <div className="col" style={{flex:1, gap:4, minWidth:0}}>
              <div className="row gap8">
                <span style={{fontSize:14.5, fontWeight:600, color:'var(--text-primary)'}}>{t.name}</span>
                {t.fixed && <span className="row gap2" style={{fontSize:10.5, color:'var(--text-subtle)'}}><I.lock s={11}/>固定地址</span>}
              </div>
              {t.note && <span style={{fontSize:11.5, color:'var(--text-muted)'}}>{t.note}</span>}
              <div className="row gap4" style={{flexWrap:'wrap'}}>
                {t.kinds.map(k=><KindTag key={k} k={k} hit={k===kind}/>)}
              </div>
            </div>
            {current===t.key ? <I.check s={18} c="var(--accent)"/> : <I.chevR s={18} c="var(--text-subtle)"/>}
          </div>
        ))}
      </div>
    </Sheet>
  );
}

/* 草稿配置页：顶栏「放弃 / 保存」；返回键等同放弃并先确认。 */
function ProviderDraftScreen({draft, onDiscard, onSave, onChangeType}){
  const [ref, scrolled] = useScrolled();
  const [name, setName] = useState(draft.name);
  const [baseUrl, setBaseUrl] = useState(draft.type.baseUrl || '');
  const [apiKey, setApiKey] = useState('');
  const [typeSheet, setTypeSheet] = useState(false);
  const [confirm, setConfirm] = useState(false);
  const t = draft.type;
  useEffect(()=>{ setName(draft.name); setBaseUrl(t.baseUrl || ''); }, [t.key]);
  const hasKey = !!apiKey.trim();
  const modelLabels = {chat:'聊天模型', video:'视频模型', audio:'音频模型', image:'图片模型'};

  return (
    <div className="screen fade-in" data-screen-label="providerDraft">
      <PageHead title="新建提供商" sub={<span style={{color:'var(--warning-text)'}}>未保存</span>} onBack={()=>setConfirm(true)} scrolled={scrolled} center
        right={<button className="btn-accent press" disabled={!name.trim()} onClick={()=>onSave({name, baseUrl, apiKey, type:t})}
          style={{height:32, padding:'0 14px', fontSize:13, marginRight:8, opacity: name.trim() ? 1 : .45}}>保存</button>}/>
      <div className="viewport" ref={ref} style={{padding:'12px 18px 28px'}}>
        <Field label="名称">
          <input className="tinput" value={name} onChange={e=>setName(e.target.value)}/>
        </Field>

        <Field label="提供商类型" hint="保存后类型不可更改。">
          <div className="tinput press row gap8" onClick={()=>setTypeSheet(true)} style={{display:'flex', alignItems:'center'}}>
            <span style={{flex:1, fontSize:14}}>{t.name}</span>
            <div className="row gap4">{t.kinds.map(k=><KindTag key={k} k={k}/>)}</div>
            <I.chevR s={16} c="var(--text-subtle)"/>
          </div>
        </Field>

        <Field label="基础 URL" hint={t.fixed ? null : (!baseUrl ? '填写服务地址，例如中转站提供的 /v1 地址。' : null)}>
          {t.fixed
            ? <div className="tinput row gap8" style={{display:'flex', alignItems:'center', color:'var(--text-muted)', background:'var(--surface-dim)'}}><I.lock s={14}/><span style={{fontSize:13, overflow:'hidden', textOverflow:'ellipsis', whiteSpace:'nowrap'}}>{t.baseUrl}</span></div>
            : <input className="tinput" value={baseUrl} onChange={e=>setBaseUrl(e.target.value)} placeholder="https://api.example.com/v1" style={{fontFamily:'var(--mono)'}}/>}
        </Field>

        <Field label="API 密钥" hint={!hasKey ? '填写 API Key 后才能启用该提供商。' : null}>
          <input className="tinput" type="password" value={apiKey} onChange={e=>setApiKey(e.target.value)} placeholder="sk-…"/>
        </Field>

        {['chat','video','audio','image'].filter(k=>t.kinds.includes(k)).map(k=>(
          <Field key={k} label={modelLabels[k]}
            right={<span className="row gap4" style={{fontSize:12, fontWeight:600, color: hasKey ? 'var(--accent)' : 'var(--text-subtle)'}}>获取模型</span>}
            hint={!hasKey ? '填写 API 密钥后可获取模型列表。' : null}>
            <div className="card" style={{padding:12, boxShadow:'none'}}>
              <div style={{fontSize:12, color:'var(--text-muted)', marginBottom:8}}>暂无模型</div>
              <div className="row gap8">
                <input className="tinput" placeholder="输入模型 ID" style={{flex:1}}/>
                <button className="btn-ghost press" style={{height:44, padding:'0 14px'}}>添加</button>
              </div>
            </div>
          </Field>
        ))}

        <div className="row gap4" style={{fontSize:12.5, fontWeight:600, color:'var(--text-secondary)', padding:'4px 0'}}>
          代理<I.chevR s={14} c="var(--text-subtle)" style={{transform:'rotate(90deg)'}}/>
        </div>
      </div>

      {typeSheet && <ProviderTypeSheet current={t.key} onClose={()=>setTypeSheet(false)}
        onPick={(nt)=>{ setTypeSheet(false); onChangeType(nt); }}/>}

      {confirm && (
        <Sheet onClose={()=>setConfirm(false)} max="40%">
          <div style={{padding:'6px 22px 24px'}}>
            <div className="display" style={{fontSize:16.5, fontWeight:700, marginBottom:6}}>放弃未保存的提供商？</div>
            <div style={{fontSize:13, color:'var(--text-muted)', lineHeight:1.6, marginBottom:18}}>「{name || t.name}」尚未保存，离开后填写的内容不会保留。</div>
            <div className="row gap10">
              <button className="btn-ghost press" style={{flex:1, height:44}} onClick={()=>setConfirm(false)}>继续编辑</button>
              <button className="btn-accent press" style={{flex:1, height:44, background:'var(--error)'}} onClick={onDiscard}>放弃</button>
            </div>
          </div>
        </Sheet>
      )}
    </div>
  );
}

/* ---------- 用量统计（对齐桌面端 usage.jsx） ---------- */
const USAGE_BD = {input:'var(--accent)', cacheRead:'var(--success)', cacheWrite:'var(--accent-warm)', output:'var(--text-muted)'};
function UsageScreen({onBack}){
  const [ref, scrolled] = useScrolled();
  const t = USAGE.today, m = USAGE.month;
  const H = 100;
  return (
    <div className="screen fade-in" data-screen-label="settings-usage">
      <PageHead title="用量" onBack={onBack} scrolled={scrolled} center/>
      <div className="viewport" ref={ref} style={{padding:'14px 20px 28px'}}>
        <div className="row gap10" style={{marginBottom:18}}>
          {[['本日',t.total,t.requests],['本月',m.total,null]].map(([label,total,req],i)=>(
            <div key={i} className="card" style={{flex:1, padding:14}}>
              <span style={{fontSize:12, color:'var(--text-muted)', fontWeight:600}}>{label}</span>
              <div className="row gap4" style={{alignItems:'baseline', margin:'6px 0 4px'}}>
                <span className="display" style={{fontSize:22, fontWeight:700, letterSpacing:'-0.02em', fontVariantNumeric:'tabular-nums'}}>{fmt(total)}</span>
                <span style={{fontSize:11, color:'var(--text-subtle)'}}>词元</span>
              </div>
              {req!==null && <span style={{fontSize:11, color:'var(--text-subtle)'}}>{req} 次请求</span>}
              {req===null && <span style={{fontSize:11, color:m.trendUp?'var(--warning)':'var(--success)'}}>{m.trendUp?'↑':'↓'} 较上月 {m.trend}</span>}
            </div>
          ))}
        </div>
        <div className="card" style={{padding:14, marginBottom:18}}>
          <div style={{fontSize:13, fontWeight:700, marginBottom:4}}>每日词元用量</div>
          <div style={{fontSize:11, color:'var(--text-muted)', marginBottom:12}}>过去 30 天</div>
          <div className="row gap8" style={{marginBottom:10, flexWrap:'wrap'}}>
            {[['输入',USAGE_BD.input],['缓存读取',USAGE_BD.cacheRead],['缓存写入',USAGE_BD.cacheWrite],['输出',USAGE_BD.output]].map(([l,c])=>(
              <div key={l} className="row gap4" style={{alignItems:'center'}}><span style={{width:8,height:8,borderRadius:2,background:c}}/><span style={{fontSize:10, color:'var(--text-muted)'}}>{l}</span></div>
            ))}
          </div>
          <div style={{display:'flex', gap:2, alignItems:'flex-end', height:H}}>
            {[0.3,0.5,0.7,0.4,0.6,0.8,0.35,0.55,0.65,0.45,0.75,0.9,0.5,0.6,0.4,0.7,0.55,0.85,0.45,0.65,0.5,0.7,0.4,0.6,0.8,0.35,0.55,0.7,0.45,0.6].map((v,i)=>(
              <div key={i} style={{flex:1, display:'flex', flexDirection:'column', gap:0}}>
                <div style={{height:v*H*0.4, background:USAGE_BD.input, borderRadius:'2px 2px 0 0'}}/>
                <div style={{height:v*H*0.2, background:USAGE_BD.cacheRead}}/>
                <div style={{height:v*H*0.1, background:USAGE_BD.cacheWrite}}/>
                <div style={{height:v*H*0.3, background:USAGE_BD.output, borderRadius:'0 0 2px 2px'}}/>
              </div>
            ))}
          </div>
        </div>
        <SectHead title="用量明细" desc="每次请求的词元消耗"/>
        <div className="col gap8">
          {USAGE.records.map((r,i)=>(
            <div key={i} className="card" style={{padding:'10px 12px', display:'flex', gap:10, alignItems:'center'}}>
              <div className="col" style={{flex:1, gap:2, minWidth:0}}>
                <span style={{fontSize:13, fontWeight:600}}>{r.model}</span>
                <span style={{fontSize:11, color:'var(--text-muted)'}}>{r.time}</span>
              </div>
              <div className="row gap8" style={{flex:'0 0 auto'}}>
                <span style={{fontSize:12, color:'var(--text-muted)'}}>入 {fmt(r.input)}</span>
                <span style={{fontSize:12, color:'var(--text-muted)'}}>出 {fmt(r.output)}</span>
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { SettingsScreen, LanguageDetail, AppearanceDetail, EditorDetail, ProvidersScreen, UsageScreen });
