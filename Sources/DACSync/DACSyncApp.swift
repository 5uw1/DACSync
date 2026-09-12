import Foundation
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Without this the log-stream child process (and hog mode, if
        // held) outlives a graceful quit — Foundation doesn't kill a
        // Process's children automatically.
        state?.stopMonitoring()
    }
}

@main
struct DACSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state: AppState

    init() {
        // Headless verification hook for the Login Item toggle, which has
        // no other scriptable path (SMAppService only works from inside
        // the bundled app itself, and driving the actual menu bar UI needs
        // Accessibility permission this isn't granted). Run directly, e.g.
        // `DACSync.app/Contents/MacOS/DACSync --test-login-item-register`.
        let args = CommandLine.arguments
        if args.contains("--test-login-item-register") || args.contains("--test-login-item-unregister") {
            let enable = args.contains("--test-login-item-register")
            let error = LaunchAtLogin.setEnabled(enable)
            if let error {
                let nsError = error as NSError
                FileHandle.standardError.write(
                    "ERROR: \(error.localizedDescription) domain=\(nsError.domain) code=\(nsError.code)\n".data(using: .utf8)!
                )
                exit(1)
            }
            print("OK: launchAtLoginEnabled=\(LaunchAtLogin.isEnabled) status=\(LaunchAtLogin.statusDescription)")
            exit(0)
        }
        let state = AppState()
        _state = StateObject(wrappedValue: state)
        _appDelegate.wrappedValue.state = state
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(state: state)
        } label: {
            Text(state.menuBarTitle)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
        .menuBarExtraStyle(.window)
    }
}
