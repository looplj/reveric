#!/usr/bin/env node
// 构建官网静态产物：复制 designs/website 的页面与资源到 site/dist，按发布版本注入版本号和安装包链接。
//
// 用法：
//   node site/build.mjs                  # 版本取本地最新正式 tag（vX.Y.Z）
//   node site/build.mjs --version 0.6.1  # 指定版本
//
// 无第三方依赖，Node 18+ 即可运行。

import { execSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const SITE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(SITE, '..');
const SRC = join(ROOT, 'designs', 'website');
const DIST = join(SITE, 'dist');
const REPO = 'https://github.com/looplj/reveric';
const DOWNLOADS = 'https://downloads.reveric.app';

// 页面和它引用的资源；directions.html 等设计过程文件不发布
const PAGE_FILES = ['index.html', 'landing.css', 'landing.js', 'assets', 'fonts', 'vendor'];

function resolveVersion() {
  const i = process.argv.indexOf('--version');
  if (i !== -1) return process.argv[i + 1].replace(/^v/, '');
  const tags = execSync('git tag --list "v*" --sort=-v:refname', { cwd: ROOT, encoding: 'utf8' })
    .split('\n')
    .filter((t) => /^v\d+\.\d+\.\d+$/.test(t));
  if (tags.length === 0) throw new Error('找不到正式发布 tag（vX.Y.Z），请用 --version 指定');
  return tags[0].slice(1);
}

// 与 distribute_options.yaml 的 artifact_name、build-android.sh 的 ANDROID_RELEASE_NAME，
// 以及 Package workflow 上传到 R2 的 releases/<tag>/<文件名> 保持一致。
function assetUrls(version) {
  const base = `${DOWNLOADS}/releases/v${version}`;
  return {
    mac: `${base}/reveric-${version}-macos-arm64.dmg`,
    win: `${base}/reveric-${version}-windows-setup.exe`,
    android: `${base}/reveric-android-arm64-v8a-v${version}.apk`,
  };
}

function render(html, version) {
  const urls = assetUrls(version);
  let out = html
    .replace(/(<[^>]*\bdata-version\b[^>]*>)v[^<]*(<)/g, `$1v${version}$2`)
    .replace(/(<a\b[^>]*\bdata-release-notes\b[^>]*\bhref=")[^"]*(")/g, `$1${REPO}/releases/tag/v${version}$2`)
    .replace(/(<a\b[^>]*\bdata-os="(\w+)"[^>]*\bhref=")[^"]*(")/g, (m, head, os, tail) => {
      if (!urls[os]) throw new Error(`未知平台 data-os="${os}"`);
      return `${head}${urls[os]}${tail}`;
    });
  // 样式和脚本文件名不变，按内容加版本参数，避免浏览器拿新页面配旧缓存
  for (const file of ['landing.css', 'landing.js']) {
    const hash = createHash('sha256').update(readFileSync(join(SRC, file))).digest('hex').slice(0, 10);
    const before = out;
    out = out.replace(`"${file}"`, `"${file}?v=${hash}"`);
    if (out === before) throw new Error(`页面里没有引用 ${file}`);
  }
  for (const [os, url] of Object.entries(urls)) {
    if (!out.includes(url)) throw new Error(`页面里没有 data-os="${os}" 的下载链接`);
  }
  return out;
}

// 页面新增了字体子集里没有的字时提醒重新裁剪，否则这些字会回退到系统字体
function checkFontCoverage(html) {
  const covered = new Set(readFileSync(join(SRC, 'fonts', 'NotoSerifSC-subset.chars.txt'), 'utf8'));
  const text = html.replace(/<[^>]+>/g, ' ');
  const missing = [...new Set(text)].filter((c) => c.trim() && !covered.has(c));
  if (missing.length) {
    console.warn(`⚠ 字体子集缺少 ${missing.length} 个字：${missing.join('')}`);
    console.warn('  运行 site/scripts/subset_fonts.py 重新生成 designs/website/fonts/');
  }
}

const version = resolveVersion();
rmSync(DIST, { recursive: true, force: true });
mkdirSync(DIST, { recursive: true });

for (const name of PAGE_FILES) {
  const from = join(SRC, name);
  if (!existsSync(from)) throw new Error(`缺少 ${from}`);
  cpSync(from, join(DIST, name), { recursive: true });
}
cpSync(join(SITE, 'static'), DIST, { recursive: true });

const html = readFileSync(join(SRC, 'index.html'), 'utf8');
checkFontCoverage(html);
writeFileSync(join(DIST, 'index.html'), render(html, version));

console.log(`site/dist 已生成，版本 v${version}`);
