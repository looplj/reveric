# Git Worktree 管理命令
# 规范文档: .agents/skills/worktree/SKILL.md
#
# 用法: make <command> <branch-name>
#
# 示例:
#   make wt-create feature/ai-chat     # 基于当前分支创建新分支和 worktree
#   make wt-merge feature/ai-chat      # 合并分支并清理 worktree
#   make wt-delete feature/ai-chat     # 删除分支和 worktree

# 配置
PROJECT_NAME := reveric
WORKTREES_DIR := $(shell dirname $(CURDIR))/$(PROJECT_NAME)-worktrees
BUILD_DIR := build

# 从命令行获取 branch 参数（第一个额外的目标）
BRANCH := $(word 2,$(MAKECMDGOALS))
# 允许 BASE 通过环境变量或 make 变量传入
BASE ?= $(shell git rev-parse --abbrev-ref HEAD)

# 默认显示帮助
.DEFAULT_GOAL := help

# 忽略额外的目标（branch 名），防止 make 报错
%:
	@:

.PHONY: help wt-create wt-merge wt-delete wt-list wt-clean
.PHONY: build-macos build-macos-release build-windows build-windows-release build-linux build-linux-release
.PHONY: build-all build-all-release run-macos run-windows run-linux clean clean-build codegen deps check-agent-rules

help: ## 显示帮助信息
	@echo "Reveric 构建与管理命令"
	@echo "======================="
	@echo ""
	@echo "用法: make <command>"
	@echo ""
	@echo "命令:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "示例:"
	@echo "  make build-macos              # 构建 macOS debug 版本"
	@echo "  make build-macos-release      # 构建 macOS release 版本"
	@echo "  make build-all-release        # 构建所有桌面端 release 版本"
	@echo "  make run-macos                # 运行 macOS 客户端"
	@echo "  make wt-create feature/ai-chat # 创建 worktree"
	@echo ""
	@echo "环境变量:"
	@echo "  BASE=<branch>  - 指定基础分支 (默认: 当前分支)"
	@echo ""
	@echo "Worktrees 目录: $(WORKTREES_DIR)"

wt-create: ## 创建新分支和对应的 worktree
	@if [ -z "$(BRANCH)" ]; then \
		echo "❌ 错误: 请提供分支名"; \
		echo "   用法: make wt-create <branch-name> [BASE=<base-branch>]"; \
		echo "   示例: make wt-create feature/ai-chat"; \
		exit 1; \
	fi
	@echo "🔧 创建 worktree: $(BRANCH)"
	@mkdir -p $(WORKTREES_DIR)
	@$(eval WT_NAME := $(subst /,-,$(BRANCH)))
	@$(eval WT_PATH := $(WORKTREES_DIR)/$(WT_NAME))
	@if [ -d "$(WT_PATH)" ]; then \
		echo "❌ 错误: worktree 已存在: $(WT_PATH)"; \
		exit 1; \
	fi
	@echo "📌 基于分支: $(BASE)"
	@git worktree add $(WT_PATH) -b $(BRANCH) $(BASE)
	@echo "✅ Worktree 创建成功!"
	@echo "   路径: $(WT_PATH)"
	@echo "   分支: $(BRANCH)"
	@echo ""
	@echo "💡 提示: cd $(WT_PATH)"

wt-merge: ## 合并分支到当前分支并自动删除 worktree
	@if [ -z "$(BRANCH)" ]; then \
		echo "❌ 错误: 请提供分支名"; \
		echo "   用法: make wt-merge <branch-name>"; \
		echo "   示例: make wt-merge feature/ai-chat"; \
		exit 1; \
	fi
	@echo "🔀 合并分支: $(BRANCH)"
	@$(eval CURRENT_BRANCH := $(shell git rev-parse --abbrev-ref HEAD))
	@$(eval WT_NAME := $(subst /,-,$(BRANCH)))
	@$(eval WT_PATH := $(WORKTREES_DIR)/$(WT_NAME))
	@echo "📌 当前分支: $(CURRENT_BRANCH)"
	@echo "📌 合并分支: $(BRANCH)"
	@git merge $(BRANCH) --no-edit || (echo "❌ 合并失败，请手动解决冲突" && exit 1)
	@echo "✅ 合并成功"
	@echo ""
	@echo "🧹 清理 worktree..."
	@if [ -d "$(WT_PATH)" ]; then \
		git worktree remove $(WT_PATH) 2>/dev/null || git worktree remove --force $(WT_PATH); \
		echo "✅ 已删除 worktree: $(WT_PATH)"; \
	else \
		echo "⚠️  worktree 目录不存在: $(WT_PATH)"; \
	fi
	@git branch -d $(BRANCH) 2>/dev/null || echo "⚠️  远程分支或未完全合并，使用 'git branch -D $(BRANCH)' 强制删除"
	@git worktree prune
	@echo ""
	@echo "✅ 完成! 分支 $(BRANCH) 已合并到 $(CURRENT_BRANCH) 并清理"

