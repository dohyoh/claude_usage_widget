# ACR-0001 · macOS 27 의 앱 데이터 보호로 브라우저 쿠키를 읽을 수 없게 됨

| | |
|---|---|
| **상태** | 적용됨 · 설치 확인 완료 · v1.5 에 포함 |
| **날짜** | 2026-11-10 |
| **범위** | `Shared/BrowserCookieSource.swift` · `Shared/SessionProblem.swift` · `Shared/ClaudeSessionSource.swift` · `ClaudeUsageWidgetApp/BrowserCookieStore.swift` · `ClaudeSessionSource+App.swift` · `ClaudeServerUsage.swift` · `UsageMonitor.swift` · `UsageSettingsView.swift` · `project.pbxproj` |

---

## 무슨 일이 있었나

macOS 를 **27.2.1 로 올린 날부터** 실측 사용량이 통째로 비었습니다. 앱이 패널과 위젯에 남긴 사유는 이것이었습니다.

```
Google Chrome 쿠키를 읽을 수 없습니다: 쿠키 파일이 없습니다
```

쿠키 파일은 멀쩡히 있었습니다. **앱 버그가 아니라 OS 정책 변경**이고, 우리 코드는 그것을 «파일이 없다»로 잘못 옮겼습니다.

### 시간 순서

| 시각 (2026) | 사건 |
|---|---|
| 11/3 10:38 | 마지막 정상 조회 (`.usage-widget-account.json` 기록) |
| 11/10 07:57 | Chrome 157.0.8103.50 자동 업데이트 |
| **11/10 08:58** | **macOS 27.2.1 설치** |
| 11/10 10:28 | 스냅샷에 실패 기록 시작 |

---

## 원인

macOS 27 이 TCC 서비스 **`kTCCServiceSystemPolicyAppDataDetailed`** 로 브라우저 프로필 폴더를 보호하기 시작했습니다. 권한이 없는 프로세스에게 이 보호는 이렇게 보입니다.

| 작업 | 결과 |
|---|---|
| `stat` (메타데이터) | **통과** — 파일이 있다는 것, 크기, 수정 시각까지 보인다 |
| `readdir` (디렉터리 열거) | `EPERM` |
| `open` / `copyfile` (내용 읽기) | `EPERM` |
| `access(R_OK)` | `false` |

보호 목록(`defaultRules-2`)에는 **Discord · Google Chrome · Brave · Microsoft Edge · Firefox** 와 암호화폐 지갑들이 올라 있습니다. 규칙은 XProtect 로 배포되므로 OS 업데이트 없이도 Apple 이 앱을 추가할 수 있습니다.

> **Safari 를 뺀 우리 지원 브라우저 전부가 보호 대상입니다.** Chrome 하나의 문제가 아니라 «브라우저 쿠키» 기능 전체가 권한 없이는 동작하지 않습니다.

### 이 머신에서 확인한 것

```
stat   ~/…/Google/Chrome/Default/Cookies   → OK (1,998,848 bytes)
ls     ~/…/Google/Chrome                   → Operation not permitted
cp     ~/…/Google/Chrome/Default/Cookies   → Operation not permitted
ls     ~/…/BraveSoftware/Brave-Browser     → Operation not permitted
ls     ~/…/Cursor  /  Notion  /  Claude    → 정상 (보호 목록 밖)
ls     ~/…/Google/Chrome/NativeMessagingHosts → 정상 (문서화된 예외)
```

`NativeMessagingHosts` 만 뚫려 있다는 것이 결정적입니다. Apple 이 브라우저 확장 연동을 깨뜨리지 않으려고 둔 예외라, 이 보호가 실제로 걸려 있다는 직접 증거입니다. POSIX 퍼미션 문제였다면 `stat` 도 함께 막혔을 것입니다.

---

## 왜 «파일이 없습니다» 로 나왔나

`BrowserCookieSource.cookieFiles` 가 프로필을 찾는 방법은 하나뿐이었습니다.

```swift
let children = (try? fm.contentsOfDirectory(at: root, …)) ?? []   // readdir → EPERM → []
```

`try?` 가 `EPERM` 을 삼키고 빈 배열이 되어, 그대로 `LoadError.fileMissing` 으로 이어졌습니다. 권한 거부와 파일 부재가 같은 길로 흘러 **사용자는 될 리 없는 재로그인을 반복**했습니다.

2차 증상도 있었습니다.

- **설정에서 브라우저가 사라졌다.** `isPresent` 가 `!cookieFiles.isEmpty` 였으므로 Chrome 이 «설치되지 않은 브라우저» 가 되어 쿠키 원본 목록에서 빠졌습니다. 사용자가 다시 고르거나 권한을 주고 되돌릴 수단까지 함께 사라진 셈입니다.
- **빠져나갈 길이 없었다.** 쿠키 원본이 «기본 브라우저» 면 후보가 브라우저 하나뿐이라, 그 하나가 막히면 조회가 끝났습니다.

---

## 결정

### 1. «없다»와 «막혔다»를 끝까지 구분한다

