#!/usr/bin/env bash
#
# build-android.sh — 本地与 CI 构建 Reveric Android APK
#
# 流程:
#   1. 备份 pubspec.yaml
#   2. 禁用 pubspec.yaml sqlite3 hooks（Android 无系统 libsqlite3.so）
#   3. fvm flutter pub get
#   4. fvm flutter build apk --release --split-per-abi --target-platform android-arm64
#   5. 校验产物：任何真实构建失败都中断，只容忍 Flutter 已知的 APK 检测误报
#   6. 复制 arm64-v8a APK 到 dist/<version>/，文件名带版本号
#   7. 还原 pubspec.yaml
#
# 用法:
#   ./build-android.sh
#   ./build-android.sh 1.2.3+42
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP="$SCRIPT_DIR/pubspec.yaml.bak"
BUILD_LOG=""
BUILD_STAMP=""
VERSION="${1:-}"
CURRENT_VERSION="$(awk '/^version:/{print $2; exit}' "$SCRIPT_DIR/pubspec.yaml")"
PACKAGE_VERSION="${VERSION:-$CURRENT_VERSION}"
VERSION_NAME="${PACKAGE_VERSION%%+*}"
DIST_VERSION_DIR="$SCRIPT_DIR/dist/$VERSION_NAME"
ANDROID_RELEASE_NAME="reveric-android-arm64-v8a-v${VERSION_NAME}.apk"

cd "$SCRIPT_DIR"

info()  { echo -e "\n==> $*" >&2; }
ok()    { echo "==> $*" >&2; }
warn()  { echo -e "\033[33m==> WARNING: $*\033[0m" >&2; }
err()   { echo -e "\033[31m==> ERROR: $*\033[0m" >&2; exit 1; }

cleanup() {
  local status=$?

  if [[ -f "$BACKUP" ]]; then
    info "还原 pubspec.yaml..."
    if mv "$BACKUP" "$SCRIPT_DIR/pubspec.yaml"; then
      ok "pubspec.yaml 已还原"
    else
      warn "pubspec.yaml 还原失败，请手动用 $BACKUP 覆盖"
    fi
  fi

  [[ -n "$BUILD_STAMP" ]] && rm -f "$BUILD_STAMP"

  # 失败时保留构建日志供排查，成功后不留垃圾。
  if [[ -n "$BUILD_LOG" && -f "$BUILD_LOG" ]]; then
    if [[ $status -ne 0 ]]; then
      warn "完整构建日志: $BUILD_LOG"
    else
      rm -f "$BUILD_LOG"
    fi
  fi

  if [[ $status -ne 0 ]]; then
    echo -e "\033[31m==> 构建未完成，dist/ 未更新。\033[0m" >&2
  fi
}
trap cleanup EXIT

# ----- 前置检查 -----
info "检查前置依赖..."

command -v python3 >/dev/null 2>&1 || err "未找到 python3"

if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  # CI 由 flutter-action 安装工作流固定的 SDK，并配置 PATH。
  command -v flutter >/dev/null 2>&1 || err "未找到 flutter，请先在 CI 中安装项目固定的 Flutter SDK"
  FLUTTER=(flutter)
else
  command -v fvm >/dev/null 2>&1 || err "未找到 fvm，请先安装 FVM 以使用项目 .fvmrc 固定的 Flutter SDK"
  FLUTTER=(fvm flutter)
  # 本地构建为原生工具提供项目 SDK；安装前后保留完整 revision。
  if [[ ! -x "$SCRIPT_DIR/.fvm/flutter_sdk/bin/dart" ]]; then
    info "链接项目 FVM SDK..."
    cp "$SCRIPT_DIR/.fvmrc" "$SCRIPT_DIR/.fvmrc.bak"
    fvm install
    mv "$SCRIPT_DIR/.fvmrc.bak" "$SCRIPT_DIR/.fvmrc"
  fi
  export PATH="$SCRIPT_DIR/.fvm/flutter_sdk/bin:$PATH"
fi
"${FLUTTER[@]}" --version

# ----- 备份 pubspec.yaml -----
info "备份 pubspec.yaml..."
cp "$SCRIPT_DIR/pubspec.yaml" "$BACKUP"

# ----- 设置版本号 -----
if [[ -n "$VERSION" ]]; then
  info "设置版本号为 $VERSION ..."
  python3 <<EOF
import re
with open('pubspec.yaml', 'r', encoding='utf-8') as f:
    content = f.read()
content = re.sub(r'^version:.*', 'version: $VERSION', content, flags=re.MULTILINE)
with open('pubspec.yaml', 'w', encoding='utf-8') as f:
    f.write(content)
print(f'Version set to $VERSION')
EOF
fi

# ----- 禁用 sqlite3 hooks -----
info "禁用 pubspec.yaml 中的 sqlite3 hooks..."
python3 <<EOF
with open('pubspec.yaml', 'r', encoding='utf-8') as f:
    lines = f.readlines()
in_hooks = False
with open('pubspec.yaml', 'w', encoding='utf-8') as f:
    for line in lines:
        if line.startswith('hooks:'):
            in_hooks = True
            f.write('# ' + line)
        elif in_hooks and (line.startswith('  ') or line.startswith('    ')):
            f.write('# ' + line)
        else:
            in_hooks = False
            f.write(line)
print('sqlite3 hooks disabled')
EOF

