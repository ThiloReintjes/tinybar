import Foundation
import Observation
import ServiceManagement
import TinybarCore

/// User preferences in UserDefaults. No config files (SPEC §11).
@MainActor
@Observable
final class Settings {
    private let defaults = UserDefaults.standard

    var pinnedLimit: String? {
        didSet { defaults.set(pinnedLimit, forKey: "pinnedLimit") }
    }

    var hidePercentage: Bool {
        didSet { defaults.set(hidePercentage, forKey: "hidePercentage") }
    }

    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }

    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            applyLaunchAtLogin()
        }
    }

    init() {
        defaults.register(defaults: ["notificationsEnabled": true, "hidePercentage": false])
        pinnedLimit = defaults.string(forKey: "pinnedLimit")
        hidePercentage = defaults.bool(forKey: "hidePercentage")
        notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        launchAtLogin = SMAppService.mainApp.status == .enabled

        // Launch at login is on by default: register once on first run.
        if !defaults.bool(forKey: "didConfigureLaunchAtLogin") {
            defaults.set(true, forKey: "didConfigureLaunchAtLogin")
            launchAtLogin = true
            applyLaunchAtLogin()
        }
    }

    private func applyLaunchAtLogin() {
        // Only meaningful for a bundled .app; `swift run` builds silently skip this.
        guard Bundle.main.bundleIdentifier != nil else { return }
        do {
            if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: Providers

    /// Auto-detected Providers are on unless the user turned them off.
    func isEnabled(_ id: ProviderID, detected: Bool) -> Bool {
        (defaults.object(forKey: "enabled.\(id.rawValue)") as? Bool) ?? detected
    }

    func setEnabled(_ id: ProviderID, _ enabled: Bool) {
        defaults.set(enabled, forKey: "enabled.\(id.rawValue)")
    }

    // MARK: Browser fallback

    /// Read from provider fetches off the main actor, so kept in a thread-safe box.
    let browserFallbackFlags = BrowserFallbackFlags()

    func isBrowserFallbackEnabled(_ id: ProviderID) -> Bool {
        browserFallbackFlags.isEnabled(id)
    }

    func setBrowserFallback(_ id: ProviderID, _ enabled: Bool) {
        browserFallbackFlags.set(id, enabled)
        browserFallbackRevision += 1
    }

    /// Bumped on change so SwiftUI re-reads the flags.
    private(set) var browserFallbackRevision = 0

    // MARK: Alert state

    func loadAlertState() -> LimitAlertPlanner {
        guard let data = defaults.data(forKey: "alertState"),
              let planner = try? JSONDecoder().decode(LimitAlertPlanner.self, from: data)
        else { return LimitAlertPlanner() }
        return planner
    }

    func saveAlertState(_ planner: LimitAlertPlanner) {
        defaults.set(try? JSONEncoder().encode(planner), forKey: "alertState")
    }
}

/// Opt-in per provider; off by default because reading Chromium cookies triggers a one-time
/// macOS Keychain prompt for the browser's "Safe Storage" key.
final class BrowserFallbackFlags: @unchecked Sendable {
    private let lock = NSLock()
    private let defaults = UserDefaults.standard

    func isEnabled(_ id: ProviderID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return defaults.bool(forKey: "browserFallback.\(id.rawValue)")
    }

    func set(_ id: ProviderID, _ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        defaults.set(enabled, forKey: "browserFallback.\(id.rawValue)")
    }
}
