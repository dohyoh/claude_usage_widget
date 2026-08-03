//
//  ServerFailure.swift
//  ClaudeUsageWidgetApp
//
//  조회가 실패했을 때 사용자에게 무엇을 하라고 할지 정한다.
//
//  실패하면 다른 계정으로 폴백하지 않는다. 조용히 다른 계정 숫자를 보여주면 사용자는 남의
//  사용량을 자기 것으로 읽는다. 대신 사유를 그대로 알리고, 할 수 있는 일을 함께 말한다.
//

import Foundation

enum ServerFailure: Equatable, Sendable {
    /// 세션이 만료·거부됐다. 다시 로그인해야 풀린다.
    case needsSignIn
    /// 일시적 실패(속도 제한·서버 오류). 기다리면 풀린다.
    case temporary

    /// HTTP 상태로 실패 종류를 가른다. 성공이면 nil.
    ///
    /// 401/403 만 재로그인을 요구한다. 429·5xx 에도 재로그인을 요구하면 사용자가 멀쩡한
    /// 세션을 버리고 캡차까지 다시 풀게 된다.
    static func forStatus(_ status: Int) -> ServerFailure? {
        switch status {
        case 200..<300: return nil
        case 401, 403: return .needsSignIn
        default: return .temporary
        }
    }

    /// 패널·설정에 그대로 띄울 문구.
    var message: String {
        switch self {
        case .needsSignIn:
            return "Claude 로그인이 만료됐습니다. 설정에서 다시 로그인하세요."
        case .temporary:
            return "사용량 조회에 실패했습니다. 잠시 후 다시 시도합니다."
        }
    }
}
