/* ============================================================
   Reveric Mobile · Mock data
   以桌面端 designs/desktop/data.js 的「夜航船」为蓝本，补全移动端
   覆盖所有功能所需的实体内容（人物 / 设定 / 伏笔 / 物品 / 势力 /
   生物 / 地图 / 素材 / 实体关系图）。词汇取自 zh-CN 翻译。
   ============================================================ */

const NOVELS = [
  { id:'n1', title:'夜航船', en:'Night Boat', tint:'#2D3A36', chapters:42, words:'18.4万',
    status:'创作中', cat:'历史 · 群像', tags:['长篇','明末','群像'], updated:'今天 14:32',
    desc:'明末江南，一艘逆流而上的客船载着失意的画师、逃婚的小姐、隐姓的旧官。每个人都怀着一桩不可对人言的心事，每个人都在等天亮。',
    last:'第 03 章 · 三舱客' },
  { id:'n2', title:'山影渐落', en:'When the Mountains Fade', tint:'#5C6B7E', chapters:18, words:'6.2万',
    status:'创作中', cat:'文学 · 悬疑', tags:['中篇','悬疑','山'], updated:'昨天',
    desc:'一位退休制图师在阿尔卑斯山脚下的小镇接到了一份奇怪的委托——为一座地图上没有的山绘制等高线。' },
  { id:'n3', title:'天文学家的女儿', en:"The Astronomer's Daughter", tint:'#34465A', chapters:9, words:'2.8万',
    status:'草稿', cat:'历史虚构', tags:['novella','demo'], updated:'3 天前',
    desc:'里昂，1893。Hélène 继承了父亲的望远镜、未完成的星表，以及他与学院的争执。' },
  { id:'n4', title:'枯木集', en:'Withered Tree Anthology', tint:'#4E7F6E', chapters:7, words:'2.0万',
    status:'已完本', cat:'短篇集 · 宋代', tags:['短篇','宋代'], updated:'上周',
    desc:'一组以宋代山水画为线索的短篇集，每篇围绕一幅画展开。' },
  { id:'n5', title:'盐与铜锈', en:'Salt & Verdigris', tint:'#6E5868', chapters:31, words:'13.0万',
    status:'创作中', cat:'蒸汽朋克', tags:['长篇','蒸汽朋克'], updated:'06/14' },
  { id:'n6', title:'观星人手记', en:"Stargazer's Notes", tint:'#3F6E73', chapters:5, words:'1.1万',
    status:'草稿', cat:'科幻', tags:['短篇','科幻'], updated:'06/09' },
];

/* 章节（夜航船） */
const VOLUMES = [
  { vol:'卷一 · 河上人', items:[
    {id:'c1', n:'01', t:'夜入吴县', words:4128, state:'已定稿'},
    {id:'c2', n:'02', t:'船头那盏灯', words:3892, state:'已润色'},
    {id:'c3', n:'03', t:'三舱客', words:4504, state:'草稿', active:true},
    {id:'c4', n:'04', t:'周清远', words:0, state:'大纲'},
  ]},
  { vol:'卷二 · 雨中人', items:[
    {id:'c5', n:'05', t:'夜雨', words:0, state:'大纲'},
    {id:'c6', n:'06', t:'未署名的信', words:0, state:'未开始'},
  ]},
];

const STATE_TONE = {
  '已定稿':{c:'var(--success)'},
  '已润色':{c:'var(--info)'},
  '草稿':{c:'var(--accent-warm)'},
  '大纲':{c:'var(--text-muted)'},
  '未开始':{c:'var(--text-subtle)'},
};

const ACTIVE_CHAPTER = {
  n:'03', t:'三舱客', words:4504, state:'草稿',
  summary:'三个互不相识的客人各自上船，画师周清远暂以化名隐瞒身份；小姐凤瑶藏在男装下；旧官老沈带着一只看似普通的木匣。船未离岸，三个人的目光已经在舱中交错。',
  body:[
    '船家的灯笼挂在桅杆上，照见雨水沿着甲板的纹路缓缓淌下去。周清远把伞收好，伞骨在他袖中微微作响。他没有看身后那两人——他知道，越是不看，越是被看。',
    '“先生，”船家的声音从船尾传来，带着江浙口音的拐弯，“您是要去松江府的，是吧？”',
    '他点了点头，没出声。他的名字写在油纸伞柄上，是他自己刻的。今晚他不打算让任何人看见。',
    '船舱里很暗。三盏小油灯在低梁下摇晃，把每一张脸都照成了半张。坐在他对面的，是一个少年——细眉，唇线却太柔，像被人用过的笔尖一样收不住。',
    '另一个客人坐在最里头，靠着舱壁，怀里抱着一只乌木匣子。匣盖上嵌了一道银线，磨得很旧，但银线那一面，永远朝着他自己。',
  ],
};

