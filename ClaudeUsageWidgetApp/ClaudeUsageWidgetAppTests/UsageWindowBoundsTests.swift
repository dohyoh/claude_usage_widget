//
//  UsageWindowBoundsTests.swift
//  ClaudeUsageWidgetAppTests
//
//  로컬 집계의 창 경계는 서버가 준 리셋 시각에서 온다. 로그만으로 잡으면 5시간 창 시작이
//  늦게 잡히고(창을 여는 요청이 데스크톱·웹에서 나가면 로컬 로그에 없다), 주간은 고정
//  주기라 최근 7일로 세면 지난 주기가 섞인다.
//
//  경계가 틀리면 그 창 안의 요청 수·토큰도 함께 틀린다. 그래서 경계 자체를 검증한다.
//

import Foundation
import Testing

struct UsageWindowBoundsTests {

    // MARK: - 리셋 시각에서 경계 역산

    @Test("리셋 시각에서 창 길이를 빼 창의 시작을 얻는다")
    func derivesBoundsFromResetTimes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = ServerUsage(fetchedAt: now,
                                fiveHour: window(resetsAt: now.addingTimeInterval(3600)),
                                sevenDay: window(resetsAt: now.addingTimeInterval(86_400)),
                                sevenDayOpus: nil,
                                organizationName: nil,
                                failureReason: nil)

        let bounds = usage.localWindowBounds

        // 1시간 뒤 리셋이면 4시간 전이 이 창의 시작이다.
        #expect(bounds.sessionStart == now.addingTimeInterval(-4 * 3600))
        // 하루 뒤 리셋이면 6일 전이 이 주기의 시작이다.
        #expect(bounds.weeklyStart == now.addingTimeInterval(-6 * 86_400))
    }

    @Test("리셋 시각이 없는 창은 경계를 모르는 상태로 남는다")
    func leavesBoundsUnknownWithoutResetTimes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = ServerUsage(fetchedAt: now,
                                fiveHour: window(resetsAt: nil),
                                sevenDay: nil,
                                sevenDayOpus: nil,
                                organizationName: nil,
                                failureReason: nil)

        let bounds = usage.localWindowBounds

        #expect(bounds.sessionStart == nil)
        #expect(bounds.weeklyStart == nil)
    }

    // MARK: - 리더가 경계를 실제로 쓰는지

    @Test("서버가 준 창 시작 이후 요청만 5시간 창에 넣는다")
    func usesServerSessionStart() throws {
        let now = Date()
        let home = try Self.claudeHome(withRequestsAt: [now.addingTimeInterval(-4 * 3600),
                                                       now.addingTimeInterval(-2 * 3600),
                                                       now.addingTimeInterval(-30 * 60)])
        defer { try? FileManager.default.removeItem(at: home) }

        // 로그 휴리스틱은 4시간 전 첫 요청부터 창을 열어 셋을 다 센다.
        let guessed = ClaudeUsageReader(claudeHome: home).makeSnapshot(now: now)
        #expect(guessed.activeBlock?.requestCount == 3)

        // 서버가 3시간 전 시작을 알려주면 그 뒤 둘만 이 창의 것이다.
        let start = now.addingTimeInterval(-3 * 3600)
        let measured = ClaudeUsageReader(claudeHome: home)
            .makeSnapshot(now: now, bounds: UsageWindowBounds(sessionStart: start))

        #expect(measured.activeBlock?.requestCount == 2)
        #expect(measured.activeBlock?.startedAt == start)
    }

    @Test("서버가 준 주기 시작 이전 요청은 주간 집계에서 빠진다")
    func usesServerWeeklyStart() throws {
        let now = Date()
        let home = try Self.claudeHome(withRequestsAt: [now.addingTimeInterval(-6 * 86_400),
                                                       now.addingTimeInterval(-86_400)])
        defer { try? FileManager.default.removeItem(at: home) }

        // 주기가 이틀 전에 시작했다면 6일 전 요청은 지난 주기의 것이다.
        let bounds = UsageWindowBounds(weeklyStart: now.addingTimeInterval(-2 * 86_400))
        let measured = ClaudeUsageReader(claudeHome: home).makeSnapshot(now: now, bounds: bounds)
        #expect(measured.weeklyTokens.output == Self.outputPerRequest)

        // 같은 로그를 롤링 7일로 세면 지난 주기까지 섞여 두 배가 된다.
        var rolling = UsageConfig.default
        rolling.weeklyResetWeekday = nil
        let mixed = ClaudeUsageReader(claudeHome: home).makeSnapshot(now: now, config: rolling)
        #expect(mixed.weeklyTokens.output == Self.outputPerRequest * 2)
    }

    @Test("주기 시작이 7일보다 앞이어도 집계 범위에서 잘리지 않는다")
    func doesNotClampWeeklyStartToSevenDays() throws {
        let now = Date()
        let home = try Self.claudeHome(withRequestsAt: [now.addingTimeInterval(-7.5 * 86_400)])
        defer { try? FileManager.default.removeItem(at: home) }

        // 파일 스캔 범위를 7일로 고정하면 이 요청이 조용히 빠진다. 주기 시작보다
        // 앞까지 훑어야 주기의 앞부분이 누락되지 않는다.
        let bounds = UsageWindowBounds(weeklyStart: now.addingTimeInterval(-8 * 86_400))
        let measured = ClaudeUsageReader(claudeHome: home).makeSnapshot(now: now, bounds: bounds)

        #expect(measured.weeklyTokens.output == Self.outputPerRequest)
    }

    // MARK: - 도구

    private func window(resetsAt: Date?) -> ServerUsageWindow {
        ServerUsageWindow(utilizationPercent: 62, resetsAt: resetsAt)
    }

    /// 로그 한 줄이 기록하는 출력 토큰.
    private static let outputPerRequest = 200

    /// 세션 로그 하나를 담은 임시 `~/.claude` 를 만든다.
    ///
    /// 실제 사용자 홈을 건드리지 않으려고 `ClaudeUsageReader(claudeHome:)` 로 넘긴다.
    private static func claudeHome(withRequestsAt timestamps: [Date]) throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-home-\(UUID().uuidString)", isDirectory: true)
        let project = home.appendingPathComponent("projects/-tmp-demo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // requestId 가 중복 제거 키라 요청마다 달라야 한다.
        let lines = timestamps.enumerated().map { index, timestamp in
            """
            {"type":"assistant","timestamp":"\(formatter.string(from: timestamp))",\
            "requestId":"req-\(index)","message":{"model":"claude-opus-5",\
            "usage":{"input_tokens":100,"output_tokens":\(outputPerRequest)}}}
            """
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: project.appendingPathComponent("session.jsonl"))
        return home
    }
}
