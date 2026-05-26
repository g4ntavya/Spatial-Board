// Models.swift
// WhiteBoARd - Spatial AR Notetaking
// Data models with SwiftData for persistence

import Foundation
import SwiftData
import simd
import RealityKit

// MARK: - Core Data Models

/// Represents a single point in a stroke with 3D world coordinates
struct StrokePoint: Codable, Hashable {
    var position: SIMD3<Float>
    var pressure: Float
    var timestamp: TimeInterval
    
    init(position: SIMD3<Float>, pressure: Float = 1.0, timestamp: TimeInterval = Date().timeIntervalSince1970) {
        self.position = position
        self.pressure = pressure
        self.timestamp = timestamp
    }
}

/// Bezier control points for smooth curve rendering
struct BezierSegment: Codable, Hashable {
    var startPoint: SIMD3<Float>
    var controlPoint1: SIMD3<Float>
    var controlPoint2: SIMD3<Float>
    var endPoint: SIMD3<Float>
}

/// Represents a complete stroke as a series of bezier curves
@Model
final class SpatialStroke {
    @Attribute(.unique) var id: UUID
    var points: [StrokePoint]
    var bezierSegments: [BezierSegment]
    var color: StrokeColor
    var thickness: Float
    var createdAt: Date
    var worldAnchorID: UUID?
    var isCompleted: Bool
    
    // Transform relative to world anchor
    var localTransformData: Data?
    
    // MARK: - Folder & Space
    
    /// Space this stroke belongs to. Defaults to "Default" for migration safety.
    var spaceID: String = "Default"
    
    /// Folder this stroke is stored inside (nil = free in world)
    var folderID: UUID?
    
    /// World-space centroid BEFORE this stroke was moved into a folder.
    /// Encoded as [x, y, z] floats in a Data blob for SwiftData compatibility.
    var previousPositionData: Data?
    
    /// World-space orientation BEFORE folder insertion (x,y,z,w quaternion).
    var previousOrientationData: Data?
    
    /// Uniform scale BEFORE folder insertion.
    var previousScale: Float = 1.0
    
    /// Full world transform BEFORE folder insertion for exact restoration.
    var previousWorldTransformData: Data?
    
    init(
        id: UUID = UUID(),
        points: [StrokePoint] = [],
        bezierSegments: [BezierSegment] = [],
        color: StrokeColor = .white,
        thickness: Float = 0.002,
        worldAnchorID: UUID? = nil,
        spaceID: String = "Default"
    ) {
        self.id = id
        self.points = points
        self.bezierSegments = bezierSegments
        self.color = color
        self.thickness = thickness
        self.createdAt = Date()
        self.worldAnchorID = worldAnchorID
        self.isCompleted = false
        self.spaceID = spaceID
    }
    
    var localTransform: simd_float4x4? {
        get {
            guard let data = localTransformData else { return nil }
            return try? JSONDecoder().decode(Matrix4x4Wrapper.self, from: data).matrix
        }
        set {
            if let matrix = newValue {
                localTransformData = try? JSONEncoder().encode(Matrix4x4Wrapper(matrix: matrix))
            } else {
                localTransformData = nil
            }
        }
    }
    
    /// Persisted centroid before folder insertion, or nil if not in a folder.
    var previousPosition: SIMD3<Float>? {
        get {
            guard let data = previousPositionData,
                  data.count == 12 else { return nil }
            return data.withUnsafeBytes { ptr in
                let f = ptr.bindMemory(to: Float.self)
                return SIMD3<Float>(f[0], f[1], f[2])
            }
        }
        set {
            if let v = newValue {
                var arr = [v.x, v.y, v.z]
                previousPositionData = Data(bytes: &arr, count: 12)
            } else {
                previousPositionData = nil
            }
        }
    }
    
    /// Persisted orientation before folder insertion, or nil if not available.
    var previousOrientation: simd_quatf? {
        get {
            guard let data = previousOrientationData, data.count == 16 else { return nil }
            return data.withUnsafeBytes { ptr in
                let f = ptr.bindMemory(to: Float.self)
                return simd_quatf(ix: f[0], iy: f[1], iz: f[2], r: f[3])
            }
        }
        set {
            if let q = newValue {
                var arr = [q.imag.x, q.imag.y, q.imag.z, q.real]
                previousOrientationData = Data(bytes: &arr, count: 16)
            } else {
                previousOrientationData = nil
            }
        }
    }
    
