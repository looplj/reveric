// 官网交互：片头指令逐字打出；按访客系统把主按钮指向对应安装包
(function () {
  const stage = document.getElementById('stage');

  // 开发期把 cineview 的配置错误打到控制台
  stage.addEventListener('cv-error', (e) => console.warn('[cineview]', e.detail.code, e.detail.message));

  // T3 打字机：全文一开始就在 DOM 里，只是逐字显色，不会引起重排
  function typewriter(el, msPerChar) {
    const text = el.textContent;
    const shown = document.createElement('span');
    const rest = document.createElement('span');
    rest.style.color = 'transparent';
    rest.textContent = text;
    el.replaceChildren(shown, rest);
    let n = 0;
    (function step() {
      shown.textContent = text.slice(0, ++n);
      rest.textContent = text.slice(n);
      if (n < text.length) setTimeout(step, msPerChar);
    })();
  }
  const cmd = document.getElementById('cmd');
  if (cmd && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
    setTimeout(() => typewriter(cmd, 70), 900);
  }

  // 识别系统：Android / Windows / macOS 直接下载，其他系统跳到下载区
  const ua = navigator.userAgent;
  const os = /Android/i.test(ua) ? 'android'
    : /iPhone|iPad|iPod/i.test(ua) ? null
    : /Windows/i.test(ua) ? 'win'
    : /Macintosh|Mac OS X/i.test(ua) ? 'mac'
    : null;
  const names = { mac: 'macOS', win: 'Windows', android: 'Android' };
  const card = os && document.querySelector(`.dl[data-os="${os}"]`);
  if (card) {
    card.classList.add('is-mine');
    const primary = document.getElementById('primary-dl');
    primary.href = card.href;
    primary.firstChild.textContent = `下载 ${names[os]} 版 `;
    const alts = document.getElementById('alt-dl');
    alts.querySelectorAll('a').forEach((a) => {
      if (a.textContent === names[os]) a.remove();
    });
  }

  // 画布画廊展映：切换作品与「成片试映 / 画布与设定」视图
  const GAL_CDN = 'https://gallery.reveric.app/showcase';
  const WORKS = [
    {
      video: `${GAL_CDN}/duantianhe.mp4`,
      poster: `${GAL_CDN}/duantianhe_poster.webp`,
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
    },
    {
      video: `${GAL_CDN}/shuangshu.mp4`,
      poster: `${GAL_CDN}/shuangshu_poster.webp`,
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
    },
    {
      video: `${GAL_CDN}/mori.mp4`,
      poster: `${GAL_CDN}/mori_poster.webp`,
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
    },
  ];

  const galVideo = document.getElementById('gal-video');
  const galBoard = document.getElementById('gal-board');
  const galPlay = document.getElementById('gal-play');
  const galPlayDur = document.getElementById('gal-play-dur');
  const galBoardTab = document.getElementById('gal-board-tab');
  const galViewNote = document.getElementById('gal-view-note');
  const galKicker = document.getElementById('gal-kicker');
  const galTitle = document.getElementById('gal-title');
  const galDesc = document.getElementById('gal-desc');
  const galNodes = document.getElementById('gal-nodes');
  const galAssets = document.getElementById('gal-assets');
  const galDuration = document.getElementById('gal-duration');
  const galTabs = document.querySelectorAll('[data-gal-view]');
  const galCards = document.querySelectorAll('[data-gal-idx]');

  if (galVideo && galBoard && galPlay) {
    let activeIdx = 0;
    let activeView = 'video';

    function setView(view) {
      activeView = view;
      const work = WORKS[activeIdx];
      const isVideo = view === 'video';
      if (!isVideo) galVideo.pause();
      galVideo.hidden = !isVideo;
      galBoard.hidden = isVideo;
      galPlay.hidden = !isVideo || !galVideo.paused;
      galTabs.forEach((tab) => {
        const on = tab.dataset.galView === view;
        tab.classList.toggle('is-on', on);
        tab.setAttribute('aria-selected', on ? 'true' : 'false');
      });
      galViewNote.textContent = isVideo ? work.note : work.boardNote;
    }

    function selectWork(idx) {
      const work = WORKS[idx];
      if (!work) return;
      activeIdx = idx;
      galVideo.pause();
      galVideo.controls = false;
      galVideo.poster = work.poster;
      galVideo.src = work.video;
      galVideo.load();
      galBoard.src = work.board;
      galBoard.alt = work.boardAlt;
      galBoardTab.textContent = work.boardTab;
      galPlayDur.textContent = work.durCode;
      galKicker.textContent = work.kicker;
      galTitle.textContent = work.title;
      galDesc.textContent = work.desc;
      galNodes.textContent = work.nodes;
      galAssets.textContent = work.assets;
      galDuration.textContent = work.duration;
      galCards.forEach((card) => {
        const on = Number(card.dataset.galIdx) === idx;
        card.classList.toggle('is-active', on);
        card.setAttribute('aria-pressed', on ? 'true' : 'false');
      });
      setView('video');
      galPlay.hidden = false;
    }

    galPlay.addEventListener('click', () => {
      galPlay.hidden = true;
      galVideo.controls = true;
      galVideo.play().catch(() => { galPlay.hidden = false; });
    });
    galVideo.addEventListener('play', () => {
      galPlay.hidden = true;
      galVideo.controls = true;
    });
    galVideo.addEventListener('ended', () => {
      galVideo.controls = false;
      if (activeView === 'video') galPlay.hidden = false;
    });
    galTabs.forEach((tab) => {
      tab.addEventListener('click', () => setView(tab.dataset.galView));
    });
    galCards.forEach((card) => {
      card.addEventListener('click', () => selectWork(Number(card.dataset.galIdx)));
    });
  }
})();
