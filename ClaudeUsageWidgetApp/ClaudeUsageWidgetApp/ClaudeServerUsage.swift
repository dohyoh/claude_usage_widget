//
//  ClaudeServerUsage.swift
//  ClaudeUsageWidgetApp
//
//  Claude 데스크톱 앱의 로그인 쿠키를 읽어 claude.ai에서 계정 전체 실측 사용량을 가져온다.
//
//  쿠키는 Chromium(Electron) 방식으로 암호화되어 있다:
//    1. macOS 키체인의 "Claude Safe Storage" 항목(generic password)이 base64 문자열 키.
//    2. 그 문자열을 그대로 password로 PBKDF2-HMAC-SHA1(salt="saltysalt", 1003회, 16바이트).
//    3. AES-128-CBC, IV = 공백 16바이트로 `encrypted_value`(v10/v11 접두사 제외)를 복호화.
//    4. 최신 Chromium은 평문 앞에 sha256(host_key) 32바이트를 붙이므로 있으면 떼어낸다.
//
//  이 코드는 App Sandbox가 꺼진 메뉴바 앱 타겟에서만 동작한다. 위젯(샌드박스 ON)은
//  키체인·쿠키 파일에 접근할 수 없어 메뉴바 앱이 내려준 스냅샷의 값을 그대로 읽는다.
//
//  비밀(키·세션 쿠키)은 메모리에서만 다루고 어디에도 저장하지 않는다. 스냅샷에는
//  복호화 결과가 아니라 서버가 계산한 백분율·리셋 시각만 담긴다.
//

import Foundation
import Security
import CommonCrypto
import CryptoKit
import SQLite3

enum ClaudeServerUsage {
    /// 실측 사용량을 한 번 가져온다. 실패해도 throw 하지 않고 `failureReason`을 채워 반환한다.
    ///
    /// Safe Storage 키는 바뀌지 않으므로 `cachedKey`를 넘기면 **키체인을 다시 읽지 않고** 그 키로
    /// 쿠키를 푼다. 사용량 숫자는 시간이 지나며 변하니 API 자체는 매번 조회한다.
    ///
    /// `nonisolated`이므로 키체인·SQLite·복호화 같은 블로킹 작업이 메인 스레드를 막지 않는다.
    ///
    /// - Returns: 조회 결과와, 다음 호출에서 재사용할 복호화 키. 키체인 읽기에 실패했을 때만 key가 nil.
    nonisolated static func fetch(now: Date = Date(),
                                  cachedKey: Data? = nil) async -> (usage: ServerUsage, key: Data?) {
        // 1. 캐시된 키가 실제로 무언가를 복호화하면 키체인(Safe Storage)을 다시 읽지 않는다.
        //    (쿠키는 회전할 수 있어 파일은 매번 다시 읽지만, 복호화 키는 그대로 재사용한다.)
        if let cachedKey,
           let jar = try? ClaudeCookieStore.load(decryptionKey: cachedKey),
           !jar.cookieHeader.isEmpty {
            guard jar.hasSession else {
                return (.failed("Claude 로그인 세션이 없습니다. Claude 데스크톱 앱에서 로그인하세요.", at: now), cachedKey)
            }
            return (await UsageAPI.fetch(jar: jar, now: now), cachedKey)
        }

        // 2. 캐시가 없거나 무효(예: 키 교체) → 키체인에서 Safe Storage 키를 읽어 유도한다.
        guard let password = SafeStorageKeychain.password() else {
            return (.failed("Claude Safe Storage 키를 읽을 수 없습니다. Claude 데스크톱 앱이 설치·로그인돼 있어야 하고, 키체인 접근을 허용해야 합니다.", at: now), nil)
        }
        let key = ChromiumCrypto.deriveKey(password: password)

        // 3. 쿠키 DB를 복호화해 claude.ai 쿠키 헤더와 org를 만든다.
        let jar: ClaudeCookieJar
        do {
            jar = try ClaudeCookieStore.load(decryptionKey: key)
        } catch {
            return (.failed("Claude 쿠키를 읽을 수 없습니다: \(error.localizedDescription)", at: now), key)
        }
        guard jar.hasSession else {
            return (.failed("Claude 로그인 세션이 없습니다. Claude 데스크톱 앱에서 로그인하세요.", at: now), key)
        }

        // 4. claude.ai에 사용량을 조회한다. org는 쿠키의 lastActiveOrg를 우선 쓰고,
        //    실패하면 조직 목록에서 chat 권한이 있는 조직으로 다시 시도한다.
        return (await UsageAPI.fetch(jar: jar, now: now), key)
    }
}