`BrowserCookieSource.CookieFileLookup` 을 `found` / `denied` / `missing` 셋으로 두고, `BrowserCookieStore.LoadError` 에 `permissionDenied` 를 더했습니다. 판정 근거는 **stat 은 통과하고 open 은 막힌다**는 보호의 성질 그 자체입니다.

- 저장소 디렉터리가 없다 → `missing`
- 디렉터리는 있는데 열거가 `EPERM` 이고 짚어 본 프로필에도 파일이 없다 → `denied`
- 파일은 찾았는데 **하나도 열 수 없다**(`access(R_OK)`) → `denied`

`EPERM` 판정(`isPermissionDenied`)은 Foundation 이 POSIX 오류를 `NSCocoaErrorDomain` 으로 감싸 올리는 경우까지 따라 들어갑니다.

### 2. 열거에 기대지 않고도 프로필을 찾는다

Chromium 은 프로필 이름이 정해져 있으므로(`Default`, `Profile 1…9`, `Guest Profile`, `System Profile`) 열거 없이 직접 짚습니다. 열거가 막혀도 «저기 쿠키가 있다»까지는 알 수 있고, 그것이 위 판정의 근거가 됩니다.

Firefox 는 `xxxxxxxx.default-release` 처럼 앞에 난수가 붙어 짚을 수 없습니다. 그쪽은 열거가 막히면 하나도 못 찾고, **그 사실 자체가 `denied` 의 근거**가 됩니다.

### 3. 막혔다고 설정 목록에서 사라지지 않는다

`isPresent` 를 «쿠키 파일을 읽어냈는가» 가 아니라 **«저장소 디렉터리가 있는가»** 로 바꿨습니다. 보이지 않으면 고칠 수도 없습니다.

### 4. 브라우저를 골라도 앱 세션을 뒤에 남긴다 — 다만 알린다

`ClaudeSessionSource.candidates` 가 브라우저 선택에도 `.appWebView` 를 마지막 후보로 붙입니다. 대신 고른 소스가 아닌 쪽으로 넘어갔으면 `ServerUsage.fallbackNotice` 로 그 사실을 적습니다.

> «조용히 다른 계정 숫자를 보여주지 않는다»는 기존 원칙과 충돌하지 않습니다. 충돌하는 것은 **조용히** 쪽이고, 알리면서 폴백하는 것은 원칙 안입니다. 길을 막아 두면 사용자는 아무 숫자도 못 보고, 그 상태에서도 계정은 여전히 틀리지 않습니다 — 다만 비어 있을 뿐입니다.
>
> «앱 안의 로그인 창» 을 **직접 고른** 경우에는 폴백을 붙이지 않습니다. 그 선택은 «브라우저를 쓰지 않겠다»는 뜻입니다.

### 5. 사유에 따라 사유를 고르고, 복구 수단을 함께 둔다

소스를 여러 개 시도하므로 모두 실패하면 어느 사유를 보여줄지 정해야 합니다. `SessionProblem` 을 두고 **권한 거부가 언제나 앞서게** 했습니다 — 손쓰지 않으면 영영 풀리지 않는 유일한 사유라서입니다. 뒤에 시도한 소스의 «로그인하세요» 에 덮이면 사용자는 엉뚱한 곳에서 로그인만 반복합니다.

권한 거부일 때 설정 화면에 두 갈래를 띄웁니다.

- **전체 디스크 접근 열기** — 권한을 주고 브라우저 쿠키를 계속 쓴다
- **앱 안의 로그인 창으로 전환** — 권한 없이 쓴다 (`UsageMonitor.useAppLoginWindow`)

### 6. Info.plist 에 권한 설명 키를 선언한다 — **파일로**

`NSSystemPolicyAppDataDetailedUsageDescription` 을 앱 번들에 넣었습니다. `tccd` 바이너리에서 이 키 이름을 확인했고, 다른 TCC 서비스와 같은 규칙이라면 이 키가 있어야 OS 가 허용 창을 띄웁니다. 1.4 의 Info.plist 에는 어떤 UsageDescription 키도 없었습니다.

**빌드 설정(`INFOPLIST_KEY_*`)으로는 들어가지 않습니다.** 처음에 그렇게 넣었더니 `xcodebuild -showBuildSettings` 에는 값이 보이는데 산출물 Info.plist 에는 없었습니다. `GENERATE_INFOPLIST_FILE` 의 생성기가 **자기가 아는 키만** 옮기고 나머지는 말없이 버리기 때문입니다 — 이 키는 macOS 27 에서 추가되어 Xcode 26 SDK 가 모릅니다.

그래서 `ClaudeUsageWidgetApp/AppInfo.plist` 를 만들고 `INFOPLIST_FILE` 로 지정했습니다. 생성기는 나머지 키를 이 파일에 **합쳐** 넣으므로 `LSUIElement` 등은 그대로입니다(위젯 타겟이 이미 쓰던 방식입니다). 산출물에서 양쪽이 모두 들어간 것을 확인했습니다.

### 7. 포기하기 전에 한 번은 진짜로 열어 본다

