#!/bin/bash
# 打包 DMG：把两个 App 放入可拖拽安装的磁盘映像。
# 用法：./scripts/make_dmg.sh   （需先运行 ./build_app.sh）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$ROOT/.dmg_stage"
OUT="$ROOT/ShutScreenDown.dmg"

[[ -d "$ROOT/ShutScreenDown.app" && -d "$ROOT/RecoveryScreen.app" ]] || {
  echo "错误：未找到构建产物，请先运行 ./build_app.sh"
  exit 1
}

rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE"
cp -R "$ROOT/ShutScreenDown.app" "$STAGE/"
cp -R "$ROOT/RecoveryScreen.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> 打包 DMG ..."
hdiutil create -volname "熄屏" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"
echo "==> 完成：$OUT"
