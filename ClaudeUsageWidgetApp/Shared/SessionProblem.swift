//
//  SessionProblem.swift
//  ClaudeUsageWidgetApp
//
//  세션을 못 구했거나 조회가 실패했을 때의 «사유». 여러 소스를 차례로 시도하므로
//  (`ClaudeSessionSource.candidates`) 모두 실패했을 때 **어느 사유를 보여줄지** 골라야 한다.
//
//  고르는 기준은 «사용자가 그 말을 듣고 할 수 있는 일이 있는가» 다. 권한이 막힌 사유가
//  뒤에 시도한 소스의 «로그인하세요» 에 덮이면, 사용자는 엉뚱한 곳에서 로그인만 반복하고
//  진짜 막힌 곳은 영영 모른다.
//
//  `ServerFailure` 는 HTTP 상태에서 오는 사유이고, 이것은 그보다 한 겹 위 — 쿠키 저장소
//  접근까지 포함한 조회 전체의 사유다.
//

import Foundation

enum SessionProblem: Equatable, Sendable {
    /// 그 소스에 claude.ai 로그인 세션이 없거나 만료됐다. 로그인하면 풀린다.
    case needsSignIn(String)
    /// 세션이 있는지조차 볼 수 없다 — OS 가 쿠키 저장소를 막았다(macOS 27 의 앱 데이터 보호).
    /// 사용자가 권한을 주거나 쿠키 원본을 바꿔야 풀린다.
    case accessDenied(String)
    /// 쿠키 저장소를 읽지 못했다(파일 없음·DB 손상·키체인 거부). 소스를 바꾸면 풀릴 수 있다.
    case unreadable(String)
    /// 기다리면 풀리는 실패(속도 제한·서버 오류).
    case temporary(String)

    /// 패널·설정에 그대로 띄울 문구.
    var message: String {
        switch self {
        case .needsSignIn(let text), .accessDenied(let text),
             .unreadable(let text), .temporary(let text):
            return text
        }
    }

    /// 사용자가 권한을 주거나 설정을 바꿔야 풀리는 사유인지 — 설정이 복구 버튼을 띄울지 정한다.
    var needsUserAction: Bool {
        if case .accessDenied = self { return true }
        return false
    }

    /// 지금까지의 사유와 새 사유 중 사용자에게 보여줄 쪽.
    ///
    /// 권한 거부가 언제나 앞선다 — 손쓰지 않으면 영영 풀리지 않는 유일한 사유라서다.
    /// 그 밖에는 **먼저 시도한 소스**, 즉 사용자가 고른 쪽의 사유를 남긴다. 나중 소스의
    /// 사유로 계속 덮으면 사용자가 고르지도 않은 소스에 대한 안내를 읽게 된다.
    static func preferred(_ current: SessionProblem?, _ next: SessionProblem) -> SessionProblem {
        guard let current else { return next }
        if next.needsUserAction && !current.needsUserAction { return next }
        return current
    }
}

extension ServerFailure {
    /// HTTP 에서 온 실패를 조회 전체의 사유로 옮긴다.
    var sessionProblem: SessionProblem {
        switch self {
        case .needsSignIn: return .needsSignIn(message)
        case .temporary: return .temporary(message)
        }
    }
}
