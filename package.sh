#!/bin/bash
#
# 배포용 .dmg 와 Homebrew Cask 파일을 만든다.
#
# 자격에 따라 하는 일이 달라진다 — 있는 것만 자동으로 쓴다.
#
#   Developer ID 인증서 있음  → 서명 + Hardened Runtime
#   + 공증 프로필 있음        → 공증(notarize) + 스테이플 → Gatekeeper 통과
#   둘 다 없음                → ad-hoc 서명 그대로. 받는 사람이 quarantine 을
#                               풀어야 하며, 생성되는 Cask 에 그 안내가 들어간다.
#
# 사용법:
#   ./package.sh
#   SIGN_ID="Developer ID Application: 홍길동 (TEAMID)" ./package.sh
#   NOTARY_PROFILE=notary ./package.sh          # notarytool store-credentials 로 미리 등록
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$ROOT/ClaudeUsageWidgetApp"
PROJECT="$PROJECT_DIR/ClaudeUsageWidgetApp.xcodeproj"
BUILD_DIR="$PROJECT_DIR/.build-dist"
DIST="$ROOT/dist"
APP_NAME="ClaudeUsageWidgetApp.app"
VOLNAME="Claude Usage Widget"
CASK_TOKEN="claude-usage-widget"
ENTITLEMENTS="$PROJECT_DIR/ClaudeUsageWidget/ClaudeUsageWidget.entitlements"

die() { echo "오류: $*" >&2; exit 1; }

command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild 를 찾을 수 없습니다. Xcode 를 설치하세요."

# ── 자격 확인 ────────────────────────────────────────────────────────────────
# 자격 탐색 규칙은 install.sh 와 공유한다 (signing.sh 주석 참고).
# shellcheck source=signing.sh
source "$(cd "$(dirname "$0")" && pwd)/signing.sh"
resolve_signing_identity
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [ -n "$SIGN_ID" ]; then
    echo "==> 서명: $SIGN_ID"
    HARDENED=YES
    if [ "$SIGN_KIND" = "development" ]; then
        echo "    Apple Development 인증서입니다 — 서명은 안정되지만 공증은 할 수 없습니다."
        echo "    받는 사람은 여전히 Gatekeeper 를 우회해야 합니다."
    fi
else
    SIGN_KIND=""
    echo "==> 서명: 건너뜀 (Developer ID Application·Apple Development 인증서가 없습니다)"
    echo "    → ad-hoc 서명으로 묶습니다. 받는 사람이 Gatekeeper 를 우회해야 합니다."
    HARDENED=NO
fi

if [ -z "$NOTARY_PROFILE" ] || [ -z "$SIGN_ID" ]; then
    echo "==> 공증: 건너뜀"
    NOTARIZE=0
elif [ "$SIGN_KIND" = "development" ]; then
    # Apple Development 로 서명한 것을 공증에 올리면 거부된다. 시도해서 실패하게 두지 않는다.
    echo "==> 공증: 건너뜀 (Apple Development 서명은 공증할 수 없습니다)"
    NOTARIZE=0
else
    echo "==> 공증: 프로필 \"$NOTARY_PROFILE\" 사용"
    NOTARIZE=1
fi

# ── 빌드 ─────────────────────────────────────────────────────────────────────
echo "==> Release 빌드 (Hardened Runtime: $HARDENED)"
mkdir -p "$BUILD_DIR" "$DIST"
LOG="$BUILD_DIR/build.log"
if ! xcodebuild \
        -project "$PROJECT" \
        -scheme ClaudeUsageWidgetApp \
        -configuration Release \
        -destination 'platform=macOS' \
        -derivedDataPath "$BUILD_DIR" \
        ENABLE_HARDENED_RUNTIME=$HARDENED \
        build > "$LOG" 2>&1; then
    echo >&2; echo "빌드 실패. 로그 마지막 30줄:" >&2; echo >&2
    tail -30 "$LOG" >&2
    echo >&2; echo "전체 로그: $LOG" >&2
    exit 1