/* 人物 */
const CHARACTERS = [
  { id:'ch1', name:'周清远', role:'主角 · 画师', tint:'#2D3A36', tag:'视角人物',
    one:'松江府画师，以化名登船，背负一桩与旧画案有关的旧事。',
    fields:[['身份','松江府画师（隐名）'],['年龄','34'],['动机','寻一幅流落的旧画，避开追查'],['弧光','由回避 → 直面']],
    /* 完整档案字段，对齐 CharacterProfiles 表 */
    profile:{
      roleKey:'protagonist', genderKey:'male', age:'34',
      identity:'松江府画师（隐名）· 旧画案余生者',
      aliases:['周十七','那个画舫上的哑客'],
      photos:[{tint:'#2D3A36', label:'登船那夜'},{tint:'#6E5868', label:'旧画残卷'},{tint:'#4E7F6E', label:'苏州旧宅'}],
      appearance:'瘦高，肩线塌，长年伏案画画留下的。手指关节有洗不掉的靛青。\n\n面上无须，眼下两道浅青，看人时先看半息再开口。惯穿一件半旧的灰青直裰，袖口沾着颜料。',
      biography:'周家原是松江府的画匠世家，父亲在万历末年替人摹了一幅不该摹的画，一案牵连九人。\n\n清远那年十四，被师娘裹在颜料箱里带出城，改名换姓，靠替书铺画插图度日。\n\n二十年后他在一间当铺见到那幅画的残卷——他谁也没说，包括同行的凤瑶。',
      description:'说话慢，句尾常收半拍，像先在心里把话过一遍。\n\n站着时右手总不自觉搭在袖袋上（里面是那卷残画）。生人面前不主动开口，一旦开口就直奔要害。',
      motivation:'寻回那幅流落的旧画，替父亲把二十年前的罪名当面撕掉。',
      arc:'从改名换姓的回避者，到肯在公堂上报出本名的人；代价是他先学会了说谎，才学会了作证。',
      personality:'外冷内热。对「亏欠」极度敏感，别人给他一分好会记很久，也因此不肯欠人情。\n\n判断快、下笔更快，但事后会反复复盘；这种自我审判往往比对手更伤他。\n\n在官身面前会本能退让半步——不是怕，是不想再连累任何人。',
      behavior:[
        ['被人认出画风','立刻改笔法，宁可画砸也不认'],
        ['面对官身','沉默顺从，把反对意见留到事后独自消化'],
        ['被人道谢','转身就走，用忙碌掩饰不自在'],
        ['同伴受伤时','话变多、变硬，用命令口吻掩盖慌张'],
      ],
      firstChapter:'第 3 章 · 夜航船',
      state:'身在夜航船中舱，右手虎口被舱门夹伤，用布条缠着。\n\n随身：旧画残卷、半锭碎银、师娘留下的一方端砚。\n\n**知识边界**：尚不知道老沈木匣里就是画案的另一半卷宗，也不知道凤瑶认得他的画风。目前认定的追查者仍是漕运司。',
      relations:{
        characters:[['同行','凤瑶','认得他的画风（他不知道）'],['同行','老沈','木匣里是另一半卷宗'],['亡父','周文简','旧画案主犯']],
        factions:[['成员','松江画行'],['敌对','漕运司']],
        skills:[['已精通','摹古'],['已学会','装裱'],['学习中','刻印'],['创造者','靛青调法']],
        items:[['持有者','旧画残卷'],['持有者','师娘的端砚']],
      },
    },
    rel:['ch2','ch3'] },
  { id:'ch2', name:'凤瑶', role:'重要 · 逃婚小姐', tint:'#6E5868', tag:'伏笔人物',
    one:'女扮男装逃婚的官家小姐，唇线与指甲是她身份的破绽。',
    fields:[['身份','苏州府官家小姐'],['年龄','19'],['动机','逃离指婚，寻自由'],['弧光','由伪装 → 显露']],
    rel:['ch1'] },
  { id:'ch3', name:'老沈', role:'重要 · 旧官', tint:'#4A5468', tag:'伏笔人物',
    one:'前苏州府同知，怀抱一只嵌银线的乌木匣，失意写在脸上。',
    fields:[['身份','前苏州府同知'],['年龄','58'],['动机','护住木匣中的秘密'],['弧光','由紧守 → 托付']],
    rel:['ch1'] },
  { id:'ch4', name:'船家', role:'配角', tint:'#4E7F6E', tag:'',
    one:'操着江浙口音的撑船人，见惯了夜航船上各怀心事的客人。',
    fields:[['身份','夜航船船家'],['动机','安然抵岸，多得几文']],
    rel:[] },
];

/* 设定条目 */
const WORLD = [
  { id:'w1', icon:'compass', name:'明末江南漕运图', cat:'地理', tint:'#56708A',
    desc:'从苏州到松江府的水路网络，夜航船循运河逆流而上，沿途盐铜两税关卡密布。' },
  { id:'w2', icon:'mountains', name:'苏州城地理', cat:'地理', tint:'#4E7F6E',
    desc:'阊门、平江路、城南水巷；故事开场的码头位于城西夜泊处。' },
  { id:'w3', icon:'scroll', name:'旧画案始末', cat:'历史', tint:'#2D3A36',
    desc:'十年前一桩涉及官库藏画失窃的旧案，牵连数名画师，周清远名列其中。' },
  { id:'w4', icon:'scales', name:'盐铜两税制度', cat:'制度', tint:'#6E5868',
    desc:'明末江南盐铜专卖与税关设置，决定了夜航船的航线与停靠节点。' },
];

