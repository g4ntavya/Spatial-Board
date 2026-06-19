// LiveActivityManager.swift
// WhiteBoARd - Spatial AR Notetaking
//
// Starts / updates / ends the sync Live Activity (Dynamic Island + Lock Screen).
// App-side only. A Live Activity must be *started* while the app is foreground
// or transitioning out — SyncCoordinator starts it on scenePhase `.inactive`.

import Foundation
import ActivityKit

@available(iOS 16.1, *)
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private init() {}

    private var activity: Activity<SyncActivityAttributes>?

    var isRunning: Bool { activity != nil }

    func start(total: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activity == nil else { return }
        let state = SyncActivityAttributes.ContentState(
            phase: .uploading, uploaded: 0, total: total,
            message: total > 0 ? "Uploading \(total) stroke\(total == 1 ? "" : "s")…" : "Uploading…"
        )
        do {
            activity = try Activity.request(
                attributes: SyncActivityAttributes(startedAt: Date()),
                content: .init(state: state, staleDate: Date().addingTimeInterval(120))
            )
            print("[LiveActivity] started")
        } catch {
            print("[LiveActivity] start failed: \(error)")
        }
    }

    func update(phase: SyncActivityAttributes.Phase, uploaded: Int, total: Int, message: String) async {
        guard let activity else { return }
        await activity.update(.init(
            state: .init(phase: phase, uploaded: uploaded, total: total, message: message),
            staleDate: Date().addingTimeInterval(120)
        ))
    }

    func finish(success: Bool, count: Int, message: String) async {
        guard let activity else { return }
        let final = SyncActivityAttributes.ContentState(
            phase: success ? .done : .failed,
            uploaded: count, total: max(count, 1),
            message: success ? (count > 0 ? "Synced \(count) note\(count == 1 ? "" : "s")" : "Synced") : message
        )
        await activity.end(.init(state: final, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(4)))
        self.activity = nil
        print("[LiveActivity] ended (\(success ? "ok" : "fail"))")
    }

    /// Cancel immediately (e.g. the user returned to the app without syncing).
    func cancel() async {
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
    }
}
