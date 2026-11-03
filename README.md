<p align="center">
  <img src="assets/hero.png" alt="Claude Usage Widget — 메뉴바와 알림센터에서 Claude 사용량을 한눈에" width="880">
</p>

# Claude Usage Widget

macOS 메뉴바와 알림센터 위젯에서 **Claude 사용량**(5시간 한도 창 / 주간)을 확인하는 프로젝트입니다.

두 개의 데이터 소스를 씁니다:

1. **claude.ai 실측 (소진율)** — 앱 안의 로그인 창에서 `claude.ai`에 로그인하면 서버가 계산한 **실제 소진율(%)** 과 정확한 리셋 시각을 가져옵니다. `/usage`가 보여주는 값과 같고, Claude Code·데스크톱·웹을 모두 포함한 **그 계정 전체** 사용량입니다. **화면의 모든 소진율은 여기서만 옵니다** — 실측이 없으면 소진율을 추정해 대신 채우지 않고 사유를 알립니다.
2. **로컬 로그 (토큰 상세)** — `~/.claude` 세션 로그를 파싱해 서버가 주지 않는 토큰 수와 모델별 분해를 채웁니다. 이 로그는 늘 **Claude Code 계정**의 활동이므로, 연동 계정과 다르면 상세 헤더에 그 계정을 적습니다.

---

## 📋 개요

- **메뉴바 앱** — 5초 간격 로컬 갱신 + 서버 실측 조회(주기 설정 가능, 기본 60초). 아이콘은 **5시간 창 소진율에 따라 채워지는 원형 링**이고, 소진율(%)은 **링 왼쪽**에 숫자로 함께 뜹니다. 기본 «이중 링»은 안쪽 얇은 링으로 **창에서 지난 시간**까지 같이 보여 줘, 남은 시간보다 빨리 태우는 중인지 한눈에 보입니다. 클릭하면 상세 패널이 열립니다 — 제목 옆 **↻** 로 즉시 갱신하고, 오른쪽 위 **⚙︎** 로 설정을 엽니다. 패널에는 소진율 아래로 서버가 주지 않는 **토큰 상세**(이번 5시간 창·오늘·이번 주기, 모델별)가 붙습니다. 설정의 **메뉴바 표시** 에서 링·막대·게이지·숫자만 등 **여섯 가지 디자인**과 **글자 색**을 고를 수 있고, **주간 소진율**·**리셋까지 남은 시간**을 링 오른쪽에 덧붙일 수 있습니다(둘 다면 위아래 두 줄).
- **알림센터·데스크톱 위젯** — 같은 소진율을 작은/중간 크기 위젯으로 표시합니다. 두 크기 모두 5시간 창과 주간을 함께 보여주고, 토큰 상세는 자리가 넉넉한 메뉴바 패널이 담당합니다.

두 개를 함께 두는 이유는 WidgetKit의 갱신 주기 때문입니다. 위젯 타임라인은 `.after(30초)`를 요청해도 시스템이 그대로 지켜주지 않고 실질 수 분~수십 분 간격으로 깨우며, 하루 갱신 예산도 제한됩니다. **초 단위 실시간은 메뉴바 앱이 담당하고, 위젯은 같은 데이터를 느리게 따라가는 보조 표시**입니다.

---

## 🔓 실측 사용량 — 로그인 세션으로 계정 전체 사용량 불러오기

`claude.ai`에 로그인한 세션으로 서버가 계산한 실제 사용량을 받아옵니다. 세션은 두 곳에서 올 수 있고, 설정의 **쿠키 원본**에서 고릅니다. **Claude 데스크톱 앱은 어느 쪽에도 필요하지 않습니다.**

### 로그인·계정 선택은 기본 브라우저에서

설정 → 실측 사용량 (claude.ai) → **연동 계정**의 버튼이 시스템 기본 브라우저에서 `claude.ai`를 엽니다. 평소 쓰는 브라우저에서 계정을 고르면 그 세션을 그대로 씁니다. 앱은 자기 로그인 창을 띄우지 않습니다.

버튼 하나가 세 가지를 합니다:

```
1. 쿠키 원본을 «기본 브라우저» 로 고정한다      — 브라우저에서 고른 계정이 실제로 쓰이도록
2. 곧바로 한 번 조회한다                        — 이미 로그인돼 있으면 여기서 끝
3. 브라우저를 열고 로그인이 끝나는지 지켜본다    — 끝나면 자동으로 가져온다 (최대 5분, 3초 간격)
```

- `NSWorkspace.open`이 LaunchServices에 맡기므로 **사용자가 기본으로 지정한 브라우저**가 그대로 열립니다.
- 브라우저는 로그인이 끝났다는 신호를 앱에 주지 않습니다. 그래서 세션 쿠키의 **지문**(`sessionFingerprint`)이 생기거나 바뀔 때까지 짧은 간격으로 확인합니다. 지문만 비교하므로 세션 값 자체는 그 경로로 흘러나오지 않습니다.
- **Safari가 기본 브라우저면** 쿠키를 읽을 수 없으므로 앱 안의 로그인 창으로 넘어갑니다. 그때만 `WKWebView` 창이 뜹니다.

### 쿠키 원본 — 세션을 어디서 읽을지

| 선택 | 세션을 읽는 곳 |
| --- | --- |
| **자동** (기본) | 앱 세션 → 만료(401)되면 기본 브라우저 |
| 앱 안의 로그인 창 | `WKWebsiteDataStore` |
| 기본 브라우저 | 그 브라우저의 쿠키 저장소 |
| 특정 브라우저 | 고른 브라우저의 쿠키 저장소 |

연동 계정 버튼으로 로그인하면 원본이 «기본 브라우저» 로 바뀌므로, 보통은 이 설정을 직접 건드릴 일이 없습니다.

**«자동»이 앱 세션을 먼저 보는 이유**: 브라우저를 먼저 보면, 이미 앱에 A계정을 연동해 둔 사용자가 브라우저의 B계정으로 조용히 바뀝니다. 앱 세션이 **401을 받을 때만** 브라우저로 넘어가므로, 소스 전환은 재로그인이 필요한 순간이나 사용자가 직접 로그인 버튼을 눌렀을 때만 일어납니다. 일시적 실패(429·5xx)에는 소스를 바꾸지 않습니다 — 그러면 보이는 계정이 네트워크 사정에 따라 흔들립니다.