// MARK: - 키체인

private enum SafeStorageKeychain {
    /// "Claude Safe Storage" / "Claude Key" generic password의 원본 바이트(base64 문자열).
    nonisolated static func password(service: String = "Claude Safe Storage",
                                     account: String = "Claude Key") -> Data? {
        // 다른 앱(Claude 데스크톱)이 만든 항목이라, 이 앱이 처음 읽을 때 시스템이
        // 표준 키체인 접근 허용 창을 띄운다. "항상 허용"을 누르면 이후엔 조용히 읽는다.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
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
            let pwBase = pw.bindMemory(to: CChar.self).baseAddress
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pwBase, password.count,
                                     salt, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                     1003,
                                     &derived, derived.count)
        }
        return Data(derived)
    }

    /// v10/v11 `encrypted_value`를 복호화해 문자열로 돌려준다. host_key 해시 접두사는 떼어낸다.
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

// MARK: - 쿠키 저장소(SQLite)

// ClaudeCookieJar 는 Shared/ClaudeCookieJar.swift 로 옮겼다 — 자체 로그인에서는 쿠키가
// WKHTTPCookieStore 에서 오므로, 조립 규칙을 SQLite 코드와 떼어내 따로 검증한다.

private enum ClaudeCookieStore {
    enum LoadError: LocalizedError {
        case fileMissing, openFailed, queryFailed
        var errorDescription: String? {
            switch self {
            case .fileMissing: return "쿠키 파일이 없습니다"
            case .openFailed: return "쿠키 DB를 열 수 없습니다"
            case .queryFailed: return "쿠키 DB 조회에 실패했습니다"
            }
        }
    }

    /// Claude 데스크톱 앱의 쿠키 SQLite 파일.
    nonisolated static var cookiesURL: URL {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        return support.appendingPathComponent("Cookies", isDirectory: false)
    }

    nonisolated static func load(decryptionKey key: Data) throws -> ClaudeCookieJar {
        let source = cookiesURL
        guard FileManager.default.fileExists(atPath: source.path) else { throw LoadError.fileMissing }

        // 앱이 쥐고 있는 파일을 잠그거나 WAL 반영이 어긋나지 않도록 사본을 만들어 읽는다.
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-cookies-\(UUID().uuidString).db")
        try FileManager.default.copyItem(at: source, to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw LoadError.openFailed
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let sql = "SELECT host_key, name, encrypted_value FROM cookies"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw LoadError.queryFailed
        }
        defer { sqlite3_finalize(statement) }

        var pairs: [(name: String, value: String)] = []
        var lastActiveOrg: String?
        var hasSession = false

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let hostC = sqlite3_column_text(statement, 0),
                  let nameC = sqlite3_column_text(statement, 1) else { continue }
            let host = String(cString: hostC)
            guard host.hasSuffix("claude.ai") else { continue }
            let name = String(cString: nameC)

            let blobLen = sqlite3_column_bytes(statement, 2)
            guard blobLen > 0, let blobPtr = sqlite3_column_blob(statement, 2) else { continue }
            let blob = Data(bytes: blobPtr, count: Int(blobLen))

            guard let value = ChromiumCrypto.decrypt(blob, key: key, hostKey: host) else { continue }
            pairs.append((name, value))

            if name == "lastActiveOrg" { lastActiveOrg = value }
            if name == "sessionKey" || name == "sessionKeyLC" { hasSession = true }
        }

