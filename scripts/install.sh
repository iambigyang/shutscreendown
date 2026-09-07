#!/bin/bash
# 安装脚本：把两个 App 复制到 /Applications。
# 若已开启开机自启，登录项会自动改指向 /Applications 的新位置（下次登录生效）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

[[ -d "$ROOT/ShutScreenDown.app" && -d "$ROOT/RecoveryScreen.app" ]] || {
  echo "错误：未找到构建产物，请先运行 ./build_app.sh"
  exit 1
}

echo "==> 复制 App 到 /Applications ..."
rm -rf /Applications/ShutScreenDown.app /Applications/RecoveryScreen.app
cp -R "$ROOT/ShutScreenDown.app" /Applications/
cp -R "$ROOT/RecoveryScreen.app" /Applications/
codesign --force --sign - /Applications/ShutScreenDown.app >/dev/null 2>&1 || true
codesign --force --sign - /Applications/RecoveryScreen.app >/dev/null 2>&1 || true

# 若登录项存在，把指向改成 /Applications 下的新位置
PLIST="$HOME/Library/LaunchAgents/com.shutscreendown.app.plist"
if [[ -f "$PLIST" ]]; then
  NEWEXE="/Applications/ShutScreenDown.app/Contents/MacOS/ShutScreenDown"
  /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $NEWEXE" "$PLIST"
  echo "==> 已更新开机自启指向 /Applications"
fi

echo "==> 完成。打开 /Applications/ShutScreenDown.app 即可使用。"