**지원 브라우저**: Chromium 계열(Chrome·Edge·Brave·네이버 웨일·Arc·Vivaldi·Chromium)과 Firefox.

```
Chromium:  ~/Library/Application Support/<브랜드>/<프로필>/Cookies   (SQLite, 값은 암호화)
  1. 키체인의 "<브랜드> Safe Storage" 항목이 base64 문자열 키
  2. PBKDF2-HMAC-SHA1(key, salt="saltysalt", 반복 1003회, 16바이트)
  3. AES-128-CBC, IV = 공백 16바이트 — encrypted_value 에서 "v10"/"v11" 접두사를 뺀 본문
  4. 최신 Chromium 은 평문 앞에 sha256(host_key) 32바이트를 붙인다 → 있으면 떼어낸다
Firefox:   ~/Library/Application Support/Firefox/Profiles/<프로필>/cookies.sqlite  (평문)
```

- 브라우저 쿠키를 처음 읽을 때 **키체인 접근 허용 창이 한 번** 뜹니다(«항상 허용»). 복호화 키는 앱 실행당 브라우저별로 한 번만 유도해 메모리에 캐시합니다.
- 프로필이 여러 개면(`Default`, `Profile 1` …) 최근에 쓴 프로필부터 보며 세션 쿠키가 있는 첫 프로필을 씁니다.
- 브라우저가 쥔 파일을 잠그지 않도록 사본을 떠서 읽고, 방금 받은 쿠키가 아직 `-wal`에만 있을 수 있어 곁다리 파일도 함께 복사합니다.
- **Safari는 지원하지 않습니다.** 쿠키가 전체 디스크 접근(TCC) 권한이 필요한 `binarycookies` 형식이라 읽을 수 없습니다. Safari가 기본 브라우저면 «자동»은 앱 세션만 쓰고, «기본 브라우저»를 고르면 그 사유를 그대로 알립니다.
- **UA는 쿠키를 꺼낸 곳에 맞춥니다.** `cf_clearance`가 UA에 묶여 있어서, 브라우저 쿠키를 웹뷰의 Safari UA로 보내면 같은 쿠키인데도 Cloudflare 챌린지를 받을 수 있습니다. 그래서 `ClaudeCookieJar`가 UA를 쿠키와 함께 들고 다니고, Chromium 계열이면 설치된 그 브라우저의 실제 메이저 버전으로 Chrome UA를 만듭니다. (TLS 지문까지 맞추지는 못하므로, 앱 로그인 창 쪽이 Cloudflare 관점에서는 여전히 더 안전합니다.)

### 앱 로그인 창으로 세션 확보 (Safari가 기본이거나 직접 골랐을 때)

```
1. 설정 → 실측 사용량 (claude.ai) → 쿠키 원본을 «앱 안의 로그인 창» 으로 두고 «Claude 로그인»
2. 앱 안의 로그인 창에서 사용자가 직접 로그인 (이메일 코드 / Google SSO)
3. 세션 쿠키가 생기면 창이 자동으로 닫힌다
4. 세션은 WKWebsiteDataStore(persistent)에 남아 앱을 다시 켜도 유지된다 (대략 4주)
```

- 앱은 세션 값을 **어디에도 복사하지 않습니다.** WebKit 저장소에 그대로 두고 조회할 때 쿠키를 읽습니다.
- 로그인 창과 조회가 **같은 저장소**를 쓰므로 `cf_clearance`·UA가 일관됩니다. 쿠키만 뽑아 다른 클라이언트로 옮기면 Cloudflare 챌린지를 받을 수 있습니다.
- 필요한 쿠키: `sessionKey`(로그인 세션), `lastActiveOrg`(조직 UUID). 실제로는 `claude.ai` 도메인 쿠키 전체를 브라우저처럼 함께 보냅니다. **다른 도메인(Google·hCaptcha) 쿠키는 걸러냅니다** — SSO 왕복에서 같은 저장소에 함께 쌓이므로 필터가 없으면 남의 도메인 자격증명이 `claude.ai` 요청에 실려 나갑니다.
- **Google 로그인은 팝업으로 진행됩니다.** `WKUIDelegate.createWebViewWith`를 구현하지 않으면 `WKWebView`가 `window.open`을 조용히 버리고 SSO가 콜백을 받지 못해 "로그인 중 오류"로 끝납니다. 구현하면 `accounts.google.com` 왕복이 정상 완주합니다 — `disallowed_useragent` 차단은 없고 UA를 바꿀 필요도 없습니다(기본 Safari 계열로 확인).
- 팝업 창을 배열에 들고 있는 상태에서 `close()`를 부르면 과다 해제로 죽습니다. `NSWindow.isReleasedWhenClosed = false` 가 필요하고, `webViewDidClose` 는 WebKit 이 그 웹뷰를 아직 쓰는 중에 오므로 창 정리를 다음 런루프로 미뤄야 합니다.

### 사용량 API

```
GET https://claude.ai/api/organizations/{org_uuid}/usage
Cookie: <고른 쿠키 원본의 claude.ai 쿠키 전체>
User-Agent: <그 쿠키를 꺼낸 곳의 UA>
```

```jsonc
{
  "five_hour": { "utilization": 62.0, "resets_at": "2026-07-29T13:39:59.6+00:00" },
  "seven_day": { "utilization": 39.0, "resets_at": "2026-08-04T05:59:59.6+00:00" },
  "seven_day_opus": null,          // Max 요금제의 주간 Opus 한도(있으면)
  "limits": [ /* session·weekly_all 등 */ ]
}
```

### 어느 계정·어느 조직을 볼지

한 로그인이 여러 조직에 속할 수 있고(개인 Pro + 팀 시트), 어느 조직을 보느냐에 따라 숫자가 달라집니다. 실제 계정에서 관측된 배치입니다(이름은 가명):

| 순서 | 이름 | capabilities |
|---|---|---|
| 1 | 개인 조직 | `api`, `api_individual` |
| 2 | 팀 조직 | **`chat`**, `raven` |

