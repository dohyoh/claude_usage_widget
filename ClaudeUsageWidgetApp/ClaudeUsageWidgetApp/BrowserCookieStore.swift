//
//  BrowserCookieStore.swift
//  ClaudeUsageWidgetApp
//
//  브라우저의 쿠키 저장소에서 claude.ai 쿠키를 꺼낸다.
//
//  Chromium 계열은 쿠키 값을 암호화해 둔다:
//    1. macOS 키체인의 "<브랜드> Safe Storage" 항목(generic password)이 base64 문자열 키.
//    2. 그 문자열을 그대로 password 로 PBKDF2-HMAC-SHA1(salt="saltysalt", 1003회, 16바이트).
//    3. AES-128-CBC, IV = 공백 16바이트로 `encrypted_value`(v10/v11 접두사 제외)를 복호화.
//    4. 최신 Chromium 은 평문 앞에 sha256(host_key) 32바이트를 붙이므로 있으면 떼어낸다.
//  Firefox 는 `cookies.sqlite` 에 값이 평문이라 키가 필요 없다.
//
//  결과는 `HTTPCookie` 로 돌려준다. 그래야 웹뷰 세션과 똑같이 `ClaudeCookieJar(cookies:)` 가
//  조립하고, 도메인 필터·세션 판정·지문 계산이 한 곳에만 남는다.
//
//  읽기만 하고 아무것도 쓰지 않는다. 복호화 키와 쿠키 값은 메모리에서만 다룬다.
//

import Foundation
import Security
import CommonCrypto
import CryptoKit
import SQLite3

enum BrowserCookieStore {
    enum LoadError: LocalizedError {
        case fileMissing, openFailed, queryFailed
        case keychainDenied(String)
        /// OS 가 쿠키 저장소 접근을 막았다 — macOS 27 의 앱 데이터 보호.
        ///
        /// «파일이 없다»와 반드시 구분해야 한다. 같은 말로 묶으면 권한이 막힌 사용자에게
        /// 브라우저로 로그인하라고 말하게 되고, 그 말대로 해도 아무것도 달라지지 않는다.
        case permissionDenied(String)

        var errorDescription: String? {
            switch self {
            case .fileMissing: return "쿠키 파일이 없습니다"
            case .openFailed: return "쿠키 DB를 열 수 없습니다"
            case .queryFailed: return "쿠키 DB 조회에 실패했습니다"
            case .keychainDenied(let name):
                return "\(name)의 Safe Storage 키를 읽지 못했습니다 (키체인 접근 허용 필요)"
            case .permissionDenied(let reason): return reason
            }
        }

        /// 사용자가 권한을 주거나 쿠키 원본을 바꿔야 풀리는 실패인지.
        var isPermissionDenied: Bool {
            if case .permissionDenied = self { return true }
            return false
        }
    }

    /// 브라우저 하나에서 claude.ai 쿠키를 읽는다.
    ///
    /// 프로필이 여러 개면 세션 쿠키가 있는 첫 프로필을 쓴다. 세션이 없는 프로필의 쿠키라도
    /// 아무것도 없는 것보다는 진단에 쓸모가 있어 폴백으로 들고 있는다.
    ///
    /// - Parameter cachedKey: 이전에 유도해 둔 복호화 키. 넘기면 키체인을 다시 읽지 않는다.
    /// - Returns: 읽은 쿠키와, 다음 호출에 재사용할 복호화 키.
    nonisolated static func cookies(from source: BrowserCookieSource,
                                    cachedKey: Data? = nil) throws -> (cookies: [HTTPCookie], key: Data?) {
        // 저장소를 찾아본 결과가 «막혔다»면 키체인은 건드리지 않는다. 읽지도 못할 쿠키를
        // 위해 키체인 접근 허용 창을 띄우면, 사용자는 허용하고도 같은 실패를 다시 본다.
        let files: [URL]
        switch source.cookieFileLookup {
        case .found(let urls):
            files = urls
        case .missing:
            throw LoadError.fileMissing
        case .denied(let blocked):
            // 보이지만 열 수 없다. 여기서 바로 포기하면 OS 가 허용 창을 띄울 기회가 없다 —
            // `access(R_OK)` 는 TCC 에 묻지 않고 곧장 거짓을 돌려주기 때문이다. 실제 열기만이
            // TCC 를 깨우므로 한 번 시도한다. 허용되면 그대로 이어 가고, 거부되면 TCC 가
            // 기억하므로 다음부터는 창 없이 같은 자리에서 막힌다.
            guard probeForPermission(blocked),
                  case .found(let urls) = source.cookieFileLookup else {
                throw LoadError.permissionDenied(source.accessDeniedMessage)
            }
            files = urls
        }

        switch source.store {
        case .unsupported(let reason):
            throw LoadError.keychainDenied(reason)

        case .firefox:
            return (try pickProfile(files, source: source) { try plainCookies(file: $0) }, nil)

        case .chromium(let service, let account):
            // 캐시된 키가 실제로 뭔가를 복호화하면 키체인을 건드리지 않는다.
            if let cachedKey {
                let found = try pickProfile(files, source: source) {
                    try encryptedCookies(file: $0, key: cachedKey)
                }
                if !found.isEmpty { return (found, cachedKey) }
            }
            guard let password = SafeStorageKeychain.password(service: service, account: account) else {
                throw LoadError.keychainDenied(source.displayName)
            }
            let key = ChromiumCrypto.deriveKey(password: password)
            let found = try pickProfile(files, source: source) {
                try encryptedCookies(file: $0, key: key)
            }
            return (found, key)
        }
    }

