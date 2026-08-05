//
//  UsageSnapshotDecodingTests.swift
//  ClaudeUsageWidgetAppTests
//
//  스냅샷은 메뉴바 앱이 쓰고 위젯이 읽는 파일이다. 날짜 전략이 어긋나면 `resetsAt` 이
//  깨지고, 그러면 리셋까지 남은 시간·경과 시간 바·창 만료 판정(`isCurrent`)이 통째로
//  틀린다. 소진율이 실측 하나뿐이라 받쳐 줄 것도 없다 — 화면이 조용히 비거나 지난 창의
//  값을 보여준다.
//
//  `UsageConfig` 에 Date 필드가 없어져 iso8601 검증을 여기서 맡는다.
//

import Foundation
import Testing

struct UsageSnapshotDecodingTests {

    @Test("스냅샷의 날짜가 프로덕션과 같은 iso8601 전략으로 오간다")
    func roundTripsDatesAsISO8601() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usage-snapshot-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        // 초 단위로 끊어 둔다 — 소수점 이하는 인코딩에서 버려지므로 값 비교가 흔들린다.
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let resetsAt = fetchedAt.addingTimeInterval(3600)
        var snapshot = UsageSnapshot.empty
        snapshot.generatedAt = fetchedAt
        snapshot.server = ServerUsage(fetchedAt: fetchedAt,
                                     fiveHour: ServerUsageWindow(utilizationPercent: 62,
                                                                 resetsAt: resetsAt),
                                     sevenDay: nil,
                                     sevenDayOpus: nil,
                                     organizationName: "My Org",
                                     failureReason: nil)

        #expect(UsageSharedStore.save(snapshot, to: url))
        let loaded = try #require(UsageSharedStore.loadSnapshot(from: url))

        #expect(loaded.server?.fetchedAt == fetchedAt)
        #expect(loaded.server?.fiveHour?.resetsAt == resetsAt)
        // 리셋 전이면 이 창은 아직 유효하다. 날짜가 깨졌다면 여기서 걸린다.
        #expect(loaded.server?.validated(at: fetchedAt)?.fiveHour != nil)
        #expect(loaded.server?.validated(at: resetsAt.addingTimeInterval(1)) == nil)
    }

    @Test("주간 집계가 없는 스냅샷도 읽힌다 — 경계를 모르면 값 자체가 없다")
    func decodesSnapshotWithoutWeeklyAggregate() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usage-snapshot-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(UsageSharedStore.save(UsageSnapshot.empty, to: url))
        let loaded = try #require(UsageSharedStore.loadSnapshot(from: url))

        #expect(loaded.weeklyTokens == nil)
        #expect(loaded.weeklyTokensByModel == nil)
        #expect(loaded.activeBlock == nil)
    }

    @Test("주간 집계가 든 이전 버전 스냅샷도 읽힌다")
    func decodesLegacySnapshotWithWeeklyAggregate() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usage-snapshot-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        // 롤링 7일 집계와 비용 환산을 담던 시절의 파일. 지금은 만들지 않지만 디스크에 남아 있다.
        let legacy = """
        {"generatedAt":"2026-07-29T08:40:00Z","scannedSessionCount":12,\
        "todayTokens":{"input":10,"output":20,"cacheCreation":0,"cacheRead":0,\
        "cacheCreation1h":0,"cacheCreation5m":0,"costUSD":0.5},\
        "weeklyTokens":{"input":100,"output":200,"cacheCreation":0,"cacheRead":300,\
        "cacheCreation1h":0,"cacheCreation5m":0,"costUSD":1.5},\
        "weeklyTokensByModel":{"claude-opus-5":300}}
        """
        try Data(legacy.utf8).write(to: url)

        let loaded = try #require(UsageSharedStore.loadSnapshot(from: url))

        #expect(loaded.weeklyTokens?.output == 200)
        #expect(loaded.weeklyTokensByModel?["claude-opus-5"] == 300)
        #expect(loaded.todayTokens.output == 20)
    }
}