`chat` 권한이 없는 조직이 목록의 **첫 번째**입니다. 그래서 "첫 조직"을 쓰면 사용량 한도가 없는 조직을 잡습니다. 선택 규칙은 이렇습니다.

```
1. 설정에서 고른 조직이 목록에 있으면 그것
2. 없으면 쿠키의 lastActiveOrg
3. 없으면 chat 권한이 있는 첫 조직
4. 없으면 목록의 첫 조직
```

고른 조직이 목록에서 사라지면(탈퇴·계정 변경) 자동 선택으로 내려가되 **그 사실을 알립니다** — 조용히 다른 조직 숫자를 사용자 것으로 보여주지 않습니다. 여러 조직이 있으면 설정에 **조직** 선택이 나타납니다.

**토큰 상세와 계정이 다를 수 있습니다.** 상세는 늘 `~/.claude/projects` 로그, 즉 **Claude Code 계정**의 활동입니다. 연동 계정이 그와 다르면 패널의 상세 헤더가 «Claude Code 로컬 상세 · other@example.com» 으로 바뀝니다. 조회가 실패하면 사유가 뜨지만 계정이 어긋나면 숫자가 멀쩡하게 나오므로, 적어 주지 않으면 구분할 방법이 없습니다.

두 쪽을 이렇게 알아냅니다.

| 쪽 | 출처 | 비용 |
|---|---|---|
| Claude Code 계정 | `~/.claude.json` 의 `oauthAccount` | 인증 불필요, 파일 읽기 |
| 연동 계정 | `GET /api/account` → `email_address` | 로그인·조직이 **바뀔 때만** 1회 |

이메일까지 비교하는 이유는 **조직 UUID가 같아도 계정은 다를 수 있기** 때문입니다 — 같은 팀 조직의 다른 멤버로 로그인한 경우입니다. 이메일을 못 얻으면 조직 단위 비교로 자동 축소됩니다.

계정 정보는 `~/.claude/.usage-widget-account.json` 에 캐시하고, **세션 지문이 바뀌거나 조직이 바뀔 때만** 다시 조회합니다. 지문은 세션 쿠키의 sha256 앞 16자이고, 쿠키 원본은 저장하지 않습니다.

### 경계·프라이버시

- **키체인을 쓰지 않습니다**: 비밀번호 프롬프트가 뜨지 않습니다. 이전에는 Claude 데스크톱 앱이 만든 `Claude Safe Storage` 항목을 읽었고, ad-hoc 서명 때문에 재빌드마다 허용 창이 다시 떴습니다.
- **샌드박스**: 웹뷰·네트워크는 샌드박스가 꺼진 **메뉴바 앱**만 씁니다. 위젯(샌드박스 ON)은 조회를 직접 하지 못하고, 메뉴바 앱이 스냅샷에 넣어 준 실측 %를 읽기만 합니다 — 그래서 메뉴바 앱이 꺼져 있으면 위젯의 값이 그 시점에 멈춥니다.
- **세션은 어디에도 복사하지 않습니다**: WebKit 저장소에만 있고, 앱이 따로 저장하는 것은 **세션 지문(sha256 앞 16자)** 뿐입니다. 지문은 "로그인이 바뀌었는지" 판단에만 씁니다. 스냅샷에는 서버가 준 **백분율·리셋 시각**만 담깁니다.
- **앱을 지우면 세션도 지웁니다**: `./uninstall.sh` 는 설정과 달리 `--purge` 없이도 웹 저장소를 지웁니다 — 앱을 지웠는데 로그인이 디스크에 남아 있으면 안 되기 때문입니다. Homebrew 는 `brew uninstall --zap` 을 쓰세요.
- **조회 주기 설정**: 설정 → 실측 사용량 (claude.ai) → **갱신 주기** 에서 30초·1분(기본)·3분·5분·10분·30분·**수동** 중 고릅니다. '수동'은 앱 시작 때 1회만 가져오고 이후엔 패널의 새로고침 버튼으로만 갱신합니다.
- **세션이 만료되면**(401/403) 다시 로그인하라고 알립니다. 429·5xx 는 일시적 실패로 보고 재로그인을 요구하지 않습니다 — 멀쩡한 세션을 버리게 만들면 안 됩니다.
- **계정을 바꾸려면**: 설정 → 실측 사용량 (claude.ai) → 연동 계정의 «계정 선택» 이 브라우저를 엽니다. 브라우저 세션은 앱이 끊을 수 없으므로(그 브라우저의 로그인입니다) 계정 전환도 거기서 합니다. 앱 안의 로그인 창을 쓰는 중이면 버튼이 «다른 계정» 이고, 웹 저장소와 계정 캐시를 비운 뒤 다시 로그인합니다. 표시만 끄는 토글은 두지 않습니다 — 소진율의 출처가 이것뿐이라 끄면 빈 화면이 남습니다. 표시만 끄는 토글은 두지 않습니다 — 소진율의 출처가 이것뿐이라 끄면 빈 화면이 남고, 정말 끄고 싶을 때는 로그아웃이 더 확실합니다.

관련 코드: [ClaudeServerUsage.swift](ClaudeUsageWidgetApp/ClaudeUsageWidgetApp/ClaudeServerUsage.swift) · [ClaudeLoginWindow.swift](ClaudeUsageWidgetApp/ClaudeUsageWidgetApp/ClaudeLoginWindow.swift) · [ClaudeWebSession.swift](ClaudeUsageWidgetApp/ClaudeUsageWidgetApp/ClaudeWebSession.swift) · [OrganizationChoice.swift](ClaudeUsageWidgetApp/Shared/OrganizationChoice.swift)

---

## 📊 로컬 데이터 소스 (토큰 상세)

서버는 소진율(%)과 리셋 시각만 주고 토큰 수·모델별 분해는 주지 않습니다. 그 빈자리를 Claude Code 세션 로그로 채웁니다.

```
~/.claude/projects/<encoded-cwd>/<session-id>.jsonl
```

`type: "assistant"` 인 줄의 `message.usage` 에서 토큰을 집계합니다.