wt-delete: ## 删除分支和对应的 worktree
	@if [ -z "$(BRANCH)" ]; then \
		echo "❌ 错误: 请提供分支名"; \
		echo "   用法: make wt-delete <branch-name>"; \
		echo "   示例: make wt-delete feature/ai-chat"; \
		exit 1; \
	fi
	@echo "🗑️  删除分支和 worktree: $(BRANCH)"
	@$(eval WT_NAME := $(subst /,-,$(BRANCH)))
	@$(eval WT_PATH := $(WORKTREES_DIR)/$(WT_NAME))
	@if [ -d "$(WT_PATH)" ]; then \
		git worktree remove $(WT_PATH) 2>/dev/null || git worktree remove --force $(WT_PATH); \
		echo "✅ 已删除 worktree: $(WT_PATH)"; \
	else \
		echo "⚠️  worktree 目录不存在: $(WT_PATH)"; \
	fi
	@git branch -d $(BRANCH) 2>/dev/null || (echo "⚠️  分支未完全合并，强制删除中..." && git branch -D $(BRANCH))
	@git worktree prune
	@echo ""
	@echo "✅ 完成! 分支 $(BRANCH) 和 worktree 已删除"

wt-list: ## 列出所有 worktree
	@echo "📋 Worktree 列表"
	@echo "==============="
	@git worktree list
	@echo ""
	@echo "📁 本地 worktrees 目录:"
	@ls -la $(WORKTREES_DIR) 2>/dev/null || echo "   (目录为空或不存在)"

wt-clean: ## 清理已删除分支的 worktree 引用
	@echo "🧹 清理 worktree 引用..."
	@git worktree prune -v
	@echo "✅ 清理完成"

# ============================================================
# 桌面端构建命令
# ============================================================

build-macos: ## 构建 macOS 客户端 (debug)
	@echo "🍎 构建 macOS 客户端 (debug)..."
	@bash third/fjs/tool/build_runtime.sh
	@bash third/fvp/macos/setup.sh
	@fvm flutter build macos --debug
	@echo "✅ macOS 构建完成: $(BUILD_DIR)/macos/Build/Products/Debug/Reveric.app"

build-macos-release: ## 构建 macOS 客户端 (release)
	@echo "🍎 构建 macOS 客户端 (release)..."
	@bash third/fjs/tool/build_runtime.sh
	@bash third/fvp/macos/setup.sh
	@fvm flutter build macos --release
	@echo "✅ macOS 构建完成: $(BUILD_DIR)/macos/Build/Products/Release/Reveric.app"

build-windows: ## 构建 Windows 客户端 (debug)
	@echo "🪟 构建 Windows 客户端 (debug)..."
	@fvm flutter build windows --debug
	@echo "✅ Windows 构建完成: $(BUILD_DIR)/windows/x64/runner/Debug/reveric.exe"

build-windows-release: ## 构建 Windows 客户端 (release)
	@echo "🪟 构建 Windows 客户端 (release)..."
	@fvm flutter build windows --release
	@echo "✅ Windows 构建完成: $(BUILD_DIR)/windows/x64/runner/Release/reveric.exe"

build-linux: ## 构建 Linux 客户端 (debug)
	@echo "🐧 构建 Linux 客户端 (debug)..."
	@fvm flutter build linux --debug
	@echo "✅ Linux 构建完成: $(BUILD_DIR)/linux/x64/debug/bundle/reveric"

build-linux-release: ## 构建 Linux 客户端 (release)
	@echo "🐧 构建 Linux 客户端 (release)..."
	@fvm flutter build linux --release
	@echo "✅ Linux 构建完成: $(BUILD_DIR)/linux/x64/release/bundle/reveric"

build-all: ## 构建所有桌面端客户端 (debug)
	@echo "🏗️  构建所有桌面端客户端 (debug)..."
	@$(MAKE) build-macos
	@$(MAKE) build-windows
	@$(MAKE) build-linux
	@echo "✅ 所有桌面端客户端构建完成!"

build-all-release: ## 构建所有桌面端客户端 (release)
	@echo "🏗️  构建所有桌面端客户端 (release)..."
	@$(MAKE) build-macos-release
	@$(MAKE) build-windows-release
	@$(MAKE) build-linux-release
	@echo "✅ 所有桌面端客户端构建完成!"

run-macos: ## 运行 macOS 客户端 (debug)
	@echo "🍎 运行 macOS 客户端..."
	@[ -e .fvm/flutter_sdk ] || fvm use --skip-pub-get
	@bash third/fjs/tool/build_runtime.sh
	@bash third/fvp/macos/setup.sh
	@fvm flutter run -d macos