    /// Persisted full world transform before folder insertion.
    var previousWorldTransform: simd_float4x4? {
        get {
            guard let data = previousWorldTransformData else { return nil }
            return try? JSONDecoder().decode(Matrix4x4Wrapper.self, from: data).matrix
        }
        set {
            if let matrix = newValue {
                previousWorldTransformData = try? JSONEncoder().encode(Matrix4x4Wrapper(matrix: matrix))
            } else {
                previousWorldTransformData = nil
            }
        }
    }
    
    /// Bounding box in world coordinates
    var boundingBox: (min: SIMD3<Float>, max: SIMD3<Float>, center: SIMD3<Float>) {
        guard !points.isEmpty else { return (.zero, .zero, .zero) }
        var minP = points[0].position
        var maxP = points[0].position
        for p in points {
            minP.x = min(minP.x, p.position.x); minP.y = min(minP.y, p.position.y); minP.z = min(minP.z, p.position.z)
            maxP.x = max(maxP.x, p.position.x); maxP.y = max(maxP.y, p.position.y); maxP.z = max(maxP.z, p.position.z)
        }
        return (minP, maxP, (minP + maxP) / 2)
    }
}

/// Stroke color options
enum StrokeColor: String, Codable, CaseIterable {
    case white = "white"
    case blue = "blue"
    case green = "green"
    case yellow = "yellow"
    case red = "red"
    case purple = "purple"
    
    var rgbColor: SIMD3<Float> {
        switch self {
        case .white: return SIMD3<Float>(1.0, 1.0, 1.0)
        case .blue: return SIMD3<Float>(0.2, 0.5, 1.0)
        case .green: return SIMD3<Float>(0.2, 0.9, 0.4)
        case .yellow: return SIMD3<Float>(1.0, 0.9, 0.2)
        case .red: return SIMD3<Float>(1.0, 0.3, 0.3)
        case .purple: return SIMD3<Float>(0.7, 0.3, 1.0)
        }
    }
}

// MARK: - World Anchor Model

/// Persistent world anchor reference
@Model
final class PersistedWorldAnchor {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var lastAccessedAt: Date
    
    // Serialized anchor data for ARKit persistence
    var anchorData: Data?
    
    // Position hint for recovery
    var positionHintX: Float
    var positionHintY: Float
    var positionHintZ: Float
    
    init(id: UUID = UUID(), name: String = "Anchor", positionHint: SIMD3<Float> = .zero) {
        self.id = id
        self.name = name
        self.createdAt = Date()
        self.lastAccessedAt = Date()
        self.positionHintX = positionHint.x
        self.positionHintY = positionHint.y
        self.positionHintZ = positionHint.z
    }
    
    var positionHint: SIMD3<Float> {
        get { SIMD3<Float>(positionHintX, positionHintY, positionHintZ) }
        set {
            positionHintX = newValue.x
            positionHintY = newValue.y
            positionHintZ = newValue.z
        }
    }
}

// MARK: - Spatial Folder Model

/// 3D folder entity in AR space
@Model
final class SpatialFolder {
    @Attribute(.unique) var id: UUID
    var name: String
    var isOpen: Bool
    var createdAt: Date
    var worldAnchorID: UUID?
    
    // Local transform relative to anchor
    var localTransformData: Data?
    
    // Visual properties
    var colorHue: Float
    var scale: Float
    
    // Contained strokes (by ID reference)
    var containedStrokeIDs: [UUID]
    
    // MARK: - Space
    
    /// Space this folder belongs to. Defaults to "Default" for migration safety.
    var spaceID: String = "Default"
    
    init(
        id: UUID = UUID(),
        name: String = "New Folder",
        worldAnchorID: UUID? = nil,
        colorHue: Float = 0.6,
        spaceID: String = "Default"
    ) {
        self.id = id
        self.name = name
        self.isOpen = false
        self.createdAt = Date()
        self.worldAnchorID = worldAnchorID
        self.colorHue = colorHue
        self.scale = 1.0
        self.containedStrokeIDs = []
        self.spaceID = spaceID
    }
    
