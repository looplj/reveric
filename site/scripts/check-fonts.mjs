#!/usr/bin/env node
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const SITE = dirname(dirname(fileURLToPath(import.meta.url)));
const DIST = join(SITE, 'dist');
const CHARS_FILE = join(SITE, 'public', 'fonts', 'NotoSerifSC-subset.chars.txt');

function collectHtmlFiles(dir) {
  const files = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) {
      files.push(...collectHtmlFiles(full));
    } else if (entry.endsWith('.html')) {
      files.push(full);
    }
  }
  return files;
}

const covered = new Set(readFileSync(CHARS_FILE, 'utf8'));
const missing = new Set();

for (const file of collectHtmlFiles(DIST)) {
  const html = readFileSync(file, 'utf8')
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, ' ')
    .replace(/<[^>]+>/g, ' ');
  for (const ch of html) {
    if (ch.trim() && !covered.has(ch)) {
      missing.add(ch);
    }
  }
}

if (missing.size > 0) {
  console.warn(`⚠ 字体子集缺少 ${missing.size} 个字符：${[...missing].join('')}`);
  console.warn('  运行 make site-fonts 重新生成 site/public/fonts/');
}
