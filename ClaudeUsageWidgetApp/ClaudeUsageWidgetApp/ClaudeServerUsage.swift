//
//  ClaudeServerUsage.swift
//  ClaudeUsageWidgetApp
//
//  claude.ai 에서 계정 전체 실측 사용량을 가져온다.
//
//  세션은 두 곳에서 올 수 있다(설정의 «쿠키 원본», `ClaudeSessionSource`):
//
//    - 앱 안의 로그인 창이 만든 WKWebsiteDataStore 세션
//    - 시스템 기본 브라우저의 쿠키 저장소 (`BrowserCookieStore`)
//
//  브라우저 세션을 쓰면 평소 쓰던 브라우저에서 한 번 로그인해 두는 것으로 끝나고, 앱이
//  따로 로그인 창을 띄우지 않는다.
//
//  세션 자체는 어디에도 복사하지 않는다. 있는 자리에서 쿠키를 읽어 쓸 뿐이고, 스냅샷에는
//  서버가 계산한 백분율·리셋 시각만 담긴다.
//

import Foundation

/// 한 번의 조회 결과.
struct ServerFetchResult: Sendable {
    let usage: ServerUsage
    /// 계정 정보를 다시 확인했다면 새 캐시. 그대로 써도 되면 nil.
    let account: AccountCache?
    /// 이 로그인이 볼 수 있는 조직 전체 — 설정의 조직 선택이 쓴다. 조회 실패면 빈 배열.
    let organizations: [OrganizationSummary]
    /// 세션을 실제로 쓴 소스의 이름(앱 로그인 창 / 브라우저 이름). 실패했으면 nil.
    let sourceName: String?
    /// 실패했다면 그 사유의 종류. 설정 화면이 복구 버튼을 띄울지 여기서 판단한다.
    ///
    /// 스냅샷에는 문구(`ServerUsage.failureReason`)만 담긴다 — 위젯은 사유를 읽어 주기만
    /// 하면 되고, 사유에 따라 행동이 갈리는 쪽은 설정 화면뿐이다.
    let problem: SessionProblem?

    init(usage: ServerUsage,
         account: AccountCache?,
         organizations: [OrganizationSummary],
         sourceName: String? = nil,
         problem: SessionProblem? = nil) {
        self.usage = usage
        self.account = account
        self.organizations = organizations
        self.sourceName = sourceName
        self.problem = problem
    }
}

enum ClaudeServerUsage {
    /// 실측 사용량을 한 번 가져온다. 실패해도 throw 하지 않고 사유를 채워 반환한다.
    ///
    /// 세션은 설정의 쿠키 원본이 정한 순서대로 찾는다(`ClaudeSessionSource.candidates`).
    /// 앞의 소스에서 **세션을 꺼내지 못했거나** 그 세션이 «재로그인이 필요하다»고 할 때만
    /// 다음 소스로 넘어간다 — 속도 제한이나 서버 오류에 소스를 바꾸면 사용자가 보는 계정이
    /// 네트워크 사정에 따라 흔들린다.
    ///
    /// 모두 실패하면 `SessionProblem.preferred` 가 보여줄 사유를 고르고, 고른 소스가 아닌
    /// 쪽으로 성공했으면 `announcing` 이 그 사실을 결과에 적는다.
    ///
    /// - Parameters:
    ///   - config: 쿠키 원본과 볼 조직(`organizationUuid`)을 읽는다.
    ///   - cachedAccount: 들고 있는 계정 캐시. 다시 확인할 필요가 있는지 판단하는 데 쓴다.
    static func fetch(now: Date = Date(),
                      config: UsageConfig,
                      cachedAccount: AccountCache?) async -> ServerFetchResult {
        let (sources, problem) = ClaudeSessionSource.candidates(for: config.cookieSource)
        guard let preferred = sources.first else {
            let reason = SessionProblem.unreadable(problem ?? ServerFailure.needsSignIn.message)
            return ServerFetchResult(usage: .failed(reason.message, at: now),
                                     account: nil,
                                     organizations: [],
                                     problem: reason)
        }

        var failure: SessionProblem?
        var organizations: [OrganizationSummary] = []
        for source in sources {
            switch await source.jar() {
            case .problem(let reason):
                // 이 소스엔 세션이 없거나 볼 수 없다. 다음 소스가 있으면 거기서 찾는다.
                failure = SessionProblem.preferred(failure, reason)
            case .found(let jar):
                let attempt = await fetch(now: now,
                                          jar: jar,
                                          sourceName: source.displayName,
                                          config: config,
                                          cachedAccount: cachedAccount)
                guard attempt.canRetryElsewhere else {
                    return announcing(attempt.result,
                                      preferred: preferred,
                                      used: source,
                                      because: failure)
                }
                if let reason = attempt.result.problem {
                    failure = SessionProblem.preferred(failure, reason)
                }
                if !attempt.result.organizations.isEmpty {
                    organizations = attempt.result.organizations
                }
            }
        }

        let reason = failure ?? .needsSignIn(ServerFailure.needsSignIn.message)
        return ServerFetchResult(usage: .failed(reason.message, at: now),
                                 account: nil,
                                 organizations: organizations,
                                 problem: reason)
    }