    /// 막힌 파일을 한 번 진짜로 열어 본다 — OS 가 허용 창을 띄울 기회를 만든다.
    ///
    /// 여는 데 성공한 것이 하나라도 있으면 true. 내용은 쓰지 않고 곧바로 닫는다 — 여기서
    /// 필요한 것은 «열 수 있는가» 뿐이고, 실제 읽기는 평소 경로(`withCopy`)가 한다.
    private nonisolated static func probeForPermission(_ files: [URL]) -> Bool {
        for file in files {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            try? handle.close()
            return true
        }
        return false
    }

    /// 세션 쿠키가 있는 첫 프로필을 고른다. 없으면 쿠키가 있는 첫 프로필.
    ///
    /// 프로필 하나가 실패해도 다음 프로필을 본다 — 쓰는 중이라 잠깐 못 읽는 경우가 있다.
    /// 다만 **권한 거부는 삼키지 않는다.** 아무 프로필도 못 읽고 그중 권한 문제가 있었다면
    /// 그대로 올려 보내야, 사용자가 «세션이 없다»가 아니라 «막혔다»를 듣는다.
    private nonisolated static func pickProfile(_ files: [URL],
                                                source: BrowserCookieSource,
                                                read: (URL) throws -> [HTTPCookie]) throws -> [HTTPCookie] {
        var fallback: [HTTPCookie] = []
        var denied = false
        for file in files {
            let cookies: [HTTPCookie]
            do {
                cookies = try read(file)
            } catch let error as LoadError where error.isPermissionDenied {
                denied = true
                continue
            } catch {
                continue
            }
            guard !cookies.isEmpty else { continue }
            if cookies.contains(where: { ClaudeCookieJar.sessionCookieNames.contains($0.name) }) {
                return cookies
            }
            if fallback.isEmpty { fallback = cookies }
        }
        if fallback.isEmpty, denied {
            throw LoadError.permissionDenied(source.accessDeniedMessage)
        }
        return fallback
    }

    // MARK: - Chromium

    private nonisolated static func encryptedCookies(file: URL, key: Data) throws -> [HTTPCookie] {
        try withCopy(of: file) { db in
            try rows(db, sql: "SELECT host_key, name, encrypted_value, value FROM cookies") { statement in
                guard let hostC = sqlite3_column_text(statement, 0),
                      let nameC = sqlite3_column_text(statement, 1) else { return nil }
                let host = String(cString: hostC)
                guard host.hasSuffix("claude.ai") else { return nil }
                let name = String(cString: nameC)

                let length = sqlite3_column_bytes(statement, 2)
                if length > 0, let pointer = sqlite3_column_blob(statement, 2) {
                    let blob = Data(bytes: pointer, count: Int(length))
                    if let value = ChromiumCrypto.decrypt(blob, key: key, hostKey: host) {
                        return cookie(host: host, name: name, value: value)
                    }
                }
                // 암호화 이전에 저장된 평문 값이 남아 있으면 그것도 쓴다.
                guard let plainC = sqlite3_column_text(statement, 3) else { return nil }
                return cookie(host: host, name: name, value: String(cString: plainC))
            }
        }
    }

    // MARK: - Firefox

    private nonisolated static func plainCookies(file: URL) throws -> [HTTPCookie] {
        try withCopy(of: file) { db in
            try rows(db, sql: "SELECT host, name, value FROM moz_cookies") { statement in
                guard let hostC = sqlite3_column_text(statement, 0),
                      let nameC = sqlite3_column_text(statement, 1),
                      let valueC = sqlite3_column_text(statement, 2) else { return nil }
                let host = String(cString: hostC)
                guard host.hasSuffix("claude.ai") else { return nil }
                return cookie(host: host, name: String(cString: nameC), value: String(cString: valueC))
            }
        }
    }

    // MARK: - SQLite 공통

    private nonisolated static func cookie(host: String, name: String, value: String) -> HTTPCookie? {
        guard !value.isEmpty else { return nil }
        return HTTPCookie(properties: [.domain: host, .path: "/", .name: name, .value: value])
    }