    var localTransform: simd_float4x4? {
        get {
            guard let data = localTransformData else { return nil }
            return try? JSONDecoder().decode(Matrix4x4Wrapper.self, from: data).matrix
        }
        set {
            if let matrix = newValue {
                localTransformData = try? JSONEncoder().encode(Matrix4x4Wrapper(matrix: matrix))
            } else {
                localTransformData = nil
            }
        }
    }
}

// MARK: - Handwriting Style Model

/// Stored character template for handwriting style matching
@Model
final class CharacterTemplate {
    @Attribute(.unique) var character: String
    var bezierSegments: [BezierSegment]
    var boundingBox: BoundingBox
    var createdAt: Date
    
    init(character: String, bezierSegments: [BezierSegment] = [], boundingBox: BoundingBox = .zero) {
        self.character = character
        self.bezierSegments = bezierSegments
        self.boundingBox = boundingBox
        self.createdAt = Date()
    }
}

struct BoundingBox: Codable, Hashable {
    var minX: Float
    var minY: Float
    var maxX: Float
    var maxY: Float
    
    static let zero = BoundingBox(minX: 0, minY: 0, maxX: 0, maxY: 0)
    
    var width: Float { maxX - minX }
    var height: Float { maxY - minY }
    var center: SIMD2<Float> { SIMD2<Float>((minX + maxX) / 2, (minY + maxY) / 2) }
}

// MARK: - Kon Glyph Sample Model

/// Source of a handwriting sample
enum GlyphSampleSource: String, Codable {
    case onboarding
    case arDrawing
}

/// A single captured instance of a character for Kon's learning
@Model
final class GlyphSample {
    @Attribute(.unique) var id: UUID
    var character: String
    var bezierSegments: [BezierSegment]
    var boundingBox: BoundingBox
    var velocityProfile: [Float]
    var pressureProfile: [Float]
    var source: GlyphSampleSource
    var createdAt: Date
    
    /// Indices in bezierSegments where a new stroke begins (for multi-stroke chars like "4", "=")
    /// e.g. [0, 5] means stroke 1 = segments[0..<5], stroke 2 = segments[5...]
    var strokeBreakIndices: [Int]
    
    init(
        character: String,
        bezierSegments: [BezierSegment],
        boundingBox: BoundingBox,
        velocityProfile: [Float] = [],
        pressureProfile: [Float] = [],
        source: GlyphSampleSource = .onboarding,
        strokeBreakIndices: [Int] = []
    ) {
        self.id = UUID()
        self.character = character.uppercased()
        self.bezierSegments = bezierSegments
        self.boundingBox = boundingBox
        self.velocityProfile = velocityProfile
        self.pressureProfile = pressureProfile
        self.source = source
        self.createdAt = Date()
        self.strokeBreakIndices = strokeBreakIndices
    }
}

// MARK: - Math Completion Model

/// Represents a math autocomplete suggestion
struct MathCompletion: Codable, Identifiable {
    let id: UUID
    let originalStrokeIDs: [UUID]
    let latexExpression: String
    let completionStrokes: [BezierSegment]
    let confidence: Float
    let timestamp: Date
    
    init(
        id: UUID = UUID(),
        originalStrokeIDs: [UUID],
        latexExpression: String,
        completionStrokes: [BezierSegment],
        confidence: Float
    ) {
        self.id = id
        self.originalStrokeIDs = originalStrokeIDs
        self.latexExpression = latexExpression
        self.completionStrokes = completionStrokes
        self.confidence = confidence
        self.timestamp = Date()
    }
}

// MARK: - Gesture State

/// Current gesture recognition state
enum GestureMode: String, Codable {
    case none
    case draw      // Single-hand pinch (index + thumb) — draws strokes
    case erase     // Open palm — erases strokes
    case resize    // Three-finger pinch (index + middle + thumb) — resizes selected content
    case select    // Two-hand pinch — freeform selection rectangle
    case kon       // Kon trigger (index + pinky up, middle + ring touching thumb)
    case fistMove  // Fist — moves selected content (bills to camera)
    case point     // Index finger pointing — interacts with folders/UI
}

/// Lifecycle of a spatial selection
enum SelectionState: Equatable {
    case idle       // No active selection
    case selecting  // Two-hand pinch active; rectangle is being drawn
    case selected   // Pinches released; strokes inside are highlighted
    case moving     // Fist detected; content follows hand in 3D
    case resizing   // Three-finger pinch; content scales from centroid
}

