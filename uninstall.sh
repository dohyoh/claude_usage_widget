#!/bin/bash
#
# 설치된 앱을 제거한다. `--purge` 를 주면 설정·스냅샷 파일까지 지운다.
#
set -euo pipefail

APP_NAME="ClaudeUsageWidgetApp.app"
DEST="/Applications/$APP_NAME"
SNAPSHOT="$HOME/.claude/.usage-widget-snapshot.json"
CONFIG="$HOME/.claude/.usage-widget-config.json"

PURGE=0
case "${1:-}" in
    --purge) PURGE=1 ;;
    "")      ;;
    *)       echo "사용법: $0 [--purge]" >&2; exit 2 ;;
esac

echo "==> 실행 중이면 종료"
osascript -e 'quit app "ClaudeUsageWidgetApp"' 2>/dev/null || true
pkill -f "$APP_NAME/Contents/MacOS/ClaudeUsageWidgetApp" 2>/dev/null || true
sleep 1

if [ -d "$DEST" ]; then
    echo "==> $DEST 삭제"
    rm -rf "$DEST"
else
    echo "==> $DEST 없음 — 건너뜁니다"
fi

# 위젯 갤러리에서도 사라지도록 위젯 호스트를 재시작한다.
killall -q ChronoAgent 2>/dev/null || true

if [ "$PURGE" -eq 1 ]; then
    echo "==> 설정·스냅샷 삭제"
    rm -f "$SNAPSHOT" "$CONFIG"
else
    echo
    echo "설정은 남겨 두었습니다. 함께 지우려면:  ./uninstall.sh --purge"
fi

echo
echo "제거 완료."
echo "로그인 시 자동 실행을 켜 두었다면 시스템 설정 → 일반 → 로그인 항목에서 확인하세요."
