#!/bin/bash
#
# 스파이크를 빌드해 실행한다.
#
# .app 번들로 감싸는 이유: WKWebsiteDataStore.default() 는 번들 식별자가 필요하다.
# 그런데 `open` 으로 띄우면 stdout 이 사라져 진단을 못 본다. 그래서 번들을 만들고
# **내부 실행 파일을 터미널에서 직접** 실행한다 — Bundle.main 은 .app 을 가리키고
# 출력은 터미널에 남는다.
#
# 사용:
#   ./spike/run.sh              # WKWebView 기본 UA
#   SPIKE_UA=chrome   ./spike/run.sh
#   SPIKE_UA=electron ./spike/run.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/.build"
APP="$BUILD/WKWebViewSSOSpike.app"
MACOS="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>            <string>spike</string>
	<key>CFBundleIdentifier</key>            <string>sdh.WKWebViewSSOSpike</string>
	<key>CFBundleName</key>                  <string>WKWebViewSSOSpike</string>
	<key>CFBundlePackageType</key>           <string>APPL</string>
	<key>CFBundleShortVersionString</key>    <string>0.1</string>
	<key>LSMinimumSystemVersion</key>        <string>15.0</string>
	<key>NSHighResolutionCapable</key>       <true/>
</dict>
</plist>
PLIST

echo "==> 컴파일"
swiftc -o "$MACOS/spike" "$HERE/WKWebViewSSOSpike.swift"

echo "==> ad-hoc 서명"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "    (서명 생략)"

if [ -n "${SPIKE_BUILD_ONLY:-}" ]; then
    echo "==> 빌드만 하고 끝냅니다 (SPIKE_BUILD_ONLY)"
    codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature" || true
    exit 0
fi

echo "==> 실행 — 창에서 로그인하고 «진단 실행» 을 누르십시오."
echo
exec "$MACOS/spike"
