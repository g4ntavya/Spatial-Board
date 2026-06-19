// SyncService.swift
// WhiteBoARd - Spatial AR Notetaking
//
// Pushes the local SwiftData store (spaces, folders, strokes) to the AWS web
// companion. Triggered when the app goes to the background ("after a session /
// exiting app"), per docs/AWS_PLAN.md §5. Strokes are UUID-keyed, so the backend
// upserts idempotently — re-sending the whole store every time is safe and the
// ingest Lambda only re-processes notes whose content actually changed.

import Foundation
import SwiftData
import simd
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class SyncService {
    static let shared = SyncService()
    private init() {}

    private var endpoint: URL?
    private var token: String?
    private var isSyncing = false

    var isConfigured: Bool { endpoint != nil && token != nil }

    /// Wire up from .env values (see WhiteBoARdApp.setupServices).
    func configure(url: String, token: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        self.endpoint = URL(string: trimmed)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[Sync] configured → \(trimmed)")
    }

    /// Fire-and-forget sync, wrapped in a background task so the request can
    /// finish after the app is backgrounded.
    func syncInBackground(context: ModelContext) {
        guard isConfigured, !isSyncing else { return }
        #if canImport(UIKit)
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "SpatialBoardSync") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        Task {
            await self.sync(context: context)
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
        }
        #else
        Task { await self.sync(context: context) }
        #endif
    }

    func sync(context: ModelContext) async {
        guard let endpoint, let token, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let spaces = try context.fetch(FetchDescriptor<Space>())
            let folders = try context.fetch(FetchDescriptor<SpatialFolder>())
            let strokes = try context.fetch(FetchDescriptor<SpatialStroke>())

            let payload = SyncPayload(
                deviceId: Self.deviceId,
                spaces: spaces.map { SpaceDTO(id: $0.id.uuidString, name: $0.name, colorHex: $0.colorHex) },
                folders: folders.map { FolderDTO(id: $0.id.uuidString, spaceId: $0.spaceID, name: $0.name) },
                strokes: strokes.compactMap(Self.strokeDTO)
            )

            guard !payload.strokes.isEmpty else {
                print("[Sync] nothing to send")
                return
            }

            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(token, forHTTPHeaderField: "x-api-key")
            // Attach our auth token so the backend keys this data to the
            // signed-in account (same user the web app logs in as).
            if let authToken = AuthService.shared.currentToken() {
                req.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            }
            req.httpBody = try JSONEncoder().encode(payload)
            req.timeoutInterval = 25

            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            print("[Sync] \(code) \(payload.strokes.count) strokes → \(body)")
        } catch {
            print("[Sync] failed: \(error)")
        }
    }

    // MARK: - DTO mapping

    private static func strokeDTO(_ s: SpatialStroke) -> StrokeDTO? {
        let pts = s.points
        guard pts.count >= 2 else { return nil }
        // Cap points per stroke to keep the payload light; the shape stays legible.
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
            geometry: Geometry(
                points: points,
                centroid: [bb.center.x, bb.center.y, bb.center.z],
                bbox: BBox(min: [bb.min.x, bb.min.y, bb.min.z], max: [bb.max.x, bb.max.y, bb.max.z])
            ),
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

private struct SpaceDTO: Encodable {
    let id: String
    let name: String
    let colorHex: String
}

private struct FolderDTO: Encodable {
    let id: String
    let spaceId: String
    let name: String
}

private struct StrokeDTO: Encodable {
    let id: String
    let spaceId: String
    let folderId: String?
    let geometry: Geometry
    let color: String
    let thickness: Float
}

private struct Geometry: Encodable {
    let points: [[Float]]
    let centroid: [Float]
    let bbox: BBox
}

private struct BBox: Encodable {
    let min: [Float]
    let max: [Float]
}
