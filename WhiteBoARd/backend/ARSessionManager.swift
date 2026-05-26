// ARSessionManager.swift
// WhiteBoARd - Spatial AR Notetaking
// Centralized AR session management with LiDAR and WorldAnchor support

import Foundation
import ARKit
import RealityKit
import Combine
import SwiftData

/// Centralized AR session manager handling all ARKit interactions
@MainActor
@Observable
final class ARSessionManager: NSObject {
    
    // MARK: - Properties
    
    /// The AR session instance
    private(set) var session: ARSession
    
    /// RealityKit AR view reference (set by ARCanvasView)
    weak var arView: ARView?
    
    /// Current session state
    private(set) var state: ARSessionState = .initializing
    
    /// Active world anchors mapped by ID
    private(set) var worldAnchors: [UUID: ARAnchor] = [:]
    
    /// LiDAR point cloud data (updated per frame)
    private(set) var pointCloud: ARPointCloud?
    
    /// Current camera transform
    private(set) var cameraTransform: simd_float4x4 = matrix_identity_float4x4
    
    /// Depth data from LiDAR
    private(set) var depthMap: CVPixelBuffer?
    
    /// Whether LiDAR is available
    private(set) var isLiDARAvailable: Bool = false
    
    /// Cancellables for Combine subscriptions
    private var cancellables = Set<AnyCancellable>()
    
    /// SwiftData model context for persistence
    private var modelContext: ModelContext?
    
    /// Delegate for AR events
    weak var delegate: ARSessionManagerDelegate?
    
    
    // MARK: - Singleton
    
    static let shared = ARSessionManager()
    
    // MARK: - Initialization
    
    private override init() {
        self.session = ARSession()
        super.init()
        
        #if !targetEnvironment(simulator)
        self.session.delegate = self
        checkLiDARAvailability()
        #else
        // Simulator mock
        self.isLiDARAvailable = true
        self.state = .ready
        #endif
    }
    
    // MARK: - Configuration
    
    func configure(with modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    func setARView(_ arView: ARView) {
        self.arView = arView
        
        #if !targetEnvironment(simulator)
        arView.session = session
        #endif
    }
    
    // MARK: - Session Lifecycle
    
    func startSession() {
        #if !targetEnvironment(simulator)
        runDefaultConfiguration(reset: false)
        state = .initializing
        
        // Load persisted world anchors
        loadPersistedAnchors()
        #else
        // Simulator: mock ready state
        state = .ready
        simulateMockData()
        #endif
    }
    
    func pauseSession() {
        #if !targetEnvironment(simulator)
        session.pause()
        #endif
        state = .limited
    }
    
    func resetSession() {
        #if !targetEnvironment(simulator)
        runDefaultConfiguration(reset: true)
        #endif
        
        worldAnchors.removeAll()
        state = .initializing
    }
    
    #if !targetEnvironment(simulator)
    @discardableResult
    private func runDefaultConfiguration(reset: Bool) -> Bool {
        guard ARWorldTrackingConfiguration.isSupported else { return false }
        let configuration = ARWorldTrackingConfiguration()
        
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .automatic
        
        session.run(configuration, options: reset ? [.resetTracking, .removeExistingAnchors] : [])
        return true
    }
    #endif
    
    // MARK: - LiDAR
    
    private func checkLiDARAvailability() {
        #if !targetEnvironment(simulator)
        isLiDARAvailable = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        #endif
    }
    
    // MARK: - World Anchors
    
    /// Create a new world anchor at the specified position
    func createWorldAnchor(at position: SIMD3<Float>, name: String = "Anchor") async -> PersistedWorldAnchor? {
        let transform = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(position.x, position.y, position.z, 1)
        )
        
        #if !targetEnvironment(simulator)
        let anchor = ARAnchor(name: name, transform: transform)
        session.add(anchor: anchor)
        worldAnchors[anchor.identifier] = anchor
        
        // Create persisted anchor
        let persistedAnchor = PersistedWorldAnchor(
            id: anchor.identifier,
            name: name,
            positionHint: position
        )
        
        // Save to SwiftData
        modelContext?.insert(persistedAnchor)
        try? modelContext?.save()
        
        return persistedAnchor
        #else
        // Simulator mock
        let mockID = UUID()
        let persistedAnchor = PersistedWorldAnchor(
            id: mockID,
            name: name,
            positionHint: position
        )
        modelContext?.insert(persistedAnchor)
        try? modelContext?.save()
        return persistedAnchor
        #endif
    }
    
    /// Remove a world anchor
    func removeWorldAnchor(id: UUID) {
        #if !targetEnvironment(simulator)
        if let anchor = worldAnchors[id] {
            session.remove(anchor: anchor)
        }
        #endif
        worldAnchors.removeValue(forKey: id)
        
        // Remove from persistence
        if let context = modelContext {
            let descriptor = FetchDescriptor<PersistedWorldAnchor>(
                predicate: #Predicate { $0.id == id }
            )
            if let anchors = try? context.fetch(descriptor), let anchor = anchors.first {
                context.delete(anchor)
                try? context.save()
            }
        }
    }
    
