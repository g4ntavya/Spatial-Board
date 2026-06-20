// SyncCoordinator.swift
// WhiteBoARd - Spatial AR Notetaking
//
// Bridges scenePhase changes to sync + the Live Activity.
//
// A Live Activity must be *started* while the app is foreground (applicationState
// != .background). The last foreground moment as the user leaves is `.inactive`,
// so we start the activity AND kick the upload there — the request begins before
// the app is backgrounded, which makes "upload after exit" reliable even on a
// quick swipe-away. (Force-quitting from the App Switcher still kills it — that's
// an iOS limitation, not a bug.)

import Foundation
import SwiftData

@MainActor
final class SyncCoordinator {
    static let shared = SyncCoordinator()
    private init() {}

    /// App is leaving the foreground (swiping to Home / app switcher / Control Center).
    func sceneBecameInactive(context: ModelContext) {
        guard SyncService.shared.isConfigured else { print("[Sync] leaving: not configured (.env missing SPATIALBOARD_SYNC_URL/TOKEN?)"); return }
        guard AuthService.shared.isSignedIn else { print("[Sync] leaving: not signed in"); return }
        guard SyncService.shared.hasUnsynced(context: context) else { print("[Sync] leaving: nothing new to sync — Live Activity only shows when there's new content"); return }
        print("[Sync] leaving with unsynced content → starting Live Activity + upload")
        // Start the Live Activity synchronously while we're still foreground…
        if #available(iOS 16.2, *) {
            LiveActivityManager.shared.start(total: 0)
        }
        // …then begin the upload (which updates + ends the activity on completion).
        SyncService.shared.syncInBackground(context: context)
    }

    /// Safety net: if `.inactive` didn't fire (rare), still sync on background.
    func sceneEnteredBackground(context: ModelContext) {
        guard SyncService.shared.isConfigured, AuthService.shared.isSignedIn else { return }
        SyncService.shared.syncInBackground(context: context) // no-op if already syncing
    }

    func sceneBecameActive() {
        // The Live Activity finishes itself when the sync completes; nothing to do.
    }
}
