#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d -t notion-ops-build)"
trap 'rm -rf "$BUILD_DIR"' EXIT
APP_DIR="$BUILD_DIR/本地 MCP 控制台.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
swiftc -O -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
  "$REPO_DIR/desktop/Runtime.swift" "$REPO_DIR/desktop/ConsoleTypes.swift" \
  "$REPO_DIR/desktop/ConsoleModel.swift" "$REPO_DIR/desktop/ConsoleView.swift" \
  "$REPO_DIR/desktop/ConsoleApp.swift" -o "$BUILD_DIR/LocalOpsConsole"
swift "$REPO_DIR/desktop/GenerateIcon.swift" "$BUILD_DIR/AppIcon.iconset"
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns"
cp "$BUILD_DIR/LocalOpsConsole" "$APP_DIR/Contents/MacOS/LocalOpsConsole"
cp "$BUILD_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c 'Clear dict' "$APP_DIR/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string local.notion-ops.console' "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string 本地 MCP 控制台' "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string 本地 MCP 控制台' "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string LocalOpsConsole' "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 0.1.0' "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 1' "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 13.0' "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LocalOpsRepository string $REPO_DIR" "$APP_DIR/Contents/Info.plist"
SIGNING_IDENTITY="${NOTION_OPS_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk '/Developer ID Application:/{print $2; exit}')"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development:/{print $2; exit}')"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo '未找到有效签名身份，请设置 NOTION_OPS_SIGNING_IDENTITY。' >&2
  exit 1
fi
codesign --force --sign "$SIGNING_IDENTITY" "$APP_DIR"
codesign --verify --strict --verbose=2 "$APP_DIR"
FINAL_APP="$REPO_DIR/dist/本地 MCP 控制台.app"
mkdir -p "$REPO_DIR/dist"
if [[ -e "$FINAL_APP" ]]; then
  EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$FINAL_APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$EXISTING_ID" != 'local.notion-ops.console' ]]; then
    echo 'dist 中存在其他同名 App，未覆盖。' >&2
    exit 1
  fi
  BACKUP_DIR="$(mktemp -d "$HOME/.Trash/notion-ops-previous.XXXXXX")"
  mv "$FINAL_APP" "$BACKUP_DIR/"
  echo "旧版本保留在：$BACKUP_DIR"
fi
mv "$APP_DIR" "$FINAL_APP"
echo "构建完成：$FINAL_APP"