/// Kon processing state lifecycle
enum KonState: Equatable {
    case idle      // Not active
    case holding   // Gesture detected, counting down 1 second
    case capturing // Taking AR snapshot
    case thinking  // Gemini API call in progress
    case writing   // Drawing the answer in 3D AR space
    case answered  // Final answer placed (will auto-idle)
    case error     // An error occurred
}

/// Hand landmark positions from Vision framework
struct HandLandmarks: Codable {
    var wrist: SIMD3<Float>?
    var thumbTip: SIMD3<Float>?
    var thumbIP: SIMD3<Float>?
    var thumbMP: SIMD3<Float>?
    var thumbCMC: SIMD3<Float>?
    var indexTip: SIMD3<Float>?
    var indexDIP: SIMD3<Float>?
    var indexPIP: SIMD3<Float>?
    var indexMCP: SIMD3<Float>?
    var middleTip: SIMD3<Float>?
    var middleDIP: SIMD3<Float>?
    var middlePIP: SIMD3<Float>?
    var middleMCP: SIMD3<Float>?
    var ringTip: SIMD3<Float>?
    var ringDIP: SIMD3<Float>?
    var ringPIP: SIMD3<Float>?
    var ringMCP: SIMD3<Float>?
    var littleTip: SIMD3<Float>?
    var littleDIP: SIMD3<Float>?
    var littlePIP: SIMD3<Float>?
    var littleMCP: SIMD3<Float>?
    
    /// Calculate pinch point between thumb and index
    var pinchPoint: SIMD3<Float>? {
        guard let thumb = thumbTip, let index = indexTip else { return nil }
        return (thumb + index) / 2.0
    }
    
    /// Distance between thumb and index tips
    var pinchDistance: Float? {
        guard let thumb = thumbTip, let index = indexTip else { return nil }
        return simd_length(thumb - index)
    }
}

// MARK: - Helper Types

/// Wrapper for encoding/decoding simd_float4x4
struct Matrix4x4Wrapper: Codable {
    let columns: [[Float]]
    
    init(matrix: simd_float4x4) {
        columns = [
            [matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w],
            [matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w],
            [matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w],
            [matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w]
        ]
    }
    
    var matrix: simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(columns[0][0], columns[0][1], columns[0][2], columns[0][3]),
            SIMD4<Float>(columns[1][0], columns[1][1], columns[1][2], columns[1][3]),
            SIMD4<Float>(columns[2][0], columns[2][1], columns[2][2], columns[2][3]),
            SIMD4<Float>(columns[3][0], columns[3][1], columns[3][2], columns[3][3])
        )
    }
}

// MARK: - Space Model

/// A named spatial workspace (like a Focus Mode).
/// All strokes and folders are tagged with a spaceID.
@Model
final class Space {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Hex color string for the UI pill accent, e.g. "#FF6B6B"
    var colorHex: String
    var createdAt: Date
    
    init(id: UUID = UUID(), name: String, colorHex: String = "#4A90D9") {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.createdAt = Date()
    }
}

// MARK: - App State

/// Observable app state for SwiftUI
@Observable
final class AppState {
    private static let thicknessKey = "com.whiteboard.strokeThickness"
    private static let colorKey = "com.whiteboard.strokeColor"
    
    var currentGestureMode: GestureMode = .none
    var selectedFolderID: UUID?
    var currentStrokeColor: StrokeColor = .white {
        didSet { UserDefaults.standard.set(currentStrokeColor.rawValue, forKey: Self.colorKey) }
    }
    var currentStrokeThickness: Float = 0.002 {
        didSet { UserDefaults.standard.set(currentStrokeThickness, forKey: Self.thicknessKey) }
    }
    var isDrawing: Bool = false
    var isOnboardingComplete: Bool = false
    var arSessionState: ARSessionState = .initializing
    var handLandmarks: HandLandmarks?
    var lastStrokeTime: Date?
    
