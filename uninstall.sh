#!/bin/bash
#
# 설치된 앱을 제거한다. `--purge` 를 주면 설정·스냅샷 파일까지 지운다.
#
set -euo pipefail

APP_NAME="ClaudeUsageWidgetApp.app"
BUNDLE_ID="sdh.ClaudeUsageWidgetApp"
DEST="/Applications/$APP_NAME"
SNAPSHOT="$HOME/.claude/.usage-widget-snapshot.json"
CONFIG="$HOME/.claude/.usage-widget-config.json"
ACCOUNT="$HOME/.claude/.usage-widget-account.json"

# 앱은 자체 로그인 창으로 claude.ai 세션을 확보하고, 그 세션을 WebKit 저장소에 둔다.
# 아래 세 곳에 살아 있는 로그인이 들어 있다 — 앱을 지우면 함께 지운다.
WEB_DATA=(
    "$HOME/Library/WebKit/$BUNDLE_ID"
    "$HOME/Library/HTTPStorages/$BUNDLE_ID"
    "$HOME/Library/Caches/$BUNDLE_ID"
)

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

# 로그인 세션은 자격증명이다. 설정과 달리 --purge 를 기다리지 않고 항상 지운다 —
# 앱을 지웠는데 claude.ai 로그인이 디스크에 남아 있으면 안 된다.
echo "==> 로그인 세션(웹 저장소) 삭제"
for path in "${WEB_DATA[@]}"; do
    [ -e "$path" ] && rm -rf "$path" && echo "    $path"
done

if [ "$PURGE" -eq 1 ]; then
    echo "==> 설정·스냅샷·계정 캐시 삭제"
    rm -f "$SNAPSHOT" "$CONFIG" "$ACCOUNT"
else
    echo
    echo "설정은 남겨 두었습니다. 함께 지우려면:  ./uninstall.sh --purge"
fi

echo
echo "제거 완료."
echo "로그인 시 자동 실행을 켜 두었다면 시스템 설정 → 일반 → 로그인 항목에서 확인하세요."