run-windows: ## 运行 Windows 客户端 (debug)
	@echo "🪟 运行 Windows 客户端..."
	@fvm flutter run -d windows

run-linux: ## 运行 Linux 客户端 (debug)
	@echo "🐧 运行 Linux 客户端..."
	@fvm flutter run -d linux

# ============================================================
# Fastforge 打包命令 (flutter_distributor -> fastforge)
# ============================================================

package-release: ## 使用 fastforge 打包 release (所有桌面端)
	@echo "📦 打包 release 版本 (所有桌面端)..."
	@bash third/fjs/tool/build_runtime.sh
	@if [ "$$(uname -s)" = Darwin ]; then bash third/fvp/macos/setup.sh; fi
	@fvm exec fastforge release --name release
	@echo "✅ 打包完成，输出目录: dist/"

package-dev: ## 使用 fastforge 打包 dev 版本 (profile)
	@echo "📦 打包 dev 版本 (profile)..."
	@bash third/fjs/tool/build_runtime.sh
	@if [ "$$(uname -s)" = Darwin ]; then bash third/fvp/macos/setup.sh; fi
	@fvm exec fastforge release --name dev
	@echo "✅ 打包完成，输出目录: dist/"

package-macos-release: ## 使用 fastforge 打包 macOS release (DMG)
	@echo "🍎 打包 macOS release (DMG)..."
	@bash third/fjs/tool/build_runtime.sh
	@bash third/fvp/macos/setup.sh
	@fvm exec fastforge release --name release --jobs macos-dmg
	@echo "✅ macOS DMG 打包完成"

package-windows-release: ## 使用 fastforge 打包 Windows release (EXE)
	@echo "🪟 打包 Windows release (EXE)..."
	@fvm exec fastforge release --name release --jobs windows-exe
	@echo "✅ Windows EXE 打包完成"

package-linux-release: ## 使用 fastforge 打包 Linux release (zip)
	@echo "🐧 打包 Linux release (zip)..."
	@bash linux/ffmpeg/prepare.sh
	@fvm exec fastforge release --name release --jobs linux-zip
	@echo "✅ Linux zip 打包完成"

clean: ## 清理 Flutter 构建缓存
	@echo "🧹 清理 Flutter 构建缓存..."
	@fvm flutter clean
	@echo "✅ 清理完成"

clean-build: ## 清理构建产物
	@echo "🧹 清理构建产物..."
	@rm -rf $(BUILD_DIR)
	@fvm flutter clean
	@echo "✅ 清理完成"

codegen: ## 运行代码生成 (build_runner)
	@echo "⚙️  运行代码生成..."
	@fvm flutter pub run build_runner build --delete-conflicting-outputs
	@echo "✅ 代码生成完成"

deps: ## 安装依赖
	@echo "📦 安装依赖..."
	@fvm flutter pub get
	@echo "✅ 依赖安装完成"

check-agent-rules: ## 检查 Agent 指令与规则引用
	@bash .agents/scripts/check-agent-rules.sh

.PHONY: plugins plugins-test
plugins: ## 构建内置插件并更新 assets 产物
	cd plugins && npm ci && node build.mjs

plugins-test: ## 验证内置插件类型和逻辑
	cd plugins && npm ci && node build.mjs --test

# 官网：字体源文件和 fonttools 虚拟环境缓存在 site/.cache，首次运行时下载
SITE_CACHE := site/.cache
SITE_VENV := $(SITE_CACHE)/venv
SITE_FONT_SRC := $(SITE_CACHE)/NotoSerifSC.ttf
SITE_FONT_URL := https://github.com/google/fonts/raw/main/ofl/notoserifsc/NotoSerifSC%5Bwght%5D.ttf

.PHONY: site-fonts site-build site-deploy
$(SITE_VENV):
	python3 -m venv $(SITE_VENV)
	$(SITE_VENV)/bin/pip install -q fonttools brotli

$(SITE_FONT_SRC):
	@mkdir -p $(SITE_CACHE)
	curl -fL -o $(SITE_FONT_SRC) "$(SITE_FONT_URL)"

site-fonts: $(SITE_VENV) $(SITE_FONT_SRC) ## 按官网用字重新裁剪字体子集
	$(SITE_VENV)/bin/python site/scripts/subset_fonts.py $(SITE_FONT_SRC)

site-build: site-fonts ## 构建官网到 site/dist（版本取最新正式 tag）
	node site/build.mjs

site-deploy: site-build ## 构建并部署官网到 Cloudflare Pages
	npx wrangler pages deploy site/dist --project-name=reveric-site --branch=unstable --commit-dirty=true
