// SyncActivityAttributes.swift
// WhiteBoARd - Spatial AR Notetaking
//
// Shared between the app and the widget extension — add this file's Target
// Membership to BOTH "WhiteBoARd" and "SpatialBoardWidgets" in Xcode.

import Foundation
import ActivityKit

struct SyncActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var phase: Phase
        var uploaded: Int
        var total: Int
        var message: String
    }

    enum Phase: String, Codable, Hashable {
        case uploading
        case processing
        case done
        case failed
    }

    /// When this sync started (for the Live Activity timer).
    var startedAt: Date
}
