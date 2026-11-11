#!/bin/zsh
# 组装 NX游戏库.app:swift build -c release 后把可执行文件塞进最小 bundle
set -e
cd "$(dirname "$0")"

echo "[1/3] swift build -c release ..."
swift build -c release

BIN=".build/release/NXGameLibrary"
DIST="dist"
APP="$DIST/NX游戏库.app"

echo "[2/3] 组装 $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NXGameLibrary"
chmod +x "$APP/Contents/MacOS/NXGameLibrary"

# app 图标(Switch 风格;由 icon/generate_icon.py 生成)
if [ -f "icon/AppIcon.icns" ]; then
  cp "icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "警告: icon/AppIcon.icns 不存在,跳过图标(可跑 icon/generate_icon.py 生成)" >&2
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>NX游戏库</string>
	<key>CFBundleDisplayName</key>
	<string>NX游戏库</string>
	<key>CFBundleIdentifier</key>
	<string>com.local.nxgamelibrary</string>
	<key>CFBundleVersion</key>
	<string>1.0</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleExecutable</key>
	<string>NXGameLibrary</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

echo "[3/3] 完成: $(cd "$DIST" && pwd)/NX游戏库.app"

# --install:原地覆盖安装到 /Applications(免拖拽;无权限时退到 ~/Applications)
if [ "$1" = "--install" ]; then
  APP_BUILT="$DIST/NX游戏库.app"
  rm -rf "/Applications/NX游戏库.app" 2>/dev/null
  if cp -R "$APP_BUILT" "/Applications/" 2>/dev/null; then
    echo "已安装(覆盖): /Applications/NX游戏库.app"
  else
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/NX游戏库.app"
    cp -R "$APP_BUILT" "$HOME/Applications/"
    echo "已安装(覆盖): ~/Applications/NX游戏库.app"
  fi
fi
