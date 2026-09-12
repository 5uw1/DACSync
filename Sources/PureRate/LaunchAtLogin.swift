import ServiceManagement

/// Wraps `SMAppService.mainApp`, the macOS 13+ Login Item API. Requires
/// PureRate to actually be running as a bundled `.app` (see
/// `scripts/build-app.sh`) — `SMAppService` has no effect on a bare binary
/// launched via `swift run`.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Error? {
        do {
            if enabled {
                if SMAppService.mainApp.status == .notRegistered {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error
        }
    }
}
