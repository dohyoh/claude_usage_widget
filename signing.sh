#!/bin/bash
#
# install.sh 와 package.sh 가 함께 쓰는 코드 서명 자격 탐색.
#
# ad-hoc 서명은 designated requirement 가 cdhash 라서 바이너리가 1비트만 바뀌어도 다른
# 신원이 된다. 그러면 코드 신원에 묶인 상태 — 로그인 항목 등록(SMAppService), TCC 허용 —
# 가 재빌드마다 초기화된다. 인증서로 서명하면 DR 이 이렇게 되어 바이너리가 바뀌어도
# 같은 신원으로 남는다:
#
#   identifier "sdh.ClaudeUsageWidgetApp" and anchor apple generic
#     and certificate leaf[subject.CN] = "Apple Development: … (TEAMID)"
#     and certificate 1[field.1.2.840.113635.100.6.2.1]
#
# 인증서를 갱신해도 CN 이 같으면 DR 이 그대로라 상태가 유지된다.
#
# 찾는 순서:
#   1. Developer ID Application — 배포용. 공증까지 갈 수 있는 유일한 자격.
#   2. Apple Development        — 무료 계정으로도 발급된다. 공증은 못 하지만 신원은 안정된다.
#   3. 없으면 ad-hoc (SIGN_ID 가 빈 문자열).
#
# 환경변수 SIGN_ID 로 직접 지정할 수 있다. 그때 SIGN_KIND 는 supplied 가 된다.

# 인증서 이름 하나를 찾아 출력한다. 이름에 팀 ID 가 붙어 있어 그대로 codesign 에 넘긴다.
_find_identity() {
    security find-identity -p codesigning -v 2>/dev/null \
        | grep -o "\"$1: [^\"]*\"" | head -1 | tr -d '"' || true
}

# SIGN_ID 와 SIGN_KIND 를 채운다.
#   SIGN_KIND = developer-id | development | supplied | ""(없음)
resolve_signing_identity() {
    SIGN_ID="${SIGN_ID:-}"
    if [ -n "$SIGN_ID" ]; then
        SIGN_KIND="supplied"
        return
    fi

    SIGN_ID="$(_find_identity 'Developer ID Application')"
    if [ -n "$SIGN_ID" ]; then
        SIGN_KIND="developer-id"
        return
    fi

    SIGN_ID="$(_find_identity 'Apple Development')"
    if [ -n "$SIGN_ID" ]; then
        SIGN_KIND="development"
        return
    fi

    SIGN_KIND=""
}

# 서명 호출(codesign)은 각 스크립트가 직접 한다. 배포용은 공증을 위해 보안 타임스탬프와
# Hardened Runtime 이 필요하지만 로컬 설치는 그렇지 않아, 옵션을 공유하면 한쪽이 망가진다.
