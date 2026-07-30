//
//  LaunchAtLogin.swift
//  ClaudeUsageWidgetApp
//
//  로그인 시 자동 실행. SMAppService 는 앱이 등록된 위치를 기준으로 동작하므로
//  /Applications 에 설치한 뒤 켜야 재부팅 후에도 유지된다.
//

import Foundation
import Observation
import ServiceManagement

@Observable
final class LaunchAtLoginController {
    /// 마지막 등록/해제 실패 메시지.
    private(set) var lastError: String?
    /// status 는 시스템이 들고 있으므로 토글 후 직접 갱신한다.
    private(set) var isEnabled: Bool

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// 개발 빌드(DerivedData)에서 켜면 경로가 바뀔 때마다 등록이 깨진다.
    var isInstalledInApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