        let header = pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return ClaudeCookieJar(cookieHeader: header, lastActiveOrg: lastActiveOrg, hasSession: hasSession)
    }
}

// MARK: - claude.ai API

private enum UsageAPI {
    nonisolated static let base = "https://claude.ai/api"
    nonisolated static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    nonisolated static func fetch(jar: ClaudeCookieJar, now: Date) async -> ServerUsage {
        // 1차: 쿠키의 lastActiveOrg로 조회.
        if let org = jar.lastActiveOrg,
           let usage = try? await usage(org: org, jar: jar, now: now) {
            return usage
        }
        // 2차: 조직 목록에서 chat 권한 조직을 찾아 재시도.
        guard let org = try? await chatOrganization(jar: jar) else {
            return .failed("사용량 API 조회에 실패했습니다. Claude 로그인 상태를 확인하세요.", at: now)
        }
        if let usage = try? await usage(org: org.uuid, jar: jar, now: now, orgName: org.name) {
            return usage
        }
        return .failed("사용량 API 조회에 실패했습니다.", at: now)
    }

    // MARK: 요청

    nonisolated private static func request(_ path: String, jar: ClaudeCookieJar) -> URLRequest {
        var req = URLRequest(url: URL(string: base + path)!)
        req.timeoutInterval = 20
        req.setValue(jar.cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        req.setValue("https://claude.ai/", forHTTPHeaderField: "Referer")
        req.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
        return req
    }

    private struct APIError: Error {}

    nonisolated private static func usage(org: String, jar: ClaudeCookieJar,
                                          now: Date, orgName: String? = nil) async throws -> ServerUsage {
        let (data, response) = try await URLSession.shared.data(for: request("/organizations/\(org)/usage", jar: jar))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw APIError() }
        let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
        return decoded.toServerUsage(now: now, orgName: orgName)
    }

    private struct Org: Sendable { let uuid: String; let name: String? }

    nonisolated private static func chatOrganization(jar: ClaudeCookieJar) async throws -> Org {
        let (data, response) = try await URLSession.shared.data(for: request("/organizations", jar: jar))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw APIError() }
        let orgs = try JSONDecoder().decode([OrgResponse].self, from: data)
        // chat(대화) 권한이 있는 조직이 사용량 한도를 가진 구독 조직이다.
        if let chat = orgs.first(where: { ($0.capabilities ?? []).contains("chat") }) {
            return Org(uuid: chat.uuid, name: chat.name)
        }
        guard let first = orgs.first else { throw APIError() }
        return Org(uuid: first.uuid, name: first.name)
    }

    // MARK: 응답 디코딩

    private nonisolated struct OrgResponse: Decodable {
        let uuid: String
        let name: String?
        let capabilities: [String]?
    }

    private nonisolated struct UsageResponse: Decodable {
        let five_hour: Window?
        let seven_day: Window?
        let seven_day_opus: Window?

        nonisolated struct Window: Decodable {
            let utilization: Double?
            let resets_at: String?

            nonisolated var toWindow: ServerUsageWindow? {
                guard let utilization else { return nil }
                return ServerUsageWindow(utilizationPercent: utilization,
                                         resetsAt: resets_at.flatMap(UsageAPI.parseDate))
            }
        }

        nonisolated func toServerUsage(now: Date, orgName: String?) -> ServerUsage {
            ServerUsage(fetchedAt: now,
                        fiveHour: five_hour?.toWindow,
                        sevenDay: seven_day?.toWindow,
                        sevenDayOpus: seven_day_opus?.toWindow,
                        organizationName: orgName,
                        failureReason: nil)
        }
    }

    /// "2026-07-29T13:39:59.649968+00:00" 같은 ISO8601을 파싱한다.
    ///
    /// ISO8601DateFormatter는 6자리 소수 초를 못 읽는 경우가 있어 소수부를 잘라 초 단위로 파싱한다.
    nonisolated static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }
}