# ----- 清除 sqlite3 hook 缓存 -----
info "清除 sqlite3 hook 缓存..."
HOOK_CACHE="$SCRIPT_DIR/.dart_tool/hooks_runner/sqlite3"
if [[ -d "$HOOK_CACHE" ]]; then
  rm -rf "$HOOK_CACHE"
  ok "sqlite3 hook 缓存已清除"
fi

# ----- flutter pub get -----
info "${FLUTTER[*]} pub get..."
"${FLUTTER[@]}" pub get

# 注意: 构建期间不要并行跑其他 fvm flutter 命令（test / analyze / pub get）。
# 它们会用 releaseMode=false 重写 android/.../GeneratedPluginRegistrant.java，把
# dev_dependencies 里的原生插件（patrol）写回去；若发生在本次构建注入之后、javac 读取之前，
# 会导致 "package pl.leancode.patrol does not exist" 编译失败。

# ----- 构建 APK -----
info "按 ABI 构建 Android APK (${FLUTTER[*]} build apk --release --split-per-abi --target-platform android-arm64)..."
BUILD_LOG="$(mktemp "${TMPDIR:-/tmp}/reveric-android-build.XXXXXX")"
# 记录构建起点，用于判断产物是本次生成的还是上次遗留的。
BUILD_STAMP="$(mktemp "${TMPDIR:-/tmp}/reveric-android-stamp.XXXXXX")"

set +e
"${FLUTTER[@]}" build apk --release --split-per-abi --target-platform android-arm64 2>&1 | tee "$BUILD_LOG"
BUILD_STATUS="${PIPESTATUS[0]}"
set -e

# ----- 校验产物 -----
# Flutter 3.44 + AGP 8.11 中 Gradle 输出路径变为 apk/release/ 而非 flutter-apk/，
# Flutter 工具自身的 APK 检测会返回假阴性退出码，但 APK 实际已编译成功。
# 只容忍这一种已知误报：必须同时满足「日志里是这条特定信息」且「APK 确实存在」，
# 其余任何非零退出码一律视为真实失败并中断，避免把上次构建残留的旧 APK 当成本次产物。
FALSE_NEGATIVE_MARKER="Gradle build failed to produce an .apk file"

APK_DIR=""
ARM64_APK=""
# 两个位置都可能有产物：AGP 原始输出在 apk/release/，Flutter 工具还会往 flutter-apk/ 拷一份。
# 必须取 mtime 最新的那份，否则会拿到上次构建的旧文件、误判成「产物不是本次生成的」。
for candidate in \
  "$SCRIPT_DIR/build/app/outputs/flutter-apk" \
  "$SCRIPT_DIR/build/app/outputs/apk/release"; do
  candidate_apk="$candidate/app-arm64-v8a-release.apk"
  if [[ -f "$candidate_apk" ]] &&
    { [[ -z "$ARM64_APK" ]] || [[ "$candidate_apk" -nt "$ARM64_APK" ]]; }; then
    APK_DIR="$candidate"
    ARM64_APK="$candidate_apk"
  fi
done

if [[ "$BUILD_STATUS" -ne 0 ]]; then
  if ! grep -qF "$FALSE_NEGATIVE_MARKER" "$BUILD_LOG"; then
    err "构建失败 (exit $BUILD_STATUS)，且不是已知的 Flutter APK 检测误报。上面是 Gradle 的真实报错。"
  fi
  if [[ -z "$ARM64_APK" ]]; then
    err "构建失败 (exit $BUILD_STATUS)：Flutter 报告未产出 APK，磁盘上也确实找不到 arm64-v8a APK。"
  fi
  warn "Flutter 工具未能定位 APK（已知误报），但产物存在，继续。"
fi

if [[ -z "$ARM64_APK" ]]; then
  err "构建命令返回成功，但没有找到 arm64-v8a APK。请检查 build/app/outputs/ 目录。"
fi

# 产物早于本次构建：正常的 Gradle 增量 up-to-date 也会这样，不算错误，但必须让人看见，
# 以免把上次的包当成本次改动的产物发出去。
if [[ ! "$ARM64_APK" -nt "$BUILD_STAMP" ]]; then
  APK_MODIFIED_AT="$(python3 -c 'from datetime import datetime; from pathlib import Path; import sys; print(datetime.fromtimestamp(Path(sys.argv[1]).stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S"))' "$ARM64_APK")"
  warn "arm64-v8a APK 不是本次构建生成的（最后修改于 ${APK_MODIFIED_AT}）。"
  warn "Gradle 判定为 up-to-date。若你自上次构建后改过代码，说明没有重新打包，请核对。"
fi

echo ""
echo -e "\033[32m产物路径:\033[0m"
ls -lh "$APK_DIR"/app-*-release.apk

# ----- 复制自动更新包 -----
mkdir -p "$DIST_VERSION_DIR"
cp "$ARM64_APK" "$DIST_VERSION_DIR/$ANDROID_RELEASE_NAME"
SRC_SIZE="$(wc -c <"$ARM64_APK" | tr -d ' ')"
DEST_SIZE="$(wc -c <"$DIST_VERSION_DIR/$ANDROID_RELEASE_NAME" | tr -d ' ')"
if [[ "$SRC_SIZE" != "$DEST_SIZE" ]]; then
  err "复制到 dist/ 后大小不一致（$SRC_SIZE != $DEST_SIZE），产物不可信。"
fi
ok "已复制 arm64-v8a 自动更新包: dist/$VERSION_NAME/$ANDROID_RELEASE_NAME"

echo ""
ok "Android APK 构建完成！"