    /// 사용자가 고른 소스가 아닌 쪽으로 조회했으면 그 사실을, **넘어온 이유와 함께** 적는다.
    ///
    /// 조회 자체는 성공했으므로 실패가 아니다. 다만 다른 소스는 곧 다른 로그인일 수 있어,
    /// 조용히 넘어가면 사용자가 남의 계정 숫자를 자기 것으로 읽는다.
    ///
    /// 이유까지 적는 까닭은, 성공한 조회에는 실패 사유 자리(`failureReason`)가 없어서다.
    /// «Chrome 을 쓸 수 없어 앱 세션으로 조회했습니다» 만 남으면 사용자는 왜 못 쓰는지도,
    /// 고른 소스를 어떻게 되살리는지도 알 수 없다.
    private static func announcing(_ result: ServerFetchResult,
                                   preferred: ClaudeSessionSource,
                                   used: ClaudeSessionSource,
                                   because problem: SessionProblem?) -> ServerFetchResult {
        guard used != preferred, result.usage.failureReason == nil else { return result }
        var usage = result.usage
        var notice = "«\(preferred.displayName)» 세션을 쓸 수 없어 «\(used.displayName)» 으로"
            + " 조회했습니다. 계정이 다를 수 있습니다."
        if let problem, problem.needsUserAction { notice += " \(problem.message)" }
        usage.fallbackNotice = [usage.fallbackNotice, notice]
            .compactMap { $0 }
            .joined(separator: " ")
        // 조회는 성공했지만 사용자가 손쓸 거리는 남아 있다. 사유를 들고 가야 설정이
        // 긴 안내문 대신 버튼을 띄울 수 있다. 권한 문제가 아닌 사유는 들고 가지 않는다 —
        // 성공한 결과에 «로그인하세요» 가 붙으면 읽는 쪽이 실패로 오해한다.
        let carried = (problem?.needsUserAction == true) ? problem : result.problem
        return ServerFetchResult(usage: usage,
                                 account: result.account,
                                 organizations: result.organizations,
                                 sourceName: result.sourceName,
                                 problem: carried)
    }

    /// 소스 하나로 끝까지 조회해 본 결과.
    private struct Attempt {
        let result: ServerFetchResult
        /// 재로그인이 필요한 실패라, 다른 소스로 다시 해 볼 만한지.
        let canRetryElsewhere: Bool
    }

    private static func fetch(now: Date,
                              jar: ClaudeCookieJar,
                              sourceName: String,
                              config: UsageConfig,
                              cachedAccount: AccountCache?) async -> Attempt {
        func failed(_ problem: SessionProblem,
                    organizations: [OrganizationSummary] = [],
                    retry: Bool = false) -> Attempt {
            Attempt(result: ServerFetchResult(usage: .failed(problem.message, at: now),
                                              account: nil,
                                              organizations: organizations,
                                              sourceName: sourceName,
                                              problem: problem),
                    canRetryElsewhere: retry)
        }

        guard let fingerprint = jar.sessionFingerprint else {
            return failed(.needsSignIn(ServerFailure.needsSignIn.message), retry: true)
        }

        // 1. 조직 목록.
        let organizations: [OrganizationSummary]
        switch await UsageAPI.get("/organizations", jar: jar) {
        case .failure(let failure):
            return failed(failure.sessionProblem, retry: failure == .needsSignIn)
        case .success(let data):
            guard let list = OrganizationSummary.list(fromJSON: data), !list.isEmpty else {
                return failed(.unreadable("조직 목록을 읽을 수 없습니다."))
            }
            organizations = list
        }

        // 2. 볼 조직을 고른다. 설정에서 고른 조직이 사라졌으면 자동 선택으로 내려가되 알린다.
        let choice = OrganizationChoice.select(from: organizations,
                                               preferred: config.organizationUuid,
                                               lastActive: jar.lastActiveOrg)
        guard let organization = choice.organization else {
            return failed(.unreadable("사용량을 볼 수 있는 조직이 없습니다."),
                          organizations: organizations)
        }

        // 3. 사용량.
        var usage: ServerUsage
        switch await UsageAPI.get("/organizations/\(organization.uuid)/usage", jar: jar) {
        case .failure(let failure):
            return failed(failure.sessionProblem,
                          organizations: organizations,
                          retry: failure == .needsSignIn)
        case .success(let data):
            guard let decoded = UsageAPI.decodeUsage(data, now: now,
                                                     organizationName: organization.name) else {
                return failed(.unreadable("사용량 응답을 읽을 수 없습니다."),
                              organizations: organizations)
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
            // 이메일은 이때만 조회한다. 조직 UUID 가 같아도 계정은 다를 수 있어서(같은 팀의
            // 다른 멤버) 필요하지만, 매 조회마다 부를 이유는 없다. 못 얻어도 조직 단위 비교는
            // 그대로 되므로 실패를 오류로 올리지 않는다.
            var email: String?
            if case .success(let data) = await UsageAPI.get("/account", jar: jar) {
                email = ClaudeAccountResponse.email(fromJSON: data)
            }
            account = AccountCache(email: email,
                                   organizationUuid: organization.uuid,
                                   organizationName: organization.name,
                                   sessionFingerprint: fingerprint,
                                   checkedAt: now)
        }

        return Attempt(result: ServerFetchResult(usage: usage,
                                                 account: account,
                                                 organizations: organizations,
                                                 sourceName: sourceName),
                       canRetryElsewhere: false)
    }
}
// MARK: - claude.ai API

private enum UsageAPI {
    static let base = "https://claude.ai/api"

    static func get(_ path: String, jar: ClaudeCookieJar) async -> Result<Data, ServerFailure> {
        var request = URLRequest(url: URL(string: base + path)!)
        request.timeoutInterval = 20
        request.setValue(jar.cookieHeader, forHTTPHeaderField: "Cookie")
        // UA 는 쿠키를 꺼낸 곳에 맞춘다. cf_clearance 가 UA 에 묶여 있어, 여기서 다른 UA 를
        // 쓰면 같은 쿠키로도 Cloudflare 챌린지를 받을 수 있다.
        request.setValue(jar.userAgent, forHTTPHeaderField: "User-Agent")
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
