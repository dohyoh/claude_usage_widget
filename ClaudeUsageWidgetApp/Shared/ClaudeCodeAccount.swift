//
//  ClaudeCodeAccount.swift
//  ClaudeUsageWidgetApp
//
//  로컬 토큰 상세(~/.claude/projects 로그)가 어느 계정의 활동인지 알려주는 값.
//
//  Claude Code 는 로그인한 계정을 ~/.claude.json 의 `oauthAccount` 에 남긴다. 자격증명이
//  아니라 신원 정보뿐이라 키체인 접근 없이 읽히고, Claude Code 가 쓸 때마다 갱신된다.
//

import Foundation

/// Claude Code 가 로그인해 둔 계정.
struct ClaudeCodeAccount: Equatable, Sendable {
    let email: String?
    let organizationUuid: String?
    let organizationName: String?

    /// `~/.claude.json` 의 기본 위치.
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json", isDirectory: false)
    }

    /// 지정한 파일에서 계정을 읽는다. 파일이 없거나 `oauthAccount` 가 없으면 nil.
    ///
    /// 이 파일은 Claude Code 소유다. 우리가 관심 있는 키만 꺼내고 나머지는 무시한다 —
    /// 새 키가 생겨도 깨지지 않아야 한다.
    static func read(from url: URL = defaultURL) -> ClaudeCodeAccount? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["oauthAccount"] as? [String: Any]
        else { return nil }

        return ClaudeCodeAccount(email: oauth["emailAddress"] as? String,
                                 organizationUuid: oauth["organizationUuid"] as? String,
                                 organizationName: oauth["organizationName"] as? String)
    }
}

/// 실측 계정과 로컬 로그의 계정이 같은지.
///
/// 다르면 패널의 소진율(실측)과 토큰 상세(로컬 로그)가 서로 다른 계정을 가리킨다. 조회가
/// 실패하면 사유가 뜨지만 계정이 어긋나면 **숫자가 멀쩡하게 나오므로**, 조용히 두면
/// 사용자는 남의 계정 활동을 자기 것으로 읽는다.
enum AccountMatch: Equatable, Sendable {
    /// 한쪽이라도 알 수 없어 비교하지 못했다.
    case unknown
    /// 같은 계정, 같은 조직.
    case same
    /// 서로 다른 계정으로 로그인돼 있다.
    case differentAccount
    /// 같은 계정이지만 실측이 로컬 로그와 다른 조직을 보고 있다.
    case differentOrganization

    /// 어느 쪽이 왜 갈리는지 판정한다.
    ///
    /// 이메일을 먼저 본다. 같은 팀 조직의 다른 멤버라면 `organizationUuid` 는 일치하므로
    /// 조직만 비교하면 계정이 다른 것을 놓친다.
    static func evaluate(server: AccountCache?, local: ClaudeCodeAccount?) -> AccountMatch {
        guard let server, let local else { return .unknown }
        if let serverEmail = server.email, serverEmail != local.email { return .differentAccount }
        if server.organizationUuid != local.organizationUuid { return .differentOrganization }
        return .same
    }
}
