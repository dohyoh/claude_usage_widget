//
//  AccountIdentity.swift
//  ClaudeUsageWidgetApp
//
//  실측 사용량을 어느 계정으로 가져왔는지 기억해 둔다. 로컬 추정은 늘 Claude Code
//  로그(~/.claude/projects)이고 실측은 로그인 세션의 계정이라, 둘이 다른 계정을 가리킬
//  수 있다. 그걸 알리려면 실측이 어느 계정인지 알아야 한다.
//
//  계정 정보는 조회 비용이 있으므로 캐시하고, 로그인이 바뀌면 버린다. 바뀜을 알아내려고
//  세션 쿠키 원본을 들고 있지는 않는다 — 지문만 남긴다.
//

import CryptoKit
import Foundation

/// 실측 사용량을 가져온 계정. 사용자 설정이 아니라 조회 결과의 캐시다.
///
/// `UsageConfig`와 파일을 분리해 둔다. 설정에 섞으면 (1) 캐시가 갱신될 때마다
/// `UsageMonitor`의 `didSet`이 전체 갱신과 위젯 리로드를 돌리고, (2) 샌드박스 위젯까지
/// 계정 이메일을 읽게 되고, (3) "기본값으로 되돌리기"가 캐시를 함께 지운다.
struct AccountCache: Codable, Equatable, Sendable {
    /// 로그인 계정의 이메일. 조회하지 못했으면 nil.
    var email: String?
    /// 실측을 조회한 조직.
    var organizationUuid: String?
    var organizationName: String?
    /// 이 캐시를 만든 로그인 세션의 지문. 세션 쿠키 원본은 저장하지 않는다.
    var sessionFingerprint: String
    /// 계정 정보를 확인한 시각.
    var checkedAt: Date
}

enum AccountIdentity {
    /// 세션 쿠키의 지문. sha256 앞 16자(64비트).
    ///
    /// 원본을 저장하지 않고 "로그인이 바뀌었는지"만 판별하려는 값이다. 되돌릴 수 없고,
    /// 이 목적에서 충돌은 사실상 일어나지 않는다.
    static func fingerprint(sessionKey: String) -> String {
        let digest = SHA256.hash(data: Data(sessionKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }

    /// 캐시된 계정 정보를 버리고 다시 조회해야 하는지.
    ///
    /// 계정 정보는 매 조회마다 가져오지 않는다. 다시 가져올 시점만 좁혀서 정한다.
    ///
    /// - Parameters:
    ///   - cache: 지금 들고 있는 캐시. 없으면 아직 모르는 상태다.
    ///   - sessionFingerprint: 이번에 읽은 세션 쿠키의 지문.
    ///   - selectedOrganization: 설정에서 고른 조직. nil이면 자동 선택이므로 조직이
    ///     달라졌다는 이유로는 다시 조회하지 않는다.
    static func needsRefresh(cache: AccountCache?,
                             sessionFingerprint: String,
                             selectedOrganization: String?) -> Bool {
        guard let cache else { return true }
        if cache.sessionFingerprint != sessionFingerprint { return true }
        // 지정하지 않았으면(자동 선택) 캐시의 조직은 자동 선택이 고른 결과다. 그걸 불일치로
        // 보면 조회마다 계정을 다시 물어보게 된다.
        if let selectedOrganization { return cache.organizationUuid != selectedOrganization }
        return false
    }
}
