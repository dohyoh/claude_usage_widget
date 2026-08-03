//
//  UsageConfigDecodingTests.swift
//  ClaudeUsageWidgetAppTests
//
//  설정 파일은 사용자 디스크에 이미 깔려 있다. 새 키를 넣을 때 기존 파일이 못 읽히면
//  loadConfig 가 조용히 .default 로 떨어져 사용자 설정이 통째로 초기화된다.
//
//  loadConfig 는 실패를 삼키므로, "새 키가 nil 이다"만 확인하면 디코딩이 아예 깨진
//  경우에도 테스트가 통과한다. 그래서 기본값과 다른 값을 함께 확인한다.
//

import Foundation
import Testing

struct UsageConfigDecodingTests {
    /// 실제 사용자 설정 파일(`~/.claude/.usage-widget-config.json`)의 내용.
    ///
    /// 조직 선택이 생기기 전에 쓰인 파일이라 `organizationUuid` 키가 없다.
    private static let legacyConfigJSON = """
    {"menuBarTextColorHex":"#000000","metric":"costUSD","weeklyResetWeekday":3,\
    "weeklyResetMinute":0,"weeklyResetHour":15,"weeklyLimit":400,\
    "sessionResetAt":"2026-07-29T08:40:00Z","menuBarStyle":"ringDual",\
    "serverUsageEnabled":true,"sessionLimit":60,"menuBarShowsRemaining":true,\
    "menuBarShowsWeekly":false}
    """

    @Test("organizationUuid 가 없는 기존 설정 파일도 값을 잃지 않고 읽힌다")
    func decodesConfigWrittenBeforeOrganizationSelection() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usage-config-\(UUID().uuidString).json")
        try Data(Self.legacyConfigJSON.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = UsageSharedStore.loadConfig(from: url)

        // 새 키가 없으면 "조직 지정 안 함" — 기존의 자동 선택이 그대로 유지된다.
        #expect(config.organizationUuid == nil)

        // 아래 둘은 UsageConfig 의 기본값이 nil 이다. 값이 들어와 있다는 것은
        // .default 로 떨어지지 않고 파일을 실제로 디코딩했다는 뜻이다.
        #expect(config.menuBarStyle == "ringDual")
        // 날짜가 들어왔다는 것은 프로덕션과 같은 iso8601 전략을 썼다는 뜻이다.
        #expect(config.sessionResetAt != nil)

        #expect(config.weeklyLimit == 400)
        #expect(config.sessionLimit == 60)
    }
}
