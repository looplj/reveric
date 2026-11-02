/* ============================================================
   Reveric Mobile · Kit — icons + shared atoms
   phosphor-regular-style stroke icons (1.6 weight) 与既有移动端一致
   ============================================================ */
const { useState, useRef, useEffect } = React;

const Ic = ({d, s=22, sw=1.6, fill=false, c="currentColor", style}) => (
  <svg width={s} height={s} viewBox="0 0 24 24" fill={fill?c:"none"} stroke={c}
    strokeWidth={sw} strokeLinecap="round" strokeLinejoin="round" style={style}>{d}</svg>
);
const I = {
  home:    p => <Ic {...p} d={<><path d="M4 11.5 12 4l8 7.5"/><path d="M5.5 10.5V20h13v-9.5"/><path d="M10 20v-5h4v5"/></>}/>,
  books:   p => <Ic {...p} d={<><rect x="4" y="4" width="5" height="16" rx="1"/><rect x="9" y="4" width="5" height="16" rx="1"/><path d="M15.5 5.2l3.8 1 .9 14.6-3.8-1z"/></>}/>,
  spark:   p => <Ic {...p} d={<><path d="M12 3c.6 3.9 1.6 5 5.5 5.5C13.6 9 12.6 10.1 12 14c-.6-3.9-1.6-5-5.5-5.5C10.4 8 11.4 6.9 12 3Z"/><path d="M18.5 14c.3 1.9.8 2.4 2.5 2.7-1.7.3-2.2.8-2.5 2.6-.3-1.8-.8-2.3-2.5-2.6 1.7-.3 2.2-.8 2.5-2.7Z"/></>}/>,
  gear:    p => <Ic {...p} d={<><circle cx="12" cy="12" r="3.1"/><path d="M12 2.6v2.2M12 19.2v2.2M21.4 12h-2.2M4.8 12H2.6M18.6 5.4l-1.6 1.6M7 17l-1.6 1.6M18.6 18.6 17 17M7 7 5.4 5.4"/></>}/>,
  crown:   p => <Ic {...p} d={<><path d="M3.2 8.4 6 15.6h12l2.8-7.2-4.6 3.1L12 5.2l-4.2 6.3z"/><path d="M6 18.4h12"/></>}/>,
  chevR:   p => <Ic {...p} d={<path d="M9 6l6 6-6 6"/>}/>,
  chevL:   p => <Ic {...p} d={<path d="M15 6l-6 6 6 6"/>}/>,
  caretD:  p => <Ic {...p} d={<path d="M6 9.5l6 6 6-6"/>}/>,
  plus:    p => <Ic {...p} d={<><path d="M12 5v14M5 12h14"/></>}/>,
  sliders: p => <Ic {...p} d={<><path d="M4 7h9M17 7h3M4 17h3M11 17h9"/><circle cx="15" cy="7" r="2"/><circle cx="9" cy="17" r="2"/></>}/>,
  minus:   p => <Ic {...p} d={<path d="M5 12h14"/>}/>,
  clock:   p => <Ic {...p} d={<><circle cx="12" cy="12" r="8.2"/><path d="M12 7.5V12l3 1.8"/></>}/>,
  target:  p => <Ic {...p} d={<><circle cx="12" cy="12" r="8.2"/><circle cx="12" cy="12" r="4.4"/><circle cx="12" cy="12" r="1" fill="currentColor"/></>}/>,
  dots:    p => <Ic {...p} d={<><circle cx="6" cy="12" r="1.3" fill="currentColor"/><circle cx="12" cy="12" r="1.3" fill="currentColor"/><circle cx="18" cy="12" r="1.3" fill="currentColor"/></>}/>,
  send:    p => <Ic {...p} d={<path d="M4.5 12 20 5l-4.2 14.5-4-6.2-7.3-1.3Z"/>}/>,
  clip:    p => <Ic {...p} d={<path d="M16.5 8.5 9.7 15.3a2.3 2.3 0 0 0 3.3 3.3l6.8-6.8a4 4 0 0 0-5.7-5.7L6.6 13.6a5.7 5.7 0 0 0 8 8l5.4-5.3"/>}/>,
  slash:   p => <Ic {...p} d={<path d="M14.5 4.5 9.5 19.5"/>}/>,
  check:   p => <Ic {...p} d={<path d="M5 12.5 10 17.5 19.5 7"/>}/>,
  x:       p => <Ic {...p} d={<path d="M6 6l12 12M18 6 6 18"/>}/>,
  search:  p => <Ic {...p} d={<><circle cx="11" cy="11" r="6.4"/><path d="M16 16l4 4"/></>}/>,
  grid:    p => <Ic {...p} d={<><rect x="4" y="4" width="7" height="7" rx="1.4"/><rect x="13" y="4" width="7" height="7" rx="1.4"/><rect x="4" y="13" width="7" height="7" rx="1.4"/><rect x="13" y="13" width="7" height="7" rx="1.4"/></>}/>,
  text:    p => <Ic {...p} d={<><path d="M5 6.5h14M5 6.5V5h14v1.5M12 6.5V19M9.5 19h5"/></>}/>,
  palette: p => <Ic {...p} d={<><path d="M12 3.5a8.5 8.5 0 0 0 0 17c1.4 0 2-.9 2-1.8 0-1.3-1.2-1.6-1.2-2.7 0-.8.7-1.3 1.6-1.3H16a4.5 4.5 0 0 0 4.5-4.7C20.3 6.6 16.6 3.5 12 3.5Z"/><circle cx="8" cy="11" r="1" fill="currentColor"/><circle cx="12" cy="8" r="1" fill="currentColor"/><circle cx="16" cy="11" r="1" fill="currentColor"/></>}/>,
  robot:   p => <Ic {...p} d={<><rect x="5" y="8" width="14" height="11" rx="2.5"/><path d="M12 8V4.5M9.5 13h0M14.5 13h0"/><path d="M2.8 12.5v3M21.2 12.5v3"/></>}/>,
  hub:     p => <Ic {...p} d={<><circle cx="12" cy="6" r="2.2"/><circle cx="6" cy="17" r="2.2"/><circle cx="18" cy="17" r="2.2"/><path d="M12 8.2v3.3M10.6 14.5 7.4 15.6M13.4 14.5l3.2 1.1"/></>}/>,
  model:   p => <Ic {...p} d={<><path d="M12 3 4 7.2v9.6L12 21l8-4.2V7.2Z"/><path d="M4 7.2 12 11.4l8-4.2M12 11.4V21"/></>}/>,
  moon:    p => <Ic {...p} d={<path d="M20 14.5A8 8 0 0 1 9.5 4 7.5 7.5 0 1 0 20 14.5Z"/>}/>,
  sun:     p => <Ic {...p} d={<><circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M21.5 12h-2M4.5 12h-2M18.4 5.6l-1.4 1.4M7 17l-1.4 1.4M18.4 18.4 17 17M7 7 5.6 5.6"/></>}/>,
  chart:   p => <Ic {...p} d={<><path d="M4 20V5M4 20h16M8 20v-6M12 20v-9M16 20v-4"/></>}/>,
  archive: p => <Ic {...p} d={<><rect x="4" y="5" width="16" height="4" rx="1"/><path d="M5.5 9v10h13V9M10 13h4"/></>}/>,
  info:    p => <Ic {...p} d={<><circle cx="12" cy="12" r="8.2"/><path d="M12 11v5M12 8h0"/></>}/>,
  warn:    p => <Ic {...p} d={<><path d="M10.3 4.2 2.6 18a2 2 0 0 0 1.7 3h15.4a2 2 0 0 0 1.7-3L13.7 4.2a2 2 0 0 0-3.4 0Z"/><path d="M12 9.5V14M12 17.3h0"/></>}/>,
  history: p => <Ic {...p} d={<><path d="M3.5 12a8.5 8.5 0 1 0 2.6-6.1M3.5 4.5V9H8"/><path d="M12 8v4.2l3 1.6"/></>}/>,
  undo:    p => <Ic {...p} d={<><path d="M3.5 12a8.5 8.5 0 1 0 2.6-6.1M3.5 4.5V9H8"/></>}/>,
  list:    p => <Ic {...p} d={<><path d="M8 6.5h12M8 12h12M8 17.5h12M4 6.5h0M4 12h0M4 17.5h0"/></>}/>,
  checks:  p => <Ic {...p} d={<><path d="M11 6.5h9M11 12h9M11 17.5h9"/><path d="M3.4 6.3 4.7 7.6 7 5M3.4 11.8l1.3 1.3L7 10.5M3.4 17.3l1.3 1.3L7 16"/></>}/>,
  checkCircle: p => <Ic {...p} d={<><circle cx="12" cy="12" r="8.4"/><path d="M8.2 12.2 11 15l5-5.6"/></>}/>,
  file:    p => <Ic {...p} d={<><path d="M7 3.5h7l4 4V20a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V4.5a1 1 0 0 1 1-1Z"/><path d="M13.5 3.5V8h4.3"/></>}/>,
  fileEdit:p => <Ic {...p} d={<><path d="M7 3.5h7l4 4V20a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V4.5a1 1 0 0 1 1-1Z"/><path d="M13.5 3.5V8h4.3"/><path d="M9.5 16.5l1.6-.4 3.6-3.6-1.2-1.2-3.6 3.6Z"/></>}/>,
  globe:   p => <Ic {...p} d={<><circle cx="12" cy="12" r="8.2"/><path d="M3.8 12h16.4M12 3.8c2.4 2.3 2.4 13.9 0 16.4-2.4-2.5-2.4-14.1 0-16.4Z"/></>}/>,
  users:   p => <Ic {...p} d={<><circle cx="9" cy="8" r="3"/><path d="M3.5 19c.5-3 2.8-4.6 5.5-4.6s5 1.6 5.5 4.6"/><path d="M16 5.2a3 3 0 0 1 0 5.6M20.5 19c-.3-2-1.3-3.4-3-4.1"/></>}/>,
  user:    p => <Ic {...p} d={<><circle cx="12" cy="8" r="3.4"/><path d="M5 19.5c.7-3.5 3.4-5.3 7-5.3s6.3 1.8 7 5.3"/></>}/>,
  users3:  p => <Ic {...p} d={<><circle cx="12" cy="7" r="2.4"/><circle cx="5.5" cy="11" r="2.2"/><circle cx="18.5" cy="11" r="2.2"/><path d="M8 18c.5-2.2 2-3.4 4-3.4s3.5 1.2 4 3.4M2.6 17c.3-1.6 1.2-2.6 2.9-2.6M21.4 17c-.3-1.6-1.2-2.6-2.9-2.6"/></>}/>,
  mask:    p => <Ic {...p} d={<><path d="M4 5.5c5.3-1.2 10.7-1.2 16 0 0 6-1.8 11-8 13-6.2-2-8-7-8-13Z"/><path d="M8.5 10.5h0M15.5 10.5h0M9 14.5c1.8 1.2 4.2 1.2 6 0"/></>}/>,
  chat:    p => <Ic {...p} d={<><path d="M12 3.8a8.2 8.2 0 0 0-7 12.5L4 20l3.9-1A8.2 8.2 0 1 0 12 3.8Z"/><path d="M8.5 10.5h7M8.5 13.5h4.5"/></>}/>,
  chatcircle: p => <Ic {...p} d={<><circle cx="12" cy="11.5" r="7.7"/><path d="M9 11.5h6M9 8.5h6M5.5 17 4 20.5l3.8-1.2"/></>}/>,
  flag:    p => <Ic {...p} d={<><path d="M6 21V4"/><path d="M6 4.8c2.2-1.3 4.2-1.3 6 0s3.8 1.3 6 0v8.4c-2.2 1.3-4.2 1.3-6 0s-3.8-1.3-6 0"/></>}/>,
  map:     p => <Ic {...p} d={<><path d="M9 4.5 3.5 6.8v12.7L9 17.2l6 2.3 5.5-2.3V4.5L15 6.8 9 4.5Z"/><path d="M9 4.5v12.7M15 6.8v12.7"/></>}/>,
  shield:  p => <Ic {...p} d={<path d="M12 3.5 5 6v6c0 4.2 3 7 7 8.5 4-1.5 7-4.3 7-8.5V6Z"/>}/>,
  leaf:    p => <Ic {...p} d={<><path d="M5 19c0-8 5-13 14-13 0 9-5 14-14 13Z"/><path d="M5 19c3.5-3.5 6.5-6 11-8"/></>}/>,
  diamond: p => <Ic {...p} d={<><path d="M5 9 12 3l7 6-7 12Z"/><path d="M5 9h14M9.5 9 12 3l2.5 6"/></>}/>,
  folder:  p => <Ic {...p} d={<path d="M3.5 7c0-.8.6-1.4 1.4-1.4h4l2 2h8.2c.8 0 1.4.6 1.4 1.4v9c0 .8-.6 1.4-1.4 1.4H4.9c-.8 0-1.4-.6-1.4-1.4Z"/>}/>,
  image:   p => <Ic {...p} d={<><rect x="4" y="5" width="16" height="14" rx="2"/><circle cx="9" cy="10" r="1.6"/><path d="M5 17l4.5-4.5 3 3L16 11l3 3.5"/></>}/>,
  scroll:  p => <Ic {...p} d={<><path d="M6 4.5h11v13a2.5 2.5 0 0 1-2.5 2.5H7"/><path d="M17 4.5a2 2 0 0 1 2 2v1h-4M6 4.5a2 2 0 0 0-2 2v11a2.5 2.5 0 0 0 2.5 2.5"/><path d="M9 9h5M9 12.5h5"/></>}/>,
  // 对齐 desktop 的 phosphor film-strip。
  film:    p => <Ic {...p} d={<><rect x="3" y="5" width="18" height="14" rx="2"/><path d="M7.5 5v14M16.5 5v14M3 12h18"/></>}/>,
  scales:  p => <Ic {...p} d={<><path d="M12 4v16M7 20h10M4 9l3-4 3 4a3 3 0 0 1-6 0ZM14 9l3-4 3 4a3 3 0 0 1-6 0Z"/></>}/>,
  mountains: p => <Ic {...p} d={<><path d="M3 19 9 8l4 6 2-3 6 8Z"/><circle cx="17" cy="6" r="1.6"/></>}/>,
  compass: p => <Ic {...p} d={<><circle cx="12" cy="12" r="8.4"/><path d="M14.5 9.5 13 13l-3.5 1.5L11 11Z"/></>}/>,
  bulb:    p => <Ic {...p} d={<><path d="M9 17.5h6M9.5 20.5h5"/><path d="M12 3.5a6 6 0 0 0-3.5 10.8c.5.4.8 1 .8 1.7h5.4c0-.7.3-1.3.8-1.7A6 6 0 0 0 12 3.5Z"/></>}/>,
  refresh: p => <Ic {...p} d={<><path d="M4.5 9a7.5 7.5 0 0 1 13-2.5M19.5 15a7.5 7.5 0 0 1-13 2.5"/><path d="M17.5 3.5V7h-3.5M6.5 20.5V17h3.5"/></>}/>,
  arrowL:  p => <Ic {...p} d={<><path d="M19.5 12h-15M9.5 6.5 4 12l5.5 5.5"/></>}/>,
  arrowR:  p => <Ic {...p} d={<><path d="M4.5 12h15M14.5 6.5 20 12l-5.5 5.5"/></>}/>,
  arrowsOut: p => <Ic {...p} d={<><path d="M8 4.5H4.5V8M16 4.5h3.5V8M8 19.5H4.5V16M16 19.5h3.5V16"/></>}/>,
  arrowsIn:  p => <Ic {...p} d={<><path d="M4.5 8H8V4.5M19.5 8H16V4.5M4.5 16H8v3.5M19.5 16H16v3.5"/></>}/>,
  pencil:  p => <Ic {...p} d={<><path d="M15.5 5 19 8.5 8.5 19H5v-3.5Z"/><path d="M13.5 7l3.5 3.5"/></>}/>,
  trash:   p => <Ic {...p} d={<><path d="M4.5 6.5h15M9.5 6V4.5h5V6M6.5 6.5l.8 13h9.4l.8-13M10 10.5v5.5M14 10.5v5.5"/></>}/>,
  save:    p => <Ic {...p} d={<><path d="M4.5 5.8c0-.7.6-1.3 1.3-1.3h10.4l3.3 3.3v10.4c0 .7-.6 1.3-1.3 1.3H5.8c-.7 0-1.3-.6-1.3-1.3Z"/><path d="M8 4.5V9h7V4.5M8 19.5V14h8v5.5"/></>}/>,
  github:  p => <Ic {...p} d={<><path d="M15 22v-4a4.8 4.8 0 0 0-1-3.5c3 0 6-2 6-5.5.08-1.25-.27-2.48-1-3.5.28-1.15.28-2.35 0-3.5 0 0-1 0-3 1.5-2.64-.5-5.36-.5-8 0C6 2 5 2 5 3.5c-.3 1.15-.3 2.35 0 3.5A5.4 5.4 0 0 0 4 9c0 3.5 3 5.5 6 5.5-.39.49-.68 1.05-.85 1.65-.17.6-.22 1.23-.15 1.85v4"/><path d="M9 18c-4.51 2-5-2-7-2"/></>}/>,
  /* QQ 品牌标（Simple Icons, CC0），实心 */
  qq:      ({s=22, c="currentColor", style}) => <svg width={s} height={s} viewBox="0 0 24 24" fill={c} style={style}><path d="M21.395 15.035a40 40 0 0 0-.803-2.264l-1.079-2.695c.001-.032.014-.562.014-.836C19.526 4.632 17.351 0 12 0S4.474 4.632 4.474 9.241c0 .274.013.804.014.836l-1.08 2.695a39 39 0 0 0-.802 2.264c-1.021 3.283-.69 4.643-.438 4.673.54.065 2.103-2.472 2.103-2.472 0 1.469.756 3.387 2.394 4.771-.612.188-1.363.479-1.845.835-.434.32-.379.646-.301.778.343.578 5.883.369 7.482.189 1.6.18 7.14.389 7.483-.189.078-.132.132-.458-.301-.778-.483-.356-1.233-.646-1.846-.836 1.637-1.384 2.393-3.302 2.393-4.771 0 0 1.563 2.537 2.103 2.472.251-.03.581-1.39-.438-4.673"/></svg>,
  copy:    p => <Ic {...p} d={<><rect x="8" y="8" width="11" height="11" rx="2"/><path d="M5 16V6a2 2 0 0 1 2-2h8"/></>}/>,
  eye:     p => <Ic {...p} d={<><path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12Z"/><circle cx="12" cy="12" r="2.7"/></>}/>,
  brain:   p => <Ic {...p} d={<><path d="M9.5 4.5A2.7 2.7 0 0 0 6.8 7.2 3.1 3.1 0 0 0 4.5 10.2c0 .9.4 1.8 1 2.4a3.1 3.1 0 0 0 1.3 5.2A2.7 2.7 0 0 0 12 19.3V7.2a2.7 2.7 0 0 0-2.5-2.7Z"/><path d="M14.5 4.5a2.7 2.7 0 0 1 2.7 2.7 3.1 3.1 0 0 1 2.3 3c0 .9-.4 1.8-1 2.4a3.1 3.1 0 0 1-1.3 5.2A2.7 2.7 0 0 1 12 19.3V7.2a2.7 2.7 0 0 1 2.5-2.7Z"/></>}/>,
  magic:   p => <Ic {...p} d={<><path d="M14 7 6 15l-1.5 4.5L9 18l8-8Z"/><path d="M14 4.5l.6 1.7 1.7.6-1.7.6L14 9.2l-.6-1.7-1.7-.6 1.7-.6Z"/><path d="M19 11l.4 1.2 1.2.4-1.2.4-.4 1.2-.4-1.2-1.2-.4 1.2-.4Z"/></>}/>,
  cursor:  p => <Ic {...p} d={<><path d="M6 4.5 18.5 11l-5.3 1.7L10 18Z"/></>}/>,
  play:    p => <Ic {...p} d={<path d="M8 5.5v13l10-6.5Z"/>}/>,
  path:    p => <Ic {...p} d={<><circle cx="6" cy="18" r="2.2"/><circle cx="18" cy="6" r="2.2"/><path d="M6 15.5V11a4 4 0 0 1 4-4h5"/></>}/>,
  link:    p => <Ic {...p} d={<><path d="M10 14a3.5 3.5 0 0 0 5 0l3-3a3.5 3.5 0 0 0-5-5l-1.5 1.5"/><path d="M14 10a3.5 3.5 0 0 0-5 0l-3 3a3.5 3.5 0 0 0 5 5l1.5-1.5"/></>}/>,
  bookmark:p => <Ic {...p} d={<path d="M6.5 4.5h11V20l-5.5-3.5L6.5 20Z"/>}/>,
  /* 题材标签 —— 对齐 desktop 的 phosphor tag */
  tag:     p => <Ic {...p} d={<><path d="M11 3.5H4.5a1 1 0 0 0-1 1V11a2 2 0 0 0 .6 1.4l7 7a2 2 0 0 0 2.8 0l6-6a2 2 0 0 0 0-2.8l-7-7A2 2 0 0 0 11 3.5Z"/><circle cx="8" cy="8" r="1.3" fill="currentColor"/></>}/>,
  scissors:p => <Ic {...p} d={<><circle cx="6" cy="7" r="2.4"/><circle cx="6" cy="17" r="2.4"/><path d="M8.1 8.4 20 17M8.1 15.6 20 7M12.6 11.7l1.6 1.1"/></>}/>,
  quote:   p => <Ic {...p} d={<><path d="M9.5 7c-2.8.6-4.5 2.5-4.5 5.6V17h5v-5H7.2c.1-1.6 1-2.7 2.3-3.2Z"/><path d="M19 7c-2.8.6-4.5 2.5-4.5 5.6V17h5v-5h-2.8c.1-1.6 1-2.7 2.3-3.2Z"/></>}/>,
  ticket:  p => <Ic {...p} d={<><path d="M2.5 9.5V8a2 2 0 0 1 2-2h15a2 2 0 0 1 2 2v1.5M2.5 14.5V16a2 2 0 0 0 2 2h15a2 2 0 0 0 2-2v-1.5"/><path d="M2.5 12h19"/></>}/>,
  logout:  p => <Ic {...p} d={<><path d="M9 3.5H5.6a1.5 1.5 0 0 0-1.5 1.5v14a1.5 1.5 0 0 0 1.5 1.5H9"/><path d="M15 17l4.5-5L15 7"/><path d="M19.5 12H9"/></>}/>,
  lock:    p => <Ic {...p} d={<><rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V7a4 4 0 1 1 8 0v4"/></>}/>,
  coins:   p => <Ic {...p} d={<><circle cx="9" cy="9" r="5.5"/><circle cx="15" cy="15" r="5.5"/><path d="M9 6.5v5M6.5 9h5M15 12.5v5M12.5 15h5"/></>}/>,
  gift:    p => <Ic {...p} d={<><rect x="3.5" y="9" width="17" height="11.5" rx="1.5"/><path d="M12 9v11.5M3.5 12.5h17"/><path d="M12 9c-1.5-2.5-5-3-5-0.5s3.5 0.5 5 0.5c1.5 0 5-2 5 0.5s-3.5 3-5 0.5"/></>}/>,
  chatsCircle: p => <Ic {...p} d={<><path d="M21 11.5a8.4 8.4 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.4 8.4 0 0 1-3.8-.9L3 21l1.9-5.7a8.4 8.4 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.4 8.4 0 0 1 3.8-.9h.5a8.5 8.5 0 0 1 8.5 8.5v.5Z"/></>}/>,
  storefront: p => <Ic {...p} d={<><path d="M3 9.5V20a1 1 0 0 0 1 1h16a1 1 0 0 0 1-1V9.5"/><path d="M1 9.5h22l-1.5-4.4a1 1 0 0 0-.9-.6H3.4a1 1 0 0 0-.9.6Z"/><path d="M10 20v-5h4v5"/><path d="M3.5 9.5V6h17v3.5"/></>}/>,
  /* 剧本元素条与大纲工具条用到，桌面端同名图标的移动端补位 */
  waves:   p => <Ic {...p} d={<><path d="M2.8 7c2-2 4.2-2 6.2 0s4.2 2 6.2 0 3.7-1.7 5-.7"/><path d="M2.8 12c2-2 4.2-2 6.2 0s4.2 2 6.2 0 3.7-1.7 5-.7"/><path d="M2.8 17c2-2 4.2-2 6.2 0s4.2 2 6.2 0 3.7-1.7 5-.7"/></>}/>,
  textB:   p => <Ic {...p} d={<><path d="M7.5 5v14"/><path d="M7.5 5H13a3 3 0 0 1 0 6H7.5"/><path d="M7.5 11h6a3.2 3.2 0 0 1 0 6.4H7.5"/></>}/>,
  textItalic: p => <Ic {...p} d={<><path d="M10.5 5h8M5.5 19h8M14.2 5l-4.4 14"/></>}/>,
  listNumbers: p => <Ic {...p} d={<><path d="M10.5 6.5h9.5M10.5 12h9.5M10.5 17.5h9.5"/><path d="M4.2 5.6 5.6 4.6V9"/><path d="M3.9 13.4c.3-.7 1-1 1.7-.9.8.2 1.2 1 .8 1.8-.5.9-2.6 1.9-2.6 2.9h3.4"/></>}/>,
};

function StatusBar(){
  return (
    <div className="statusbar">
      <span className="clock">21:24</span>
      <span className="sb-right">
        <svg width="18" height="12" viewBox="0 0 18 12" fill="var(--text-primary)"><rect x="0" y="7" width="3" height="5" rx="1"/><rect x="4.5" y="4.5" width="3" height="7.5" rx="1"/><rect x="9" y="2" width="3" height="10" rx="1"/><rect x="13.5" y="0" width="3" height="12" rx="1" opacity=".35"/></svg>
        <svg width="17" height="12" viewBox="0 0 17 12" fill="var(--text-primary)"><path d="M8.5 2.2c2.3 0 4.4.85 6 2.25l-1.4 1.45A6.9 6.9 0 0 0 8.5 4.1c-1.7 0-3.3.6-4.6 1.8L2.5 4.45A8.9 8.9 0 0 1 8.5 2.2Z"/><path d="M8.5 6.1c1.2 0 2.3.45 3.15 1.2l-3.15 3.2-3.15-3.2A4.7 4.7 0 0 1 8.5 6.1Z"/></svg>
        <svg width="26" height="13" viewBox="0 0 26 13" fill="none"><rect x="1" y="1.5" width="21" height="10" rx="2.6" stroke="var(--text-primary)" strokeOpacity=".4"/><rect x="2.6" y="3.1" width="15" height="6.8" rx="1.4" fill="var(--text-primary)"/><rect x="23.2" y="4.5" width="1.8" height="4" rx=".9" fill="var(--text-primary)" fillOpacity=".4"/></svg>
      </span>
    </div>
  );
}

/* 给任意 CSS 颜色（hex 或 var(--token)）叠透明度，主题切换时跟着 token 变。 */
function tint(color, a){
  return `color-mix(in srgb, ${color} ${+(a*100).toFixed(2)}%, transparent)`;
}

function useScrolled(){
  const ref = useRef(null);
  const [scrolled, setScrolled] = useState(false);
  useEffect(()=>{
    const el = ref.current; if(!el) return;
    const onScroll = ()=> setScrolled(el.scrollTop > 4);
    el.addEventListener('scroll', onScroll); return ()=>el.removeEventListener('scroll', onScroll);
  },[]);
  return [ref, scrolled];
}

function Cover({n, w, h, fs=15}){
  return (
    <div className="cover" style={{width:w, height:h, background:n.tint, padding:fs*0.7}}>
      <span className="cspine"></span>
      <div className="ctitle" style={{fontSize:fs}}>{n.title}</div>
      <div className="cfoot">REVERIC</div>
    </div>
  );
}

function StatusChip({status}){
  const map = {
    '创作中':{c:'var(--accent-warm)', bg:'color-mix(in srgb, var(--accent-warm) 13%, transparent)'},
    '已完本':{c:'var(--success)', bg:'color-mix(in srgb, var(--success) 13%, transparent)'},
    '草稿':{c:'var(--text-muted)', bg:'var(--surface-dim)'},
  };
  const s = map[status]||map['草稿'];
  return <span className="chip" style={{color:s.c, background:s.bg, height:22, fontSize:11, padding:'0 8px'}}>
    <span style={{width:5,height:5,borderRadius:'50%',background:s.c}}></span>{status}</span>;
}

function StateChip({state, small}){
  const t = STATE_TONE[state] || STATE_TONE['未开始'];
  return <span className="chip" style={{color:t.c, background:tint(t.c,.13), height:small?19:22,
    fontSize:small?10:11, padding:small?'0 7px':'0 8px', fontWeight:600}}>{state}</span>;
}

// 与 RevericSizes.touchTargetSize 一致；图标本体仍默认 22px。
const MOBILE_ICON_BUTTON_SIZE = 48;

/* page header with optional back button */
function PageHead({title, sub, onBack, right, scrolled, big, center}){
  return (
    <div className={"appbar"+(scrolled?' scrolled':'')} style={{paddingTop:54}}>
      <div className="row" style={{justifyContent:'space-between', padding:big?'8px 20px 12px':'8px 12px 10px', gap:8}}>
        {onBack
          ? <button className="press" onClick={onBack} style={{width:MOBILE_ICON_BUTTON_SIZE,height:MOBILE_ICON_BUTTON_SIZE,flexShrink:0,display:'flex',alignItems:'center',justifyContent:'center',color:'var(--text-secondary)',background:'transparent',border:'none'}}><I.chevL s={24}/></button>
          : (center ? <div style={{width:MOBILE_ICON_BUTTON_SIZE,flexShrink:0}}></div> : null)}
        {big ? (
          <span className="display" style={{fontSize:26, fontWeight:700, flex:1, letterSpacing:'-0.02em'}}>{title}</span>
        ) : (
          <div className="col" style={{alignItems:center?'center':'flex-start', flex:1, minWidth:0}}>
            <span className="display" style={{fontSize:15.5, fontWeight:700, color:'var(--text-primary)', whiteSpace:'nowrap', overflow:'hidden', textOverflow:'ellipsis', maxWidth:'100%'}}>{title}</span>
            {sub && <span style={{fontSize:11, color:'var(--text-muted)'}}>{sub}</span>}
          </div>
        )}
        {right ? <div style={{display:'flex',alignItems:'center',flexShrink:0}}>{right}</div> : (center ? <div style={{width:MOBILE_ICON_BUTTON_SIZE,flexShrink:0}}></div> : null)}
      </div>
    </div>
  );
}

function IconBtn({icon, onClick, c='var(--text-secondary)', size=22, ariaLabel}){
  const Cmp = typeof icon==='string' ? I[icon] : icon;
  return (
    <button className="press" onClick={onClick} aria-label={ariaLabel} style={{width:MOBILE_ICON_BUTTON_SIZE,height:MOBILE_ICON_BUTTON_SIZE,flexShrink:0,display:'flex',alignItems:'center',justifyContent:'center',color:c,background:'transparent',border:'none'}}>
      <Cmp s={size}/>
    </button>
  );
}

function Switch({on, onToggle}){
  return <div className={"switch press"+(on?' on':'')} onClick={onToggle}><div className="knob"></div></div>;
}

/* bottom sheet
   lift = 键盘高度。sheet 里有输入框时键盘要把整个面板顶起来，而不是盖住它的底部
   （真机上这个值来自 MediaQuery.viewInsets.bottom）。默认 0，不影响既有 sheet。 */
function Sheet({onClose, children, max='86%', lift=0}){
  return (
    <div style={{position:'absolute', inset:0, zIndex:50}}>
      <div onClick={onClose} style={{position:'absolute', inset:0, background:'var(--scrim)'}}></div>
      <div className="sheet-in" style={{position:'absolute', left:0, right:0, bottom:lift, maxHeight:max,
        background:'var(--canvas)', borderRadius:'var(--r-full) var(--r-full) 0 0', display:'flex', flexDirection:'column', overflow:'hidden'}}>
        <div style={{padding:'12px 0 6px', display:'flex', justifyContent:'center', flex:'0 0 auto'}}>
          <div style={{width:38, height:4, borderRadius:2, background:'var(--border)'}}></div>
        </div>
        {children}
      </div>
    </div>
  );
}
function SheetHeader({iconBox, title, sub, right}){
  return (
    <div className="row gap10" style={{padding:'6px 18px 13px', borderBottom:'1px solid var(--border-subtle)', flex:'0 0 auto'}}>
      {iconBox}
      <div className="col" style={{flex:1, minWidth:0, gap:2}}>
        <span className="display" style={{fontSize:16.5, fontWeight:700, color:'var(--text-primary)',
          whiteSpace:'nowrap', overflow:'hidden', textOverflow:'ellipsis'}}>{title}</span>
        {sub && <span style={{fontSize:11.5, color:'var(--text-muted)'}}>{sub}</span>}
      </div>
      {right}
    </div>
  );
}

function Field({label, hint, children, right}){
  return (
    <div style={{marginBottom:16}}>
      <div className="row" style={{marginBottom:7, justifyContent:'space-between'}}>
        <span style={{fontSize:12.5, fontWeight:600, color:'var(--text-secondary)'}}>{label}</span>
        {right}
      </div>
      {children}
      {hint && <div style={{fontSize:11.5, color:'var(--text-subtle)', marginTop:6, lineHeight:1.55}}>{hint}</div>}
    </div>
  );
}

function SectionLabel({text, right}){
  return (
    <div className="row" style={{padding:'0 4px 8px', justifyContent:'space-between'}}>
      <span style={{fontSize:11.5, fontWeight:700, color:'var(--text-subtle)', letterSpacing:.6}}>{text}</span>
      {right}
    </div>
  );
}

/* 不传 tint 时是主题色头像（如 AI），文字用 --on-accent；传入的人物色是内容色，文字保持白色。 */
function Avatar({label, size=40, tint, fs, children}){
  return (
    <div style={{width:size,height:size,borderRadius:'50%',background:tint||'linear-gradient(135deg,var(--accent),var(--accent-warm))',display:'flex',alignItems:'center',
      justifyContent:'center',color:tint?'#fff':'var(--on-accent)',fontWeight:700,fontSize:fs||size*0.4,fontFamily:'var(--display)',flex:'0 0 auto'}}>{children||label}</div>
  );
}

/* entity-style icon box (rounded square) */
function EntityIcon({icon, hex, s=40, is=20}){
  const Cmp = typeof icon==='string' ? I[icon] : icon;
  return (
    <div style={{width:s,height:s,borderRadius:'var(--r-lg)',background:tint(hex,.14),display:'flex',
      alignItems:'center',justifyContent:'center',color:hex,flex:'0 0 auto'}}><Cmp s={is}/></div>
  );
}

function Empty({icon, text, sub}){
  const Cmp = icon ? (typeof icon==='string'?I[icon]:icon) : null;
  return (
    <div className="col" style={{alignItems:'center', justifyContent:'center', gap:11, padding:'46px 30px', textAlign:'center'}}>
      {Cmp && <div style={{width:46,height:46,borderRadius:'var(--r-2xl)',background:'var(--surface-dim)',display:'flex',alignItems:'center',justifyContent:'center',color:'var(--text-subtle)'}}><Cmp s={22}/></div>}
      <div style={{fontSize:13.5, fontWeight:600, color:'var(--text-secondary)'}}>{text}</div>
      {sub && <div style={{fontSize:12, color:'var(--text-muted)', maxWidth:250, lineHeight:1.6}}>{sub}</div>}
    </div>
  );
}

/* 默认用户头像（未设置图片时）— 与桌面 Avatar.jsx 同一套规则：
   取昵称首字，底色从 5 个低饱和色（青 黛 赭 藕 苍）里按昵称哈希挑。
   ?avatar=ink 远山剪影，?avatar=legacy 现状灰色人像，用于对比。 */
const USER_AVATAR_TONES = ['#4F8C7C', '#56688C', '#A7714F', '#93708A', '#76875A'];
const USER_AVATAR_VARIANT = new URLSearchParams(location.search).get('avatar') || 'mono';
function DefaultUserAvatar({name='Reveric', size=52, variant=USER_AVATAR_VARIANT}){
  let h = 0;
  for (const ch of (name || 'Reveric')) h = (h * 31 + ch.codePointAt(0)) & 0x7fffffff;
  const tone = USER_AVATAR_TONES[h % USER_AVATAR_TONES.length];
  const ring = `inset 0 0 0 1px color-mix(in srgb, ${tone} 26%, transparent)`;
  const base = {width:size, height:size, borderRadius:'50%', flex:'none', overflow:'hidden',
    display:'flex', alignItems:'center', justifyContent:'center'};
  if (variant === 'legacy') {
    return <div style={{...base, background:'var(--surface-container)', color:'var(--text-muted)'}}><I.user s={size*0.46}/></div>;
  }
  if (variant === 'ink') {
    const a = 30 + (h % 18), b = 58 + ((h >> 5) % 20);
    const mix = (pct) => `color-mix(in srgb, ${tone} ${pct}%, var(--surface))`;
    return (
      <div style={{...base, background:mix(9), boxShadow:ring}}>
        <svg viewBox="0 0 100 100" width="100%" height="100%">
          <circle cx={72 - (h % 14)} cy="30" r="9" fill={mix(30)}/>
          <path d={`M0 74 L${a} 46 L${a+16} 60 L${b} 38 L100 66 L100 100 L0 100Z`} fill={mix(38)}/>
          <path d={`M0 86 L${a+10} 64 L${b-4} 80 L${b+14} 68 L100 84 L100 100 L0 100Z`} fill={mix(78)}/>
        </svg>
      </div>
    );
  }
  const first = Array.from(name.trim())[0] || 'R';
  return (
    <div style={{...base, boxShadow:ring,
      background:`color-mix(in srgb, ${tone} 20%, var(--surface))`,
      color:`color-mix(in srgb, ${tone} 72%, var(--text-primary))`,
      fontFamily:'var(--sans)', fontWeight:600, fontSize:Math.round(size*0.44), lineHeight:1}}>
      {/[a-z]/i.test(first) ? first.toUpperCase() : first}
    </div>
  );
}

Object.assign(window, {
  DefaultUserAvatar,
  Ic, I, StatusBar, tint, useScrolled, Cover, StatusChip, StateChip,
  MOBILE_ICON_BUTTON_SIZE, PageHead, IconBtn, Switch, Sheet, SheetHeader, Field, SectionLabel,
  Avatar, EntityIcon, Empty,
});