fi
grep -E "\*\* BUILD" "$LOG" || true

BUILT="$BUILD_DIR/Build/Products/Release/$APP_NAME"
[ -d "$BUILT" ] || die "빌드 산출물을 찾을 수 없습니다: $BUILT"

VERSION="$(plutil -extract CFBundleShortVersionString raw "$BUILT/Contents/Info.plist")"
MIN_OS="$(plutil -extract LSMinimumSystemVersion raw "$BUILT/Contents/Info.plist")"
echo "    버전 $VERSION · 최소 macOS $MIN_OS"

# ── 스테이징 (원본 산출물을 건드리지 않는다) ──────────────────────────────────
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$BUILT" "$STAGE/$APP_NAME"
STAGE_APP="$STAGE/$APP_NAME"

# ── 서명 ─────────────────────────────────────────────────────────────────────
if [ -n "$SIGN_ID" ]; then
    echo "==> 코드 서명"
    # 안쪽(익스텐션)부터 서명하고 바깥 앱을 마지막에 서명한다.
    # --deep 은 Apple 이 권장하지 않으므로 쓰지 않는다.
    while IFS= read -r appex; do
        [ -n "$appex" ] || continue
        echo "    $(basename "$appex")"
        codesign --force --timestamp --options runtime \
                 --entitlements "$ENTITLEMENTS" \
                 --sign "$SIGN_ID" "$appex"
    done < <(find "$STAGE_APP/Contents/PlugIns" -maxdepth 1 -name "*.appex" 2>/dev/null)

    echo "    $APP_NAME"
    codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$STAGE_APP"

    echo "==> 서명 검증"
    codesign --verify --deep --strict --verbose=2 "$STAGE_APP" 2>&1 | tail -3
fi

# ── DMG ──────────────────────────────────────────────────────────────────────
#
# 배경 이미지·볼륨 아이콘·아이콘 배치를 입히려면 rw 이미지로 만들어 마운트한 뒤
# Finder 로 창을 꾸미고 압축(UDZO)으로 변환해야 한다. assets/ 가 없거나 Finder
# 자동화가 막혀 있으면 꾸미기만 건너뛰고 평범한 DMG 를 그대로 만든다.
#
DMG="$DIST/ClaudeUsageWidget-$VERSION.dmg"
echo "==> DMG 생성"
DMG_SRC="$(mktemp -d)"
cp -R "$STAGE_APP" "$DMG_SRC/"
# 드래그 설치를 위한 /Applications 별칭.
ln -s /Applications "$DMG_SRC/Applications"

# 배경 이미지 — 다중 해상도 TIFF 한 장으로 Retina 까지 커버한다 (assets/make-images.swift).
DMG_BG="$ROOT/assets/dmg-background.tiff"
if [ -f "$DMG_BG" ]; then
    mkdir -p "$DMG_SRC/.background"
    cp "$DMG_BG" "$DMG_SRC/.background/background.tiff"
fi

# 볼륨 아이콘 — 앱 아이콘 PNG 들이 iconutil 규격 이름 그대로라 바로 묶을 수 있다.
# 이미지에는 아직 넣지 않는다. Finder 가 창을 갱신할 때 볼륨 루트의
# .VolumeIcon.icns 를 지우고 커스텀 아이콘 플래그까지 되돌리므로, 창을 꾸민
# **뒤에** 복사해야 최종 DMG 까지 남는다.
VOL_ICNS=""
APPICONSET="$PROJECT_DIR/ClaudeUsageWidgetApp/Assets.xcassets/AppIcon.appiconset"
if [ -d "$APPICONSET" ] && command -v iconutil >/dev/null 2>&1; then
    ISET="$(mktemp -d)/VolumeIcon.iconset"
    mkdir -p "$ISET"
    cp "$APPICONSET"/icon_*.png "$ISET/" 2>/dev/null || true
    # 볼륨 아이콘은 512 까지면 충분하다 — 1024 를 넣으면 icns 만 700KB 넘게 붙는다.
    rm -f "$ISET/icon_512x512@2x.png"
    if iconutil -c icns "$ISET" -o "$(dirname "$ISET")/VolumeIcon.icns" 2>/dev/null; then
        VOL_ICNS="$(dirname "$ISET")/VolumeIcon.icns"
    fi
