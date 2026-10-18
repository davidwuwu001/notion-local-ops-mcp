#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_DIR/dist/本地 MCP 控制台.app"
DESKTOP_LINK="$HOME/Desktop/本地 MCP 控制台.app"
bash "$REPO_DIR/scripts/build-desktop.sh"
if [[ -e "$DESKTOP_LINK" || -L "$DESKTOP_LINK" ]]; then
  if [[ -L "$DESKTOP_LINK" && "$(readlink "$DESKTOP_LINK")" == "$APP_DIR" ]]; then
    echo "桌面入口已存在：$DESKTOP_LINK"
    exit 0
  fi
  echo "桌面存在其他同名项目，未覆盖：$DESKTOP_LINK" >&2
  exit 1
fi
ln -s "$APP_DIR" "$DESKTOP_LINK"
echo "桌面入口已创建：$DESKTOP_LINK"