    /// Load persisted anchors from SwiftData
    private func loadPersistedAnchors() {
        guard let context = modelContext else { return }
        
        let descriptor = FetchDescriptor<PersistedWorldAnchor>()
        guard let persistedAnchors = try? context.fetch(descriptor) else { return }
        
        for persisted in persistedAnchors {
            #if !targetEnvironment(simulator)
            // Create AR anchor from persisted data
            let transform = simd_float4x4(
                SIMD4<Float>(1, 0, 0, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(0, 0, 1, 0),
                SIMD4<Float>(persisted.positionHint.x, persisted.positionHint.y, persisted.positionHint.z, 1)
            )
            
            let anchor = ARAnchor(name: persisted.name, transform: transform)
            session.add(anchor: anchor)
            worldAnchors[persisted.id] = anchor
            #endif
            
            // Update last accessed
            persisted.lastAccessedAt = Date()
        }
        
        try? context.save()
    }
    
    // MARK: - Drawing Plane State
    
    /// The current drawing plane (set when user starts drawing)
    private(set) var drawingPlaneNormal: SIMD3<Float> = SIMD3<Float>(0, 0, -1)
    private(set) var drawingPlaneCenter: SIMD3<Float> = SIMD3<Float>(0, 1.5, -0.5)
    private(set) var drawingPlaneDistance: Float = 0.5  // 50cm from camera
    
    /// Default distance fallback
    private let defaultDrawingPlaneDistance: Float = 0.5
    
    /// Valid depth range for LiDAR sampling
    private let minValidDepth: Float = 0.2  // 20cm minimum
    private let maxValidDepth: Float = 5.0  // 5m maximum
    
    /// Track whether we're currently drawing
    private var isCurrentlyDrawing: Bool = false
    
    /// Pre-pinch hand depth tracking - continuously updated when hand is detected (not drawing)
    private var lastTrackedHandDepth: Float? = nil
    
    /// Running average for smoother depth tracking (reduces noise)
    private var depthTrackingBuffer: [Float] = []
    private let depthTrackingBufferSize: Int = 3  // Reduced from 5 for faster response
    
    /// Offset to add to wrist/MCP depth to approximate fingertip depth
    /// Wrist is ~8-12cm closer to camera than fingertips; we add this to push the plane forward
    /// Positive = further from camera (towards where fingertips actually are)
    private let wristToFingertipOffset: Float = 0.005  // Almost 0 offset to anchor cleanly under optical pinch node
    
    /// PERFORMANCE: Throttle depth tracking updates
    private var lastDepthTrackingTime: TimeInterval = 0
    private let depthTrackingInterval: TimeInterval = 1.0 / 15.0  // 15fps max for depth tracking
    
    /// Update hand depth tracking using stable joints (wrist, MCP) - called by GestureRecognizer
    /// These joints are more reliably detected by LiDAR than fingertips
    /// PERFORMANCE: Throttled to reduce CPU load
    func updateHandDepthTracking(stableJoints: [CGPoint]) {
        #if !targetEnvironment(simulator)
        // Don't update depth while drawing - plane is locked
        guard !isCurrentlyDrawing else { return }
        
        // PERFORMANCE: Throttle depth tracking to 15fps
        let now = CACurrentMediaTime()
        guard (now - lastDepthTrackingTime) >= depthTrackingInterval else { return }
        lastDepthTrackingTime = now
        
        guard let arView = arView,
              let frame = session.currentFrame,
              let depthData = frame.sceneDepth?.depthMap else { return }
        
        let viewSize = arView.bounds.size
        let orientation = getCurrentInterfaceOrientation()
        let displayTransform = frame.displayTransform(for: orientation, viewportSize: viewSize)
        
        // PERFORMANCE: Only sample 2 joints (wrist + one MCP) instead of all 5
        let jointsToSample = stableJoints.prefix(2)
        var validDepths: [Float] = []
        
        // Lock depth buffer once for all samples
        CVPixelBufferLockBaseAddress(depthData, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthData, .readOnly) }
        
        let depthWidth = CVPixelBufferGetWidth(depthData)
        let depthHeight = CVPixelBufferGetHeight(depthData)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthData)
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthData) else { return }
        
        // Sample depth at each stable joint using raw camera sensor layouts
        for normalizedPoint in jointsToSample {
            // Vision gives origin at bottom-left, CVPixelBuffer is origin top-left.
            // Both map perfectly 1:1 against the raw iOS ARFrame sensor bounds natively.
            let clampedX = max(0, min(1, Float(normalizedPoint.x)))
            let clampedY = max(0, min(1, Float(1.0 - normalizedPoint.y)))
            
            let pixelX = min(depthWidth - 1, max(0, Int(clampedX * Float(depthWidth - 1))))
            let pixelY = min(depthHeight - 1, max(0, Int(clampedY * Float(depthHeight - 1))))
            
            let offset = pixelY * bytesPerRow + pixelX * MemoryLayout<Float32>.size
            let depth = baseAddress.advanced(by: offset).assumingMemoryBound(to: Float32.self).pointee
            
            if depth > minValidDepth && depth < maxValidDepth && depth.isFinite {
                validDepths.append(depth)
            }
        }
        
        guard !validDepths.isEmpty else { return }
        
        // Use minimum depth (hand is closest thing in its region)
        let minDepth = validDepths.min()!
        
        // Simple exponential smoothing instead of buffer
        if let lastDepth = lastTrackedHandDepth {
            lastTrackedHandDepth = lastDepth * 0.7 + minDepth * 0.3
        } else {
            lastTrackedHandDepth = minDepth
        }
        #endif
    }
    
    /// Initialize/update the drawing plane based on current camera pose
    func initializeDrawingPlane() {
        #if !targetEnvironment(simulator)
        guard let frame = session.currentFrame else { return }
        
        let cameraTransform = frame.camera.transform
        
        // Camera forward is -Z in camera space
        let cameraForward = -SIMD3<Float>(
            cameraTransform.columns.2.x,
            cameraTransform.columns.2.y,
            cameraTransform.columns.2.z
        )
        
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        
        drawingPlaneNormal = simd_normalize(cameraForward)
        drawingPlaneCenter = cameraPosition + drawingPlaneNormal * drawingPlaneDistance
        #else
        drawingPlaneNormal = SIMD3<Float>(0, 0, -1)
        drawingPlaneCenter = SIMD3<Float>(0, 1.5, -0.5)
        #endif
    }
    
    // MARK: - Raycasting
    
    /// Perform raycast from screen point to 3D world coordinate - projects onto drawing plane
    func raycast(from screenPoint: CGPoint, allowedTargets: ARRaycastQuery.Target = .estimatedPlane) -> SIMD3<Float>? {
        #if !targetEnvironment(simulator)
        guard let arView = arView,
              let frame = session.currentFrame else { return nil }
        
        // Project screen point onto the drawing plane (for 2D strokes)
        return projectScreenPointToDrawingPlane(screenPoint: screenPoint, frame: frame)
        #else
        return simulatorRaycast(from: screenPoint)
        #endif
    }
    
    /// Project a screen point onto the drawing plane using ARView's ray casting
    #if !targetEnvironment(simulator)
    func projectScreenPointToDrawingPlane(screenPoint: CGPoint, frame: ARFrame) -> SIMD3<Float>? {
        guard let arView = arView else { return nil }
        
        // Use RealityKit's ray casting which handles all coordinate transforms correctly
        // This creates a ray from the camera through the screen point
        guard let rayResult = arView.ray(through: screenPoint) else { return nil }
        
        let rayOrigin = rayResult.origin
        let rayDirection = rayResult.direction
        
        // Ray-plane intersection
        // Plane equation: dot(P - planeCenter, planeNormal) = 0
        // Ray: P = rayOrigin + t * rayDirection
        // Solving: t = dot(planeCenter - rayOrigin, planeNormal) / dot(rayDirection, planeNormal)
        
        let denom = simd_dot(rayDirection, drawingPlaneNormal)
        
        // Avoid division by zero (ray parallel to plane)
        if abs(denom) < 0.001 {
            return nil
        }
        
        let t = simd_dot(drawingPlaneCenter - rayOrigin, drawingPlaneNormal) / denom
        
        // Only accept intersections in front of camera
        if t < 0 {
            return nil
        }
        
        let intersectionPoint = rayOrigin + t * rayDirection
        return intersectionPoint
    }
    #endif
    
    /// Raycast using LiDAR depth map directly
    func raycastUsingDepth(from screenPoint: CGPoint) -> SIMD3<Float>? {
        #if !targetEnvironment(simulator)
        guard let arView = arView,
              let frame = session.currentFrame,
              let depthData = frame.sceneDepth?.depthMap else { return nil }
        
        let viewSize = arView.bounds.size
        let normalizedX = Float(screenPoint.x / viewSize.width)
        let normalizedY = Float(screenPoint.y / viewSize.height)
        
        // Sample depth at normalized coordinates
        let width = CVPixelBufferGetWidth(depthData)
        let height = CVPixelBufferGetHeight(depthData)
        
        let pixelX = min(max(Int(normalizedX * Float(width)), 0), width - 1)
        let pixelY = min(max(Int(normalizedY * Float(height)), 0), height - 1)
        
        CVPixelBufferLockBaseAddress(depthData, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthData, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthData) else { return nil }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthData)
        let offset = pixelY * bytesPerRow + pixelX * MemoryLayout<Float32>.size
        let depth = baseAddress.advanced(by: offset).assumingMemoryBound(to: Float32.self).pointee
        
        guard depth > 0.1 && depth < 5.0 else { return nil } // Valid depth range
        
        // Convert screen point + depth to world coordinate
        let camera = frame.camera
        let intrinsics = camera.intrinsics
        let imageResolution = camera.imageResolution
        
        // Map screen coordinates to image coordinates
        let imageX = Float(screenPoint.x / viewSize.width) * Float(imageResolution.width)
        let imageY = Float(screenPoint.y / viewSize.height) * Float(imageResolution.height)
        
        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        let cx = intrinsics[2][0]
        let cy = intrinsics[2][1]
        
        // Unproject to camera space
        let x = (imageX - cx) * depth / fx
        let y = -(imageY - cy) * depth / fy  // Flip Y
        let z = -depth
        
        let cameraSpacePoint = SIMD4<Float>(x, y, z, 1)
        let worldSpacePoint = camera.transform * cameraSpacePoint
        
        return SIMD3<Float>(worldSpacePoint.x, worldSpacePoint.y, worldSpacePoint.z)
        #else
        return nil
        #endif
    }
    
    /// Raycast from 2D hand landmark (Vision normalized coords) to 3D world position on drawing plane
    /// Pass isDrawing=true when actively drawing to handle stroke start/end
    func raycastHandLandmark(normalizedPoint: CGPoint, estimatedDepth: Float = 0.5, isDrawing: Bool = false) -> SIMD3<Float>? {
        #if !targetEnvironment(simulator)
        guard let arView = arView,
              let frame = session.currentFrame else { return nil }
        
        let viewSize = arView.bounds.size
        
        // Get the current interface orientation dynamically
        let interfaceOrientation = getCurrentInterfaceOrientation()
        
        // Use ARKit's displayTransform which handles all orientation complexity
        // This transforms from normalized image coordinates to normalized view coordinates
        let displayTransform = frame.displayTransform(for: interfaceOrientation, viewportSize: viewSize)
        
        // Vision coordinates: origin bottom-left, Y up (normalized 0-1)
        // We need to flip Y to match image coordinates (origin top-left, Y down)
        let normalizedImagePoint = CGPoint(x: normalizedPoint.x, y: 1.0 - normalizedPoint.y)
        
        // Apply the display transform
        let transformedPoint = normalizedImagePoint.applying(displayTransform)
        
        // transformedPoint is now in normalized view coordinates (0-1)
        // Convert to actual screen coordinates
        let screenX = transformedPoint.x * viewSize.width
        let screenY = transformedPoint.y * viewSize.height
        let screenPoint = CGPoint(x: screenX, y: screenY)
        
        // Note: Pre-pinch depth tracking is now handled by updateHandDepthTracking() 
        // which is called from GestureRecognizer with stable joint positions (wrist, MCP)
        
        // Handle stroke start: lock plane at pre-tracked hand depth
        // IMPORTANT: Return nil for the first point to avoid depth discontinuity
        // The first point would be projected onto the OLD plane before we update it
        if isDrawing && !isCurrentlyDrawing {
            lockPlaneAtHandDepth()
            isCurrentlyDrawing = true
            // Skip this first point - it would have wrong depth
            // The next frame will have a properly positioned point
            print("[ARSession] ⏭️ Skipping first point (plane just locked)")
            return nil
        }
        
        // Handle stroke end: reset to default depth
        if !isDrawing && isCurrentlyDrawing {
            handleStrokeEnd()
        }
        
        // Update drawing state
        isCurrentlyDrawing = isDrawing
        
        // Project onto the drawing plane for consistent 2D strokes
        if let planePoint = projectScreenPointToDrawingPlane(screenPoint: screenPoint, frame: frame) {
            return planePoint
        }
        
        // Fallback: project at fixed depth from camera
        return projectToWorld(screenPoint: screenPoint, depth: drawingPlaneDistance, frame: frame, viewSize: viewSize)
        #else
        // Simulator mock - project onto simulated drawing plane
        let screenX = Float(normalizedPoint.x) - 0.5
        let screenY = Float(normalizedPoint.y) - 0.5
        
        // Project onto the drawing plane
        return drawingPlaneCenter + SIMD3<Float>(screenX * 0.5, screenY * 0.5, 0)
        #endif
    }
    
    /// Raycast hand landmark to free 3D world position using scene depth when available.
    /// Used by move gestures where forward/backward hand motion should affect Z.
    func raycastHandLandmarkDepthAware(normalizedPoint: CGPoint, estimatedDepth: Float = 0.6) -> SIMD3<Float>? {
        #if !targetEnvironment(simulator)
        guard let arView = arView,
              let frame = session.currentFrame else { return nil }
        
        let viewSize = arView.bounds.size
        let interfaceOrientation = getCurrentInterfaceOrientation()
        let displayTransform = frame.displayTransform(for: interfaceOrientation, viewportSize: viewSize)
        
        let normalizedImagePoint = CGPoint(x: normalizedPoint.x, y: 1.0 - normalizedPoint.y)
        let transformedPoint = normalizedImagePoint.applying(displayTransform)
        let screenPoint = CGPoint(x: transformedPoint.x * viewSize.width, y: transformedPoint.y * viewSize.height)
        
        // Use the same robust depth sampling path used elsewhere (with orientation-aware transforms),
        // then unproject with camera intrinsics. This preserves vertical hand motion better.
        if let sampledDepth = sampleDepthAtScreenPoint(screenPoint),
           sampledDepth.isFinite && sampledDepth > 0.08 {
            return projectToWorld(screenPoint: screenPoint, depth: sampledDepth, frame: frame, viewSize: viewSize)
        }
        
        return projectToWorld(screenPoint: screenPoint, depth: estimatedDepth, frame: frame, viewSize: viewSize)
        #else
        let screenX = Float(normalizedPoint.x) - 0.5
        let screenY = Float(normalizedPoint.y) - 0.5
        return drawingPlaneCenter + SIMD3<Float>(screenX * 0.6, screenY * 0.6, -estimatedDepth)
        #endif
    }
    
    /// Track hand depth continuously when NOT drawing (pre-pinch prediction)
    /// Lock plane at the pre-tracked hand depth when pinch starts
    #if !targetEnvironment(simulator)
    private func lockPlaneAtHandDepth() {
        if let trackedDepth = lastTrackedHandDepth {
            // Use the smoothed depth we've been tracking before pinch
            // Add offset because wrist/MCP is closer to camera than fingertips
            let adjustedDepth = trackedDepth + wristToFingertipOffset
            drawingPlaneDistance = adjustedDepth
            print("[ARSession] 🎯 Plane LOCKED at pre-tracked depth: \(String(format: "%.3f", trackedDepth))m + \(String(format: "%.2f", wristToFingertipOffset))m offset = \(String(format: "%.3f", adjustedDepth))m")
        } else {
            // No tracked depth, use default
            drawingPlaneDistance = defaultDrawingPlaneDistance
            print("[ARSession] ⚠️ No pre-tracked depth, using default: \(defaultDrawingPlaneDistance)m")
        }
        
        // Initialize the plane with this locked depth
        initializeDrawingPlane()
    }
    
    /// Sample depth at a specific screen point using LiDAR with proper coordinate transforms
    func sampleDepthAtScreenPoint(_ screenPoint: CGPoint) -> Float? {
        guard let arView = arView,
              let frame = session.currentFrame,
              let depthData = frame.sceneDepth?.depthMap else { return nil }
        
        let viewSize = arView.bounds.size
        let orientation = getCurrentInterfaceOrientation()
        
        // Get depth buffer dimensions
        let depthWidth = CVPixelBufferGetWidth(depthData)
        let depthHeight = CVPixelBufferGetHeight(depthData)
        
        // Convert screen point to normalized view coordinates (0-1)
        let normalizedViewX = screenPoint.x / viewSize.width
        let normalizedViewY = screenPoint.y / viewSize.height
        let normalizedViewPoint = CGPoint(x: normalizedViewX, y: normalizedViewY)
        
        // Get the inverse display transform to go from view coords → image coords
        // displayTransform goes image → view, so we need to invert it
        let displayTransform = frame.displayTransform(for: orientation, viewportSize: viewSize)
        let inverseTransform = displayTransform.inverted()
        
        // Transform from view coordinates to camera image coordinates
        let normalizedImagePoint = normalizedViewPoint.applying(inverseTransform)
        
        // The depth map is aligned with the camera image, so use normalized image coords
        // Clamp to valid range [0, 1]
        let clampedX = max(0, min(1, Float(normalizedImagePoint.x)))
        let clampedY = max(0, min(1, Float(normalizedImagePoint.y)))
        
        // Convert to depth buffer pixel coordinates
        let pixelX = Int(clampedX * Float(depthWidth - 1))
        let pixelY = Int(clampedY * Float(depthHeight - 1))
        
        // Ensure within bounds
        let safePixelX = max(0, min(depthWidth - 1, pixelX))
        let safePixelY = max(0, min(depthHeight - 1, pixelY))
        
        // Read depth value
        CVPixelBufferLockBaseAddress(depthData, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthData, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthData) else { return nil }
        
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthData)
        let offset = safePixelY * bytesPerRow + safePixelX * MemoryLayout<Float32>.size
        let depth = baseAddress.advanced(by: offset).assumingMemoryBound(to: Float32.self).pointee
        
        // Check if depth is valid (positive and finite)
        guard depth > 0 && depth.isFinite else { return nil }
        
        return depth
    }
    
    /// Sample LiDAR depth at a Vision-normalized point (x, y in [0, 1]).
    /// Converts from Vision coordinate space → screen space, then samples depth.
    func sampleDepthAtNormalizedPoint(_ normalizedPoint: CGPoint) -> Float? {
        guard let arView = arView,
              let frame = session.currentFrame else { return nil }
        let viewSize = arView.bounds.size
        let orientation = getCurrentInterfaceOrientation()
        let displayTransform = frame.displayTransform(for: orientation, viewportSize: viewSize)
        // Vision y is bottom-up; ARKit image y is top-down.
        let normalizedImagePoint = CGPoint(x: normalizedPoint.x, y: 1.0 - normalizedPoint.y)
        let transformed = normalizedImagePoint.applying(displayTransform)
        let screenPoint = CGPoint(x: transformed.x * viewSize.width, y: transformed.y * viewSize.height)
        return sampleDepthAtScreenPoint(screenPoint)
    }
    
    // NOTE: sampleDepthUsingRaycast was removed because ARKit's raycast hits
    // estimated planes (walls, floor, etc.) NOT the user's hand. The hand is not
    // a surface ARKit tracks. Only raw LiDAR depth buffer can "see" the hand.
    
    /// Handle stroke end: keep tracking but allow plane updates for next stroke
    private func handleStrokeEnd() {
        // DON'T clear the tracking buffer - we want continuity between strokes
        // Just re-initialize the plane which will be updated by ongoing tracking
        print("[ARSession] ✅ Stroke ended - continuing depth tracking (last: \(String(format: "%.2f", lastTrackedHandDepth ?? 0))m)")
        // Note: initializeDrawingPlane will be called when next stroke starts with fresh depth
    }
    #endif

    /// Reset depth tracking and drawing plane state for a fresh move session.
    func resetMoveTrackingForFreshSession() {
        lastTrackedHandDepth = nil
        depthTrackingBuffer.removeAll()
        isCurrentlyDrawing = false
        drawingPlaneDistance = defaultDrawingPlaneDistance
        initializeDrawingPlane()
    }
    
    /// Get current interface orientation from the active window scene
    #if !targetEnvironment(simulator)
    private func getCurrentInterfaceOrientation() -> UIInterfaceOrientation {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            return .portrait
        }
        return windowScene.interfaceOrientation
    }
    #endif
    
    /// Raycast for erasing - finds the nearest stroke and projects onto its plane
    func raycastForErasing(normalizedPoint: CGPoint, strokes: [SpatialStroke]) -> (position: SIMD3<Float>, nearestStrokeID: UUID?)? {
        #if !targetEnvironment(simulator)
        guard let arView = arView,
              let frame = session.currentFrame else { return nil }
        
        let viewSize = arView.bounds.size
        let interfaceOrientation = getCurrentInterfaceOrientation()
        let displayTransform = frame.displayTransform(for: interfaceOrientation, viewportSize: viewSize)
        
        // Transform Vision coordinates to screen coordinates
        let normalizedImagePoint = CGPoint(x: normalizedPoint.x, y: 1.0 - normalizedPoint.y)
        let transformedPoint = normalizedImagePoint.applying(displayTransform)
        let screenX = transformedPoint.x * viewSize.width
        let screenY = transformedPoint.y * viewSize.height
        let screenPoint = CGPoint(x: screenX, y: screenY)
        
        // Get the ray from camera through screen point
        guard let rayResult = arView.ray(through: screenPoint) else { return nil }
        let rayOrigin = rayResult.origin
        let rayDirection = rayResult.direction
        
        // Find the nearest stroke to this ray
        var nearestStrokeID: UUID?
        var nearestDistance: Float = Float.greatestFiniteMagnitude
        var nearestPoint: SIMD3<Float>?
        var nearestStrokePlaneNormal: SIMD3<Float>?
        var nearestStrokePlaneCenter: SIMD3<Float>?
        
        for stroke in strokes {
            guard !stroke.points.isEmpty else { continue }
            
            // Calculate stroke's plane (average position and estimated normal)
            let strokeCenter = stroke.points.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(stroke.points.count)
            
            // For each point in the stroke, find distance to ray
            for point in stroke.points {
                // Distance from point to ray line
                let pointToOrigin = point.position - rayOrigin
                let projection = simd_dot(pointToOrigin, rayDirection)
                
                // Only consider points in front of camera
                guard projection > 0 else { continue }
                
                let closestPointOnRay = rayOrigin + projection * rayDirection
                let distance = simd_length(point.position - closestPointOnRay)
                
                if distance < nearestDistance {
                    nearestDistance = distance
                    nearestStrokeID = stroke.id
                    nearestPoint = point.position
                    nearestStrokePlaneCenter = strokeCenter
                    
                    // Estimate plane normal from camera direction (strokes face camera)
                    let cameraPosition = SIMD3<Float>(
                        frame.camera.transform.columns.3.x,
                        frame.camera.transform.columns.3.y,
                        frame.camera.transform.columns.3.z
                    )
                    nearestStrokePlaneNormal = simd_normalize(cameraPosition - strokeCenter)
                }
            }
        }
        
        // If we found a nearby stroke, project onto its plane
        if let planeCenter = nearestStrokePlaneCenter,
           let planeNormal = nearestStrokePlaneNormal,
           nearestDistance < 0.15 { // Within 15cm of a stroke
            
            let denom = simd_dot(rayDirection, planeNormal)
            if abs(denom) > 0.001 {
                let t = simd_dot(planeCenter - rayOrigin, planeNormal) / denom
                if t > 0 {
                    let intersectionPoint = rayOrigin + t * rayDirection
                    return (intersectionPoint, nearestStrokeID)
                }
            }
        }
        
        // If the plane projection failed but we still found a close stroke point,
        // use that nearest stroke point directly so erase still works after move/rotate.
        if let nearestPoint, nearestDistance < 0.10 {
            return (nearestPoint, nearestStrokeID)
        }
        
        // Fallback: use the default drawing plane
        if let planePoint = projectScreenPointToDrawingPlane(screenPoint: screenPoint, frame: frame) {
            return (planePoint, nearestStrokeID)
        }
        
        return nil
        #else
        // Simulator fallback
        let screenX = Float(normalizedPoint.x) - 0.5
        let screenY = Float(normalizedPoint.y) - 0.5
        let position = drawingPlaneCenter + SIMD3<Float>(screenX * 0.5, screenY * 0.5, 0)
        return (position, nil)
        #endif
    }

    /// Raycast a Vision-normalized point to the nearest visible plane
    func raycastToNearestPlane(normalizedPoint: CGPoint) -> SIMD3<Float>? {
        #if !targetEnvironment(simulator)
        guard let arView = arView,
              let frame = session.currentFrame else { return nil }

        let viewSize = arView.bounds.size
        let interfaceOrientation = getCurrentInterfaceOrientation()
        let displayTransform = frame.displayTransform(for: interfaceOrientation, viewportSize: viewSize)

        // Vision coordinates: origin bottom-left, Y up
        let normalizedImagePoint = CGPoint(x: normalizedPoint.x, y: 1.0 - normalizedPoint.y)
        let transformedPoint = normalizedImagePoint.applying(displayTransform)
        let screenPoint = CGPoint(x: transformedPoint.x * viewSize.width,
                                  y: transformedPoint.y * viewSize.height)

        let results = arView.raycast(from: screenPoint, allowing: .estimatedPlane, alignment: .any)
        if let hit = results.first {
            let t = hit.worldTransform
            return SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        }

        if let planePoint = projectScreenPointToDrawingPlane(screenPoint: screenPoint, frame: frame) {
            return planePoint
        }

        return nil
        #else
        let screenX = Float(normalizedPoint.x) - 0.5
        let screenY = Float(normalizedPoint.y) - 0.5
        return drawingPlaneCenter + SIMD3<Float>(screenX * 0.5, screenY * 0.5, 0)
        #endif
    }
    
    /// Project a Vision-normalized point directly onto the active drawing plane.
    /// This is stable for 2D gestures like selection rectangles.
    func projectToDrawingPlane(normalizedPoint: CGPoint) -> SIMD3<Float>? {
        #if !targetEnvironment(simulator)
        guard let arView = arView,
              let frame = session.currentFrame else { return nil }
        
        let viewSize = arView.bounds.size
        let interfaceOrientation = getCurrentInterfaceOrientation()
        let displayTransform = frame.displayTransform(for: interfaceOrientation, viewportSize: viewSize)
        
        let normalizedImagePoint = CGPoint(x: normalizedPoint.x, y: 1.0 - normalizedPoint.y)
        let transformedPoint = normalizedImagePoint.applying(displayTransform)
        let screenPoint = CGPoint(
            x: transformedPoint.x * viewSize.width,
            y: transformedPoint.y * viewSize.height
        )
        
        return projectScreenPointToDrawingPlane(screenPoint: screenPoint, frame: frame)
        #else
        let screenX = Float(normalizedPoint.x) - 0.5
        let screenY = Float(normalizedPoint.y) - 0.5
        return drawingPlaneCenter + SIMD3<Float>(screenX * 0.5, screenY * 0.5, 0)
        #endif
    }

    /// Project a Vision-normalized point onto an arbitrary plane in world space.
    func projectToPlane(normalizedPoint: CGPoint, planeCenter: SIMD3<Float>, planeNormal: SIMD3<Float>) -> SIMD3<Float>? {
        #if !targetEnvironment(simulator)
        guard let arView = arView,
              let frame = session.currentFrame else { return nil }

        let viewSize = arView.bounds.size
        let interfaceOrientation = getCurrentInterfaceOrientation()
        let displayTransform = frame.displayTransform(for: interfaceOrientation, viewportSize: viewSize)

        let normalizedImagePoint = CGPoint(x: normalizedPoint.x, y: 1.0 - normalizedPoint.y)
        let transformedPoint = normalizedImagePoint.applying(displayTransform)
        let screenPoint = CGPoint(
            x: transformedPoint.x * viewSize.width,
            y: transformedPoint.y * viewSize.height
        )

        return projectScreenPointToPlane(screenPoint: screenPoint, planeCenter: planeCenter, planeNormal: planeNormal)
        #else
        return nil
        #endif
    }
    
    #if !targetEnvironment(simulator)
    func projectToWorld(screenPoint: CGPoint, depth: Float, frame: ARFrame, viewSize: CGSize) -> SIMD3<Float> {
        let camera = frame.camera
        let intrinsics = camera.intrinsics
        let imageResolution = camera.imageResolution
        
        let orientation = getCurrentInterfaceOrientation()
        let displayTransform = frame.displayTransform(for: orientation, viewportSize: viewSize)
        let inverseTransform = displayTransform.inverted()
        
        // Convert screen point to normalized view coordinates (0-1)
        let normalizedViewPoint = CGPoint(x: screenPoint.x / viewSize.width, y: screenPoint.y / viewSize.height)
        
        // Transform from view coordinates to camera image coordinates
        let normalizedImagePoint = normalizedViewPoint.applying(inverseTransform)
        
        // Map to image pixel coordinates
        let imageX = Float(normalizedImagePoint.x) * Float(imageResolution.width)
        let imageY = Float(normalizedImagePoint.y) * Float(imageResolution.height)
        
        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        let cx = intrinsics[2][0]
        let cy = intrinsics[2][1]
        
        let x = (imageX - cx) * depth / fx
        let y = -(imageY - cy) * depth / fy
        let z = -depth
        
        let cameraSpacePoint = SIMD4<Float>(x, y, z, 1)
        let worldSpacePoint = camera.transform * cameraSpacePoint
        
        return SIMD3<Float>(worldSpacePoint.x, worldSpacePoint.y, worldSpacePoint.z)
    }
    #endif

    #if !targetEnvironment(simulator)
    private func projectScreenPointToPlane(screenPoint: CGPoint, planeCenter: SIMD3<Float>, planeNormal: SIMD3<Float>) -> SIMD3<Float>? {
        guard let arView = arView,
              let rayResult = arView.ray(through: screenPoint) else { return nil }

        let rayOrigin = rayResult.origin
        let rayDirection = rayResult.direction
        let denom = simd_dot(rayDirection, planeNormal)
        if abs(denom) < 0.001 { return nil }
        let t = simd_dot(planeCenter - rayOrigin, planeNormal) / denom
        if t < 0 { return nil }
        return rayOrigin + t * rayDirection
    }
    #endif

    /// Cluster-sample depth around a Vision-normalized point and reproject to world space.
    func clusterSampleWorldPosition(from normalizedPoint: CGPoint) -> SIMD3<Float>? {
        #if !targetEnvironment(simulator)
        guard let arView = arView,
              let frame = session.currentFrame else { return nil }

        let viewSize = arView.bounds.size
        let orientation = getCurrentInterfaceOrientation()
        let displayTransform = frame.displayTransform(for: orientation, viewportSize: viewSize)

        let normalizedImagePoint = CGPoint(x: normalizedPoint.x, y: 1.0 - normalizedPoint.y)
        let transformed = normalizedImagePoint.applying(displayTransform)
        let screenPoint = CGPoint(x: transformed.x * viewSize.width, y: transformed.y * viewSize.height)

        let offsets: [CGPoint] = [
            .zero,
            CGPoint(x: 12, y: 0),
            CGPoint(x: -12, y: 0),
            CGPoint(x: 0, y: 12),
            CGPoint(x: 0, y: -12)
        ]

        var minDepth: Float = .greatestFiniteMagnitude
        for offset in offsets {
            let samplePoint = CGPoint(x: screenPoint.x + offset.x, y: screenPoint.y + offset.y)
            if let depth = sampleDepthAtScreenPoint(samplePoint),
               depth.isFinite,
               depth > 0.1 && depth < 2.0,
               depth < minDepth {
                minDepth = depth
            }
        }

        guard minDepth < .greatestFiniteMagnitude else { return nil }

        return projectToWorld(screenPoint: screenPoint, depth: minDepth, frame: frame, viewSize: viewSize)
        #else
        return nil
        #endif
    }
    
    #if !targetEnvironment(simulator)
    /// Public wrapper used by high-level gesture logic that needs deterministic
    /// re-projection from a freshly sampled depth value.
    func projectToWorldPublic(screenPoint: CGPoint, depth: Float, frame: ARFrame, viewSize: CGSize) -> SIMD3<Float> {
        projectToWorld(screenPoint: screenPoint, depth: depth, frame: frame, viewSize: viewSize)
    }
    #endif
    
    // MARK: - Simulator Mocking
    
    #if targetEnvironment(simulator)
    private func simulateMockData() {
        // Create mock camera transform
        cameraTransform = simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 1.5, 0, 1)
        )
        
        state = .tracking
    }
    
    private func simulatorRaycast(from screenPoint: CGPoint) -> SIMD3<Float> {
        // Mock raycast: project to a plane 1m in front of camera
        let depth: Float = 1.0
        let normalizedX = Float(screenPoint.x / 390) - 0.5 // Assuming iPhone screen width
        let normalizedY = Float(screenPoint.y / 844) - 0.5
        
        return SIMD3<Float>(
            normalizedX * depth,
            1.5 - normalizedY * depth,
            -depth
        )
    }
    #endif
    
    // MARK: - Collision Detection
    
    /// Check if a point is near any existing stroke
    func findNearestStroke(to point: SIMD3<Float>, maxDistance: Float = 0.05) -> UUID? {
        guard let context = modelContext else { return nil }
        
        let descriptor = FetchDescriptor<SpatialStroke>()
        guard let strokes = try? context.fetch(descriptor) else { return nil }
        
        var nearestID: UUID?
        var nearestDistance: Float = maxDistance
        
        for stroke in strokes {
            for strokePoint in stroke.points {
                let distance = simd_length(strokePoint.position - point)
                if distance < nearestDistance {
                    nearestDistance = distance
                    nearestID = stroke.id
                }
            }
        }
        
        return nearestID
    }
    
    /// Check if a point is inside any folder bounds
    func findFolderAtPoint(_ point: SIMD3<Float>) -> UUID? {
        guard let context = modelContext else { return nil }
        
        let descriptor = FetchDescriptor<SpatialFolder>()
        guard let folders = try? context.fetch(descriptor) else { return nil }
        
        for folder in folders {
            guard let transform = folder.localTransform else { continue }
            
            let folderPosition = SIMD3<Float>(
                transform.columns.3.x,
                transform.columns.3.y,
                transform.columns.3.z
            )
            
            let folderSize: Float = 0.1 * folder.scale
            let distance = simd_length(point - folderPosition)
            
            if distance < folderSize {
                return folder.id
            }
        }
        
        return nil
    }
}