- **중복 제거**: 같은 요청이 여러 줄에 기록되므로 `requestId`(없으면 `message.id`) 기준으로 한 번만 셉니다.
- **창 경계는 실측에서 받습니다**: 5시간 창의 시작은 서버가 준 `resets_at` 에서 5시간을, 주간 주기의 시작은 7일을 뺀 값입니다. 로그의 첫 요청 시각으로 창을 추정하지 않습니다 — 창을 여는 요청이 Claude 데스크톱·웹에서 나갔으면 로컬 로그에 없어 시작이 늦게 잡히고, 그러면 그 창의 요청 수와 토큰이 통째로 모자라게 나옵니다.
- **경계를 모르면 집계하지 않습니다**: 실측이 없는 동안(미로그인·세션 만료·조회 실패) 5시간 창과 주간 줄은 화면에서 빠집니다. 최근 7일 롤링 같은 근사치를 대신 넣지 않습니다 — 주간 한도는 롤링이 아니라 고정 주기로 리셋되므로 롤링으로 세면 지난 주기 사용량이 섞입니다. **오늘** 사용량만 경계가 로컬 자정이라 늘 남습니다.
- **증분 파싱**: 파일별로 읽은 바이트 위치를 기억해 새로 붙은 부분만 파싱합니다. 마지막 개행 이후는 쓰는 중일 수 있어 다음 회차로 넘깁니다.

표시는 로그에 적힌 토큰만 씁니다 — **캐시 읽기를 제외한 합계**와 **캐시 읽기**를 나눠 적습니다. Claude Code 는 대화 컨텍스트를 매 요청 캐시에서 다시 읽기 때문에 캐시 읽기 토큰이 나머지의 수십 배가 되고, 둘을 합쳐 한 숫자로 만들면 그 사실이 가려집니다.

비용 환산(예상 금액)은 두지 않습니다. 모델별 단가표를 앱이 들고 있어야 하고, 그렇게 계산한 값이 요금제별 실제 청구와 맞는지 확인할 방법이 없습니다.

> 이 로그에는 **Claude 데스크톱 앱 / claude.ai 사용량이 없습니다.** 그쪽 소비량은 서버에만 있습니다. 소진율은 실측에서 오므로 영향이 없지만, 토큰 상세는 Claude Code 몫만 셉니다.

---

## 🗂 파일 구조

```
├── install.sh                       # 사전 점검 → Release 빌드 → /Applications 설치 → 실행
├── uninstall.sh                     # 제거 (--purge 로 설정까지)
├── package.sh                       # DMG + Homebrew Cask 생성 (서명·공증은 자격 있으면 자동)
├── assets/                          # 배포용 이미지와 그 생성기 (톤 토큰 한 곳)
│   ├── make-images.swift            # 아이콘·히어로·소셜·DMG 배경을 한 번에 렌더
│   ├── hero.png                     # README 상단 배너
│   ├── social-preview.png           # GitHub Settings → Social preview (1280×640)
│   ├── app-icon.png                 # 1024 마스터
│   └── dmg-background.tiff          # DMG 창 배경 (1x·2x 다중 해상도)
ClaudeUsageWidgetApp/
├── Shared/                          # 두 타겟이 함께 컴파일하는 코어
│   ├── UsageModels.swift            # TokenCounts, SessionBlock, ServerUsage, UsageSnapshot, 창 경계
│   ├── ClaudeUsageReader.swift      # JSONL 증분 파싱 및 창·일·주 집계
│   ├── UsageSharedStore.swift       # 스냅샷·설정 파일 읽기/쓰기
│   ├── UsageBarView.swift           # 진행 바 + 경고 단계 색
│   ├── MenuBarStyle.swift           # 메뉴바 아이콘 디자인 목록 (설정 파일에 저장)
│   ├── BrowserCookieSource.swift    # 지원 브라우저 목록·프로필 경로·UA 조립
│   └── ClaudeSessionSource.swift    # 쿠키 원본 선택값 → 시도할 소스 순서 (순수 로직)
├── ClaudeUsageWidgetApp/            # 메뉴바 앱 타겟 (샌드박스 OFF)
│   ├── ClaudeUsageWidgetAppApp.swift  # MenuBarExtra + Settings 씬
│   ├── UsageMonitor.swift             # 5초 로컬 + 60초 서버 조회, 스냅샷 발행
│   ├── ClaudeServerUsage.swift        # claude.ai 실측 조회 (조직 선택·실패 분류 배선)
│   ├── ClaudeLoginWindow.swift        # 자체 로그인 창 (WKWebView + Google SSO 팝업)
│   ├── ClaudeWebSession.swift         # WKWebsiteDataStore 의 claude.ai 쿠키 읽기
│   ├── ClaudeSessionSource+App.swift  # 기본 브라우저 판별 + 소스별 쿠키 꺼내기 + 키 캐시
│   ├── BrowserCookieStore.swift       # 브라우저 쿠키 DB 복호화 (키체인·AES·SQLite)
│   ├── MenuBarIcon.swift              # 메뉴바 링·막대 아이콘 렌더링 (AppKit)
│   ├── UsagePanel.swift               # 메뉴바 팝오버 UI
│   └── UsageSettingsView.swift        # 디자인 고르기 + 연동 계정·조직·갱신 주기
└── ClaudeUsageWidget/               # 위젯 익스텐션 타겟 (샌드박스 ON)
    ├── ClaudeUsageWidgetBundle.swift
    ├── ClaudeUsageWidget.swift
    └── ClaudeUsageWidget.entitlements
```

---

## 🔐 샌드박스와 프로세스 간 공유

위젯 익스텐션은 App Sandbox가 강제되므로 `~/.claude` 를 그냥 읽을 수 없습니다. 이 프로젝트는 다음과 같이 풉니다.

| 타겟 | 샌드박스 | 접근 방식 |
|------|----------|-----------|
| 메뉴바 앱 | OFF (`ENABLE_APP_SANDBOX = NO`) | `~/.claude` 직접 읽기, 스냅샷 쓰기, **로그인 웹뷰 · claude.ai 네트워크**. 키체인은 쓰지 않습니다 |
| 위젯 익스텐션 | ON | entitlement의 읽기 전용 예외로 `~/.claude` 의 스냅샷 읽기. 실측 조회는 불가 |

위젯 entitlement:

```xml
<key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
<array><string>/.claude/</string></array>
```