fi

rm -f "$DMG"
RW_DMG="$(mktemp -d)/rw.dmg"
# .DS_Store 를 쓸 여유를 두고 크기를 잡는다.
DMG_KB=$(( $(du -sk "$DMG_SRC" | cut -f1) + 20000 ))
hdiutil create -volname "$VOLNAME" -srcfolder "$DMG_SRC" -ov \
               -fs HFS+ -format UDRW -size "${DMG_KB}k" "$RW_DMG" >/dev/null

# 같은 이름의 볼륨이 이미 붙어 있으면 macOS 가 "... 1" 로 이름을 바꿔 마운트하므로,
# AppleScript 에는 실제 마운트 이름을 넘긴다. (grep 이 빈손이어도 스크립트를 죽이지 않게 || true)
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" \
         | grep -o '/Volumes/.*' | head -1 || true)"
if [ -n "$MOUNT" ]; then
    VOL_ACTUAL="$(basename "$MOUNT")"
    # 창 크기·아이콘 위치·배경은 배경 이미지(640×400)에 맞춘 좌표다.
    if [ -f "$MOUNT/.background/background.tiff" ]; then
        if osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL_ACTUAL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 140, 840, 568}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 12
        set background picture of opts to file ".background:background.tiff"
        set position of item "$APP_NAME" of container window to {160, 205}
        set position of item "Applications" of container window to {480, 205}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT
        then
            echo "    창 배경·아이콘 배치 적용"
        else
            echo "    경고: Finder 자동화가 막혀 창 꾸미기를 건너뜁니다 (DMG 자체는 정상)"
            echo "          시스템 설정 → 개인정보 보호 및 보안 → 자동화 에서 터미널의 Finder 제어를 허용하세요."
        fi
    fi

    # 볼륨 아이콘 — Finder 스텝 이후에 넣는다(위 주석 참고). 플래그까지 세워야 보인다.
    if [ -n "$VOL_ICNS" ] && command -v SetFile >/dev/null 2>&1; then
        cp "$VOL_ICNS" "$MOUNT/.VolumeIcon.icns"
        SetFile -a C "$MOUNT" 2>/dev/null || true
    fi
    sync
    hdiutil detach "$MOUNT" >/dev/null || hdiutil detach "$MOUNT" -force >/dev/null
else
    echo "    경고: rw 이미지를 마운트하지 못해 창 꾸미기를 건너뜁니다 (DMG 자체는 정상)"
fi

hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -rf "$(dirname "$RW_DMG")" "$DMG_SRC" ${VOL_ICNS:+"$(dirname "$VOL_ICNS")"}
echo "    $DMG ($(du -h "$DMG" | cut -f1))"

# ── 공증 ─────────────────────────────────────────────────────────────────────
if [ "$NOTARIZE" -eq 1 ]; then
    echo "==> 공증 제출 (수 분 걸릴 수 있습니다)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "==> 스테이플"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
fi

# ── Cask 생성 ────────────────────────────────────────────────────────────────
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

# 저장소 slug 을 원격에서 뽑아 url 에 채운다. 원격이 없으면 자리표시자를 남긴다.
SLUG=""
if REMOTE="$(git -C "$ROOT" remote get-url origin 2>/dev/null)"; then
    # BSD sed 는 non-greedy(+?) 를 모른다 — 꼬리를 먼저 떼고 앞을 지우는 순서로 뽑는다.
    case "$REMOTE" in
        *github.com*)
            SLUG="$(printf '%s' "$REMOTE" | sed -E -e 's|\.git/?$||' -e 's|/$||' -e 's|.*github\.com[:/]+||')"
            ;;
    esac
