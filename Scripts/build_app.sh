#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ReceiptTodo"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> 编译 $APP_NAME (release)..."
cd "$ROOT_DIR"
if [[ "${1:-}" != "--bundle-only" ]]; then
  swift build -c release
fi

BIN_PATH="$ROOT_DIR/.build/release/$APP_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "错误：未找到编译产物 $BIN_PATH"
  exit 1
fi

echo "==> 组装 $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
if [[ -d "$ROOT_DIR/Resources" ]]; then
  cp -R "$ROOT_DIR/Resources/"* "$RESOURCES_DIR/" 2>/dev/null || true
fi

cat > "$CONTENTS_DIR/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>ReceiptTodo</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.receipttodo</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>小票待办</string>
    <key>CFBundleDisplayName</key>
    <string>小票待办</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>小票待办需要使用麦克风录下你的每日语音计划，以便自动整理成今日待办清单。</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>小票待办需要使用语音识别将你的语音实时转为文字，以便整理成今日待办清单。</string>
</dict>
</plist>
EOF

echo "==> 进行本地 Ad-hoc 签名..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "✅ 构建完成：$APP_BUNDLE"
echo "   直接双击或在终端运行：open \"$APP_BUNDLE\""
