# 官网（reveric.app）

基于 Astro 静态输出（`output: 'static'`）与 [cineview](https://www.npmjs.com/package/cineview) 构建，部署在 Cloudflare Pages。

## 目录

| 路径 | 内容 |
|---|---|
| `site/src/pages/` | 页面路由（首页 `index.astro` 等） |
| `site/src/layouts/` | 通用页面骨架 `BaseLayout.astro` |
| `site/src/components/` | 复用组件（`Topbar.astro` 等） |
| `site/src/data/` | 发布版本与下载链接 `release.ts`、画廊数据 `gallery.ts` |
| `site/src/styles/` | 全局样式 `landing.css` |
| `site/public/` | 静态资源（`assets/`、`fonts/`、`_headers`、`robots.txt`），原样复制到 `site/dist/` |
| `site/scripts/subset_fonts.py` | 按页面用字裁剪 Noto Serif SC |
| `site/scripts/check-fonts.mjs` | 构建后检查页面字符是否被字体子集覆盖 |
| `site/screenshots/` | 原始截图和打码脚本，已加入 `.gitignore`，只在本地保留 |

## 本地预览

首次运行前在 `site/` 下安装依赖：

```bash
cd site && npm install
npm run dev
# 或指定版本预览：SITE_VERSION=0.10.6 npm run dev
```

查看构建产物：

```bash
cd site
npm run build                        # 版本取最新正式 tag
SITE_VERSION=0.10.6 npm run build    # 或指定版本
npm run preview
```

## 修改文案

改 `site/src/` 下的页面或数据文件。如果新增了字体子集里没有的汉字，`npm run build` 会列出缺少的字，此时运行 `make site-fonts` 重新生成字体子集（首次运行会把源字体和 fonttools 缓存到 `site/.cache/`）。

## 更新截图

原始截图用 Reveric 深色主题、窗口 1440×900、按 2x 截取，放进本地的 `site/screenshots/`，打码后输出到 `site/public/assets/`。

## 画布画廊展映素材（Cloudflare R2）

`SC.02`（`#gallery`）展示的成片 MP4、剧照封面和设定/画布节点图不存进 Git 仓库，统一放在 `reveric-gallery` 桶的 `showcase/` 前缀下，通过 `https://gallery.reveric.app/showcase/` 提供公开读取：

- 视频规格：720p H.264（`yuv420p`）+ AAC，`+faststart` 便于网页分段缓冲。
- 图片规格：16:9 WebP（`*_poster.webp` 1280×720、`*_thumb.webp` 640×360、`*_board.webp` 1280×720）。

新增或替换展映素材时，用 Wrangler 上传后更新 `site/src/data/gallery.ts` 的 `GALLERY_WORKS` 配置：

```bash
npx wrangler r2 object put "reveric-gallery/showcase/<文件名>" \
  --file="<本地路径>" \
  --content-type="video/mp4" \
  --cache-control="public, max-age=604800" \
  --remote --force
```

## 部署

- **发版**：`Package` workflow 的全平台打包成功后，`deploy-website` 用本次 tag 的版本构建并部署。手动只打单个平台时会跳过这一步。
- **改文案或补打平台后**：在 Actions 页面手动运行 `Website` workflow，版本号取最新正式 tag。推送代码不会触发部署。
- **本地上传**：`make site-deploy`，依次裁剪字体、构建、上传。只构建不上传用 `make site-build`。

下载链接指向 `https://downloads.reveric.app/releases/v<版本>/<文件名>`，文件名按 `distribute_options.yaml` 与 `build-android.sh` 的产物命名拼出，两边改名时要同步修改 `site/src/data/release.ts` 的 `getReleaseInfo`。更新日志仍指向 GitHub Release。

### 首次配置

1. 创建 Direct Upload 类型的 Pages 项目，生产分支设为 `unstable`（Direct Upload 项目不连 git，这里只需与 workflow 中 `--branch` 一致）：
   `npx wrangler pages project create reveric-site --production-branch=unstable`
2. 在 Pages 项目里绑定自定义域名 `reveric.app`。
3. 在 GitHub 仓库 Secrets 中添加：
   - `CLOUDFLARE_API_TOKEN`：带 `Cloudflare Pages: Edit` 权限的 API Token
   - `CLOUDFLARE_ACCOUNT_ID`：Cloudflare 账户 ID
