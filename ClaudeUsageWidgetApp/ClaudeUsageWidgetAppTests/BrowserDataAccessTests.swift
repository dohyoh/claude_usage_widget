//
//  BrowserDataAccessTests.swift
//  ClaudeUsageWidgetAppTests
//
//  macOS 27 의 앱 데이터 보호(`kTCCServiceSystemPolicyAppDataDetailed`)는 브라우저 프로필
//  폴더의 **열거(readdir)와 열기(open)** 를 막고 **메타데이터(stat)는 통과**시킨다.
//  그래서 «파일이 없다»와 «막혔다»가 같은 모습으로 보이기 쉽다 — 실제로 1.4 는 막힌 것을
//  «쿠키 파일이 없습니다» 로 보고했고, 사용자는 될 리 없는 재로그인을 반복했다.
//
//  여기서 고정하는 것은 두 가지다: 그 둘을 가르는 판정과, 막혔다고 브라우저가 설정 목록에서
//  사라지지 않는다는 것.
//

import Foundation
import Testing

struct BrowserDataAccessTests {
    /// 홈 아래 임시 디렉터리를 만들고 정리한다. `userDataPath` 가 홈 상대 경로라 시스템
    /// 임시 폴더는 쓸 수 없다.
    private static func withTemporaryUserData(
        _ body: (_ relativePath: String, _ root: URL) throws -> Void
    ) rethrows {
        let relative = "Library/Caches/ClaudeUsageWidgetTests/\(UUID().uuidString)"
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(relative, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(relative, root)
    }

    private static func source(userDataPath: String) -> BrowserCookieSource {
        BrowserCookieSource(id: "test", displayName: "테스트 브라우저",
                            bundleIDs: ["test.browser"],
                            store: .chromium(keychainService: "Test Safe Storage",
                                             keychainAccount: "Test"),
                            userDataPath: userDataPath,
                            cookieFileName: "Cookies")
    }

    @Test("저장소가 없으면 «없다»로 본다")
    func reportsMissingWhenThereIsNoStore() {
        let source = Self.source(userDataPath: "Library/Caches/없는브라우저-\(UUID().uuidString)")

        #expect(source.cookieFileLookup == .missing)
        #expect(source.isPresent == false)
    }

    @Test("프로필 디렉터리를 열거해 쿠키를 찾는다")
    func findsCookiesInsideProfileDirectories() throws {
        try Self.withTemporaryUserData { relative, root in
            let profile = root.appendingPathComponent("Default", isDirectory: true)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            let cookies = profile.appendingPathComponent("Cookies")
            try Data("sqlite".utf8).write(to: cookies)

            let lookup = Self.source(userDataPath: relative).cookieFileLookup

            #expect(lookup == .found([cookies]))
        }
    }

    @Test("열거하지 않고도 알려진 프로필 이름으로 쿠키를 찾는다")
    func findsCookiesByKnownProfileNameWithoutEnumerating() throws {
        // 열거가 막히는 상황을 테스트에서 만들 수는 없다(TCC 를 끌 수 없다). 대신 열거에
        // 기대지 않고도 같은 파일에 닿는지 — 즉 폴백이 실제로 동작하는지 — 를 고정한다.
        try Self.withTemporaryUserData { relative, root in
            let profile = root.appendingPathComponent("Profile 1", isDirectory: true)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            try Data("sqlite".utf8).write(to: profile.appendingPathComponent("Cookies"))

            let source = Self.source(userDataPath: relative)

            #expect(source.knownProfileNames.contains("Profile 1"))
            #expect(source.cookieFiles.count == 1)
        }
    }

    @Test("Chromium 은 프로필 이름을 알고 Firefox 는 모른다")
    func knowsChromiumProfileNamesOnly() {
        // Firefox 프로필은 `xxxxxxxx.default-release` 처럼 앞에 난수가 붙어 짚을 수 없다.
        // 그래서 열거가 막히면 하나도 못 찾고, 그 사실 자체가 «막혔다»의 근거가 된다.
        #expect(BrowserCookieSource.source(id: "chrome")?.knownProfileNames.first == "Default")
        #expect(BrowserCookieSource.source(id: "firefox")?.knownProfileNames.isEmpty == true)
    }

    @Test("안이 비어 있어도 저장소가 있으면 설정 목록에 남는다")
    func staysInTheSettingsListEvenWhenNoCookieFileIsVisible() throws {
        // 1.4 는 `isPresent` 를 «쿠키 파일을 찾았는가»로 봤다. macOS 가 폴더를 막자
        // 브라우저가 쿠키 원본 목록에서 통째로 사라져, 사용자가 다시 고르거나 권한을 주고
        // 되돌릴 수단까지 함께 사라졌다.
        try Self.withTemporaryUserData { relative, _ in
            let source = Self.source(userDataPath: relative)

            #expect(source.cookieFiles.isEmpty)
            #expect(source.isPresent)
        }
    }

    @Test("EPERM 은 권한 거부로 읽는다")
    func readsPosixPermissionErrorsAsDenial() {
        let eperm = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let eacces = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)

        #expect(BrowserCookieSource.isPermissionDenied(eperm))
        #expect(BrowserCookieSource.isPermissionDenied(eacces))
        #expect(BrowserCookieSource.isPermissionDenied(cocoa))
    }

    @Test("감싼 오류 안쪽까지 본다")
    func looksInsideWrappedErrors() {
        // Foundation 은 POSIX 오류를 NSCocoaErrorDomain 으로 감싸 올린다. 겉만 보면
        // «파일을 못 읽었다»로만 보여 권한 문제인지 알 수 없다.
        let wrapped = NSError(domain: NSCocoaErrorDomain,
                              code: NSFileReadUnknownError,
                              userInfo: [NSUnderlyingErrorKey:
                                          NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])

        #expect(BrowserCookieSource.isPermissionDenied(wrapped))
    }

    @Test("권한과 무관한 실패는 권한 거부가 아니다")
    func doesNotCallEveryFailureADenial() {
        // 이 확인이 없으면 «늘 true» 인 구현도 위 테스트를 모두 통과한다.
        let missing = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)

        #expect(BrowserCookieSource.isPermissionDenied(missing) == false)
    }
}
