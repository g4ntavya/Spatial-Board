// SyncCoordinator.swift
// WhiteBoARd - Spatial AR Notetaking
//
// Bridges scenePhase changes to sync + the Live Activity. A Live Activity must
// be started while the app is foreground/transitioning, so we start it on
// `.inactive` (the moment the user is leaving), run the upload on `.background`,
// and cancel the activity if the user comes back without backgrounding.

import Foundation
import SwiftData

@MainActor
final class SyncCoordinator {
    static let shared = SyncCoordinator()
    private init() {}

    private var armed = false

    /// App is leaving the foreground (user swiping away, or pulling Control Center).
    func sceneBecameInactive(context: ModelContext) {
        guard SyncService.shared.isConfigured,
              AuthService.shared.isSignedIn,
              SyncService.shared.hasUnsynced(context: context) else { return }
        armed = true
        if #available(iOS 16.2, *) {
            LiveActivityManager.shared.start(total: 0)
        }
    }

    /// App entered the background — kick off the upload (Live Activity already live).
    func sceneEnteredBackground(context: ModelContext) {
        guard SyncService.shared.isConfigured, AuthService.shared.isSignedIn else { return }
        armed = false
        SyncService.shared.syncInBackground(context: context)
    }

    /// Returned to the app. If we armed a Live Activity but never backgrounded
    /// (e.g. just a Control Center pull), tear it down.
    func sceneBecameActive() {
        guard armed else { return }
        armed = false
        if #available(iOS 16.2, *), LiveActivityManager.shared.isRunning, !SyncService.shared.isSyncing {
            Task { await LiveActivityManager.shared.cancel() }
        }
    }
}