`access(R_OK)` 로 미리 거르면 키체인 프롬프트를 피할 수 있지만, 부작용이 있습니다 — **`access` 는 TCC 에 묻지 않고 곧장 거짓을 돌려주므로, 그 결과만 믿고 포기하면 OS 가 허용 창을 띄울 기회가 영영 없습니다.** TCC 를 깨우는 것은 실제 열기뿐입니다.

그래서 `denied` 에 «보이지만 열 수 없던 경로» 를 함께 담고, `BrowserCookieStore` 가 거기에 `FileHandle(forReadingFrom:)` 를 한 번 시도한 뒤에야 포기합니다. 허용되면 그대로 이어 가고, 거부되면 TCC 가 기억하므로 다음부터는 창 없이 같은 자리에서 막힙니다.

---

## 설치해서 확인한 것 (2026-11-10, macOS 27.2.1 · Xcode 26.6)

| 확인 | 결과 |
|---|---|
| 실측 사용량 복구 | **됨** — 5시간 6% · 주간 65% · 조직 `A-Autunomous Tech` |
| 폴백 동작 | **됨** — Chrome 이 막히자 앱 세션으로 넘어가 조회 성공 |
| 폴백 알림 | **됨** — 넘어온 사실 + 사유 + 복구 방법이 패널·설정에 함께 뜸 |
| Info.plist 키 | **들어감** — 파일로 옮긴 뒤 설치본에서 확인 |
| 복구 버튼의 설정 URL | **열림** — `…com.apple.preference.security?Privacy_AllFiles` 가 macOS 27 에서도 전체 디스크 접근 패널을 연다 |
| **허용 창** | **뜨지 않음** |

마지막 줄이 중요합니다. 키를 넣고 실제 `open()` 까지 시도했는데도 **허용 창이 뜨지 않았고, `tccd`·커널 로그에 거부 기록조차 남지 않았습니다.** 이 보호는 묻지 않고 막습니다 — chrome-devtools-mcp 쪽 보고와 같습니다.

따라서 **브라우저 쿠키를 되살리는 길은 사용자가 전체 디스크 접근에 앱을 직접 추가하는 것뿐**입니다. 키는 그대로 둡니다. 비용이 없고, OS 가 언젠가 묻게 되면 쓰일 문구이며, 무엇보다 «왜 안 묻는가» 를 다음 사람이 다시 파헤치지 않도록 하는 기록입니다.

---

## 아직 검증하지 못한 것

- **전체 디스크 접근으로 실제로 풀리는지.** 권한 부여는 사용자만 할 수 있고, 이 머신에서는 허용하지 않기로 했습니다. 「파일 및 폴더」 패널은 OS 가 한 번이라도 물어본 앱만 올라오는데 이 보호는 묻지 않으므로, 사용자가 `+` 로 직접 추가할 수 있는 전체 디스크 접근 쪽으로 보냈습니다. 패널이 열리는 것까지는 확인했으니, 남은 것은 허용 후 Chrome 쿠키가 실제로 읽히는지 한 번 보는 일뿐입니다.

  > 허용하지 않아도 앱은 앱 세션으로 정상 동작합니다. 이 항목은 «브라우저 쿠키 경로를 되살릴 수 있는가» 를 확인하는 것이지, 앱이 동작하는지를 확인하는 것이 아닙니다.
- **열거가 막힌 상태 자체는 테스트로 만들 수 없습니다.** TCC 를 끌 수 없기 때문입니다. 대신 ① 열거에 기대지 않고도 같은 파일에 닿는지, ② `EPERM` 을 권한 거부로 읽는지, ③ 파일이 안 보여도 설정 목록에 남는지를 각각 고정했습니다 (`BrowserDataAccessTests`).

---

## 남은 방향

**«브라우저 쿠키» 를 기본 자리에서 내리는 것을 검토해야 합니다.** 보호 목록은 XProtect 로 배포되어 Apple 이 언제든 브라우저를 더 넣거나 규칙을 조일 수 있습니다. 지금 구조는 OS 정책 한 줄에 기능 전체가 끊기는 자리에 서 있고, 이번 수정은 그 자리를 옮긴 것이 아니라 **끊겼을 때 사용자가 알아채고 빠져나오게** 만든 것입니다.

기본값을 «앱 안의 로그인 창» 으로 옮기는 것은 로그인을 한 번 더 시키는 비용이 있어, 6번의 검증 결과를 보고 정하는 편이 낫습니다.

---

## 참고

- [Crossing the Golden Gate: macOS's New Application Support Protection](https://wojciechregula.blog/post/golden-gate-appdata-protection/) — 보호 목록과 `NativeMessagingHosts` 예외
- [chrome-devtools-mcp 트러블슈팅](https://github.com/ChromeDevTools/chrome-devtools-mcp/blob/main/docs/troubleshooting.md) — 안내 없이 막히는 동작과 권한 부여 경로
- [CVE-2023-42929: Why do we need the App Container Protection](https://jhftss.github.io/CVE-2023-42929-Why-Do-We-Need-The-App-Container-Protection/) — macOS 14 의 `kTCCServiceSystemPolicyAppData` 전사
