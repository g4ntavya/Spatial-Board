// SyncService.swift
// WhiteBoARd - Spatial AR Notetaking
//
// Pushes the local SwiftData store (spaces, folders, strokes) to the AWS web
// companion. Two entry points:
//   • syncNow(context:)        — foreground, returns a result string for the UI
//   • syncInBackground(context:) — on app exit, drives a Live Activity so the
//     upload state is visible in the Dynamic Island / Lock Screen.
//
// Strokes are UUID-keyed, so the backend upserts idempotently.

import Foundation
import SwiftData
import simd
#if canImport(UIKit)
import UIKit
#endif

struct SyncResult {
    let ok: Bool
    let message: String
    let noteCount: Int
}

@MainActor
@Observable
final class SyncService {
    static let shared = SyncService()
    private init() {}

    private var endpoint: URL?
    private var token: String?
    private(set) var isSyncing = false
    var lastStatus: String?

    var isConfigured: Bool { endpoint != nil && token != nil }

    func configure(url: String, token: String) {
        endpoint = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines))
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[Sync] configured → \(url)")
    }

    /// Foreground sync triggered by the user. Returns a human-readable result.
    @discardableResult
    func syncNow(context: ModelContext) async -> String {
        let result = await performSync(context: context, live: false)
        lastStatus = result.message
        return result.message
    }

    /// Background sync on app exit, with a Live Activity for visible progress.
    func syncInBackground(context: ModelContext) {
        guard isConfigured, !isSyncing else { return }
        #if canImport(UIKit)
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "SpatialBoardSync") {
            UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid
        }
        Task {
            let result = await performSync(context: context, live: true)
            if #available(iOS 16.1, *) {
                await LiveActivityManager.shared.finish(success: result.ok, count: result.noteCount, message: result.message)
            }
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
        }
        #else
        Task { _ = await performSync(context: context, live: false) }
        #endif
    }

    private static let syncedCountKey = "com.whiteboard.lastSyncedStrokeCount"

    private func strokeCount(_ context: ModelContext) -> Int {
        (try? context.fetchCount(FetchDescriptor<SpatialStroke>())) ?? 0
    }

    /// True if the store changed since the last successful sync (gates the Live
    /// Activity so it doesn't flash when nothing's new).
    func hasUnsynced(context: ModelContext) -> Bool {
        let count = strokeCount(context)
        guard count > 0 else { return false }
        return count != UserDefaults.standard.integer(forKey: Self.syncedCountKey)
    }

    // MARK: - Core

    private func performSync(context: ModelContext, live: Bool) async -> SyncResult {
        guard let endpoint, let token else { return SyncResult(ok: false, message: "Sync not configured", noteCount: 0) }
        guard !isSyncing else { return SyncResult(ok: false, message: "Already syncing", noteCount: 0) }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let spaces = try context.fetch(FetchDescriptor<Space>())
            let folders = try context.fetch(FetchDescriptor<SpatialFolder>())
            let strokes = try context.fetch(FetchDescriptor<SpatialStroke>())
            let strokeDTOs = strokes.compactMap(Self.strokeDTO)

            guard !strokeDTOs.isEmpty else {
                print("[Sync] nothing to send")
                return SyncResult(ok: true, message: "Nothing to sync", noteCount: 0)
            }

            if live, #available(iOS 16.1, *) {
                LiveActivityManager.shared.start(total: strokeDTOs.count)
            }

            let payload = SyncPayload(
                deviceId: Self.deviceId,
                spaces: spaces.map { SpaceDTO(id: $0.id.uuidString, name: $0.name, colorHex: $0.colorHex) },
                folders: folders.map { FolderDTO(id: $0.id.uuidString, spaceId: $0.spaceID, name: $0.name) },
                strokes: strokeDTOs
            )

            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(token, forHTTPHeaderField: "x-api-key")
            if let authToken = AuthService.shared.currentToken() {
                req.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            }
            req.httpBody = try JSONEncoder().encode(payload)
            req.timeoutInterval = 30

            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if code == 200 {
                let r = try? JSONDecoder().decode(SyncAck.self, from: data)
                let n = r?.noteClusters ?? 0
                print("[Sync] 200 — \(strokeDTOs.count) strokes, \(n) notes")
                return SyncResult(ok: true, message: n > 0 ? "Synced \(n) note\(n == 1 ? "" : "s")" : "Synced", noteCount: n)
            } else {
                let body = String(data: data, encoding: .utf8) ?? ""
                print("[Sync] HTTP \(code): \(body)")
                return SyncResult(ok: false, message: code == 401 ? "Not signed in" : "Sync failed (\(code))", noteCount: 0)
            }
        } catch {
            print("[Sync] error: \(error)")
            return SyncResult(ok: false, message: "Sync failed — check connection", noteCount: 0)
        }
    }

    // MARK: - DTO mapping

    private static func strokeDTO(_ s: SpatialStroke) -> StrokeDTO? {
        let pts = s.points
        guard pts.count >= 2 else { return nil }
        let stride = max(1, pts.count / 200)
        var points: [[Float]] = []
        var i = 0
        while i < pts.count { points.append([pts[i].position.x, pts[i].position.y, pts[i].position.z]); i += stride }
        if let last = pts.last { points.append([last.position.x, last.position.y, last.position.z]) }

        let bb = s.boundingBox
        return StrokeDTO(
            id: s.id.uuidString,
            spaceId: s.spaceID,
            folderId: s.folderID?.uuidString,
            geometry: Geometry(points: points, centroid: [bb.center.x, bb.center.y, bb.center.z],
                               bbox: BBox(min: [bb.min.x, bb.min.y, bb.min.z], max: [bb.max.x, bb.max.y, bb.max.z])),
            color: s.color.rawValue,
            thickness: s.thickness
        )
    }

    private static let deviceIdKey = "com.whiteboard.deviceId"
    static var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey) { return existing }
        #if canImport(UIKit)
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #else
        let id = UUID().uuidString
        #endif
        UserDefaults.standard.set(id, forKey: deviceIdKey)
        return id
    }
}

// MARK: - Wire format (matches infra/lambdas/ingest/index.mjs)

private struct SyncPayload: Encodable {
    let deviceId: String
    let spaces: [SpaceDTO]
    let folders: [FolderDTO]
    let strokes: [StrokeDTO]
}
private struct SpaceDTO: Encodable { let id: String; let name: String; let colorHex: String }
private struct FolderDTO: Encodable { let id: String; let spaceId: String; let name: String }
private struct StrokeDTO: Encodable {
    let id: String; let spaceId: String; let folderId: String?
    let geometry: Geometry; let color: String; let thickness: Float
}
private struct Geometry: Encodable { let points: [[Float]]; let centroid: [Float]; let bbox: BBox }
private struct BBox: Encodable { let min: [Float]; let max: [Float] }
private struct SyncAck: Decodable { let accepted: Int; let noteClusters: Int; let enqueued: Int? }
