// 职责: 提供短剧制作的内置风格分类、名称与前后提示词。
// 关联文件:
//   lib/shared/models/production/style.dart
import 'style.dart';

// 风格名称与提示词作为同一份创作素材维护，不随界面语言切换。
const _contentScope =
    '风格只约束视觉表现。角色身份、年龄、体型、服装和关键道具以具体内容与对应参考为准；'
    '场景、景别、光源、动作和运镜服从当前镜头要求。';

/// id 是写进剧本 / 节点风格引用的稳定 slug，不能改名或复用。
const productionStylePresetRows =
    <
      ({
        String id,
        ProductionStyleCategory category,
        String name,
        String before,
        String after,
      })
    >[
      (
        id: 'premium-costume-drama',
        category: ProductionStyleCategory.live_action,
        name: '古装偶像剧',
        before:
            '视觉风格：真人古装爱情剧影像，人物妆发精致且各有辨识度，肤色自然通透，保留眼神、唇形与细微表情。以暖白、浅青和淡金形成柔和配色，柔光塑造面部，轻微逆光提亮发丝与衣料边缘；辉光克制，丝绸、纱与金属饰物各有清楚质感，人物与环境层次分明。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'cn-modern-idol-drama',
        category: ProductionStyleCategory.live_action,
        name: '现代偶像剧',
        before:
            '视觉风格：真人现代爱情剧影像，人物造型精致、自然立体，保留各自的骨相、肤质与鲜活神态。色彩明快而协调，肤色温润，环境色适度收敛；柔亮主光配合轻侧光塑造面部，衣料具有清楚的剪裁与材质差异，背景细节有序，呈现亲近、清新的都市生活质感。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'cn-urban-realism',
        category: ProductionStyleCategory.live_action,
        name: '都市生活剧',
        before:
            '视觉风格：真人都市生活剧影像，自然肤色与真实皮肤纹理，中性略暖的克制配色，保留室内外环境的生活细节。光线有明确的环境来源，明暗过渡自然，人物与关键道具清楚可辨；衣料、木材、玻璃各有真实质感，造型整洁程度与生活条件服从人物设定。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'kr-urban-soft-light',
        category: ProductionStyleCategory.live_action,
        name: '韩系都市柔光',
        before:
            '视觉风格：真人都市爱情剧影像，妆发细致，面部轮廓柔和而清晰，保留人物差异与自然肤质。环境以清冷中性色为底，肤色与局部暖光形成温和对比；柔亮面光、轻侧光和克制的发丝轮廓光突出神态，背景虚化柔和，画面精致、浪漫而不泛白。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'jp-youth-film',
        category: ProductionStyleCategory.live_action,
        name: '日系青春胶片',
        before:
            '视觉风格：真人青春电影影像，自然清透的肤色，浅蓝、柔灰与淡绿的轻盈配色，细腻胶片颗粒与柔和高光。自然光保留空气感，逆光仅形成轻微光晕，暗部有层次；人物表情与衣物细节清晰，构图有呼吸感，呈现温柔、含蓄的青春气息。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'us-idol-drama',
        category: ProductionStyleCategory.live_action,
        name: '欧美青春剧',
        before:
            '视觉风格：真人欧美青春剧影像，人物面部有自然立体感，造型鲜明但保留各自年龄、肤色和骨相。明快色块搭配自然肤色，有方向的主光与适度冷暖对比塑造体积；发型、妆面和衣料细节清楚，画面鲜活、时髦，人物情绪易于辨认。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'palace-intrigue-cold',
        category: ProductionStyleCategory.live_action,
        name: '宫廷权谋剧',
        before:
            '视觉风格：真人古装权谋影像，低饱和金棕、暗红、冷灰与深木色形成庄重配色，构图强调空间秩序和人物之间的距离。侧光与局部暖光塑造面部和织物层次，阴影深而有细节；眼神、手部与关键物件可辨，服饰的剪裁、面料和做工体现各自身份。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'wuxia-realist-photo',
        category: ProductionStyleCategory.live_action,
        name: '写实武侠',
        before:
            '视觉风格：真人武侠影像，青灰、墨绿与土黄为基础色，肤色自然，织物、竹木、皮革与金属呈现真实触感。自然侧光和环境阴影塑造空间纵深，人物轮廓清楚；动作发生时保留身体重心、肢体关系和武器轨迹，画面利落、沉着，粗粝程度服从场景。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'eastern-wuxia-poetic',
        category: ProductionStyleCategory.live_action,
        name: '写意武侠',
        before:
            '视觉风格：真人写意武侠影像，以大面积统一主题色与留白组织画面，背景色彩凝练，人物和关键物件通过明度或局部对比突出。构图讲究前后层次与空间韵律，有方向的柔光保留肌肤、织物和金属质感；动作与衣料运动呈现舒展流动的线条，浓丽而克制。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'chinese-supernatural-film',
        category: ProductionStyleCategory.live_action,
        name: '中式志怪电影感',
        before:
            '视觉风格：真人中式志怪影像，以灰青、赭褐、苔绿与米白为基调，暗朱作少量点缀。古画式留白与真实空间结合，旧木、灰墙、棉麻和器物保留细腻触感；柔和侧光与局部幽暗形成含蓄异样感，细微胶片颗粒统一画面，面部、手部与叙事物件保持可辨。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'cn-suspense-cold',
        category: ProductionStyleCategory.live_action,
        name: '现实悬疑',
        before:
            '视觉风格：真人现实悬疑影像，低饱和冷灰与暗绿为环境基调，自然肤色与局部暖光提供视觉焦点。布光有明确来源，侧光、遮挡与有细节的阴影形成紧张感；构图克制，空间关系清楚，人物眼神、手部动作和关键证据保持可辨，材质真实而不过度污损。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'horror-film',
        category: ProductionStyleCategory.live_action,
        name: '惊悚电影',
        before:
            '视觉风格：真人惊悚电影影像，冷灰与暗褐构成克制的环境色，局部光源形成狭窄亮区和层次深的阴影。通过遮挡、负空间和明暗边界制造不安，肤色保持可信，人物表情与关键物件仍可辨；怪异内容由剧情提供，画面质感紧张、冷峻。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'period-rural-drama',
        category: ProductionStyleCategory.live_action,
        name: '年代乡土剧',
        before:
            '视觉风格：真人年代乡土生活剧影像，色彩自然略暖，土色、棉麻和木质呈现朴素的生活触感，保留细腻皮肤纹理。自然光与平实室内光让人物、动作和环境细节清楚可辨；衣物的新旧、做工和整洁程度符合人物处境，以克制的胶片柔和感表达年代气息。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'cn-2000s-tv-drama',
        category: ProductionStyleCategory.live_action,
        name: '千禧年代生活剧',
        before:
            '视觉风格：真人千禧年代都市生活剧影像，色彩自然略暖，布光明亮平实，景深适中，人物与生活环境均可辨认。保留早期电视影像柔和的边缘、轻微视频噪点与温和高光，面部和道具细节清楚；妆发、衣物与场景陈设由具体年代设定决定。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'realist-suspense-cold',
        category: ProductionStyleCategory.live_action,
        name: '末世写实',
        before:
            '视觉风格：真人末世题材影像，去饱和冷灰、土褐与暗绿构成环境基调，局部暖色突出人物和重要物件。光线来自场景中的实际光源，暗部有层次，空间纵深清楚；建筑、装备和衣料的磨损有具体材质依据，人物肤色与身份特征保留，呈现沉重但可信的生存氛围。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'tech-film',
        category: ProductionStyleCategory.live_action,
        name: '写实科幻',
        before:
            '视觉风格：真人写实科幻影像，金属、玻璃、织物和发光表面具有清楚的材质差异。以中性冷色为基础，局部功能光与自然肤色形成对比，反射与阴影方向一致；科技细节简洁有秩序，人物表情和关键操作清晰，具体设备与时代形态服从世界设定。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'retro-war-film',
        category: ProductionStyleCategory.live_action,
        name: '战争电影',
        before:
            '视觉风格：真人战争电影影像，克制的土褐、灰绿和冷灰配色，细腻胶片颗粒与有方向的自然光表现环境压力。保留皮肤、织物、金属和地面的真实质感，明暗对比有力度但动作轮廓与关键物件可辨；装备、服饰与损伤状态服从剧情和时代设定。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'neon-cyber-film',
        category: ProductionStyleCategory.live_action,
        name: '霓虹赛博',
        before:
            '视觉风格：真人赛博朋克影像，深色环境中以有限的青蓝与洋红光形成冷暖分区，发光面、玻璃和金属反射各有层次。面部保留可信肤色和清楚轮廓，辉光集中在实际光源附近；明暗对比鲜明，人物与关键物件易于辨认，科技与城市元素由场景内容决定。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'wong-kar-wai-hk-night',
        category: ProductionStyleCategory.live_action,
        name: '港风霓虹电影',
        before:
            '视觉风格：真人港风复古电影影像，墨绿、暗红与暖琥珀形成情绪化色彩，局部霓虹光与有层次的暗部相互映衬。细腻胶片颗粒、轻微高光晕染和前景遮挡营造疏离感；人物眼神与轮廓清楚，保留肌肤与衣料细节，画面浓郁、含蓄而不失真。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'us-retro-hollywood',
        category: ProductionStyleCategory.live_action,
        name: '复古胶片电影',
        before:
            '视觉风格：真人复古电影影像，温暖钨丝灯色感与橄榄绿、棕红相协调，胶片颗粒细腻，黑位略柔和，高光平顺过渡。面部和织物保留自然纹理，侧前方主光塑造体积，画面沉着、温润；景别与机位服从当前镜头，年代感不依赖模糊和划痕。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'hollywood-bw-film',
        category: ProductionStyleCategory.live_action,
        name: '黑白电影',
        before:
            '视觉风格：真人黑白电影影像，以丰富灰阶区分肤色、衣料和空间，主光与深阴影形成清楚的明暗结构。轮廓光适度分离人物与背景，面部表情、手部和关键道具保留细节；细腻胶片颗粒与克制高光呈现经典黑白摄影质感。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'retro-dv-camcorder',
        category: ProductionStyleCategory.live_action,
        name: '复古家庭录像',
        before:
            '视觉风格：真人家用摄像机影像，适度柔和的边缘、轻微电子噪点、略窄的高光宽容度和自然偏暖色彩。人物面部、动作与重要物件仍清楚，肤质真实，画面具有生活记录的亲近感；手持晃动仅在镜头明确要求时使用。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'guoman-anime',
        category: ProductionStyleCategory.two_d,
        name: '国风二维动画',
        before:
            '视觉风格：国风二维手绘动画，线条清楚且有粗细变化，人物比例稳定，五官简洁但保留眼神和口型表现。赛璐璐色块与少量柔和渐层塑造体积，服装纹样疏密有序，背景使用克制的手绘肌理；角色剪影和配色容易区分，装饰细节服从人物身份。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'jp-flat-illustration',
        category: ProductionStyleCategory.two_d,
        name: '日系赛璐璐动画',
        before:
            '视觉风格：日系二维赛璐璐动画，干净流畅的轮廓线、明确的固有色与简洁硬边阴影，人物比例和五官结构稳定。头发按清楚的发束组织，眼神和口型可辨，背景细节服从主体；色彩明快协调，角色与空间具有清晰的前后层次。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'hq-2d-shonen-action',
        category: ProductionStyleCategory.two_d,
        name: '热血动作漫画',
        before:
            '视觉风格：二维热血动作漫画影像，有力度的轮廓线与利落的收笔，简洁硬边阴影塑造人体和衣褶，明暗对比突出动作剪影。人物骨架和肢体关系清楚，表情有张力；速度线、冲击形状和特效仅随具体动作出现，对话镜头保留清楚的脸部与口型。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'us-dark-noir-illustration',
        category: ProductionStyleCategory.two_d,
        name: '美式黑色漫画',
        before:
            '视觉风格：美式黑色漫画影像，粗细分明的墨线、锐利轮廓和大面积黑色块形成强烈明暗结构。低饱和环境中保留少量强调色，干刷和轻微半调纹理集中于阴影；人物表情、动作与关键物件可辨，画面有犯罪图像小说的紧张感与印刷质感。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'cn-myth-gold-line',
        category: ProductionStyleCategory.two_d,
        name: '神话描金动画',
        before:
            '视觉风格：中国神话二维动画，流畅细线与薄涂色块塑造人物，岩彩般的细微颗粒和克制描金形成装饰感。金线集中于既有服饰和器物的纹样边缘，少量珠光高光提亮焦点；面部、手部与动作轮廓清楚，柔边晕染主要用于环境，神话内容服从剧情。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'eastern-ink-decorative',
        category: ProductionStyleCategory.two_d,
        name: '东方水墨动画',
        before:
            '视觉风格：东方水墨设色动画，以书法式线条、墨色浓淡和克制的传统设色组织形体，留白与虚实层次塑造空间。人物面部、手部和关键道具轮廓稳定清楚，飞白、渗化和晕染主要用于衣料边缘与环境；画面疏密有序，保留宣纸与笔墨的自然质感。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'bw-ink-guohua',
        category: ProductionStyleCategory.two_d,
        name: '黑白水墨动画',
        before:
            '视觉风格：黑白水墨动画，以纸白、淡墨、焦墨构成层次，书法式用笔与适度飞白呈现笔势。人物五官、手部和关键物件有稳定清楚的墨线结构，环境通过留白、墨色渗化与虚实关系表达空间；画面简洁有力度，保持纯黑白灰的视觉体系。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'western-flat-kids-illustration',
        category: ProductionStyleCategory.two_d,
        name: '儿童绘本动画',
        before:
            '视觉风格：二维儿童绘本动画，圆润而不规则的几何轮廓概括形体，角色剪影鲜明，眼睛和嘴部易于辨认。有限的明快柔和配色与平面叠层组织空间，弱化复杂透视，局部手绘线条补充表情；纸面肌理克制，人物与道具保持清楚的色块分离。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'retro-gothic-dark-comic',
        category: ProductionStyleCategory.two_d,
        name: '哥特漫画',
        before:
            '视觉风格：二维哥特漫画，钢笔墨线、尖锐剪影与大面积黑色块形成戏剧性明暗。低饱和底色配少量暗红或冷色点缀，轻微旧纸与套印肌理保留印刷感；人物五官和动作清楚，服饰与建筑只在既有设定上强调装饰轮廓，呈现肃穆、神秘的气质。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'dark-fantasy-concept-art',
        category: ProductionStyleCategory.two_d,
        name: '暗黑厚涂动画',
        before:
            '视觉风格：半写实二维厚涂动画，以清楚的大形体和冷暖色块塑造人物与环境，可见笔触沿体积转折分布。焦点区域精绘，背景适度概括，人物面部、手部与关键物件保持稳定轮廓；暗部有层次，材质粗细有别，呈现沉重的奇幻气氛而不强加具体世界元素。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'bw-comic-book',
        category: ProductionStyleCategory.two_d,
        name: '黑白漫画',
        before:
            '视觉风格：二维黑白漫画影像，富有弹性的粗细变化墨线、清楚轮廓与纤细细节线结合。纯黑、纸白与少量网点灰形成明暗层次，人物五官、口型和肢体关系明确；网点随形体稳定分布，背景适度简化，保持清晰的单色漫画印刷质感。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'showa-anime',
        category: ProductionStyleCategory.two_d,
        name: '复古赛璐璐动画',
        before:
            '视觉风格：复古日系二维赛璐璐动画，手绘线条有轻微粗细变化，人物结构清楚，平涂色块与硬边阴影分区明确。墨蓝、棕红与柔灰等复古色彩保持适度饱和，细腻颗粒和轻微褪色统一画面；面部与动作清晰，保留手绘时代的温度。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'pixel-art',
        category: ProductionStyleCategory.two_d,
        name: '像素动画',
        before:
            '视觉风格：二维复古像素动画，统一像素尺度、有限色板、清楚的阶梯轮廓与有序色块表现体积。角色通过剪影、服装主色和少量稳定特征区分，表情与重要道具在当前景别下可辨；背景细节密度低于主体，保留像素边缘，光影采用色阶变化。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'shadow-puppet-illustration',
        category: ProductionStyleCategory.two_d,
        name: '皮影动画',
        before:
            '视觉风格：二维皮影动画，清楚的侧向剪影、镂空纹样与半透明染色皮革质感，平面叠层呈现前后关系。柔和背光让人物轮廓和道具形状可辨，关节动作体现铰接偶形的节奏；角色身份通过稳定的头饰轮廓、服装纹样和色彩区分。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'semi-real-cg',
        category: ProductionStyleCategory.three_d,
        name: '半写实 CG 动画',
        before:
            '视觉风格：半写实三维动画，人物在真实比例上适度美型化，保留各自骨相、年龄和体型。皮肤具有细微纹理和自然次表面散射，发丝分束清楚，织物与金属各有真实反射；柔和主光与克制轮廓光塑造体积，暗部有层次，眼神、口型与表情细节清晰。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'guoman-3d-hd',
        category: ProductionStyleCategory.three_d,
        name: '国风三维动画',
        before:
            '视觉风格：国风三维动画，人物比例修长但结构可信，五官与发型各有辨识度，服装剪裁和纹样符合设定。皮肤光泽柔和，织物褶皱、发束与器物材质清楚；环境光与有方向的主光塑造层次，特效和辉光集中于剧情要求的区域，保留表情与动作轮廓。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'pixar-3d-cartoon',
        category: ProductionStyleCategory.three_d,
        name: '三维卡通动画',
        before:
            '视觉风格：三维卡通动画，圆润的大形体与适度夸张的比例构成鲜明剪影，五官简洁且富有表情变化。材质经过概括，皮肤和织物保持柔和触感，光影具有连续的三维体积；配色明快协调，人物与背景层次清楚，眼神、口型与肢体动作易于辨认。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'anime-toon-shading',
        category: ProductionStyleCategory.three_d,
        name: '三渲二动画',
        before:
            '视觉风格：三维建模结合二维赛璐璐着色的动画影像，人物体积和比例稳定，轮廓线清楚，明暗以少量硬边色块分区。材质反射适度简化，发束和衣褶保持明确结构，眼神与口型可辨；画面具有二维动画的平涂观感与一致的三维空间关系。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'western-surreal-game-cg',
        category: ProductionStyleCategory.three_d,
        name: '写实游戏 CG',
        before:
            '视觉风格：写实三维游戏过场影像，人物结构可信、面部保留个体差异，皮肤、发丝、织物、皮革和金属具有清楚材质层次。光源、反射与阴影方向一致，局部轮廓光突出主体；色彩克制，面部表情和动作清晰，奇幻或科技元素由世界设定决定。\n\n具体内容：',
        after: _contentScope,
      ),
      (
        id: 'stop-motion',
        category: ProductionStyleCategory.three_d,
        name: '定格偶动画',
        before:
            '视觉风格：手工定格偶动画，人物和道具具有可见的制作痕迹，表面保留粘土、织物或木材等设定材质的细微纹理。造型概括而剪影鲜明，实际布景般的光影塑造体积；运动采用逐格摆拍的节奏，角色面部、服装轮廓和材质在连续画面中保持一致。\n\n具体内容：',
        after: _contentScope,
      ),
    ];
