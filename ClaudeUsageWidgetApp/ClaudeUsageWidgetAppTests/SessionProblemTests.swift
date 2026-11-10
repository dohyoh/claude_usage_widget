//
//  SessionProblemTests.swift
//  ClaudeUsageWidgetAppTests
//
//  소스를 여러 개 시도하므로, 모두 실패하면 어느 사유를 보여줄지 골라야 한다. 그 선택을
//  고정한다 — 잘못 고르면 사용자는 진짜 막힌 곳 대신 엉뚱한 안내를 읽는다.
//

import Foundation
import Testing

struct SessionProblemTests {
    @Test("권한 거부는 다른 사유에 덮이지 않는다")
    func accessDenialOutranksEverythingElse() {
        // 브라우저가 막혔는데 뒤이어 본 앱 세션이 «로그인하세요» 라고 하면, 그 말에 따라
        // 로그인해도 아무것도 달라지지 않는다. 막혔다는 사실이 먼저 전해져야 한다.
        let denied = SessionProblem.accessDenied("막혔습니다")
        let signIn = SessionProblem.needsSignIn("로그인하세요")

        #expect(SessionProblem.preferred(signIn, denied) == denied)
        #expect(SessionProblem.preferred(denied, signIn) == denied)
    }

    @Test("권한 문제가 없으면 먼저 시도한 사유를 남긴다")
    func keepsTheFirstProblemOtherwise() {
        // 먼저 시도한 소스가 사용자가 고른 쪽이다. 뒤 소스의 사유로 덮으면 고르지도 않은
        // 소스에 대한 안내를 읽게 된다.
        let first = SessionProblem.needsSignIn("로그인하세요")
        let later = SessionProblem.temporary("잠시 후 다시")

        #expect(SessionProblem.preferred(first, later) == first)
        #expect(SessionProblem.preferred(nil, later) == later)
    }

    @Test("복구 버튼은 권한 거부에만 붙는다")
    func onlyAccessDenialAsksTheUserToAct() {
        #expect(SessionProblem.accessDenied("막혔습니다").needsUserAction)
        #expect(SessionProblem.needsSignIn("로그인하세요").needsUserAction == false)
        #expect(SessionProblem.temporary("잠시 후 다시").needsUserAction == false)
        #expect(SessionProblem.unreadable("못 읽었습니다").needsUserAction == false)
    }

    @Test("HTTP 실패도 같은 사유 체계로 옮겨진다")
    func carriesHttpFailuresIntoTheSameVocabulary() {
        #expect(ServerFailure.needsSignIn.sessionProblem
            == .needsSignIn(ServerFailure.needsSignIn.message))
        #expect(ServerFailure.temporary.sessionProblem
            == .temporary(ServerFailure.temporary.message))
    }
}