/* 伏笔台账 */
const FORESHADOW = [
  { id:'f1', name:'老沈的乌木匣', status:'open', plant:'第 03 章', payoff:'第 06 章（计划）',
    note:'匣盖嵌银线，「银线那一面永远朝着他自己」。第六章揭开，此处只交代朝向。' },
  { id:'f2', name:'凤瑶的女装破绽', status:'open', plant:'第 03 章', payoff:'未定',
    note:'目前仅靠指甲与唇线两个细节透露，建议在对白节奏上再留一处破绽。' },
  { id:'f3', name:'油纸伞柄上的名字', status:'open', plant:'第 03 章', payoff:'第 04 章',
    note:'周清远自刻其名于伞柄，今晚不愿被任何人看见——身份伏笔。' },
  { id:'f4', name:'船头那盏不灭的灯', status:'closed', plant:'第 02 章', payoff:'第 02 章',
    note:'已在本章内自洽回收，作为夜航船的固定意象。' },
];

/* 图鉴：物品 / 势力 / 生物 / 技能；素材仍是独立创作资源。 */
const ITEMS = [
  { id:'it1', name:'乌木银线匣', tint:'#4A5468', sub:'关键物品', desc:'老沈怀抱之物，盖嵌一道磨旧的银线。' },
  { id:'it2', name:'油纸伞', tint:'#2D3A36', sub:'随身', desc:'周清远的伞，柄上自刻其名。' },
  { id:'it3', name:'三盏小油灯', tint:'#8C98B0', sub:'场景', desc:'船舱低梁下的灯，把每张脸照成半张。' },
];
const FACTIONS = [
  { id:'fa1', name:'苏州府衙', tint:'#56708A', sub:'官方', desc:'追查旧画案的官署，老沈的前东家。' },
  { id:'fa2', name:'松江画社', tint:'#4E7F6E', sub:'民间', desc:'周清远旧时所属的画师同人。' },
];
const CREATURES = [
  { id:'cr1', name:'夜航船', tint:'#5C6B7E', sub:'载具/意象', desc:'逆流而上的客船，故事的舞台与隐喻。' },
];
const COMPENDIUM_SKILLS = [
  { id:'cs1', name:'摹古', tint:'#4A5D7A', sub:'技艺', desc:'依笔触、纸性与旧痕复原前人画法，周清远最擅长的本事。' },
  { id:'cs2', name:'装裱', tint:'#2D3A36', sub:'手艺', desc:'托心、覆背、砑装成卷，也能从装裱层次辨认画作年代。' },
  { id:'cs3', name:'刻印', tint:'#34465A', sub:'技艺', desc:'老沈传下的篆刻手法，刀路克制，落款常藏一处断笔。' },
];
const MATERIALS = [
  { id:'ma1', name:'明末漕运参考', icon:'file', sub:'文本 · 1.2k 字' },
  { id:'ma2', name:'宋元山水画集', icon:'file', sub:'文本 · 860 字' },
  { id:'ma3', name:'江浙方言语料', icon:'file', sub:'文本 · 1.2k 字' },
];

/* 实体关系图 — 节点 + 关系（用于 Workspace 的「实体关系图」屏） */
const GRAPH = {
  nodes:[
    {id:'ch1', label:'周清远', kind:'character', x:50, y:34, r:30, tint:'#2D3A36'},
    {id:'ch2', label:'凤瑶',   kind:'character', x:22, y:62, r:24, tint:'#6E5868'},
    {id:'ch3', label:'老沈',   kind:'character', x:78, y:62, r:24, tint:'#4A5468'},
    {id:'it1', label:'乌木匣', kind:'item',      x:80, y:24, r:18, tint:'#4A5468'},
    {id:'fa1', label:'苏州府衙', kind:'faction',  x:50, y:84, r:20, tint:'#56708A'},
    {id:'w3',  label:'旧画案',  kind:'lore',      x:20, y:30, r:18, tint:'#2D3A36'},
  ],
  edges:[
    {a:'ch1', b:'ch2', label:'同舱'},
    {a:'ch1', b:'ch3', label:'对坐'},
    {a:'ch3', b:'it1', label:'持有'},
    {a:'ch3', b:'fa1', label:'旧属'},
    {a:'ch1', b:'w3',  label:'牵连'},
    {a:'ch2', b:'fa1', label:'逃离'},
  ],
};

const KIND_META = {
  character:{label:'人物', icon:'user'},
  item:{label:'物品', icon:'diamond'},
  faction:{label:'势力', icon:'shield'},
  lore:{label:'设定', icon:'scroll'},
};

/* 作品内的「世界观 / 创作」分区入口 */
const SECTIONS = [
  {k:'chapters', label:'章节', icon:'books', count:6, group:'创作'},
  {k:'outline', label:'大纲', icon:'list', count:6, group:'创作'},
  {k:'characters', label:'人物', icon:'users', count:4, group:'创作'},
  {k:'foreshadow', label:'伏笔', icon:'flag', count:4, group:'创作'},
  {k:'graph', label:'实体关系图', icon:'hub', count:6, group:'世界观'},
  {k:'world', label:'设定', icon:'globe', count:4, group:'世界观'},
  {k:'map', label:'地图', icon:'map', count:1, group:'世界观'},
  {k:'factions', label:'势力', icon:'shield', count:2, group:'世界观'},
  {k:'creatures', label:'生物', icon:'leaf', count:1, group:'世界观'},
  {k:'items', label:'物品', icon:'diamond', count:3, group:'世界观'},
  {k:'materials', label:'素材', icon:'folder', count:3, group:'资料'},
];

