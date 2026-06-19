// LiveActivityManager.swift
// WhiteBoARd - Spatial AR Notetaking
//
// Starts / updates / ends the sync Live Activity (Dynamic Island + Lock Screen).
// App-side only. A Live Activity must be *started* while the app is foreground
// or transitioning out — SyncCoordinator starts it on scenePhase `.inactive`.
//
// Swift 6 note: the actual ActivityKit update/end calls run in `nonisolated`
// static helpers that take only Sendable values (the activity id + ContentState).
// We never pass a main-actor-isolated `Activity` into a nonisolated async method,
// which is what triggers the "Sending 'activity' risks data races" diagnostic.

import Foundation
import ActivityKit

@available(iOS 16.2, *)
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private init() {}

    private var activityID: String?

    var isRunning: Bool { activityID != nil }

    func start(total: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activityID == nil else { return }
        let state = SyncActivityAttributes.ContentState(
            phase: .uploading, uploaded: 0, total: total,
            message: total > 0 ? "Uploading \(total) stroke\(total == 1 ? "" : "s")…" : "Uploading…"
        )
        do {
            let activity = try Activity.request(
                attributes: SyncActivityAttributes(startedAt: Date()),
                content: .init(state: state, staleDate: Date().addingTimeInterval(120))
            )
            activityID = activity.id
            print("[LiveActivity] started")
        } catch {
            print("[LiveActivity] start failed: \(error)")
        }
    }

    func update(phase: SyncActivityAttributes.Phase, uploaded: Int, total: Int, message: String) async {
        guard let id = activityID else { return }
        await Self.applyUpdate(id: id, state: .init(phase: phase, uploaded: uploaded, total: total, message: message))
    }

    func finish(success: Bool, count: Int, message: String) async {
        guard let id = activityID else { return }
        activityID = nil
        let final = SyncActivityAttributes.ContentState(
            phase: success ? .done : .failed,
            uploaded: count, total: max(count, 1),
            message: success ? (count > 0 ? "Synced \(count) note\(count == 1 ? "" : "s")" : "Synced") : message
        )
        await Self.applyEnd(id: id, state: final, dismissAfter: 4)
        print("[LiveActivity] ended (\(success ? "ok" : "fail"))")
    }

    /// Cancel immediately (e.g. the user returned to the app without syncing).
    func cancel() async {
        guard let id = activityID else { return }
        activityID = nil
        await Self.applyEnd(id: id, state: nil, dismissAfter: nil)
    }

    // MARK: - Off-main-actor ActivityKit work (Sendable params only)

    private nonisolated static func find(_ id: String) -> Activity<SyncActivityAttributes>? {
        Activity<SyncActivityAttributes>.activities.first { $0.id == id }
    }

    private nonisolated static func applyUpdate(id: String, state: SyncActivityAttributes.ContentState) async {
        guard let activity = find(id) else { return }
        await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(120)))
    }

    private nonisolated static func applyEnd(id: String, state: SyncActivityAttributes.ContentState?, dismissAfter: Double?) async {
        guard let activity = find(id) else { return }
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        let policy: ActivityUIDismissalPolicy = dismissAfter.map { .after(Date().addingTimeInterval($0)) } ?? .immediate
        await activity.end(content, dismissalPolicy: policy)
    }
}
