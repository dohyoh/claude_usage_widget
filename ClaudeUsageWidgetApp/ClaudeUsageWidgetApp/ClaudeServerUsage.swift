//
//  ClaudeServerUsage.swift
//  ClaudeUsageWidgetApp
//
//  claude.ai 에서 계정 전체 실측 사용량을 가져온다.
//
//  이전에는 Claude 데스크톱 앱의 쿠키 파일을 키체인의 Safe Storage 키로 복호화해 읽었다.
//  이제는 앱이 자체 로그인 창으로 세션을 직접 확보한다. 그 결과:
//
//    - 키체인을 전혀 쓰지 않는다 (비밀번호 프롬프트 0회)
//    - Claude 데스크톱 앱이 설치돼 있지 않아도 된다
//    - 어느 계정을 연동할지 사용자가 고를 수 있다
//
//  세션 자체는 어디에도 복사하지 않는다. WKWebsiteDataStore 에 그대로 두고 필요할 때
//  쿠키를 읽어 쓴다. 스냅샷에는 서버가 계산한 백분율·리셋 시각만 담긴다.
//

import Foundation

/// 한 번의 조회 결과.
struct ServerFetchResult: Sendable {
    let usage: ServerUsage
    /// 계정 정보를 다시 확인했다면 새 캐시. 그대로 써도 되면 nil.
    let account: AccountCache?
    /// 이 로그인이 볼 수 있는 조직 전체 — 설정의 조직 선택이 쓴다. 조회 실패면 빈 배열.
    let organizations: [OrganizationSummary]
}

enum ClaudeServerUsage {
    /// 실측 사용량을 한 번 가져온다. 실패해도 throw 하지 않고 사유를 채워 반환한다.
    ///
    /// - Parameters:
    ///   - config: 어느 조직을 볼지(`organizationUuid`)를 읽는다.
    ///   - cachedAccount: 들고 있는 계정 캐시. 다시 확인할 필요가 있는지 판단하는 데 쓴다.
    static func fetch(now: Date = Date(),
                      config: UsageConfig,
                      cachedAccount: AccountCache?) async -> ServerFetchResult {
        func failed(_ message: String,
                    organizations: [OrganizationSummary] = []) -> ServerFetchResult {
            ServerFetchResult(usage: .failed(message, at: now),
                              account: nil,
                              organizations: organizations)
        }

        let jar = await ClaudeWebSession.currentJar()
        guard jar.hasSession, let fingerprint = jar.sessionFingerprint else {
            return failed(ServerFailure.needsSignIn.message)
        }

        // 1. 조직 목록.
        let organizations: [OrganizationSummary]
        switch await UsageAPI.get("/organizations", jar: jar) {
        case .failure(let failure):
            return failed(failure.message)
        case .success(let data):
            guard let list = OrganizationSummary.list(fromJSON: data), !list.isEmpty else {
                return failed("조직 목록을 읽을 수 없습니다.")
            }
            organizations = list
        }

        // 2. 볼 조직을 고른다. 설정에서 고른 조직이 사라졌으면 자동 선택으로 내려가되 알린다.
        let choice = OrganizationChoice.select(from: organizations,
                                               preferred: config.organizationUuid,
                                               lastActive: jar.lastActiveOrg)
        guard let organization = choice.organization else {
            return failed("사용량을 볼 수 있는 조직이 없습니다.", organizations: organizations)
        }

        // 3. 사용량.
        var usage: ServerUsage
        switch await UsageAPI.get("/organizations/\(organization.uuid)/usage", jar: jar) {
        case .failure(let failure):
            return failed(failure.message, organizations: organizations)
        case .success(let data):
            guard let decoded = UsageAPI.decodeUsage(data, now: now,
                                                     organizationName: organization.name) else {
                return failed("사용량 응답을 읽을 수 없습니다.", organizations: organizations)
            }
            usage = decoded
        }

        if choice.fellBackFromMissingSelection {
            let label = organization.name ?? organization.uuid
            usage.fallbackNotice = "설정에서 고른 조직을 찾을 수 없어 «\(label)» 로 조회했습니다."
        }

        // 4. 계정 캐시. 매 조회마다 갱신하지 않고, 로그인이나 조직이 바뀔 때만 다시 만든다.
        //    실제로 고른 조직을 넘긴다 — 설정값(nil 가능)이 아니라 결과를 기준으로 비교해야
        //    자동 선택이 바뀐 경우도 잡히고, 매번 갱신되는 일도 없다.
        var account: AccountCache?
        if AccountIdentity.needsRefresh(cache: cachedAccount,
                                        sessionFingerprint: fingerprint,
                                        selectedOrganization: organization.uuid) {
            account = AccountCache(email: nil,
                                   organizationUuid: organization.uuid,
                                   organizationName: organization.name,
                                   sessionFingerprint: fingerprint,
                                   checkedAt: now)
        }

        return ServerFetchResult(usage: usage, account: account, organizations: organizations)
    }
}

// MARK: - claude.ai API

private enum UsageAPI {
    static let base = "https://claude.ai/api"

    /// 로그인 창의 웹뷰와 같은 계열의 UA 를 쓴다. cf_clearance 는 UA 에 묶여 있어, 여기서
    /// 다른 UA 를 쓰면 같은 쿠키로도 Cloudflare 챌린지를 받을 수 있다.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func get(_ path: String, jar: ClaudeCookieJar) async -> Result<Data, ServerFailure> {
        var request = URLRequest(url: URL(string: base + path)!)
        request.timeoutInterval = 20
        request.setValue(jar.cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://claude.ai/", forHTTPHeaderField: "Referer")
        request.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if let failure = ServerFailure.forStatus(status) { return .failure(failure) }
            return .success(data)
        } catch {
            // 네트워크가 끊긴 경우다. 재로그인으로 풀릴 문제가 아니다.
            return .failure(.temporary)
        }
    }

    static func decodeUsage(_ data: Data, now: Date, organizationName: String?) -> ServerUsage? {
        guard let decoded = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
            return nil
        }
        return decoded.toServerUsage(now: now, orgName: organizationName)
    }

    private struct UsageResponse: Decodable {
        let five_hour: Window?
        let seven_day: Window?
        let seven_day_opus: Window?

        struct Window: Decodable {
            let utilization: Double?
            let resets_at: String?

            var toWindow: ServerUsageWindow? {
                guard let utilization else { return nil }
                return ServerUsageWindow(utilizationPercent: utilization,
                                         resetsAt: resets_at.flatMap(UsageAPI.parseDate))
            }
        }

        func toServerUsage(now: Date, orgName: String?) -> ServerUsage {
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
    static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }
}