/* AI — 智能体 / 子智能体 / 技能 / 提示词 / 快捷方式 / 会话 / 模式 */
const PRIMARY_AGENT = { name:'主笔', en:'Primary writing agent', icon:'pencil' };

const SUBAGENTS = [
  { id:'s1', slug:'plot-architect', name:'情节顾问', emoji:'🗺️', mode:'council', model:'mimo-v2.5 · 默认',
    enabled:true, builtin:true, useCustom:false,
    desc:'在议会模式中担任结构顾问，负责梳理主线、副线与转折节奏，指出大纲中悬而未决的伏笔与动机断层。',
    prompt:'你是一名长篇小说的情节顾问，专注结构而非文笔。\n\n职责：\n- 梳理主线 / 副线，标出每个转折的因果链；\n- 指出未回收的伏笔、动机断层、节奏塌陷；\n- 给出可执行的结构调整建议，而非替作者写句子。\n\n输出时先给三句话结论，再逐条展开。' },
  { id:'s2', slug:'character-voice', name:'人物声音', emoji:'🎭', mode:'chat', model:'mimo-v2.5 · 默认',
    enabled:true, builtin:false, useCustom:true,
    desc:'守护每个角色的语气一致性，根据人物档案校验对白是否符合身份、年龄与处境。',
    prompt:'你负责守护角色的「声音」一致性。\n\n给定一段对白与对应的人物档案，判断：\n- 用词、句长、语气是否符合身份与年龄；\n- 是否出现了角色不会知道的信息；\n- 情绪强度是否与当前处境匹配。\n\n只在确有偏离时提出修改，逐句给出替换建议。' },
  { id:'s3', slug:'worldbuilding-check', name:'世界观考据', emoji:'🧭', mode:'chat', model:null,
    enabled:false, builtin:false, useCustom:true,
    desc:'对照世界观设定与历史背景，核查正文中的地理、器物、制度、时间线是否前后自洽。',
    prompt:'你是世界观考据助手。对照已建立的世界设定，核查正文中的：\n- 地理与路线是否自洽；\n- 器物、服饰、制度是否符合设定年代；\n- 时间线与既有章节是否冲突。\n\n发现冲突时，引用设定原文与正文原文并列指出。' },
];

const SKILLS = [
  { id:'sk1', name:'章节扩写', en:'Chapter expansion', enabled:true, builtin:true,
    when:'当一章只有大纲或寥寥数段，需要在保持既定情节节点的前提下扩展为完整初稿时使用。',
    desc:'把章节大纲扩写为符合既定节奏与人物声音的完整初稿。',
    prompt:'根据提供的章节大纲、人物档案与世界观设定，扩写为完整章节初稿。\n\n要求：\n- 严格遵守大纲中的情节节点，不擅自新增重大转折；\n- 维持已有的叙事人称与语气；\n- 对白与描写交替，避免大段独白。' },
  { id:'sk2', name:'润色重写', en:'Polish & rewrite', enabled:true, builtin:false,
    when:'初稿已完成、情节无需改动，只需打磨语言节奏、消除重复与口水句时使用。',
    desc:'在不改动情节的前提下打磨语言：节奏、重复、冗词、标点。',
    prompt:'对给定段落做语言润色，不改变情节与信息：\n- 消除重复用词与口水句；\n- 调整句子长短，制造节奏；\n- 规范标点与对白格式。\n\n保留作者原有的措辞风格，改动以最小为度。' },
  { id:'sk3', name:'伏笔检查', en:'Foreshadowing audit', enabled:true, builtin:false,
    when:'完成一卷或多章后，需要检查埋下的伏笔是否回收、是否过早暴露时使用。',
    desc:'梳理全书已埋伏笔与其回收状态，标出悬而未决或暴露过早的线索。',
    prompt:'通读提供的章节，建立伏笔台账：\n- 每条伏笔的埋设位置与预期回收点；\n- 标出尚未回收、回收过早或自相矛盾的线索；\n- 给出建议的回收章节。' },
];

const SHORTCUTS = [
  {id:'sc1', name:'扩写', en:'Expand', icon:'arrows-out', builtin:true},
  {id:'sc2', name:'润色', en:'Polish', icon:'spark', builtin:true},
  {id:'sc3', name:'续写', en:'Continue', icon:'arrow-r', builtin:true},
];

const SESSIONS = [
  {id:'r1', title:'第三章·夜遇', time:'今天 14:20', preview:'三个身份伏笔不要一口气交代完…'},
  {id:'r2', title:'周清远的视角校验', time:'昨天', preview:'确认画师身份未被明说…'},
  {id:'r3', title:'明末江南漕运背景', time:'3 天前', preview:'盐铜两税关卡的设置…'},
];

