import ServiceManagement

/// Wraps `SMAppService.mainApp`, the macOS 13+ Login Item API. Requires
/// PureRate to actually be running as a bundled `.app` (see
/// `scripts/build-app.sh`) — `SMAppService` has no effect on a bare binary
/// launched via `swift run`.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval (enable it under System Settings > General > Login Items)"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Error? {
        do {
            if enabled {
                // Always attempt registration rather than gating on the
                // current status first — `.notFound` (not just
                // `.notRegistered`) is a perfectly normal starting status
                // and skipping register() for it silently no-ops the
                // request. `register()` itself is safe to call when
                // already registered; that specific case is swallowed
                // below instead of being treated as a failure.
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch let error as NSError
            where enabled && error.domain == "SMAppServiceErrorDomain" && error.code == 1 {
            // kSMErrorAlreadyRegistered — already in the desired state.
            return nil
        } catch {
            return error
        }
    }
}
