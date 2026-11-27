import { execSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const SITE_DIR = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
const REPO_ROOT = join(SITE_DIR, '..');

export const REPO_URL = 'https://github.com/looplj/reveric';
export const DOWNLOADS_BASE = 'https://downloads.reveric.app';

export interface ReleaseInfo {
  version: string;
  repoUrl: string;
  releaseNotesUrl: string;
  downloads: {
    mac: string;
    win: string;
    android: string;
  };
}

function resolveVersion(): string {
  const fromEnv = (process.env.SITE_VERSION || process.env.TAG_NAME || '').trim();
  if (fromEnv) {
    return fromEnv.replace(/^v/, '');
  }

  const tags = execSync('git tag --list "v*" --sort=-v:refname', {
    cwd: REPO_ROOT,
    encoding: 'utf8',
  })
    .split('\n')
    .map((t) => t.trim())
    .filter((t) => /^v\d+\.\d+\.\d+$/.test(t));

  if (tags.length === 0) {
    throw new Error('找不到正式发布 tag（vX.Y.Z），请设置环境变量 SITE_VERSION');
  }

  return tags[0].slice(1);
}

// 与 distribute_options.yaml 的 artifact_name、build-android.sh 的 ANDROID_RELEASE_NAME，
// 以及 Package workflow 上传到 R2 的 releases/<tag>/<文件名> 保持一致。
export function getReleaseInfo(): ReleaseInfo {
  const version = resolveVersion();
  const base = `${DOWNLOADS_BASE}/releases/v${version}`;
  return {
    version,
    repoUrl: REPO_URL,
    releaseNotesUrl: `${REPO_URL}/releases/tag/v${version}`,
    downloads: {
      mac: `${base}/reveric-${version}-macos-arm64.dmg`,
      win: `${base}/reveric-${version}-windows-setup.exe`,
      android: `${base}/reveric-android-arm64-v8a-v${version}.apk`,
    },
  };
}