/* AI 模式 — 圆桌会议 / 独白 / 小剧场 / 角色扮演 */
const AI_MODES = [
  {k:'chat', label:'对话', icon:'chat', desc:'与主笔一对一协作，最常用的写作助手模式。', tint:'var(--accent)'},
  {k:'council', label:'圆桌会议', icon:'users3', desc:'多个子智能体围绕同一议题各抒己见，主笔汇总成结论。', tint:'var(--info)',
    members:['情节顾问','人物声音','世界观考据']},
  {k:'monologue', label:'独白', icon:'user', desc:'让某个角色以第一人称自述，挖掘其内心动机与声音。', tint:'#6E5868',
    members:['周清远']},
  {k:'theater', label:'小剧场', icon:'mask', desc:'指定多个角色即兴演一场戏，用于试探对白与冲突。', tint:'#4E7F6E',
    members:['周清远','凤瑶','老沈']},
  {k:'roleplay', label:'角色扮演', icon:'chatcircle', desc:'你扮演一个角色，与 AI 扮演的角色对戏。', tint:'var(--accent-warm)',
    members:['凤瑶']},
];

/* 聊天消息 / 智能体任务轨迹（agent trace） */
const CHAT_MSGS = [
  {role:'user', content:'我希望第三章的开头能更含蓄一些，三个人的身份伏笔不要一口气全部交代完。'},
  {role:'ai', content:'理解。我把目前第一段拆成两段，并把「老沈的木匣」这条线推迟到周清远第二次抬头之后——也就是第六、第七段之间。这样三个人的身份分别落在三个独立的呼吸节奏里，不会像点名一样依次出场。',
    ref:'对照参考：人物档案 / 周清远、凤瑶、老沈'},
  {role:'user', content:'好。把改稿放进编辑器，但保留我原来的版本作为对照。'},
];

const AGENT_TRACE = [
  {kind:'section', icon:'checks', title:'任务列表', progress:'3/3', done:true},
  {kind:'task', icon:'search', title:'读取章节', sub:'chapters / 第 03 章 · 三舱客', state:'已完成'},
  {kind:'reasoning'},
  {kind:'task', icon:'file', title:'生成改稿', sub:'拆分首段，推迟木匣线索', state:'已完成'},
  {kind:'reasoning'},
  {kind:'task', icon:'send', title:'委派任务', sub:'委派给 · 人物声音（校验对白）', state:'已完成'},
];

/* 设置 — 提供商 / 主题 / 背景 */
const PROVIDERS = [
  {name:'自定义供应商', model:'mimo-v2.5', state:'已连接', kind:'ok'},
  {name:'Anthropic', model:'Claude Opus 4.8', state:'已连接', kind:'ok'},
  {name:'OpenAI', model:'GPT-4o', state:'已连接', kind:'ok'},
  {name:'Google', model:'Gemini 1.5 Pro', state:'未配置密钥', kind:'warn'},
  {name:'本地 · Ollama', model:'Qwen2.5 32B', state:'已连接', kind:'ok'},
];

/* 添加自定义提供商的可选类型 — 对齐 aiProviderTypeConfigs（移动端不提供 Codex）。
   kinds = 可用能力，fixed = 固定地址。 */
const PROVIDER_KIND_LABELS = {chat:'对话', image:'图片', video:'视频', audio:'音频'};
const PROVIDER_TYPES = [
  {key:'openai_compatible', name:'OpenAI 兼容', kinds:['chat','image'], note:'大多数中转站与自部署服务'},
  {key:'anthropic', name:'Anthropic', kinds:['chat']},
  {key:'gemini', name:'Gemini', kinds:['chat','image']},
  {key:'openai', name:'OpenAI', kinds:['chat','image']},
  {key:'minimax', name:'MiniMax', kinds:['video','audio'], note:'兼容 MiniMax 格式的视频接口（如 H3）'},
  {key:'doubao', name:'Doubao', kinds:['chat','image','video'], note:'兼容方舟格式的视频接口（如 Seedance）'},
  {key:'qwen', name:'Qwen', kinds:['chat','image','video','audio'], baseUrl:'https://maas.qianwenaiapi.com/compatible-mode/v1'},
  {key:'agnes', name:'Agnes', kinds:['image','video'], baseUrl:'https://apihub.agnes-ai.com/v1'},
  {key:'xai', name:'xAI', kinds:['chat','image']},
  {key:'deepseek', name:'DeepSeek', kinds:['chat']},
  {key:'moonshot', name:'Moonshot', kinds:['chat']},
  {key:'zhipu', name:'Zhipu', kinds:['chat']},
  {key:'openrouter', name:'OpenRouter', kinds:['chat','image','video','audio'], fixed:true, baseUrl:'https://openrouter.ai/api/v1'},
  {key:'api88', name:'88API', kinds:['chat','image','video','audio'], fixed:true, baseUrl:'https://api.88api.ai/v1'},
  {key:'atlascloud', name:'AtlasCloud', kinds:['chat','image','video','audio'], fixed:true, baseUrl:'https://api.atlascloud.ai/v1'},
  {key:'volcengine', name:'火山引擎', kinds:['chat','image','video','audio'], fixed:true, baseUrl:'https://ark.cn-beijing.volces.com/api/v3'},
  {key:'metaso', name:'秘塔科技', kinds:['video'], fixed:true, baseUrl:'https://metaso.cn/api/minimax'},
];

/* 主题色板 — 对齐 lib/shared/widgets/settings/appearance_settings_section.dart 的 AppTheme。
   数据来自 ../theme.js（RevericTheme.PALETTES），切换后由 ../themes.css 的 token 生效。 */