샌드박스 안에서는 `NSHomeDirectory()` 가 컨테이너(`~/Library/Containers/<bundle-id>/Data`)를 가리키므로, `ClaudeUsageReader.defaultClaudeHome` 이 경로에서 실제 홈을 복원합니다.

**App Group을 쓰지 않은 이유**: macOS의 App Group ID는 `<TeamID>.group.*` 형식이어야 하고 팀 서명이 필요합니다. 이 프로젝트는 `DEVELOPMENT_TEAM` 이 비어 있는 ad-hoc 로컬 서명이라 App Group 컨테이너를 쓸 수 없습니다. 대신 파일 두 개로 주고받습니다.

| 파일 | 쓰는 쪽 | 읽는 쪽 |
|------|---------|---------|
| `~/.claude/.usage-widget-snapshot.json` | 메뉴바 앱 (5초) | 위젯 |
| `~/.claude/.usage-widget-config.json` | 메뉴바 앱 (설정 변경 시) | 메뉴바 앱 (시작 시) |
| `~/.claude/.usage-widget-account.json` | 메뉴바 앱 (계정 확인 시) | 메뉴바 앱 (시작 시) |

### 위젯이 보여주는 것

위젯은 **스냅샷만 읽습니다.** 샌드박스 안에서는 `claude.ai` 를 조회할 수 없으니 소진율의 출처가 메뉴바 앱 하나뿐이고, 위젯이 로그를 직접 파싱해도 소진율은 나오지 않습니다.

바마다 **소진율(%) + 리셋까지 남은 시간**을 적고, 하단에 **조회 시각**을 둡니다.

| | 5시간 창 / 주간 바 | 하단 |
|---|---|---|
| 실측이 있을 때 | `62%` · `3h 4m 남음` (서버가 준 `resets_at`) | `✓ 14:22` |
| 실측이 없을 때 | 그리지 않음 | 사유 — `claude.ai에 로그인하면 표시됩니다` 또는 조회 실패 문구 |

**낡았다고 실측을 버리지 않습니다.** 위젯 타임라인은 `.after(5분)` 을 요청해도 시스템이 실질 수 분~수십 분 간격으로 깨우므로, 위젯의 값은 구조적으로 조금 낡아 있습니다. 버리면 화면이 비고 대신 그릴 것이 없으므로, 조금 낡은 참값을 그대로 두고 **조회 시각을 적어 신선도를 읽는 사람이 판단**하게 합니다.

리셋이 지난 창만 버립니다. 그건 낡은 값이 아니라 **지난 창의 값**이라 성격이 다릅니다. 그때는 «새 한도 창을 불러오는 중…» 을 표시하고, 메뉴바 앱이 다음 조회에서 새 창을 받아옵니다.

### 바가 두 줄인 이유 — 사용량과 시간은 다른 축입니다

한도 창은 «얼마나 썼는가»와 «창이 얼마나 지났는가»가 함께 있어야 판단이 됩니다(80%인데 4시간 남았으면 아껴야 하고, 80%인데 10분 남았으면 그냥 쓰면 됩니다). 그래서 바마다 두 줄을 그립니다.

| | 두께 | 색 | 채우는 값 |
|---|---|---|---|
| 사용량(소진율) | 5pt (작은 위젯 4pt) | accent `#D97757` → 70% 주황 → 90% 빨강 | 한도 중 쓴 비율 |
| 창에서 지난 시간 | 3pt | 청록 `#5C999E` 한 톤 (경고 단계 없음) | 창 길이 중 지나간 비율 |

**둘 다 왼쪽에서 자랍니다.** 같은 방향으로 두면 두 바의 길이를 그대로 견줄 수 있어 소진 속도가 한눈에 보입니다 — 사용량 바가 시간 바보다 길면 시간보다 빨리 태우는 중이고, 짧으면 이 창은 여유가 있습니다. 두 바의 구분은 색과 두께가 맡습니다.

시간 색은 accent의 보색 쪽으로 빼되 채도·명도를 accent에 맞춰 두 바가 같은 팔레트로 읽히게 했습니다. 시간이 흐르는 것 자체는 나쁜 상태가 아니므로 경고 단계는 두지 않습니다. 바 아래 글자는 그대로 **리셋까지 남은 시간**(`2h 14m 남음`)이라 채워진 부분과 남은 부분을 각각 눈과 숫자로 읽습니다.

### 크기별 배치

| 크기 | 배치 |
|---|---|
| 작은 (155×155) | 한 열에 **5시간 창 + 주간**. 줄 간격·바 두께를 줄여 155pt 안에 헤더·바 두 개·배지가 잘리지 않고 들어갑니다 |
| 중간 (329×155) | **두 열** — 왼쪽 5시간 창, 오른쪽 주간(+ Max 요금제의 주간 Opus). 높이가 155pt뿐이라 세 개를 세로로 쌓으면 잘립니다 |

> 작은 위젯도 주간을 함께 보여줍니다. 5시간 창만으로는 주간 한도에 얼마나 다가섰는지 알 수 없습니다. 예전에는 바를 세로로 쌓으면서 간격이 넉넉해 주간 바가 위젯 밖으로 밀려 보이지 않았습니다 — `GeometryReader` 로 그리는 바는 공간이 모자라면 높이 0으로 접힙니다.

> Team ID를 넣어 정식 서명으로 전환한다면, App Group 방식으로 바꾸고 위젯 entitlement의 임시 예외를 제거하는 편이 낫습니다. 임시 예외는 App Store 심사에서 거부될 수 있습니다.

---

## 🛠 기술 스택

| 구분 | 내용 |
|------|------|
| 언어 | Swift 5 (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) |
| UI | SwiftUI (`MenuBarExtra`, `@Observable`) |
| 위젯 | WidgetKit (`StaticConfiguration`, `TimelineProvider`) |
| 대상 OS | macOS 26.5 이상 |
| IDE | Xcode 26 (`objectVersion = 77`, 동기화된 폴더) |

---

## 🚀 설치

이 앱은 App Store에 없습니다. **소스를 받아 직접 빌드해 설치**합니다. 자기 머신에서 빌드하므로 Gatekeeper 경고나 별도 서명 절차가 없습니다.

