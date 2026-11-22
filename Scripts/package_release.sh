#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-v1.0.0}"
ARCH="$(uname -m)"
APP_BUNDLE="$ROOT_DIR/build/ReceiptTodo.app"
OUT_ZIP="$ROOT_DIR/build/ReceiptTodo-${VERSION}-macOS-${ARCH}.zip"

if [[ "${2:-}" != "--zip-only" ]]; then
  "$ROOT_DIR/Scripts/build_app.sh"
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "错误：未找到 $APP_BUNDLE，请先执行 ./Scripts/build_app.sh"
  exit 1
fi

rm -f "$OUT_ZIP"
echo "==> 打包 GitHub Release 压缩包：$OUT_ZIP..."
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$OUT_ZIP"

echo ""
echo "✅ Release 包已生成：$OUT_ZIP"
ls -lh "$OUT_ZIP"