const THEMES = window.RevericTheme.PALETTES;

/* 顺序与文案对齐 Flutter AppThemeMode：浅色 / 深色 / 跟随系统 */
const THEME_MODES = window.RevericTheme.MODES.map(m=>({
  ...m, icon:{light:'sun', dark:'moon', system:'target'}[m.key],
}));

/* 小说级智能体规则 — 存于每本作品的 NovelContentDatabase（对齐 AgentRules 表） */
const NOVEL_AGENT_RULES = [
  { id:'ar1', name:'文风约束', enabled:true,
    content:'正文以白描为主，少用形容词堆叠；对白不带「说道」之外的提示语；环境描写每个场景不超过三句。' },
  { id:'ar2', name:'人称与视角', enabled:true,
    content:'全书采用有限第三人称，视角随章节切换但不在一章内跳换；不得出现上帝视角的全知交代。' },
  { id:'ar3', name:'历史考据底线', enabled:false,
    content:'涉及明末制度、官制、漕运术语时，必须对照世界观设定，不得出现清代以后才有的器物与称谓。' },
];

/* 小说级智能体技能 — 全局库中 scope=novel、novelId=本作品（对齐 AgentSkills 表） */
const NOVEL_AGENT_SKILLS = [
  { id:'nsk1', name:'漕运术语校对', enabled:true,
    when:'当正文出现漕运、钞关、船埠相关描写，需要核对术语是否符合明末设定时使用。',
    desc:'校验正文中的漕运术语与制度描写，标出时代错位之处。',
    prompt:'通读正文，逐句检查漕运相关术语：\n- 钞关、船埠、漕船、粮长等称谓是否符合作者设定的年代；\n- 计量单位与税制是否错位；\n- 列出可疑之处并给出替换建议。' },
  { id:'nsk2', name:'江南风物补笔', enabled:true,
    when:'当场景设定在苏州、松江一带，需要补入风物细节以增强真实感时使用。',
    desc:'为江南场景补入时令、物候、街巷与器物细节。',
    prompt:'给定一个场景，结合明末江南背景，补充：\n- 时令物候与天气；\n- 街巷、桥埠、舟船的细节；\n- 饮食、器物、服饰的地域特征。\n不喧宾夺主，服务于人物与情节。' },
];

const LANGUAGES = [
  {k:'zh', label:'中文简体', sub:'Chinese (Simplified)'},
  {k:'en', label:'English', sub:'英语'},
];

/* ============================================================
   详情页扩展字段 — 为 designs/mobile 各内容详情页补充
   结构化字段（fields）、正文（body）、出现章节（appearsIn）、
   交叉引用（related: {kind,id}）。内容沿用「夜航船」既有设定，
   按 id 合并进上面的实体数组，不改写原数组结构。
   kind: character | world | item | faction | creature | foreshadow | location | chapter
   ============================================================ */
