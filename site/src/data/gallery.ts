export const GAL_CDN = 'https://gallery.reveric.app/showcase';

export interface GalleryWork {
  slug: string;
  video: string;
  poster: string;
  thumb: string;
  thumbAlt: string;
  board: string;
  boardAlt: string;
  boardTab: string;
  note: string;
  boardNote: string;
  kicker: string;
  title: string;
  desc: string;
  nodes: string;
  assets: string;
  duration: string;
  durCode: string;
  cardBadge: string;
  cardSummary: string;
}

export const GALLERY_WORKS: GalleryWork[] = [
  {
    slug: 'duantianhe',
    video: `${GAL_CDN}/duantianhe.mp4`,
    poster: `${GAL_CDN}/duantianhe_poster.webp`,
    thumb: `${GAL_CDN}/duantianhe_thumb.webp`,
    thumbAlt: '《断天河》成片剧照',
    board: `${GAL_CDN}/duantianhe_board.webp`,
    boardAlt: '《断天河》云岫定妆四视图、万妖原全景、影狼妖将与霜鸣剑匣设定',
    boardTab: '角色与设定',
    note: '完整成片 · 720p 在线试映',
    boardNote: '角色四视图 · 场景与道具设定',
    kicker: '01 · 仙侠动作短片',
    title: '断天河',
    desc: '一场酣畅淋漓的高速动作打戏：从完整剧本、云岫定妆四视图、万妖原与妖兽设定出发，三段视频直剪出 29 秒成片。',
    nodes: '14',
    assets: '12',
    duration: '29s',
    durCode: '00:29',
    cardBadge: '01 · 仙侠动作',
    cardSummary: '14 节点 · 完整 29s 成片直出',
  },
  {
    slug: 'shuangshu',
    video: `${GAL_CDN}/shuangshu.mp4`,
    poster: `${GAL_CDN}/shuangshu_poster.webp`,
    thumb: `${GAL_CDN}/shuangshu_thumb.webp`,
    thumbAlt: '《双姝之战》成片剧照',
    board: `${GAL_CDN}/shuangshu_board.webp`,
    boardAlt: '《双姝之战》24 节点画布全貌图',
    boardTab: '画布节点图',
    note: '三幕完整成片 · 720p 在线试映',
    boardNote: '24 节点画布全貌 · 剧本 / 定妆 / 三幕连剪',
    kicker: '02 · 奇幻哥特双人打斗',
    title: '双姝之战',
    desc: '月陨圣堂三幕连战：双女主四区定妆、圣堂骑士与石像鬼设定、冷月教堂空场与配乐在画布上连成完整流水线，直剪出 51 秒三幕打戏。',
    nodes: '24',
    assets: '21',
    duration: '51s',
    durCode: '00:51',
    cardBadge: '02 · 奇幻哥特',
    cardSummary: '24 节点 · 三幕连剪完整 51s 成片',
  },
  {
    slug: 'mori',
    video: `${GAL_CDN}/mori.mp4`,
    poster: `${GAL_CDN}/mori_poster.webp`,
    thumb: `${GAL_CDN}/mori_thumb.webp`,
    thumbAlt: '《末日圣母回收指南》成片剧照',
    board: `${GAL_CDN}/mori_board.webp`,
    boardAlt: '《末日圣母回收指南》男主定妆、改装厢式货车与检疫站设定',
    boardTab: '角色与设定',
    note: '三段完整成片 · 720p 在线试映',
    boardNote: '人物定妆 · 载具与末世场景设定',
    kicker: '03 · 末世悬疑短剧',
    title: '末日圣母回收指南',
    desc: '围绕改装厢式货车与废弃检疫站展开的三段末世短剧：从人物定妆、首尾帧衔接、配音配乐到多轨提速剪辑，输出 81 秒完整成片。',
    nodes: '36',
    assets: '32',
    duration: '81s',
    durCode: '01:21',
    cardBadge: '03 · 末世短剧',
    cardSummary: '36 节点 · 三段连剪加速版 81s 成片',
  },
];
