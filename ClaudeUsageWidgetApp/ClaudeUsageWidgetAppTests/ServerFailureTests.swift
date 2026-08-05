//
//  ServerFailureTests.swift
//  ClaudeUsageWidgetAppTests
//
//  조회가 실패하면 다른 계정으로 폴백하지 않고 사유를 그대로 알린다. 사용자가 할 수 있는
//  일이 사유마다 다르기 때문이다 — 재로그인해야 하는지, 기다려야 하는지.
//

import Foundation
import Testing

struct ServerFailureTests {
    @Test("세션이 거부되면 재로그인을 요구한다")
    func asksForSignInWhenSessionRejected() {
        // claude.ai 세션은 4주쯤 유지되다 만료된다. 그때 401/403 이 온다.
        #expect(ServerFailure.forStatus(401) == .needsSignIn)
        #expect(ServerFailure.forStatus(403) == .needsSignIn)
    }

    @Test("그 밖의 실패는 재로그인으로 풀리지 않는다")
    func doesNotAskForSignInOnOtherFailures() {
        // 429·5xx 에 재로그인을 요구하면 사용자가 멀쩡한 세션을 버리게 된다.
        #expect(ServerFailure.forStatus(429) == .temporary)
        #expect(ServerFailure.forStatus(500) == .temporary)
        #expect(ServerFailure.forStatus(503) == .temporary)
    }

    @Test("성공은 실패가 아니다")
    func treatsSuccessAsNoFailure() {
        // 이 확인이 없으면 모든 상태를 실패로 보는 구현도 위 테스트를 통과한다.
        #expect(ServerFailure.forStatus(200) == nil)
    }
}
