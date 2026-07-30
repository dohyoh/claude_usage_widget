#!/bin/bash
#
# Release 빌드를 만들어 /Applications 에 설치한다.
# Xcode를 열지 않고 이 스크립트만 실행하면 된다.
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)/ClaudeUsageWidgetApp"
PROJECT="$PROJECT_DIR/ClaudeUsageWidgetApp.xcodeproj"
BUILD_DIR="$PROJECT_DIR/.build"
APP_NAME="ClaudeUsageWidgetApp.app"
DEST="/Applications/$APP_NAME"
LOG="$BUILD_DIR/build.log"
# project.pbxproj 의 MACOSX_DEPLOYMENT_TARGET 과 맞춘다.
REQUIRED_MACOS="15.0"

die() { echo "오류: $*" >&2; exit 1; }

echo "==> 사전 점검"

# 1. Xcode 본체가 필요하다. Command Line Tools 만으로는 WidgetKit 익스텐션 타겟을
#    빌드할 수 없어서, 여기서 먼저 걸러 주면 원인을 알기 어려운 빌드 실패를 피할 수 있다.
command -v xcodebuild >/dev/null 2>&1 \
    || die "xcodebuild 를 찾을 수 없습니다. App Store 에서 Xcode 를 설치하세요."

if ! xcodebuild -version >/dev/null 2>&1; then
    cat >&2 <<'EOF'
오류: xcodebuild 가 Xcode 를 가리키지 않습니다 (Command Line Tools 만 설치된 상태로 보입니다).
      Xcode 를 설치한 뒤 다음을 실행하세요:

        sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
EOF
    exit 1
fi

# 2. 배포 타겟보다 낮은 macOS 에서는 빌드가 되더라도 실행되지 않는다.
CURRENT_MACOS="$(sw_vers -productVersion)"
if [ "$(printf '%s\n%s\n' "$REQUIRED_MACOS" "$CURRENT_MACOS" | sort -V | head -1)" != "$REQUIRED_MACOS" ]; then
    die "이 앱은 macOS $REQUIRED_MACOS 이상이 필요합니다 (현재 $CURRENT_MACOS)."
fi

echo "    Xcode $(xcodebuild -version | head -1 | awk '{print $2}') · macOS $CURRENT_MACOS"

echo "==> Release 빌드"
mkdir -p "$BUILD_DIR"
# 전체 로그는 파일에 남기고 화면에는 결과만 보여준다. 실패하면 끝부분을 그대로 출력해
# 사용자가 원인을 바로 볼 수 있게 한다.
if ! xcodebuild \
        -project "$PROJECT" \
        -scheme ClaudeUsageWidgetApp \
        -configuration Release \
        -destination 'platform=macOS' \
        -derivedDataPath "$BUILD_DIR" \
        build > "$LOG" 2>&1; then
    echo >&2
    echo "빌드 실패. 로그 마지막 30줄:" >&2
    echo >&2
    tail -30 "$LOG" >&2
    echo >&2
    echo "전체 로그: $LOG" >&2
    exit 1
fi
grep -E "error:|warning: .*(deprecated|unused)|\*\* BUILD" "$LOG" || true

BUILT="$BUILD_DIR/Build/Products/Release/$APP_NAME"
[ -d "$BUILT" ] || die "빌드 산출물을 찾을 수 없습니다: $BUILT"

echo "==> 실행 중인 이전 버전 종료"
# 이전 버전이 떠 있으면 위젯이 낡은 번들을 붙잡고 있게 된다.
osascript -e 'quit app "ClaudeUsageWidgetApp"' 2>/dev/null || true
pkill -f "$APP_NAME/Contents/MacOS/ClaudeUsageWidgetApp" 2>/dev/null || true
sleep 1

echo "==> $DEST 에 설치"
if [ -d "$DEST" ] && [ ! -w "/Applications" ]; then
    die "/Applications 에 쓸 수 없습니다. 권한을 확인하세요."
fi
rm -rf "$DEST"
cp -R "$BUILT" "$DEST"

echo "==> 위젯 익스텐션 재등록"
# LaunchServices 가 새 번들 위치를 알아야 위젯 갤러리에 뜬다.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DEST" 2>/dev/null || true
killall -q ChronoAgent 2>/dev/null || true   # 알림센터 위젯 호스트
killall -q WidgetKit\ Simulator 2>/dev/null || true

echo "==> 실행"
open "$DEST"
sleep 2

if pgrep -f "$DEST/Contents/MacOS/ClaudeUsageWidgetApp" > /dev/null; then
    echo
    echo "설치 완료. 메뉴바에 아이콘이 나타났습니다."
    echo "  · 실측 사용량: 첫 조회 때 키체인 접근 허용 창이 뜨면 «항상 허용» 을 누르세요"
    echo "  · 로그인 시 자동 실행: 메뉴바 → 한도 설정 → 실행"
    echo "  · 위젯 추가: 데스크톱 우클릭 → 위젯 편집 → \"Claude Code 사용량\""
else
    echo "앱이 실행되지 않았습니다. 직접 열어보세요: open \"$DEST\"" >&2
    exit 1
fi