### 요구 사항

| 항목 | 버전 | 비고 |
|------|------|------|
| macOS | **15.0 이상** | `MACOSX_DEPLOYMENT_TARGET` 기준. 낮으면 스크립트가 먼저 알려 줍니다 |
| Xcode | 16 이상 | **Command Line Tools 만으로는 안 됩니다** — WidgetKit 익스텐션 타겟이 있어 Xcode 본체가 필요합니다. (개발·검증은 26.6에서 했습니다) |
| Claude 계정 | (선택) | 실측 사용량을 쓰려면 설정에서 «Claude 로그인» 을 눌러 로그인합니다. Claude 데스크톱 앱은 필요하지 않습니다 |

### 설치

```bash
git clone <이-저장소-URL> claude-usage-widget
cd claude-usage-widget
./install.sh
```

스크립트가 하는 일:

1. **사전 점검** — Xcode 존재·`xcode-select` 경로·macOS 버전을 먼저 확인하고, 문제가 있으면 해결 명령까지 알려 줍니다
2. Release 구성으로 빌드 (산출물 `ClaudeUsageWidgetApp/.build/`, 전체 로그 `.build/build.log`). 실패하면 로그 끝부분을 그대로 보여 줍니다
3. 실행 중인 이전 버전 종료 — 낡은 번들을 위젯이 붙잡고 있는 것을 막습니다
4. `/Applications/ClaudeUsageWidgetApp.app` 로 교체 설치
5. `lsregister` 로 위젯 익스텐션 재등록 후 위젯 호스트 재시작 — `ChronoAgent` 와 **`chronod`** 둘 다입니다. `chronod` 가 위젯 목록의 아이콘·표시 이름을 캐시하므로, 이걸 재시작하지 않으면 «위젯 편집» 목록이 예전 메타데이터를 계속 보여줍니다 (launchd 가 바로 되살립니다)
6. 앱 실행

코드를 수정하거나 `git pull` 한 뒤에는 `./install.sh` 를 다시 실행하면 됩니다.

