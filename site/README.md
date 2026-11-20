# 官网（reveric.app）

纯静态页面，部署在 Cloudflare Pages。

## 目录

| 路径 | 内容 |
|---|---|
| `designs/website/` | 页面真源：`index.html`、`landing.css`、`landing.js`、截图、字体子集和本地化的 [cineview](https://www.npmjs.com/package/cineview) |
| `site/build.mjs` | 复制页面到 `site/dist/`，注入版本号和安装包链接 |
| `site/static/` | `robots.txt`、`sitemap.xml`、`_headers`，原样复制到产物根目录 |
| `site/scripts/subset_fonts.py` | 按页面用字裁剪 Noto Serif SC |
| `site/screenshots/` | 原始截图和打码脚本，已加入 `.gitignore`，只在本地保留 |

## 本地预览

```bash
python3 -m http.server 4311 --directory designs
# 打开 http://localhost:4311/website/index.html
```

查看构建产物：

```bash
node site/build.mjs                  # 版本取最新正式 tag
node site/build.mjs --version 0.6.1  # 或指定版本
python3 -m http.server 4312 --directory site/dist
```

## 修改文案

改 `designs/website/index.html`。如果新增了字体子集里没有的汉字，`build.mjs` 会列出缺少的字，此时运行 `make site-fonts` 重新生成字体子集（首次运行会把源字体和 fonttools 缓存到 `site/.cache/`）。

## 更新截图

原始截图用 Reveric 深色主题、窗口 1440×900、按 2x 截取，放进本地的 `site/screenshots/`，用其中的 `process_screenshots.py` 打码后输出到 `designs/website/assets/`。

## 部署

- **发版**：`Package` workflow 的三个平台都打包成功后，`deploy-website` 用本次 tag 的版本构建并部署。手动只打单个平台时会跳过这一步。
- **改文案或补打平台后**：在 Actions 页面手动运行 `Website` workflow，版本号取最新正式 tag。推送代码不会触发部署。
- **本地上传**：`make site-deploy`，依次裁剪字体、构建、上传。只构建不上传用 `make site-build`。

下载链接指向 `https://downloads.reveric.app/releases/v<版本>/<文件名>`，文件名按 `distribute_options.yaml` 与 `build-android.sh` 的产物命名拼出，两边改名时要同步修改 `build.mjs` 的 `assetUrls`。更新日志仍指向 GitHub Release。

### 首次配置

1. 创建 Direct Upload 类型的 Pages 项目，生产分支设为 `unstable`（Direct Upload 项目不连 git，这里只需与 workflow 中 `--branch` 一致）：
   `npx wrangler pages project create reveric-site --production-branch=unstable`
2. 在 Pages 项目里绑定自定义域名 `reveric.app`。
3. 在 GitHub 仓库 Secrets 中添加：
   - `CLOUDFLARE_API_TOKEN`：带 `Cloudflare Pages: Edit` 权限的 API Token
   - `CLOUDFLARE_ACCOUNT_ID`：Cloudflare 账户 ID
