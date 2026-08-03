#!/bin/bash
# 打包 Usage-show.app 并发布到 GitHub Release
# 用法: ./scripts/publish.sh [版本号，如 0.3.0；默认读取 Info.plist 的 CFBundleShortVersionString]
# 前置: git 已配置 github.com 凭据（osxkeychain），gh CLI 可用

set -e
cd "$(dirname "$0")/.."

# 版本号
VERSION="${1:-$(plutil -extract CFBundleShortVersionString raw Usage-show.app/Contents/Info.plist)}"
echo "==> 版本: v$VERSION"

# 1. Release 构建
echo "==> 构建 release 二进制"
swift build -c release --disable-sandbox --scratch-path /tmp/token_show_build

# 2. 组装 .app（Info.plist 从项目模板复制，避免手动维护版本号漂移）
APP_STAGE=/tmp/Usage-show.app
rm -rf "$APP_STAGE"
mkdir -p "$APP_STAGE/Contents/MacOS" "$APP_STAGE/Contents/Resources"
cp /tmp/token_show_build/release/token_show "$APP_STAGE/Contents/MacOS/token_show"
# 图标
cp Assets/AppIcon.icns "$APP_STAGE/Contents/Resources/AppIcon.icns" 2>/dev/null || true
# Info.plist 模板
if [ -f "scripts/Info.plist.template" ]; then
  sed "s/__VERSION__/$VERSION/g" scripts/Info.plist.template > "$APP_STAGE/Contents/Info.plist"
else
  echo "警告: scripts/Info.plist.template 不存在，跳过 Info.plist 生成" >&2
fi

# 3. ad-hoc 签名（清理 ._ 后签，避免 exFAT AppleDouble 干扰）
find "$APP_STAGE" -name "._*" -delete 2>/dev/null || true
codesign --force --deep --sign - "$APP_STAGE"
find "$APP_STAGE" -name "._*" -delete 2>/dev/null || true
codesign --verify --verbose "$APP_STAGE"

# 4. 同步到项目目录（保留本地产物）
rm -rf Usage-show.app
ditto "$APP_STAGE" Usage-show.app
find Usage-show.app -name "._*" -delete 2>/dev/null || true
find Usage-show.app -name ".DS_Store" -delete 2>/dev/null || true
codesign --force --deep --sign - Usage-show.app
find Usage-show.app -name "._*" -delete 2>/dev/null || true
codesign --verify --verbose Usage-show.app
echo "==> 本地 Usage-show.app 已更新 (v$VERSION)"

# 5. 打包 zip（干净卷，禁 ._ 文件）
ZIP=/tmp/Usage-show-v$VERSION-macos-arm64.zip
rm -f "$ZIP"
rm -rf /tmp/release_stage && mkdir -p /tmp/release_stage
ditto Usage-show.app /tmp/release_stage/Usage-show.app
find /tmp/release_stage -name "._*" -delete 2>/dev/null || true
cd /tmp/release_stage && COPYFILE_DISABLE=1 zip -rq "$ZIP" Usage-show.app
cd - >/dev/null
echo "==> zip 打包完成: $ZIP ($(du -h "$ZIP" | cut -f1))"

# 5b. 打包 dmg（拖拽安装布局：Usage-show.app + Applications 快捷方式）
DMG=/tmp/Usage-show-v$VERSION-macos-arm64.dmg
rm -f "$DMG"
rm -rf /tmp/dmg_stage && mkdir -p /tmp/dmg_stage
ditto Usage-show.app /tmp/dmg_stage/Usage-show.app
find /tmp/dmg_stage -name "._*" -delete 2>/dev/null || true
ln -sf /Applications /tmp/dmg_stage/Applications
if hdiutil create -volname "Usage-show" -srcfolder /tmp/dmg_stage -ov -format UDZO "$DMG" >/tmp/dmg_build.log 2>&1; then
  echo "==> dmg 打包完成: $DMG ($(du -h "$DMG" | cut -f1))"
else
  echo "警告: dmg 打包失败（hdiutil 无权限）。请在有权限的终端手动运行:"
  echo "  rm -rf /tmp/dmg_stage && mkdir -p /tmp/dmg_stage"
  echo "  ditto Usage-show.app /tmp/dmg_stage/Usage-show.app"
  echo "  ln -sf /Applications /tmp/dmg_stage/Applications"
  echo "  hdiutil create -volname Usage-show -srcfolder /tmp/dmg_stage -ov -format UDZO /tmp/Usage-show-v$VERSION-macos-arm64.dmg"
  DMG=""  # 不传 dmg 资产
fi

# 6. 提交代码（若 Assets/版本变化未提交）
if ! git diff --quiet; then
  git add -A
  git -c user.name="token_show" -c user.email="dev@local" commit -m "release: v$VERSION" || true
fi

# 7. 推送代码 + tag
git -c http.version=HTTP/1.1 push origin main || true
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
  echo "==> tag v$VERSION 已存在，跳过"
else
  git tag "v$VERSION"
  git -c http.version=HTTP/1.1 push origin "v$VERSION" 2>&1 | tail -1 || true
fi

# 8. 创建/更新 Release 并上传资产（gh 用 keychain 凭据）
GH_TOKEN=$(python3 -c "
import subprocess
r = subprocess.run(['git','credential','fill'], input='protocol=https\nhost=github.com\n\n', capture_output=True, text=True, timeout=10)
for line in r.stdout.splitlines():
    if line.startswith('password='): print(line[9:])
") && export GH_TOKEN

if gh release view "v$VERSION" --repo liu247/Usage-show >/dev/null 2>&1; then
  echo "==> release v$VERSION 已存在，上传资产"
  gh release upload "v$VERSION" "$ZIP" --repo liu247/Usage-show --clobber
  if [ -n "$DMG" ]; then
    gh release upload "v$VERSION" "$DMG" --repo liu247/Usage-show --clobber
  fi
else
  echo "==> 创建 release v$VERSION"
  if [ -n "$DMG" ]; then
    gh release create "v$VERSION" \
      --repo liu247/Usage-show \
      --title "Usage-show v$VERSION" \
      --notes "macOS 菜单栏 token 额度显示工具（codex / deepseek / kiro）
安装：下载 .dmg，打开后拖 Usage-show.app 到 Applications；若 Gatekeeper 提示，右键→打开。" \
      "$ZIP" "$DMG"
  else
    gh release create "v$VERSION" \
      --repo liu247/Usage-show \
      --title "Usage-show v$VERSION" \
      --notes "macOS 菜单栏 token 额度显示工具（codex / deepseek / kiro）" \
      "$ZIP"
  fi
fi

echo ""
echo "✅ 完成: https://github.com/liu247/Usage-show/releases/tag/v$VERSION"