const ENTITY_DETAIL = {
  /* 设定 */
  w1:{ fields:[['类别','地理 · 水路']],
    appearsIn:['c1','c3'], related:[{kind:'faction',id:'fa1'},{kind:'location',id:'lo2'}],
    body:['夜航船循运河自苏州逆流而上，经吴江、平望、嘉兴，最终抵松江府。',
      '沿途盐、铜两税关卡密布，钞关查验严苛。夜行可避白日的盘问——这也是三舱客都选在入夜登船的缘由。'] },
  w2:{ fields:[['类别','地理 · 城邑']],
    appearsIn:['c1'], related:[{kind:'location',id:'lo1'},{kind:'location',id:'lo2'}],
    body:['阊门为水陆要冲，平江路沿河而市；城南水巷错落，舟楫往来。',
      '开场的码头在城西夜泊处，僻静而少灯，正合避人耳目。'] },
  w3:{ fields:[['类别','历史 · 旧案']],
    appearsIn:['c3'], related:[{kind:'character',id:'ch1'},{kind:'item',id:'it1'}],
    body:['十年前，官库藏画失窃，案涉数名供奉画师。',
      '周清远名列其中，虽未定罪，却从此隐名，避居松江。木匣中那道银线，或与此案的最后一幅画有关。'] },
  w4:{ fields:[['类别','制度 · 赋税']],
    appearsIn:['c1','c3'], related:[{kind:'faction',id:'fa1'},{kind:'world',id:'w1'}],
    body:['明末江南行盐铜专卖，税关沿运河设置，决定了客船的航线与停靠节点。',
      '夜航船刻意错开白日的钞关查验，停靠点也多在两关之间的僻处。'] },
  /* 物品 */
  it1:{ fields:[['类型','关键物品']],
    appearsIn:['c3'], related:[{kind:'character',id:'ch3'},{kind:'foreshadow',id:'f1'},{kind:'world',id:'w3'}],
    body:['盖上嵌一道磨旧的银线，「银线那一面，永远朝着他自己」。',
      '此物是第六章揭晓的核心，眼下只交代朝向，不写来历。'] },
  it2:{ fields:[['类型','随身']],
    appearsIn:['c3'], related:[{kind:'character',id:'ch1'},{kind:'foreshadow',id:'f3'}],
    body:['柄上自刻其名，是周清远的旧习。今晚他不愿被任何人看见这个名字。'] },
  it3:{ fields:[['类型','场景道具']],
    appearsIn:['c3'], related:[{kind:'creature',id:'cr1'}],
    body:['船舱低梁下的三盏灯，把每一张脸都照成半张——半明半暗，恰是三舱客的写照。'] },
  /* 势力 */
  fa1:{ fields:[['类型','官方'],['立场','追查旧画案']],
    appearsIn:[], related:[{kind:'character',id:'ch3'},{kind:'character',id:'ch2'},{kind:'world',id:'w3'}],
    body:['追查旧画案的官署，也是老沈的前东家。','凤瑶逃离的指婚，亦与府衙中人相关。'] },
  fa2:{ fields:[['类型','民间'],['关涉','周清远旧属']],
    appearsIn:[], related:[{kind:'character',id:'ch1'}],
    body:['周清远旧时所属的画师同人，松江一带小有声名。'] },
  /* 生物 */
  cr1:{ fields:[['类型','载具 / 意象']],
    appearsIn:['c1','c2','c3'], related:[{kind:'foreshadow',id:'f4'},{kind:'item',id:'it3'}],
    body:['逆流而上的客船，是故事的舞台，也是「各怀心事、共渡一夜」的隐喻。','船头那盏不灭的灯，是它固定的意象。'] },
  /* 伏笔（setup/payoff 正文 + related） */
  f1:{ related:[{kind:'item',id:'it1'},{kind:'character',id:'ch3'}],
    setupText:'第三章，老沈抱匣入舱，匣盖银线「永远朝着他自己」。此处只写朝向，不交代来历。',
    payoffText:'计划在第六章揭匣，银线的指向与旧画案的最后一幅画相互印证，回收老沈这条线。' },
  f2:{ related:[{kind:'character',id:'ch2'}],
    setupText:'指甲与唇线两处细节，在第三章透露凤瑶的女子身份。',
    payoffText:'尚未确定回收点。建议在对白节奏上再留一处破绽，避免后续反转显得突兀。' },
  f3:{ related:[{kind:'item',id:'it2'},{kind:'character',id:'ch1'}],
    setupText:'周清远自刻其名于伞柄，今晚不愿被任何人看见。',
    payoffText:'第四章，伞柄上的名字被人窥见，周清远的身份伏笔收束。' },
  f4:{ related:[{kind:'creature',id:'cr1'}],
    setupText:'第二章，船头一灯彻夜不灭。',
    payoffText:'同章内自洽回收，确立为夜航船的固定意象。' },
};
[...WORLD, ...ITEMS, ...FACTIONS, ...CREATURES, ...FORESHADOW].forEach(e=>{
  if(ENTITY_DETAIL[e.id]) Object.assign(e, ENTITY_DETAIL[e.id]);
});

/* 大纲 — 作品级条目（OutlineDraft）：每条含状态 + 正文 + 节奏点(beats)时间线。
   对齐 lib/shared/models/outline.dart：status ∈ in_progress/finished/pending，
   beat 含 status + chapterCount（计划章数）。大纲是整部作品/卷级，而非单章。 */
const OUTLINE_STATUS = {
  in_progress:{label:'进行中', hex:'var(--accent)'},
  finished:   {label:'已完成', hex:'var(--accent-warm)'},
  pending:    {label:'待展开', hex:'var(--warning-text)'},
};
const OUTLINES = [
  { id:'ol_main', title:'全书主线 · 夜航一程', status:'in_progress',
    content:'一艘逆流而上的夜航船，载着三个各怀心事的客人共渡一夜。主线沿「上船 → 交错 → 揭破 → 天亮」四段推进，每个人的秘密在抵达松江府前后陆续揭开。',
    beats:[
      {id:'b1', title:'三客登船', status:'finished',    chapterCount:2, content:'画师、逃婚小姐、旧官在城西夜泊处先后登船，身份各自隐藏。'},
      {id:'b2', title:'舱中交错', status:'in_progress', chapterCount:2, content:'三人目光在舱中交错，木匣、女装、伞柄名字三条伏笔同场埋下。'},
      {id:'b3', title:'秘密揭破', status:'pending',     chapterCount:3, content:'木匣银线与旧画案相互印证，凤瑶身份逐步显露。'},
      {id:'b4', title:'天亮靠岸', status:'pending',     chapterCount:2, content:'船抵松江府，各人去向分明，留一处余韵收束全书。'},
    ] },
  { id:'ol_v1', title:'卷一 · 河上人', status:'in_progress',
    content:'卷一聚焦「上船」与初次交错：建立夜航船意象，三舱客同场登场，埋下三条身份伏笔。',
    beats:[
      {id:'b5', title:'夜入吴县',   status:'finished',    chapterCount:1, content:'周清远入夜抵码头，避开钞关登船。'},
      {id:'b6', title:'船头那盏灯', status:'finished',    chapterCount:1, content:'离岸夜行，确立船头不灭灯的意象。'},
      {id:'b7', title:'三舱客',     status:'in_progress', chapterCount:1, content:'三人同舱，木匣、女装、伞柄名字伏笔同场埋下。'},
      {id:'b8', title:'周清远',     status:'pending',     chapterCount:1, content:'转入画师视角，回溯旧画案的牵连。'},
    ] },
  { id:'ol_v2', title:'卷二 · 雨中人', status:'pending',
    content:'卷二在雨夜推进副线，凤瑶与老沈的过往逐步浮现，主线伏笔开始收束。',
    beats:[
      {id:'b9',  title:'夜雨',       status:'pending', chapterCount:2, content:'雨夜独处，凤瑶的来历透露一角。'},
      {id:'b10', title:'未署名的信', status:'pending', chapterCount:2, content:'一封信牵出老沈与府衙的旧账。'},
    ] },
];