fi
if [ -z "$SLUG" ]; then
    SLUG="YOUR_GITHUB_USER/claude-usage-widget"
    echo "==> 경고: git 원격이 없어 Cask url 에 자리표시자를 넣었습니다 ($SLUG)"
fi

# 최소 macOS 를 Homebrew 심볼로 옮긴다.
case "${MIN_OS%%.*}" in
    15) MACOS_SYM=":sequoia" ;;
    14) MACOS_SYM=":sonoma" ;;
    13) MACOS_SYM=":ventura" ;;
    *)  MACOS_SYM="\"$MIN_OS\"" ;;
esac

CASK="$DIST/$CASK_TOKEN.rb"
{
cat <<EOF
cask "$CASK_TOKEN" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$SLUG/releases/download/v#{version}/ClaudeUsageWidget-#{version}.dmg"
  name "Claude Usage Widget"
  desc "Menu bar and Notification Center widget for Claude usage limits"
  homepage "https://github.com/$SLUG"

  depends_on macos: ">= $MACOS_SYM"

  app "$APP_NAME"

  zap trash: [
    "~/.claude/.usage-widget-snapshot.json",
    "~/.claude/.usage-widget-config.json",
    "~/.claude/.usage-widget-account.json",
    "~/Library/WebKit/sdh.ClaudeUsageWidgetApp",
    "~/Library/HTTPStorages/sdh.ClaudeUsageWidgetApp",
    "~/Library/Caches/sdh.ClaudeUsageWidgetApp",
  ]
EOF

if [ "$NOTARIZE" -eq 0 ]; then
cat <<'EOF'

  caveats <<~EOS
    이 빌드는 Apple 공증(notarization)을 받지 않았습니다. 처음 열 때 Gatekeeper 가
    막으면 quarantine 속성을 지우세요:

      xattr -dr com.apple.quarantine /Applications/ClaudeUsageWidgetApp.app

    또는 처음부터 붙지 않게 설치할 수 있습니다:

      brew install --cask --no-quarantine claude-usage-widget

    실측 사용량(claude.ai)을 쓰려면 설정에서 «Claude 로그인» 을 눌러 앱 안의 로그인
    창에서 로그인하세요. 세션은 앱의 웹 저장소에만 남고, 키체인은 쓰지 않습니다.
    Claude 데스크톱 앱은 필요하지 않습니다.

    앱을 지울 때 로그인 세션까지 함께 지우려면:  brew uninstall --zap --cask claude-usage-widget
  EOS
EOF
else
cat <<'EOF'

  caveats <<~EOS
    실측 사용량(claude.ai)을 쓰려면 설정에서 «Claude 로그인» 을 눌러 앱 안의 로그인
    창에서 로그인하세요. 세션은 앱의 웹 저장소에만 남고, 키체인은 쓰지 않습니다.
    Claude 데스크톱 앱은 필요하지 않습니다.

    앱을 지울 때 로그인 세션까지 함께 지우려면:  brew uninstall --zap --cask claude-usage-widget
  EOS
EOF
fi

echo "end"
} > "$CASK"

echo
echo "완료."
echo "  DMG   : $DMG"
echo "  SHA256: $SHA"
echo "  Cask  : $CASK"
echo
if [ "$NOTARIZE" -eq 0 ]; then
    echo "이 빌드는 공증되지 않았습니다 — 받는 사람이 Gatekeeper 를 우회해야 합니다."
    echo "정식 배포는 Apple Developer Program(유료) 가입 후:"
    echo "  1) Developer ID Application 인증서 발급"
    echo "  2) xcrun notarytool store-credentials notary --apple-id <id> --team-id <team>"
    echo "  3) NOTARY_PROFILE=notary ./package.sh"
    echo
fi
echo "배포 순서:"
echo "  1) gh release create v$VERSION \"$DMG\" --title \"v$VERSION\""
echo "  2) $CASK 을 homebrew-tap 저장소의 Casks/ 에 복사"
echo "  3) 사용자는  brew tap $(dirname "$SLUG")/tap && brew install --cask $CASK_TOKEN"
