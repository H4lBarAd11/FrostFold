import Foundation
import ServiceManagement

/// Start-at-login, through `SMAppService`.
///
/// The older `SMLoginItemSetEnabled` route needs a separate helper bundle;
/// `SMAppService.mainApp` registers the app itself, which is what a background
/// app like this one wants. macOS 13 and later, and the deployment target is 14.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when macOS has the registration but the user has switched it off in
    /// System Settings. Their decision wins, and the UI should say so rather
    /// than showing a toggle that silently refuses to move.
    static var isBlockedByUser: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func set(_ enabled: Bool) -> Error? {
        do {
            if enabled {
                // Registering while already registered throws rather than
                // being a no-op.
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            NSLog("FrostFold: login item \(enabled ? "register" : "unregister") failed — \(error)")
            return error
        }
    }

    /// Opens the Login Items pane, for when the user has to approve it there.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
