//
//  UsageConfigDecodingTests.swift
//  ClaudeUsageWidgetAppTests
//
//  설정 파일은 사용자 디스크에 이미 깔려 있다. 키를 넣거나 뺄 때 기존 파일이 못 읽히면
//  loadConfig 가 조용히 .default 로 떨어져 사용자 설정이 통째로 초기화된다.
//
//  loadConfig 는 실패를 삼키므로, "새 키가 nil 이다"만 확인하면 디코딩이 아예 깨진
//  경우에도 테스트가 통과한다. 그래서 기본값과 다른 값을 함께 확인한다.
//

import Foundation
import Testing

struct UsageConfigDecodingTests {
    /// 추정 한도·측정 방식·리셋 시점이 아직 있던 시절의 실제 사용자 설정 파일.
    ///
    /// 지금은 없는 키가 여섯 개 섞여 있고, 조직 선택이 생기기 전이라 `organizationUuid` 는
    /// 없다. 양쪽 방향의 하위 호환을 한 파일로 함께 확인한다.
    private static let legacyConfigJSON = """
    {"menuBarTextColorHex":"#000000","metric":"costUSD","weeklyResetWeekday":3,\
    "weeklyResetMinute":0,"weeklyResetHour":15,"weeklyLimit":400,\
    "sessionResetAt":"2026-07-29T08:40:00Z","menuBarStyle":"ringDual",\
    "serverUsageEnabled":true,"sessionLimit":60,"menuBarShowsRemaining":true,\
    "menuBarShowsWeekly":false}
    """

    @Test("제거된 키가 남아 있는 기존 설정 파일도 값을 잃지 않고 읽힌다")
    func decodesConfigWithRemovedKeys() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usage-config-\(UUID().uuidString).json")
        try Data(Self.legacyConfigJSON.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = UsageSharedStore.loadConfig(from: url)

        // 없는 키는 "지정 안 함" — 기존의 자동 선택이 그대로 유지된다.
        #expect(config.organizationUuid == nil)

        // 아래 셋은 UsageConfig 의 기본값이 nil 이다. 값이 들어와 있다는 것은 .default 로
        // 떨어지지 않고 파일을 실제로 디코딩했다는 뜻이다 — 지운 키가 남아 있어도
        // 사용자가 고른 메뉴바 디자인·색·표시 항목이 보존된다.
        #expect(config.menuBarStyle == "ringDual")
        #expect(config.menuBarTextColorHex == "#000000")
        #expect(config.menuBarShowsRemaining == true)
    }
}
