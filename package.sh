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
SIGN_ID="${SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    # 이름에 팀 ID 가 붙어 있어 그대로 codesign 에 넘길 수 있다.
    SIGN_ID="$(security find-identity -v 2>/dev/null \
        | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
fi
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [ -n "$SIGN_ID" ]; then
    echo "==> 서명: $SIGN_ID"
    HARDENED=YES
else
    echo "==> 서명: 건너뜀 (Developer ID Application 인증서가 없습니다)"
    echo "    → ad-hoc 서명으로 묶습니다. 받는 사람이 Gatekeeper 를 우회해야 합니다."
    HARDENED=NO
fi
if [ -n "$SIGN_ID" ] && [ -n "$NOTARY_PROFILE" ]; then
    echo "==> 공증: 프로필 \"$NOTARY_PROFILE\" 사용"
    NOTARIZE=1
else
    echo "==> 공증: 건너뜀"
    NOTARIZE=0
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
DMG="$DIST/ClaudeUsageWidget-$VERSION.dmg"
echo "==> DMG 생성"
DMG_SRC="$(mktemp -d)"
cp -R "$STAGE_APP" "$DMG_SRC/"
# 드래그 설치를 위한 /Applications 별칭.
ln -s /Applications "$DMG_SRC/Applications"
rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$DMG_SRC" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMG_SRC"
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
    SLUG="$(printf '%s' "$REMOTE" | sed -E 's|.*github\.com[:/]+([^/]+/[^/]+?)(\.git)?/?$|\1|')"
    [ "$SLUG" = "$REMOTE" ] && SLUG=""
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

    실측 사용량(claude.ai)을 쓰려면 Claude 데스크톱 앱이 설치·로그인돼 있어야 하고,
    첫 조회 때 키체인 접근 허용 창에서 «항상 허용» 을 눌러야 합니다.
  EOS
EOF
else
cat <<'EOF'

  caveats <<~EOS
    실측 사용량(claude.ai)을 쓰려면 Claude 데스크톱 앱이 설치·로그인돼 있어야 하고,
    첫 조회 때 키체인 접근 허용 창에서 «항상 허용» 을 눌러야 합니다.
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