> 사용량을 보려면 **설정 → 실측 사용량 (claude.ai) → 연동 계정** 의 버튼을 누르세요. 시스템 기본 브라우저에서 claude.ai가 열리고, 거기서 계정을 고르면(이미 로그인돼 있으면 고를 것도 없이) 앱이 그 세션을 가져옵니다. 로그인 전에는 소진율이 표시되지 않습니다 (자세한 배경은 위 [실측 사용량](#-실측-사용량--로그인-세션으로-계정-전체-사용량-불러오기) 절).

### 로그인 시 자동 실행

메뉴바 → **⚙︎ 설정** → **실행** 섹션의 토글을 켭니다 (`SMAppService` 사용). `/Applications` 밖에서 실행 중이면 경로가 바뀔 때 등록이 깨지므로 경고가 표시됩니다 — 설치 후 켜세요.

### 메뉴바 디자인 고르기

메뉴바 → **⚙︎ 설정** → **메뉴바 표시** 에서 카드를 눌러 고릅니다. 카드에는 **지금 값이 그대로 렌더링**되므로 고르기 전에 실제 모습과 폭을 볼 수 있습니다(데이터가 아직 없으면 예시 값으로 그립니다).

| 디자인 | 모양 | 채우는 값 |
|---|---|---|
| **이중 링** (기본) | 링 두 겹 + 숫자 | 바깥 = 5시간 창 소진율, 안쪽 얇은 링 = 그 창에서 지난 시간 |
| 링 | 링 하나 + 숫자 | 소진율만 |
| 링 + 내부 숫자 | 링 안에 숫자 | 소진율만. 메뉴바 폭을 가장 적게 씁니다 |
| 막대 | 얇은 막대 두 겹 + 숫자 | 위 = 소진율, 아래 = 지난 시간 (패널의 진행 바와 같은 모양) |
| 게이지 | SF Symbol + 숫자 | 단색 — 메뉴바 색을 그대로 따릅니다 (v1 모양) |
| 숫자만 | 텍스트만 | — |

링·막대 색은 패널과 같은 기준입니다 — 70% 미만 테라코타, 90% 미만 주황, 그 이상 빨강. 시간 축은 청록으로 빼 두어 두 값을 견줄 수 있습니다. **사용량이 시간보다 앞서 있으면 남은 시간보다 빨리 한도를 태우는 중**입니다.

#### 숫자 배치

**사용량(5시간 창 소진율)은 아이콘 왼쪽**, **주간 소진율과 남은 시간은 아이콘 오른쪽**에 붙습니다. 오른쪽에 둘 다 켜면 한 줄로 늘이지 않고 **글자를 줄여 위아래로 쌓습니다** — 폭을 아끼면서 두 값을 모두 보여주기 위해서입니다.

| 설정 | 라벨 |
|---|---|
| (기본) | `62%` ◍ |
| 주간 소진율 | `62%` ◍ `주 39%` |
| 리셋까지 남은 시간 | `62%` ◍ `2h 14m` |
| 둘 다 | `62%` ◍ `주 39%` / `2h 14m` (오른쪽 두 줄) |

«링 + 내부 숫자»는 소진율을 링 안에 넣으므로 왼쪽이 비고, 오른쪽만 붙습니다. 메뉴바가 좁아지면 macOS가 뒤쪽부터 잘라내므로 필요한 것만 켜는 편이 좋습니다. 실측이 아직 없으면 소진율 자리에 «—» 가 뜨고 오른쪽 항목은 생략됩니다.

#### 글자 색

**글자 색** 줄에서 자주 쓰는 색 6개를 바로 누르거나, 오른쪽 색상 선택기로 임의의 색을 고릅니다. 기본값은 **검정**입니다 — 다크 모드 메뉴바에서는 읽히지 않으므로 **흰색**(두 번째 프리셋)으로 바꿔 쓰세요. 링·막대의 **사용량 색은 경고 단계를 나타내는 값이라 이 설정을 따르지 않습니다.**

> **왜 라벨 전체를 AppKit으로 그리는가** — `MenuBarExtra`의 `label`은 SwiftUI 뷰를 그대로 그리지 않습니다. 내부적으로 `NSStatusItem`의 `image`와 `title`로만 뽑아 쓰기 때문에, 실측해 보면 이렇게 동작합니다.
>
> - `Shape`·`Canvas`·`GeometryReader`는 아무것도 그려지지 않습니다.
> - `Text`를 `Image` **앞**에 두어도 항상 «이미지 → 글자» 순서로 나옵니다(선언 순서 무시).
> - `VStack`으로 `Text`를 두 줄 쌓으면 그 블록이 **통째로 사라집니다.**
> - `Text`에 준 `.foregroundStyle`은 무시됩니다.
>
> 그래서 위의 «왼쪽/오른쪽 배치», «두 줄 축소 표기», «글자 색 지정»은 SwiftUI 라벨로는 불가능하고, 라벨 전체(링·막대·글자)를 한 장의 `NSImage`로 직접 그려 `Image(nsImage:)` 하나로 넘깁니다(`MenuBarIcon.swift`). 색을 살려야 하므로 템플릿 이미지로 두지 않고, 그래서 링의 빈 부분과 기본 글자색은 동적 색 대신 앱의 유효 외관을 보고 고른 값을 씁니다 — 동적 색은 NSImage가 어느 외관에서 래스터화되는지에 따라 배경에 묻힐 수 있습니다. 글자를 이미지로 그리면 VoiceOver가 읽을 것이 없어지므로 `accessibilityDescription`에 같은 내용을 넣습니다.
>
> 이미지 크기는 메뉴바가 24pt까지 자르지 않고 받는 것을 확인했고, 표준 메뉴바에서 위아래 여백이 남도록 링은 **20pt**, 라벨 전체 높이는 22pt 이하로 둡니다.

### 위젯 추가

1. 데스크톱을 우클릭 → **위젯 편집**.
2. **Claude Code 사용량** 을 찾아 원하는 크기로 드래그합니다.

---

## 📦 배포 패키징 (DMG · Homebrew)

`.app` 을 DMG 로 묶고 Homebrew Cask 파일을 만듭니다.

```bash
./package.sh
```

산출물은 `dist/` 에 생깁니다 — `ClaudeUsageWidget-<버전>.dmg` 와 `claude-usage-widget.rb`(SHA256·버전·최소 OS 가 채워진 Cask). 스크립트는 **있는 자격만 자동으로 씁니다.**

DMG 는 `assets/` 가 있으면 **창 배경·볼륨 아이콘·아이콘 배치까지 입혀** 만듭니다 (rw 이미지로 만들어 마운트 → Finder 로 창을 꾸미고 → UDZO 로 압축). Finder 자동화 권한이 없으면 꾸미기만 건너뛰고 평범한 DMG 가 나옵니다 — 실패로 끝나지 않습니다.

### 🎨 배포 이미지

이미지는 모두 `assets/make-images.swift` 하나가 그립니다. 색·형태·모티프 토큰이 그 파일 맨 위 `enum T` 에만 있어, 코랄 값을 하나 바꾸면 아이콘·README 배너·DMG 배경이 함께 따라옵니다.

```bash
./assets/make-images.swift
```

| 산출물 | 크기 | 쓰는 곳 |
|---|---|---|
| `ClaudeUsageWidgetApp/…/AppIcon.appiconset` | 16~1024 (1x·2x) | 앱 아이콘 — 에셋 카탈로그에 직접 씁니다 |
| `ClaudeUsageWidget/…/AppIcon.appiconset` | 16~256 | **위젯 갤러리(«위젯 편집») 목록 아이콘.** 익스텐션 번들이 자기 아이콘을 들고 있어야 뜨므로 같은 아트를 넣습니다 (목록은 작게 쓰므로 256까지) |
| `assets/hero.png` | 2400×760 | README 상단 배너 |
| `assets/social-preview.png` | 1280×640 | GitHub 저장소 **Settings → Social preview** 에 수동 업로드 |
| `assets/dmg-background.tiff` | 640×400 (1x·2x) | DMG 창 배경 — `package.sh` 가 집어 씁니다 |
| `assets/app-icon.png` | 1024×1024 | 릴리스 노트·스토어 등에 쓰는 마스터 |

톤은 앱 UI 와 같은 계열입니다 — 진행 바의 `AccentColor` 가 아이콘 바탕과 같은 코랄(`#D97757`)이고, 경고·위험 단계만 주황·빨강으로 갈라집니다. 볼륨 아이콘은 앱 아이콘 PNG 를 `iconutil` 로 묶어 만들기 때문에 따로 관리할 파일이 없습니다.

작은 크기(16·32px)는 축소만 하지 않고 **반짝임을 빼고 링을 굵게** 그린 별도 변형을 씁니다 — 그대로 줄이면 두 요소가 뭉개져 무엇인지 읽히지 않습니다.

`install.sh` 와 `package.sh` 는 [signing.sh](signing.sh) 의 같은 규칙으로 자격을 찾습니다.

```
1. Developer ID Application  — 배포용. 공증까지 갈 수 있는 유일한 자격
2. Apple Development         — 무료 계정으로도 발급된다. 공증은 못 하지만 신원은 안정된다
3. 없으면 ad-hoc
```

| 보유 자격 | 하는 일 | 받는 사람 경험 |
|---|---|---|
| 없음 | ad-hoc 서명 그대로 DMG | Gatekeeper 우회 필요 — Cask `caveats` 에 안내가 자동 포함됨 |
| Apple Development (현재) | 서명 + Hardened Runtime. **코드 신원이 안정됨** | 그대로 — 공증이 없으므로 Gatekeeper 우회 필요 |
| Developer ID 인증서 | 서명 + Hardened Runtime | 여전히 공증 경고 |
| + 공증 프로필 | 공증(notarize) + 스테이플 | **경고 없이 바로 실행** |

`SIGN_ID` 환경변수로 직접 지정할 수도 있습니다. Apple Development 로 서명한 빌드는 공증할 수 없으므로, `NOTARY_PROFILE` 을 줬더라도 공증 단계를 건너뜁니다 — 올려서 거부당하게 두지 않습니다.

> **Hardened Runtime 과 WKWebView** — 인증서로 서명하면 `package.sh` 가 Hardened Runtime 을 켭니다. 그 아래에서도 로그인 창이 정상 동작합니다(패키징한 DMG 로 확인). WKWebView 의 웹 콘텐츠는 Apple 이 서명한 별도 XPC 프로세스(`com.apple.WebKit.WebContent`)에서 돌아가므로, JavaScriptCore 의 JIT 이 우리 앱의 런타임 제한을 받지 않습니다. `com.apple.security.cs.allow-jit` 같은 예외는 필요하지 않습니다.
>
> `install.sh` 는 Hardened Runtime 을 켜지 않습니다 — 로컬 설치에 필요하지 않고, 공증 요건인 배포용에서만 켭니다.

```bash
# 유료 가입 후 — 인증서는 자동 감지되고, 공증만 프로필을 지정합니다
xcrun notarytool store-credentials notary --apple-id <id> --team-id <team>
NOTARY_PROFILE=notary ./package.sh
```

### 공증하지 않은 빌드의 한계

Apple Developer Program(유료, $99/년) 없이는 **공증할 수 없습니다.** 이때 받는 사람은 quarantine 속성을 지워야 합니다:

```bash
xattr -dr com.apple.quarantine /Applications/ClaudeUsageWidgetApp.app
```

> `spctl -a` 는 이 앱을 항상 `rejected` 로 판정합니다(ad-hoc 서명이므로). 하지만 그건 **정책 평가 결과**이고 실행 차단과 다릅니다 — Gatekeeper 가 실제로 막는 것은 **quarantine 속성이 붙어 있을 때**뿐이라, 위 명령이면 정상 실행됩니다. 직접 빌드해 설치하는 경우(`./install.sh`)는 애초에 quarantine 이 붙지 않아 아무 조치가 필요 없습니다.

### ad-hoc 서명이 왜 문제인가

ad-hoc 서명의 designated requirement 는 `cdhash` 하나입니다.

```
designated => cdhash H"cb541b976398ed6fffff04c493c2f082d385c341"
```

바이너리가 1비트만 바뀌어도 **다른 신원**이 됩니다. 그러면 코드 신원에 묶인 상태 — 로그인 항목 등록(`SMAppService`), TCC 허용 — 가 재빌드마다 초기화됩니다. 인증서로 서명하면 DR 이 이렇게 바뀝니다.

```
designated => identifier "sdh.ClaudeUsageWidgetApp" and anchor apple generic
  and certificate leaf[subject.CN] = "Apple Development: … (TEAMID)"
  and certificate 1[field.1.2.840.113635.100.6.2.1]
```

`cdhash` 가 없으므로 바이너리가 바뀌어도 같은 신원입니다. 인증서를 갱신해도 CN 이 같으면 그대로 유지됩니다.

> 예전에는 이 문제가 훨씬 크게 나타났습니다. 실측 사용량을 위해 키체인의 `Claude Safe Storage` 를 읽던 시절에는 **업데이트마다 키체인 허용 창이 다시 떴습니다.** 자체 로그인으로 바꿔 키체인을 쓰지 않게 되면서 그 증상은 사라졌고, 남은 이득은 로그인 항목·TCC 상태의 안정성입니다.
>
> 서명 주체를 바꾸면 DR 이 달라지므로 **전환 직후 한 번은** 기존에 부여된 상태가 초기화됩니다. 그 뒤로는 안정됩니다.

### Homebrew 로 배포하기

GUI 앱이므로 **Cask** 를 씁니다. 공식 `homebrew-cask` 는 notability 요건과 심사가 있어 개인 프로젝트는 **자체 tap** 이 현실적입니다.

```bash
# 1. 릴리스에 DMG 올리기
gh release create v1.0 dist/ClaudeUsageWidget-1.0.dmg --title v1.0

# 2. homebrew-tap 저장소(이름이 homebrew- 로 시작해야 합니다)의 Casks/ 에 복사
cp dist/claude-usage-widget.rb ../homebrew-tap/Casks/

# 3. 받는 사람
brew tap <사용자>/tap
brew install --cask claude-usage-widget       # 공증 안 된 빌드면 --no-quarantine 추가
```

> 원격(`origin`)이 설정돼 있으면 Cask 의 `url` 이 자동으로 채워집니다. 없으면 `YOUR_GITHUB_USER` 자리표시자가 들어가니 치환하세요.

---

### 제거

```bash
./uninstall.sh
```

앱을 종료하고 `/Applications` 에서 지운 뒤 위젯 호스트를 재시작합니다. 설정과 스냅샷(`~/.claude/.usage-widget-*.json`)까지 함께 지우려면:

```bash
./uninstall.sh --purge
```

자동 실행을 켜 두었다면 먼저 토글을 끄거나, 시스템 설정 → 일반 → 로그인 항목에서 제거합니다.

---

## 🧑‍💻 개발 중 빌드

```bash
xcodebuild -project ClaudeUsageWidgetApp/ClaudeUsageWidgetApp.xcodeproj -scheme ClaudeUsageWidgetApp -destination 'platform=macOS' build
```

Xcode에서는 스킴을 `ClaudeUsageWidgetApp` 으로 두고 `Cmd + R`.

앱은 `LSUIElement = YES` 라서 **Dock에 뜨지 않고 메뉴바에만** 나타납니다. 종료는 메뉴바 패널의 "종료".

> 개발 빌드와 설치 버전은 번들 ID가 같아서 위젯 등록이 서로를 덮어씁니다. 위젯이 엉뚱한 버전을 보는 것 같으면 `./install.sh` 를 다시 실행하세요.

---

## 🧩 Shared 폴더를 두 타겟이 쓰는 방법

Xcode 26의 동기화된 폴더(`PBXFileSystemSynchronizedRootGroup`)는 폴더 하나를 한 타겟에만 붙일 수 있습니다. 그래서 `Shared` 를 가리키는 그룹을 **두 개** 만들어 각 타겟에 하나씩 붙였습니다 (`project.pbxproj` 의 `AAAA000000000000000000A1` / `A2`).

`Shared/` 에 파일을 새로 넣으면 두 타겟에 자동으로 들어갑니다 — pbxproj를 손댈 필요가 없습니다.

---

## 📄 라이선스

교육 및 연구 목적으로 제공되며, 필요에 따라 수정 및 재배포가 가능합니다.