    init() {
        // Restore persisted pen settings
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.thicknessKey) != nil {
            currentStrokeThickness = defaults.float(forKey: Self.thicknessKey)
        }
        if let savedColor = defaults.string(forKey: Self.colorKey),
           let color = StrokeColor(rawValue: savedColor) {
            currentStrokeColor = color
        }
    }
    
    // Kon keyboard input state
    var showKonKeyboard: Bool = false
    var pendingKonText: String?
    
    // Kon processing state
    var konState: KonState = .idle
    var konAnswerText: String = ""
    var konStatusMessage: String = "" // Minimal HUD messages (Thinking..., Solving...)
    var konHoldProgress: Float = 0  // 0.0 to 1.0 during hold
    var folderTransitionStatus: String = "" // Opening..., Closing...
    
    // Convenience computed properties for backward compatibility
    var showKonAnswer: Bool {
        // Only show the big popup/bubble for Error states now. 
        // Success answers are written directly in the air.
        return konState == .error
    }
    var konIsProcessing: Bool {
        switch konState {
        case .capturing, .thinking:
            return true
        default:
            return false
        }
    }
    
    // MARK: - Selection State
    
    /// Current lifecycle phase of the spatial selection
    var selectionState: SelectionState = .idle
    
    /// IDs of strokes currently selected
    var selectedStrokeIDs: Set<UUID> = []
    
    /// IDs of folders currently selected
    var selectedFolderIDs: Set<UUID> = []
    
    /// The two 3D corners of the live selection rectangle (set while .selecting)
    /// topLeft  = left-hand pinch point
    /// bottomRight = right-hand pinch point
    var selectionCornerLeft: SIMD3<Float>?   // Top-left corner (left hand)
    var selectionCornerRight: SIMD3<Float>?  // Bottom-right corner (right hand)

    /// Screen-space corners for the selection overlay (computed from Vision points)
    var selectionCornerLeftScreen: CGPoint?
    var selectionCornerRightScreen: CGPoint?

    // MARK: - Move Debug Overlay

    var debugMoveOverlayEnabled: Bool = true
    var debugPalmScreenRaw: CGPoint?
    var debugPalmScreenPlane: CGPoint?
    var debugPalmScreenDepth: CGPoint?
    
    // Actions - closures set by ARCanvasView coordinator
    var undoAction: (() -> Void)?
    var clearAllAction: (() -> Void)?
    
    // MARK: - Spaces State
    
    /// ID string of the currently active Space (matches Space.id.uuidString or "Default")
    var activeSpaceID: String = "Default"
    /// Show the spaces picker sheet
    var showSpacePicker: Bool = false
    /// True while the fade-out/fade-in transition is running
    var isSpaceTransitioning: Bool = false
    
    // MARK: - Folder Sheet State
    
    /// Show folder naming sheet before creating a folder
    var showFolderSheet: Bool = false
    /// Name typed into the folder creation sheet
    var pendingFolderName: String = "New Folder"
    
    // MARK: - Actions
    
    func undo() {
        undoAction?()
    }
    
    func clearAll() {
        clearAllAction?()
    }
}

enum ARSessionState: String {
    case initializing
    case ready
    case tracking
    case limited
    case notAvailable
    case failed
}

// MARK: - Generative Cursive ML Model

/// Raw spatial trajectory dataset stored locally for CoreML generative training
@Model
final class CursiveTrainingSample {
    @Attribute(.unique) var id: UUID
    var recognizedText: String
    var capturedAt: Date
    
    // We store the raw spatial geometry points so PyTorch/CoreML can learn the velocity & curves
    var strokes: [SpatialStroke]
    
    init(id: UUID = UUID(), recognizedText: String, strokes: [SpatialStroke]) {
        self.id = id
        self.recognizedText = recognizedText
        self.strokes = strokes
        self.capturedAt = Date()
    }
}

/// Codable version of CursiveTrainingSample for file-system persistence (Files app)
struct CursiveExportData: Codable {
    let id: UUID
    let text: String
    let timestamp: Date
    let strokes: [[StrokePoint]]
    
    init(from sample: CursiveTrainingSample) {
        self.id = sample.id
        self.text = sample.recognizedText
        self.timestamp = sample.capturedAt
        self.strokes = sample.strokes.map { $0.points }
    }
}

// MARK: - SwiftData Schema

/// Schema configuration for SwiftData
enum WhiteBoARdSchema {
    static var schema: Schema {
        Schema([
            SpatialStroke.self,
            PersistedWorldAnchor.self,
            SpatialFolder.self,
            CharacterTemplate.self,
            GlyphSample.self,
            CursiveTrainingSample.self,
            Space.self
        ])
    }
    
    static var modelConfiguration: ModelConfiguration {
        ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )
    }
}