    private nonisolated static func rows(_ db: OpaquePointer,
                                         sql: String,
                                         map: (OpaquePointer) -> HTTPCookie?) throws -> [HTTPCookie] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw LoadError.queryFailed
        }
        defer { sqlite3_finalize(statement) }

        var result: [HTTPCookie] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let cookie = map(statement) { result.append(cookie) }
        }
        return result
    }

    /// 브라우저가 쥐고 있는 파일을 잠그지 않도록 사본을 만들어 읽는다.
    ///
    /// 실행 중인 브라우저는 방금 받은 쿠키를 아직 `-wal` 에만 써 뒀을 수 있다. 본 파일만
    /// 복사하면 재로그인 직후의 세션 쿠키를 놓치므로 곁다리 파일도 함께 복사하고, 사본은
    /// 쓰기 가능으로 열어 SQLite 가 WAL 을 반영하게 둔다.
    private nonisolated static func withCopy<T>(of source: URL,
                                                _ body: (OpaquePointer) throws -> T) throws -> T {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw LoadError.fileMissing }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-browser-cookies-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }

        let name = source.lastPathComponent
        let copy = directory.appendingPathComponent(name, isDirectory: false)
        do {
            try fm.copyItem(at: source, to: copy)
        } catch {
            // stat 은 통과하고 open 만 막히는 것이 앱 데이터 보호의 모습이라, 파일이 보여도
            // 복사에서 처음 막힐 수 있다. 사본 경로는 우리가 만든 임시 폴더이므로 여기서의
            // 권한 오류는 언제나 원본 쪽이다.
            throw BrowserCookieSource.isPermissionDenied(error)
                ? LoadError.permissionDenied("쿠키 파일을 열 수 없습니다 (macOS 가 접근을 막았습니다)")
                : LoadError.openFailed
        }
        for suffix in ["-wal", "-shm"] {
            let sidecar = source.deletingLastPathComponent()
                .appendingPathComponent(name + suffix, isDirectory: false)
            guard fm.fileExists(atPath: sidecar.path) else { continue }
            try? fm.copyItem(at: sidecar,
                             to: directory.appendingPathComponent(name + suffix, isDirectory: false))
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw LoadError.openFailed
        }
        defer { sqlite3_close(db) }
        return try body(db)
    }
}

// MARK: - 키체인

private enum SafeStorageKeychain {
    /// "<브랜드> Safe Storage" generic password 의 원본 바이트(base64 문자열).
    ///
    /// 다른 앱(브라우저)이 만든 항목이라, 이 앱이 처음 읽을 때 시스템이 표준 키체인 접근
    /// 허용 창을 띄운다. "항상 허용"을 누르면 이후엔 조용히 읽는다.
    nonisolated static func password(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }
}

// MARK: - Chromium 복호화

private enum ChromiumCrypto {
    /// PBKDF2-HMAC-SHA1(password, "saltysalt", 1003, 16바이트).
    nonisolated static func deriveKey(password: Data) -> Data {
        let salt = Array("saltysalt".utf8)
        var derived = [UInt8](repeating: 0, count: kCCKeySizeAES128)   // 16
        password.withUnsafeBytes { pw in
            let base = pw.bindMemory(to: CChar.self).baseAddress
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     base, password.count,
                                     salt, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                     1003,
                                     &derived, derived.count)
        }
        return Data(derived)
    }

    /// v10/v11 `encrypted_value` 를 복호화한다. host_key 해시 접두사는 떼어낸다.
    nonisolated static func decrypt(_ blob: Data, key: Data, hostKey: String) -> String? {
        guard blob.count > 3 else { return nil }
        let scheme = blob.prefix(3)
        guard scheme == Data("v10".utf8) || scheme == Data("v11".utf8) else {
            // 접두사가 없으면 평문(암호화 이전) 값일 수 있다.
            return String(data: blob, encoding: .utf8)
        }
        let body = blob.subdata(in: blob.index(blob.startIndex, offsetBy: 3)..<blob.endIndex)
        guard !body.isEmpty else { return nil }

        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)   // 공백 16개
        var output = [UInt8](repeating: 0, count: body.count + kCCBlockSizeAES128)
        var moved = 0

        let status: CCCryptorStatus = key.withUnsafeBytes { keyPtr in
            body.withUnsafeBytes { dataPtr in
                CCCrypt(CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyPtr.baseAddress, key.count,
                        iv,
                        dataPtr.baseAddress, body.count,
                        &output, output.count,
                        &moved)
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        var plain = Data(output.prefix(moved))

        // 최신 Chromium: 평문 = sha256(host_key)(32B) || 실제 값.
        if plain.count >= 32 {
            let hash = Data(SHA256.hash(data: Data(hostKey.utf8)))
            if plain.prefix(32) == hash {
                plain = plain.subdata(in: plain.index(plain.startIndex, offsetBy: 32)..<plain.endIndex)
            }
        }
        return String(data: plain, encoding: .utf8)
    }
}