/* 地图地点（与 MapBody 的针位对齐，x/y 为百分比坐标） */
const LOCATIONS = [
  { id:'lo1', name:'阊门', region:'苏州 · 城西', x:32, y:28, appearsIn:['c1'],
    related:[{kind:'world',id:'w2'}],
    desc:'水陆要冲，舟楫汇集；夜航船的旅客多由此入城，白日里最是喧闹。' },
  { id:'lo2', name:'夜泊处', region:'苏州 · 城西河湾', x:50, y:52, appearsIn:['c1','c3'],
    related:[{kind:'world',id:'w2'},{kind:'creature',id:'cr1'}],
    desc:'僻静少灯的码头，三舱客在此登船。故事开场之地，也是全书第一盏灯亮起的地方。',
    photos:[{tint:'#5E6E7D', name:'河湾夜色'}, {tint:'#7D8A85', name:'旧码头'}, {tint:'#5A7A6E', name:''}] },
  { id:'lo3', name:'平江路', region:'苏州 · 城内', x:68, y:38, appearsIn:[],
    related:[{kind:'world',id:'w2'}],
    desc:'沿河而市的老街，白日喧闹，入夜渐静；河水把两岸的灯影揉成一片。' },
  { id:'lo4', name:'松江府', region:'终点', x:74, y:76, appearsIn:[],
    related:[{kind:'character',id:'ch1'},{kind:'world',id:'w1'}],
    desc:'夜航船此行的终点，周清远的避居之所。隔着一夜的水路，像一桩迟迟不肯天亮的心事。' },
];

/* 素材详情扩展 */
const MATERIAL_DETAIL = {
  ma1:{ type:'文本', source:'外部资料整理',
    desc:'明末运河漕运的航线、关卡与税制汇编，是世界观「漕运图」与「盐铜两税」两条设定的主要依据。',
    excerpt:'……自苏州出阊门，循运河南下，经吴江、平望，至嘉兴分水，盐铜两税各设钞关查验……',
    usedIn:[{kind:'world',id:'w1'},{kind:'world',id:'w4'}] },
  ma2:{ type:'文本', source:'图片素材笔记',
    desc:'宋元山水画二十四帧，用于旧画案与画师身份的视觉参照，也为环境白描提供笔意。',
    excerpt:null,
    usedIn:[{kind:'world',id:'w3'},{kind:'character',id:'ch1'}] },
  ma3:{ type:'笔记', source:'手记',
    desc:'船家及苏松一带人物对白的方言用词与口吻参考，避免对白失了地域味道。',
    excerpt:'「先生，您是要去松江府的，是吧？」——带江浙口音的拐弯，句尾微微上挑。',
    usedIn:[{kind:'character',id:'ch4'}] },
};
MATERIALS.forEach(m=>{ if(MATERIAL_DETAIL[m.id]) Object.assign(m, MATERIAL_DETAIL[m.id]); });

const fmt = (n)=> n>=1e6 ? (n/1e6).toFixed(1)+'m' : n>=1e3 ? (n/1e3).toFixed(1)+'k' : String(n);

/* 用量统计 */
const USAGE = {
  today:{ total:12480, requests:18, b:{ input:4200, cacheRead:2100, cacheWrite:800, output:5380, reasoning:0 }},
  month:{ total:342600, trend:'12.3%', trendUp:true, avgPerDay:11420,
    b:{ input:128000, cacheRead:64200, cacheWrite:22400, output:118000, reasoning:10000 }},
  records:[
    { time:'今天 14:32', model:'mimo-v2.5', input:2100, output:3280 },
    { time:'今天 11:05', model:'Claude Opus 4.8', input:4600, output:6100 },
    { time:'昨天 22:18', model:'mimo-v2.5', input:1800, output:2400 },
    { time:'昨天 15:40', model:'DeepSeek-V3', input:3200, output:4800 },
    { time:'06/25 09:12', model:'mimo-v2.5', input:800, output:1200 },
  ],
  page:{ current:1, total:4 },
};

Object.assign(window, {
  NOVELS, VOLUMES, STATE_TONE, ACTIVE_CHAPTER,
  CHARACTERS, WORLD, FORESHADOW, ITEMS, FACTIONS, CREATURES, COMPENDIUM_SKILLS, MATERIALS, LOCATIONS,
  OUTLINES, OUTLINE_STATUS,
  GRAPH, KIND_META, SECTIONS,
  PRIMARY_AGENT, SUBAGENTS, SKILLS, SHORTCUTS, SESSIONS, AI_MODES,
  CHAT_MSGS, AGENT_TRACE, PROVIDERS, PROVIDER_TYPES, PROVIDER_KIND_LABELS, THEMES, THEME_MODES, LANGUAGES,
  NOVEL_AGENT_RULES, NOVEL_AGENT_SKILLS,
  fmt, USAGE,
});