// MARK: - ARSessionDelegate

#if !targetEnvironment(simulator)
extension ARSessionManager: ARSessionDelegate {
    
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor in
            // Only update essential state
            self.cameraTransform = frame.camera.transform
            
            // PERFORMANCE: Don't copy point cloud every frame - rarely used
            // self.pointCloud = frame.rawFeaturePoints
            
            // PERFORMANCE: Don't copy depth map - accessed directly when needed
            // self.depthMap = frame.sceneDepth?.depthMap
            
            // Only update tracking state when it changes
            let newState: ARSessionState
            switch frame.camera.trackingState {
            case .normal:
                newState = .tracking
            case .limited:
                newState = .limited
            case .notAvailable:
                newState = .notAvailable
            }
            
            if self.state != newState {
                self.state = newState
            }
            
            self.delegate?.arSessionManager(self, didUpdateFrame: frame)
        }
    }
    
    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        Task { @MainActor in
            for anchor in anchors {
                self.worldAnchors[anchor.identifier] = anchor
                self.delegate?.arSessionManager(self, didAddAnchor: anchor)
            }
        }
    }
    
    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        Task { @MainActor in
            for anchor in anchors {
                self.worldAnchors[anchor.identifier] = anchor
                self.delegate?.arSessionManager(self, didUpdateAnchor: anchor)
            }
        }
    }
    
    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        Task { @MainActor in
            for anchor in anchors {
                self.worldAnchors.removeValue(forKey: anchor.identifier)
                self.delegate?.arSessionManager(self, didRemoveAnchor: anchor)
            }
        }
    }
    
    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.state = .failed
            self.delegate?.arSessionManager(self, didFailWithError: error)
        }
    }
    
    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in
            self.state = .limited
        }
    }
    
    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in
            self.startSession()
        }
    }
}
#endif

// MARK: - Delegate Protocol

@MainActor
protocol ARSessionManagerDelegate: AnyObject {
    func arSessionManager(_ manager: ARSessionManager, didUpdateFrame frame: ARFrame)
    func arSessionManager(_ manager: ARSessionManager, didAddAnchor anchor: ARAnchor)
    func arSessionManager(_ manager: ARSessionManager, didUpdateAnchor anchor: ARAnchor)
    func arSessionManager(_ manager: ARSessionManager, didRemoveAnchor anchor: ARAnchor)
    func arSessionManager(_ manager: ARSessionManager, didFailWithError error: Error)
}

// MARK: - Default Delegate Implementation

extension ARSessionManagerDelegate {
    func arSessionManager(_ manager: ARSessionManager, didUpdateFrame frame: ARFrame) {}
    func arSessionManager(_ manager: ARSessionManager, didAddAnchor anchor: ARAnchor) {}
    func arSessionManager(_ manager: ARSessionManager, didUpdateAnchor anchor: ARAnchor) {}
    func arSessionManager(_ manager: ARSessionManager, didRemoveAnchor anchor: ARAnchor) {}
    func arSessionManager(_ manager: ARSessionManager, didFailWithError error: Error) {}
}
