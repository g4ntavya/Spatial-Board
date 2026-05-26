// ARCanvasView.swift
// WhiteBoARd - Spatial AR Notetaking
// Main AR canvas with RealityKit integration - optimized for 120fps ProMotion (iPhone 15 Pro)

import SwiftUI
import SwiftData
import RealityKit
import ARKit
import Combine
import Metal
import UIKit

/// Main AR canvas view using RealityKit
struct ARCanvasView: UIViewRepresentable {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        
        #if !targetEnvironment(simulator)
        // Configure AR view for maximum performance (iPhone 15 Pro optimizations)
        arView.automaticallyConfigureSession = false
        arView.renderOptions = [.disableMotionBlur, .disableDepthOfField]
        
        // ProMotion 120Hz is automatically enabled via Info.plist (CADisableMinimumFrameDurationOnPhone)
        // ARKit will use the display's native refresh rate on supported devices
        
        // Metal performance optimizations
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            // Verify GPU is being used
            print("🎮 Metal GPU: \(metalDevice.name)")
        }
        
        // Set up AR session
        ARSessionManager.shared.setARView(arView)
        ARSessionManager.shared.startSession()
        
        // Enable occlusion for realistic depth
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            arView.environment.sceneUnderstanding.options.insert(.occlusion)
        }
        #endif
        
        // Add coaching overlay
        #if !targetEnvironment(simulator)
        let coachingOverlay = ARCoachingOverlayView()
        coachingOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        coachingOverlay.session = arView.session
        coachingOverlay.goal = .tracking
        coachingOverlay.activatesAutomatically = true
        coachingOverlay.delegate = context.coordinator
        arView.addSubview(coachingOverlay)
        context.coordinator.coachingOverlay = coachingOverlay
        #endif
        
        // Set up coordinator
        context.coordinator.arView = arView
        context.coordinator.setupScene()
        
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.updateDrawingSettings(
            color: appState.currentStrokeColor,
            thickness: appState.currentStrokeThickness
        )
        
        // Space switch trigger
        if appState.isSpaceTransitioning {
            // Already handled in coordinator
        }
        
        // Handle Kon keyboard text placement
        if let konText = appState.pendingKonText {
            appState.pendingKonText = nil
            context.coordinator.placeKonText(konText)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState, modelContext: modelContext)
    }
    
    // MARK: - Coordinator
    
    @MainActor
    class Coordinator: NSObject, ARSessionManagerDelegate, ARCoachingOverlayViewDelegate {
        weak var arView: ARView?
        weak var coachingOverlay: ARCoachingOverlayView?
        private let appState: AppState
        private let modelContext: ModelContext
        
        // Scene entities
        private var strokesAnchor: AnchorEntity?
        private var foldersAnchor: AnchorEntity?
        
        // Current drawing state
        private var currentStrokePoints: [StrokePoint] = []
        private var currentStrokeEntity: Entity?
        private var currentColor: StrokeColor = .white
        private var currentThickness: Float = 0.003
        
        // Drawing plane state
        private var drawingPlaneNormal: SIMD3<Float> = SIMD3<Float>(0, 0, 1)
        private var drawingPlaneDistance: Float = 0.5  // 50cm from camera
        private var drawingPlaneAnchor: AnchorEntity?
        private var drawingPlaneCenter: SIMD3<Float> = .zero
        
        // Performance optimization - iPhone 15 Pro 120Hz support
        private var lastMeshUpdateTime: TimeInterval = 0
        private let meshUpdateInterval: TimeInterval = 1.0 / 90.0  // 90 mesh updates/sec for ProMotion
        private var pendingPoints: [StrokePoint] = []
        
        // Math completion timer

        
        // Frame counter for throttling
        private var frameCount: Int = 0
        
        // Undo stack - stores stroke IDs in order they were created
        private var strokeUndoStack: [UUID] = []
        
        // Map from stroke ID to entity for quick removal
        private var strokeEntities: [UUID: Entity] = [:]
        
        // Map from folder ID to entity for quick access
        private var folderEntities: [UUID: Entity] = [:]
        
        // Billboard frame counter — only update every 2nd frame to save CPU
        private var billboardFrameCount: Int = 0
        private var lastBillboardUpdateTime: TimeInterval = 0
        private var lastBillboardCameraPos: SIMD3<Float> = .zero
        private var lastBillboardCameraForward: SIMD3<Float> = SIMD3<Float>(0, 0, -1)
        private let billboardUpdateInterval: TimeInterval = 1.0 / 30.0
        private let billboardMoveThreshold: Float = 0.01
        private let billboardAngleThreshold: Float = 0.03
        private let billboardMaxTilt: Float = .pi / 18.0
        private let billboardTiltFactor: Float = 0.25

        // Distance culling
        private var lastCullTime: TimeInterval = 0
        private let cullInterval: TimeInterval = 0.35
        private let maxRenderDistance: Float = 30.0
        private var distanceCulledStrokeIDs: Set<UUID> = []
        private var distanceCulledFolderIDs: Set<UUID> = []
        
        // Erase state
        private var lastEraseCheckPosition: SIMD3<Float>?
        private var lastEraseCheckTime: TimeInterval = 0
        
        // Kon learning state
        private var recentStrokesForLearning: [SpatialStroke] = []
        private var konLearningTimer: Timer?
        private var konHoldProgressTask: Task<Void, Never>?
        
        // MARK: - Selection State
        
        /// Semi-transparent rectangle entity shown while user is selecting
        private var selectionRectEntity: Entity?
        /// Highlight overlay entities keyed by stroke ID
        private var highlightEntities: [UUID: Entity] = [:]
        /// Folder highlight overlays keyed by folder ID
        private var folderHighlightEntities: [UUID: Entity] = [:]
        /// Live target glow while a moving selection is within folder absorption range
        private var folderTargetGlowEntities: [UUID: Entity] = [:]
        private var activeFolderTargetGlowID: UUID?
        /// Last folder candidate from target glow (used to finalize absorption on drop)
        private var lastAbsorptionFolderID: UUID?
        /// Debounce tracking for folder toggles via pointing
        private var lastFolderToggleTime: [UUID: Date] = [:]
        /// Hover tracking for folder open (index pointing)
        private var folderHoverStartTime: [UUID: Date] = [:]
        private var hoveredFolderID: UUID?
        /// Sticky pointing lock so brief tracking jitter doesn't reset hover timer
        private var folderPointingLockUntil: Date = .distantPast

        // Folder move/resize state
        private var folderMoveOrigin: SIMD3<Float>?
        private var folderMoveStartPos: SIMD3<Float>?
        private var folderMoveActiveID: UUID?
        private var folderResizeActiveID: UUID?
        
        /// Notification tokens for cleanup
        private var notificationTokens: [Any] = []
        /// World positions of the two selection corners (on the drawing plane)
        private var selectionCorner3DLeft: SIMD3<Float>  = .zero
        private var selectionCorner3DRight: SIMD3<Float> = .zero
        /// Per-entity offsets from selection centroid captured at move start.
        /// During move we place every selected entity at `palm + offset`.
        private var strokeMoveOffsets: [UUID: SIMD3<Float>] = [:]
        private var folderMoveOffsets: [UUID: SIMD3<Float>] = [:]
        private var strokeMoveBaseCentroids: [UUID: SIMD3<Float>] = [:]
        private var folderMoveBasePositions: [UUID: SIMD3<Float>] = [:]
        private var strokeMoveBaseRotations: [UUID: simd_quatf] = [:]
        private var strokeMoveBaseTransforms: [UUID: Transform] = [:]
        /// Last palm position applied during active selected move.
        private var lastMovePalmPosition: SIMD3<Float>?
        /// Anchor the moved selection slightly to the left of palm for better visibility.
        private var movePalmLeftOffset: SIMD3<Float> = .zero
        /// Centroid of selected strokes (used for center-scaling)
        private var selectionCentroid: SIMD3<Float> = .zero
        /// Track whether the selection plane has been initialized for the current selection gesture
        private var selectionPlaneInitialized: Bool = false
        /// Cached plane basis for selection rectangle orientation
        private var selectionPlaneRight: SIMD3<Float> = SIMD3<Float>(1, 0, 0)
        private var selectionPlaneUp: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
        /// Fixed move plane for the current selection (world-space)
        private var selectionMovePlaneCenter: SIMD3<Float> = .zero
        private var selectionMovePlaneNormal: SIMD3<Float> = SIMD3<Float>(0, 0, 1)
        
        init(appState: AppState, modelContext: ModelContext) {
            self.appState = appState
            self.modelContext = modelContext
            super.init()
            
            setupGestureCallbacks()
        }
        
        func setupScene() {
            guard let arView = arView else { return }
            
            // Create root anchor for strokes
            strokesAnchor = AnchorEntity(world: .zero)
            strokesAnchor?.name = "StrokesRoot"
            arView.scene.addAnchor(strokesAnchor!)
            
            // Create root anchor for folders
            foldersAnchor = AnchorEntity(world: .zero)
            foldersAnchor?.name = "FoldersRoot"
            arView.scene.addAnchor(foldersAnchor!)
            
            // Load only entities belonging to the active space
            loadEntitiesForSpace(appState.activeSpaceID, thenFadeIn: false)
            
            // Set up notifications
            setupNotifications()
            
            // Set up tap gesture for folder interaction
            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            arView.addGestureRecognizer(tapGesture)
            
            // Start gesture recognition
            GestureRecognizer.shared.startProcessing()
            
            // Set as AR session delegate
            ARSessionManager.shared.delegate = self
            
            // Register undo/clear actions with AppState
            appState.undoAction = { [weak self] in
                self?.undoLastStroke()
            }
            appState.clearAllAction = { [weak self] in
                self?.clearAllStrokes()
            }
        }
        
        private func setupGestureCallbacks() {
            let gestureRecognizer = GestureRecognizer.shared
            
            // Gesture mode changes
            gestureRecognizer.onGestureModeChanged = { [weak self] mode in
                Task { @MainActor in
                    self?.appState.currentGestureMode = mode
                    
                    if mode != .draw {
                        self?.finishCurrentStroke()
                    }
                    
                    // Initialize drawing plane for both draw and erase modes
                    // This ensures erase coordinates are in the same space as stroke points
                    if mode == .draw || mode == .erase {
                        self?.initializeDrawingPlane()
                    }
                }
            }
            
            // Drawing (pinch gesture) - receives normalized 2D position from gesture recognizer
            gestureRecognizer.onPinchPositionUpdated = { [weak self] position in
                Task { @MainActor in
                    self?.handleDrawing(at: position)
                }
            }
            
            // Erasing (open palm) - receives 2D normalized Vision point
            gestureRecognizer.onEraseActivated = { [weak self] normalizedPoint in
                Task { @MainActor in
                    self?.handleErasing(at: normalizedPoint)
                }
            }
            

            // Kon gesture callbacks
            gestureRecognizer.onKonHoldStarted = { [weak self] in
                Task { @MainActor in self?.startKonHoldProgress() }
            }
            gestureRecognizer.onKonHoldCancelled = { [weak self] in
                Task { @MainActor in self?.cancelKonHold() }
            }
            gestureRecognizer.onKonTriggered = { [weak self] in
                Task { @MainActor in self?.triggerKon() }
            }
            
            // MARK: Selection Callbacks
            
            // 1. Live selection rectangle update (two-hand pinch)
            gestureRecognizer.onSelectionRectUpdated = { [weak self] leftNorm, rightNorm in
                Task { @MainActor in
                    if self?.selectionPlaneInitialized == false {
                        self?.initializeDrawingPlane()
                        self?.captureSelectionPlaneBasis()
                        self?.selectionPlaneInitialized = true
                    }
                    self?.handleSelectionRectUpdate(leftNorm: leftNorm, rightNorm: rightNorm)
                }
            }
            // 2. Confirmed selection (both pinches released)
            gestureRecognizer.onSelectionConfirmed = { [weak self] leftNorm, rightNorm in
                Task { @MainActor in
                    self?.selectionPlaneInitialized = false
                    self?.handleSelectionConfirmed(leftNorm: leftNorm, rightNorm: rightNorm)
                }
            }
            // 3. Fist move (per-frame)
            gestureRecognizer.onFistMoveUpdated = { [weak self] rawPoint2D, fist3D in
                Task { @MainActor in self?.handleFistMove(rawPoint2D: rawPoint2D, fist3D: fist3D) }
            }
            // 4. Fist released — lock position
            gestureRecognizer.onFistMoveEnded = { [weak self] in
                Task { @MainActor in self?.handleFistMoveEnded() }
            }
            // 5. Three-finger resize (per-frame scale delta)
            gestureRecognizer.onThreeFingerResizeUpdated = { [weak self] scaleDelta in
                Task { @MainActor in self?.handleThreeFingerResize(scaleDelta: scaleDelta) }
            }
            // 6. Three-finger resize ended
            gestureRecognizer.onThreeFingerResizeEnded = { [weak self] in
                Task { @MainActor in self?.persistResizedStrokes() }
            }
            // 7. Double-tap deselect
            gestureRecognizer.onDoubleTapDetected = { [weak self] in
                Task { @MainActor in
                    guard let self,
                          !(self.appState.selectedStrokeIDs.isEmpty && self.appState.selectedFolderIDs.isEmpty)
                    else { return }
                    self.clearSelection()
                }
            }
            // Selection-aware pinch behavior: selected => pinch resizes, otherwise pinch draws.
            gestureRecognizer.isSelectionActive = { [weak self] in
                guard let self else { return false }
                return !(self.appState.selectedStrokeIDs.isEmpty && self.appState.selectedFolderIDs.isEmpty)
            }
            // 8. Index pointing
            gestureRecognizer.onPointUpdated = { [weak self] pointNorm, point3D in
                Task { @MainActor in self?.handlePointing(at: pointNorm, point3D: point3D) }
            }
        }
        
        func updateDrawingSettings(color: StrokeColor, thickness: Float) {
            currentColor = color
            currentThickness = thickness
        }
        
        // MARK: - Drawing Plane
        
        /// Initialize a drawing plane perpendicular to camera at fixed distance
        private func initializeDrawingPlane() {
            // Use ARSessionManager's centralized drawing plane
            ARSessionManager.shared.initializeDrawingPlane()
            
            // Copy values for local use (face direction for mesh generation)
            drawingPlaneNormal = ARSessionManager.shared.drawingPlaneNormal
            drawingPlaneCenter = ARSessionManager.shared.drawingPlaneCenter
        }

        /// Cache a stable right/up basis for the selection plane.
        private func captureSelectionPlaneBasis() {
            let normal = ARSessionManager.shared.drawingPlaneNormal
            let cam = ARSessionManager.shared.cameraTransform
            var right = SIMD3<Float>(cam.columns.0.x, cam.columns.0.y, cam.columns.0.z)
            right = right - normal * simd_dot(right, normal)
            if simd_length(right) < 0.001 {
                right = SIMD3<Float>(1, 0, 0)
            }
            right = simd_normalize(right)
            let up = simd_normalize(simd_cross(normal, right))
            selectionPlaneRight = right
            selectionPlaneUp = up
        }
        
        /// Project a 3D point onto the drawing plane (not needed if ARSessionManager does projection)
        private func projectOntoDrawingPlane(_ point: SIMD3<Float>) -> SIMD3<Float> {
            // Points from GestureRecognizer are already on the plane
            // But we can re-project just to be safe
            let d = simd_dot(point - drawingPlaneCenter, drawingPlaneNormal)
            return point - d * drawingPlaneNormal
        }
        
        // MARK: - Drawing
        
        /// Last point time for velocity calculation (using CACurrentMediaTime for accuracy)
        private var lastPointTime: TimeInterval = 0
        
        private func handleDrawing(at worldPosition: SIMD3<Float>) {
            appState.isDrawing = true
            appState.lastStrokeTime = Date()
            
            // Removed automatic math completion timer. Math is now exclusively handled by Kon gesture.
            
            // Use an optimized minimum distance for fluid drawing (3mm buffers out thousands of excess vertices on ML nodes)
            if let lastPoint = currentStrokePoints.last {
                let distance = simd_length(worldPosition - lastPoint.position)
                if distance < 0.003 {  // 3mm minimum
                    return
                }
            }
            
            // Use CACurrentMediaTime for accurate timing (cheaper than Date())
            let now = CACurrentMediaTime()
            
            // Calculate velocity-based pressure
            var pressure: Float = 1.0
            if !currentStrokePoints.isEmpty && lastPointTime > 0 {
                let timeDelta = now - lastPointTime
                if timeDelta > 0 {
                    let distance = simd_length(worldPosition - currentStrokePoints.last!.position)
                    let velocity = Float(Double(distance) / timeDelta)
                    pressure = max(0.5, min(1.2, 1.0 - velocity * 0.5))
                }
            }
            lastPointTime = now
            
            let strokePoint = StrokePoint(position: worldPosition, pressure: pressure)
            currentStrokePoints.append(strokePoint)
            
            // Rebuild stroke visual for every new point — no throttling during
            // active drawing so the ink feels instant and responsive.
            updateCurrentStrokeVisual()
        }
        
        private func updateCurrentStrokeVisual() {
            guard currentStrokePoints.count >= 2 else { return }
            
            // Remove previous temporary entity
            currentStrokeEntity?.removeFromParent()
            
            // Process points with Catmull-Rom smoothing for fluid curves
            let processedPoints = StrokeProcessor.shared.processPoints(currentStrokePoints)
            
            // Create ribbon mesh entity (2D flat stroke)
            if let entity = StrokeProcessor.shared.createEntity(
                from: processedPoints,
                thickness: currentThickness,
                color: currentColor,
                faceDirection: drawingPlaneNormal
            ) {
                currentStrokeEntity = entity
                strokesAnchor?.addChild(entity)
            }
        }
        
        private func finishCurrentStroke() {
            guard currentStrokePoints.count >= 2 else {
                currentStrokePoints.removeAll()
                currentStrokeEntity?.removeFromParent()
                currentStrokeEntity = nil
                appState.isDrawing = false
                return
            }
            
            // Deduplicate points that are too close together (keeps stroke as-drawn).
            // Use a gentle simplification to reduce storage without distorting handwriting.
            let finalPoints = StrokeProcessor.shared.processPoints(currentStrokePoints)
            let segments = StrokeProcessor.shared.pointsToBezierSegments(finalPoints)
            
            // Calculate stroke centroid for anchor placement
            let centroid = calculateCentroid(of: finalPoints)
            
            // Create persisted stroke
            let stroke = SpatialStroke(
                points: finalPoints,
                bezierSegments: segments,
                color: currentColor,
                thickness: currentThickness,
                spaceID: appState.activeSpaceID
            )
            stroke.isCompleted = true
            
            // Save to SwiftData
            modelContext.insert(stroke)
            try? modelContext.save()
            
            // Update entity name to match stroke ID
            if let entity = currentStrokeEntity {
                entity.name = "Stroke_\(stroke.id.uuidString)"
                
                // Track for undo
                strokeUndoStack.append(stroke.id)
                strokeEntities[stroke.id] = entity
            }
            
            // Track for Kon learning
            recentStrokesForLearning.append(stroke)
            scheduleKonLearning()
            
            // Create WorldAnchor for persistence across sessions
            #if !targetEnvironment(simulator)
            createWorldAnchor(for: stroke, at: centroid)
            #endif
            
            // Reset state
            currentStrokePoints.removeAll()
            currentStrokeEntity = nil
            appState.isDrawing = false
        }
        
        private func calculateCentroid(of points: [StrokePoint]) -> SIMD3<Float> {
            guard !points.isEmpty else { return .zero }
            
            var sum = SIMD3<Float>.zero
            for point in points {
                sum += point.position
            }
            return sum / Float(points.count)
        }
        
        private func createWorldAnchor(for stroke: SpatialStroke, at position: SIMD3<Float>) {
            guard let arView = arView else { return }
            
            var transform = matrix_identity_float4x4
            transform.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1.0)
            
            let anchor = ARAnchor(name: "StrokeAnchor_\(stroke.id.uuidString)", transform: transform)
            arView.session.add(anchor: anchor)
            
            stroke.worldAnchorID = anchor.identifier
            try? modelContext.save()
        }
        
        // MARK: - Erasing (Partial - like Photoshop)
        
        /// Handle erasing with stroke-aware plane projection
        /// - Parameter normalizedPoint: 2D normalized Vision coordinates (origin bottom-left)
        private func handleErasing(at normalizedPoint: CGPoint) {
            // Don't allow erasing currently selected strokes; user must deselect first.
            let selectedIDs = appState.selectedStrokeIDs
            
            // Throttle erase checks (max ~30/sec for smooth but stable partial erasing)
            let now = Date().timeIntervalSince1970
            if now - lastEraseCheckTime < 0.033 {
                return
            }
            lastEraseCheckTime = now
            
            // Get all current strokes for stroke-aware projection
            let descriptor = FetchDescriptor<SpatialStroke>()
            guard let allStrokes = try? modelContext.fetch(descriptor) else { return }

            // Use stroke-aware raycasting - projects onto the nearest stroke's plane
            let position: SIMD3<Float>
            if let result = ARSessionManager.shared.raycastForErasing(
                normalizedPoint: normalizedPoint,
                strokes: allStrokes
            ) {
                position = result.position
            } else if let fallback = ARSessionManager.shared.clusterSampleWorldPosition(from: normalizedPoint)
                        ?? ARSessionManager.shared.raycastHandLandmarkDepthAware(normalizedPoint: normalizedPoint) {
                position = fallback
            } else {
                return
            }
            
            // Validate position is finite
            guard position.x.isFinite && position.y.isFinite && position.z.isFinite else {
                return
            }
            
            // Skip if position hasn't moved much
            if let lastPos = lastEraseCheckPosition {
                let moved = simd_length(position - lastPos)
                if moved < 0.0015 { // Less than 1.5mm movement
                    return
                }
            }
            lastEraseCheckPosition = position
            
            // Natural erase radius: tighter so user must be near the stroke
            let eraseRadius: Float = 0.040  // 4.0cm radius
            
            guard strokesAnchor != nil else { return }
            
            var nearestStrokeToProcess: (id: UUID, stroke: SpatialStroke, distance: Float)?
            
            let strokesByID = Dictionary(uniqueKeysWithValues: allStrokes.map { ($0.id, $0) })
            // Find all strokes that intersect with erase position
            for (strokeID, _) in strokeEntities {
                if selectedIDs.contains(strokeID) { continue }
                guard let stroke = strokesByID[strokeID] else { continue }
                
                var strokeNearest: Float = .greatestFiniteMagnitude
                for strokePoint in stroke.points {
                    let distance = simd_length(strokePoint.position - position)
                    strokeNearest = min(strokeNearest, distance)
                }
                
                guard strokeNearest < eraseRadius else { continue }
                if let current = nearestStrokeToProcess {
                    if strokeNearest < current.distance {
                        nearestStrokeToProcess = (strokeID, stroke, strokeNearest)
                    }
                } else {
                    nearestStrokeToProcess = (strokeID, stroke, strokeNearest)
                }
            }
            
            // Erase only nearest stroke per frame to avoid cross-erasing adjacent strokes.
            if let target = nearestStrokeToProcess {
                partialEraseStroke(stroke: target.stroke, strokeID: target.id, erasePosition: position, eraseRadius: eraseRadius)
            }
        }
        
        /// Partially erase a stroke by splitting it into segments
        private func partialEraseStroke(stroke: SpatialStroke, strokeID: UUID, erasePosition: SIMD3<Float>, eraseRadius: Float) {
            // Find indices of points to erase
            var eraseIndices: Set<Int> = []
            for (index, point) in stroke.points.enumerated() {
                let distance = simd_length(point.position - erasePosition)
                if distance < eraseRadius {
                    eraseIndices.insert(index)
                }
            }
            
            guard !eraseIndices.isEmpty else { return }
            
            // Remove the original stroke entity
            if let entity = strokeEntities[strokeID] {
                entity.removeFromParent()
            }
            strokeEntities.removeValue(forKey: strokeID)
            strokeUndoStack.removeAll { $0 == strokeID }
            
            // Split into segments (contiguous runs of non-erased points)
            var segments: [[StrokePoint]] = []
            var currentSegment: [StrokePoint] = []
            
            for (index, point) in stroke.points.enumerated() {
                if eraseIndices.contains(index) {
                    // End current segment if it has enough points
                    if currentSegment.count >= 2 {
                        segments.append(currentSegment)
                    }
                    currentSegment = []
                } else {
                    currentSegment.append(point)
                }
            }
            
            // Don't forget the last segment
            if currentSegment.count >= 2 {
                segments.append(currentSegment)
            }
            
            // Delete original stroke from database
            modelContext.delete(stroke)
            
            // Create new strokes for each remaining segment
            for segment in segments {
                let newStroke = SpatialStroke(
                    points: segment,
                    bezierSegments: StrokeProcessor.shared.pointsToBezierSegments(segment),
                    color: stroke.color,
                    thickness: stroke.thickness,
                    spaceID: stroke.spaceID
                )
                newStroke.isCompleted = true
                modelContext.insert(newStroke)
                
                // Create entity for new segment
                if let entity = StrokeProcessor.shared.createEntity(
                    from: segment,
                    thickness: stroke.thickness,
                    color: stroke.color,
                    faceDirection: drawingPlaneNormal
                ) {
                    entity.name = "Stroke_\(newStroke.id.uuidString)"
                    strokesAnchor?.addChild(entity)
                    strokeEntities[newStroke.id] = entity
                    strokeUndoStack.append(newStroke.id)
                }
            }
            
            try? modelContext.save()
            
            // Haptic feedback
            #if !targetEnvironment(simulator)
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            #endif
        }
        
        private func deleteStroke(id: UUID) {
            let descriptor = FetchDescriptor<SpatialStroke>(
                predicate: #Predicate { $0.id == id }
            )
            
            if let strokes = try? modelContext.fetch(descriptor), let stroke = strokes.first {
                modelContext.delete(stroke)
                try? modelContext.save()
            }
            
            // Remove from tracking
            strokeEntities.removeValue(forKey: id)
            strokeUndoStack.removeAll { $0 == id }
        }
        
        // MARK: - Undo
        
        /// Undo the last stroke
        func undoLastStroke() {
            guard let lastStrokeID = strokeUndoStack.popLast() else { return }
            
            // Remove entity from scene
            if let entity = strokeEntities[lastStrokeID] {
                entity.removeFromParent()
                strokeEntities.removeValue(forKey: lastStrokeID)
            }
            
            // Delete from database
            let descriptor = FetchDescriptor<SpatialStroke>(
                predicate: #Predicate { $0.id == lastStrokeID }
            )
            
            if let strokes = try? modelContext.fetch(descriptor), let stroke = strokes.first {
                modelContext.delete(stroke)
                try? modelContext.save()
            }
        }
        
        // MARK: - Clear All
        
        /// Clear all strokes, folders, and anchors from the scene and database
        func clearAllStrokes() {
            clearSelection()
            lastFolderToggleTime.removeAll()

            // Remove all stroke entities from scene
            for (_, entity) in strokeEntities {
                entity.removeFromParent()
            }
            strokeEntities.removeAll()
            strokeUndoStack.removeAll()

            // Remove all folder entities from scene
            for (_, entity) in folderEntities {
                entity.removeFromParent()
            }
            folderEntities.removeAll()

            // Also remove any that weren't tracked
            strokesAnchor?.children.forEach { child in
                if child.name.hasPrefix("Stroke_") || child.name.hasPrefix("Folder_") {
                    child.removeFromParent()
                }
            }
            foldersAnchor?.children.forEach { child in
                if child.name.hasPrefix("Folder_") {
                    child.removeFromParent()
                }
            }

            // Delete all strokes and folders from database
            let strokeDesc = FetchDescriptor<SpatialStroke>()
            if let strokes = try? modelContext.fetch(strokeDesc) {
                for stroke in strokes {
                    modelContext.delete(stroke)
                }
            }

            let folderDesc = FetchDescriptor<SpatialFolder>()
            if let folders = try? modelContext.fetch(folderDesc) {
                for folder in folders {
                    modelContext.delete(folder)
                }
            }

            // Remove all persisted anchors
            let anchorDesc = FetchDescriptor<PersistedWorldAnchor>()
            if let anchors = try? modelContext.fetch(anchorDesc) {
                for anchor in anchors {
                    ARSessionManager.shared.removeWorldAnchor(id: anchor.id)
                }
            }

            try? modelContext.save()
        }
        
        // MARK: - Resizing (legacy single-hand callback, kept for compatibility)
        
        private func handleResizing(scale: Float) {
            // Legacy: no-op — resizing is now handled via onThreeFingerResizeUpdated
        }
        
        // MARK: - Spatial Selection
        
        /// Called every Vision frame while two-hand pinch is active.
        /// Converts the two normalized 2D pinch points to 3D on the drawing plane
        /// and updates the selection rectangle entity.
        private func handleSelectionRectUpdate(leftNorm: CGPoint, rightNorm: CGPoint) {
            if let arView = arView,
               let frame = ARSessionManager.shared.session.currentFrame {
                appState.selectionCornerLeftScreen = visionNormalizedToScreen(leftNorm, frame: frame, viewSize: arView.bounds.size)
                appState.selectionCornerRightScreen = visionNormalizedToScreen(rightNorm, frame: frame, viewSize: arView.bounds.size)
            } else {
                appState.selectionCornerLeftScreen = nil
                appState.selectionCornerRightScreen = nil
            }

            guard let left3D  = ARSessionManager.shared.projectToDrawingPlane(normalizedPoint: leftNorm),
                  let right3D = ARSessionManager.shared.projectToDrawingPlane(normalizedPoint: rightNorm)
            else { return }
            
            selectionCorner3DLeft  = left3D
            selectionCorner3DRight = right3D
            appState.selectionCornerLeft  = left3D
            appState.selectionCornerRight = right3D
            appState.selectionState = .selecting
            
            updateSelectionRectEntity(left3D: left3D, right3D: right3D)
        }
        
        /// Called once when both pinches release. Performs bounding-volume intersection
        /// to find which strokes fall inside the drawn rectangle.
        private func handleSelectionConfirmed(leftNorm: CGPoint, rightNorm: CGPoint) {
            // Remove live rectangle
            selectionRectEntity?.removeFromParent()
            selectionRectEntity = nil
            
            guard let arView = arView,
                  let frame = ARSessionManager.shared.session.currentFrame else {
                appState.selectionState = .idle
                return
            }
            
            // Keep final outline visible after selection is confirmed.
            appState.selectionCornerLeft = selectionCorner3DLeft
            appState.selectionCornerRight = selectionCorner3DRight
            appState.selectionCornerLeftScreen = visionNormalizedToScreen(leftNorm, frame: frame, viewSize: arView.bounds.size)
            appState.selectionCornerRightScreen = visionNormalizedToScreen(rightNorm, frame: frame, viewSize: arView.bounds.size)
            
            // Use final (release-frame) normalized corners, not initial ones.
            let leftScreen = visionNormalizedToScreen(leftNorm, frame: frame, viewSize: arView.bounds.size)
            let rightScreen = visionNormalizedToScreen(rightNorm, frame: frame, viewSize: arView.bounds.size)
            let rect = CGRect(
                x: min(leftScreen.x, rightScreen.x),
                y: min(leftScreen.y, rightScreen.y),
                width: abs(rightScreen.x - leftScreen.x),
                height: abs(rightScreen.y - leftScreen.y)
            ).insetBy(dx: -8, dy: -8)
            
            var newSelection: Set<UUID> = []
            let descriptor = FetchDescriptor<SpatialStroke>()
            let strokes = try? modelContext.fetch(descriptor)
            if let strokes {
                for stroke in strokes {
                    guard stroke.spaceID == appState.activeSpaceID else { continue }
                    var included = false
                    
                    // Prefer per-point projection so thin strokes select correctly.
                    for point in stroke.points {
                        if let projected = arView.project(point.position), rect.contains(projected) {
                            newSelection.insert(stroke.id)
                            included = true
                            break
                        }
                    }
                    
                    // Fallback to entity origin projection if stroke points did not hit.
                    if !included,
                       let entity = strokeEntities[stroke.id],
                       let projected = arView.project(entity.position(relativeTo: nil)),
                       rect.contains(projected) {
                        newSelection.insert(stroke.id)
                    }
                }
            }
            
            var newFolderSelection: Set<UUID> = []
            let folderHitRect = rect.insetBy(dx: -36, dy: -36)
            for (id, entity) in folderEntities {
                if entityIntersectsScreenRect(entity: entity, screenRect: folderHitRect, in: arView) {
                    newFolderSelection.insert(id)
                }
            }
            
            appState.selectedStrokeIDs = newSelection
            appState.selectedFolderIDs = newFolderSelection
            appState.selectionState = (newSelection.isEmpty && newFolderSelection.isEmpty) ? .idle : .selected
            
            // Highlight selected strokes
            clearHighlights()
            for id in newSelection {
                addHighlight(for: id)
            }
            clearFolderHighlights()
            for id in newFolderSelection {
                addFolderHighlight(for: id)
            }
            
            let strokesByID = Dictionary(uniqueKeysWithValues: (strokes ?? []).map { ($0.id, $0) })
            // Compute centroid for center-scaling
            updateSelectionCentroid(
                strokesByID: strokesByID,
                selectedStrokeIDs: newSelection,
                selectedFolderIDs: newFolderSelection
            )
            updateSelectionMovePlane(strokesByID: strokesByID, selectedStrokeIDs: newSelection)
            ARSessionManager.shared.resetMoveTrackingForFreshSession()
            
            // Haptic feedback
            #if !targetEnvironment(simulator)
            let hasSelection = !(newSelection.isEmpty && newFolderSelection.isEmpty)
            let gen = UIImpactFeedbackGenerator(style: hasSelection ? .medium : .light)
            gen.impactOccurred()
            #endif
        }
        
        // MARK: - Selection Rectangle Entity
        
        private func updateSelectionRectEntity(left3D: SIMD3<Float>, right3D: SIMD3<Float>) {
            let center = (left3D + right3D) * 0.5
            let delta = right3D - left3D
            let width  = abs(simd_dot(delta, selectionPlaneRight))
            let height = abs(simd_dot(delta, selectionPlaneUp))

            let lineThickness: Float = 0.002
            let lineDepth: Float = 0.001

            // Create or reuse parent entity
            if selectionRectEntity == nil {
                let entity = Entity()
                entity.name = "SelectionRect"
                strokesAnchor?.addChild(entity)
                selectionRectEntity = entity
            }

            selectionRectEntity?.children.forEach { $0.removeFromParent() }
            let normal = ARSessionManager.shared.drawingPlaneNormal
            var basis = matrix_identity_float4x4
            basis.columns.0 = SIMD4<Float>(selectionPlaneRight, 0)
            basis.columns.1 = SIMD4<Float>(selectionPlaneUp, 0)
            basis.columns.2 = SIMD4<Float>(normal, 0)
            basis.columns.3 = SIMD4<Float>(center.x, center.y, center.z, 1)
            selectionRectEntity?.transform = Transform(matrix: basis)

            var mat = UnlitMaterial()
            mat.color = .init(tint: UIColor(red: 0.2, green: 0.6, blue: 1.0, alpha: 0.6))

            let w = max(width, 0.005)
            let h = max(height, 0.005)

            // Top
            let top = Entity()
            top.components.set(ModelComponent(mesh: MeshResource.generateBox(size: [w, lineThickness, lineDepth]), materials: [mat]))
            top.position = [0, h / 2, 0]
            selectionRectEntity?.addChild(top)

            // Bottom
            let bottom = Entity()
            bottom.components.set(ModelComponent(mesh: MeshResource.generateBox(size: [w, lineThickness, lineDepth]), materials: [mat]))
            bottom.position = [0, -h / 2, 0]
            selectionRectEntity?.addChild(bottom)

            // Left
            let left = Entity()
            left.components.set(ModelComponent(mesh: MeshResource.generateBox(size: [lineThickness, h, lineDepth]), materials: [mat]))
            left.position = [-w / 2, 0, 0]
            selectionRectEntity?.addChild(left)

            // Right
            let right = Entity()
            right.components.set(ModelComponent(mesh: MeshResource.generateBox(size: [lineThickness, h, lineDepth]), materials: [mat]))
            right.position = [w / 2, 0, 0]
            selectionRectEntity?.addChild(right)
        }
        
        // MARK: - Highlight Entities
        
        private func addHighlight(for strokeID: UUID) {
            guard let strokeEntity = strokeEntities[strokeID] else { return }
            // Remove stale highlight if one exists.
            highlightEntities[strokeID]?.removeFromParent()
            
            let highlight = Entity()
            highlight.name = "Highlight_\(strokeID.uuidString)"
            
            // Build an actual outline frame around the stroke bounds (instead of a random cube).
            let bounds = strokeEntity.visualBounds(relativeTo: strokeEntity)
            let extents = SIMD3<Float>(
                max(bounds.extents.x, 0.006),
                max(bounds.extents.y, 0.006),
                max(bounds.extents.z, 0.006)
            )
            let minCorner = bounds.center - extents * 0.5
            let maxCorner = bounds.center + extents * 0.5
            
            var mat = UnlitMaterial()
            mat.color = .init(tint: UIColor(red: 0.15, green: 0.65, blue: 1.0, alpha: 0.9))
            let edgeThickness: Float = 0.0014
            
            let c000 = SIMD3<Float>(minCorner.x, minCorner.y, minCorner.z)
            let c001 = SIMD3<Float>(minCorner.x, minCorner.y, maxCorner.z)
            let c010 = SIMD3<Float>(minCorner.x, maxCorner.y, minCorner.z)
            let c011 = SIMD3<Float>(minCorner.x, maxCorner.y, maxCorner.z)
            let c100 = SIMD3<Float>(maxCorner.x, minCorner.y, minCorner.z)
            let c101 = SIMD3<Float>(maxCorner.x, minCorner.y, maxCorner.z)
            let c110 = SIMD3<Float>(maxCorner.x, maxCorner.y, minCorner.z)
            let c111 = SIMD3<Float>(maxCorner.x, maxCorner.y, maxCorner.z)
            
            addOutlineEdge(to: highlight, from: c000, to: c100, thickness: edgeThickness, material: mat)
            addOutlineEdge(to: highlight, from: c001, to: c101, thickness: edgeThickness, material: mat)
            addOutlineEdge(to: highlight, from: c010, to: c110, thickness: edgeThickness, material: mat)
            addOutlineEdge(to: highlight, from: c011, to: c111, thickness: edgeThickness, material: mat)
            
            addOutlineEdge(to: highlight, from: c000, to: c010, thickness: edgeThickness, material: mat)
            addOutlineEdge(to: highlight, from: c001, to: c011, thickness: edgeThickness, material: mat)
            addOutlineEdge(to: highlight, from: c100, to: c110, thickness: edgeThickness, material: mat)
            addOutlineEdge(to: highlight, from: c101, to: c111, thickness: edgeThickness, material: mat)
            
            addOutlineEdge(to: highlight, from: c000, to: c001, thickness: edgeThickness, material: mat)
            addOutlineEdge(to: highlight, from: c010, to: c011, thickness: edgeThickness, material: mat)
            addOutlineEdge(to: highlight, from: c100, to: c101, thickness: edgeThickness, material: mat)
            addOutlineEdge(to: highlight, from: c110, to: c111, thickness: edgeThickness, material: mat)
            
            strokeEntity.addChild(highlight)
            highlightEntities[strokeID] = highlight
        }
        
        private func addOutlineEdge(
            to parent: Entity,
            from start: SIMD3<Float>,
            to end: SIMD3<Float>,
            thickness: Float,
            material: UnlitMaterial
        ) {
            let dir = end - start
            let len = simd_length(dir)
            guard len > 0.0001 else { return }
            
            let edge = Entity()
            edge.components.set(
                ModelComponent(
                    mesh: MeshResource.generateBox(size: [len, thickness, thickness]),
                    materials: [material]
                )
            )
            edge.position = (start + end) * 0.5
            edge.orientation = simd_quatf(from: SIMD3<Float>(1, 0, 0), to: simd_normalize(dir))
            parent.addChild(edge)
        }
        
        private func clearHighlights() {
            for (_, entity) in highlightEntities { entity.removeFromParent() }
            highlightEntities.removeAll()
        }
        
        private func addFolderHighlight(for folderID: UUID) {
            guard let folderEntity = folderEntities[folderID] else { return }
            folderHighlightEntities[folderID]?.removeFromParent()
            
            let ring = Entity()
            ring.name = "FolderHighlight_\(folderID.uuidString)"
            var mat = UnlitMaterial()
            mat.color = .init(tint: UIColor(red: 0.18, green: 0.74, blue: 1.0, alpha: 0.9))
            let mesh = MeshResource.generatePlane(width: 0.14, height: 0.14)
            ring.components.set(ModelComponent(mesh: mesh, materials: [mat]))
            ring.position = [0, 0, -0.003]
            folderEntity.addChild(ring)
            folderHighlightEntities[folderID] = ring
        }
        
        private func clearFolderHighlights() {
            for (_, entity) in folderHighlightEntities { entity.removeFromParent() }
            folderHighlightEntities.removeAll()
        }
        
        private func updateFolderTargetGlow(_ folderID: UUID?) {
            if activeFolderTargetGlowID == folderID { return }
            clearFolderTargetGlow()
            guard let folderID,
                  let folderEntity = folderEntities[folderID] else { return }
            let glow = Entity()
            glow.name = "FolderTargetGlow_\(folderID.uuidString)"
            var mat = UnlitMaterial()
            mat.color = .init(tint: UIColor(red: 0.35, green: 0.88, blue: 1.0, alpha: 0.32))
            let mesh = MeshResource.generatePlane(width: 0.165, height: 0.165)
            glow.components.set(ModelComponent(mesh: mesh, materials: [mat]))
            glow.position = [0, 0, -0.006]
            folderEntity.addChild(glow)
            folderTargetGlowEntities[folderID] = glow
            activeFolderTargetGlowID = folderID
            lastAbsorptionFolderID = folderID
        }
        
        private func clearFolderTargetGlow() {
            for (_, entity) in folderTargetGlowEntities { entity.removeFromParent() }
            folderTargetGlowEntities.removeAll()
            activeFolderTargetGlowID = nil
            lastAbsorptionFolderID = nil
        }
        
        private func bestAbsorptionFolderID() -> UUID? {
            let folderAbsorptionRadius3D: Float = 0.125
            let folderAbsorptionRadiusWeighted: Float = 0.090
            var bestID: UUID?
            var bestScore: Float = .greatestFiniteMagnitude
            
            let folderDesc = FetchDescriptor<SpatialFolder>()
            guard let folders = try? modelContext.fetch(folderDesc) else { return nil }
            for folder in folders {
                guard folder.spaceID == appState.activeSpaceID,
                      let folderEntity = folderEntities[folder.id],
                      !appState.selectedFolderIDs.contains(folder.id) else { continue }
                let folderPos = folderEntity.position(relativeTo: nil)
                
                var nearest3D: Float = .greatestFiniteMagnitude
                var nearestWeighted: Float = .greatestFiniteMagnitude
                for id in appState.selectedStrokeIDs {
                    guard let strokeEntity = strokeEntities[id] else { continue }
                    let baseCentroid = strokeMoveBaseCentroids[id] ?? .zero
                    let p = strokeEntity.position(relativeTo: nil) + strokeEntity.orientation(relativeTo: nil).act(baseCentroid)
                    let d = p - folderPos
                    let d3 = simd_length(d)
                    let dw = sqrt(d.x * d.x + d.y * d.y + (d.z * 0.35) * (d.z * 0.35))
                    nearest3D = min(nearest3D, d3)
                    nearestWeighted = min(nearestWeighted, dw)
                }
                
                let score = min(nearest3D / folderAbsorptionRadius3D, nearestWeighted / folderAbsorptionRadiusWeighted)
                if score < 1.0, score < bestScore {
                    bestScore = score
                    bestID = folder.id
                }
            }
            return bestID
        }
        
        // MARK: - Fist Move (Billboard)
        
        private func handleFistMove(rawPoint2D: CGPoint, fist3D: SIMD3<Float>) {
            if appState.selectedStrokeIDs.isEmpty && appState.selectedFolderIDs.isEmpty {
                handleFolderFistMove(fist3D: fist3D)
                return
            }

            guard !(appState.selectedStrokeIDs.isEmpty && appState.selectedFolderIDs.isEmpty),
                  appState.selectionState == .selected || appState.selectionState == .moving
            else { return }
            
            if appState.selectionState == .selected {
                // First move frame: snap selected content directly to palm.
                appState.selectionState = .moving
                strokeMoveOffsets.removeAll()
                folderMoveOffsets.removeAll()
                strokeMoveBaseCentroids.removeAll()
                folderMoveBasePositions.removeAll()
                strokeMoveBaseRotations.removeAll()
                strokeMoveBaseTransforms.removeAll()
                movePalmLeftOffset = .zero
                appState.debugMoveOverlayEnabled = true
                ARSessionManager.shared.resetMoveTrackingForFreshSession()
                // Re-lock move plane to current selection so the palm projects into the same world plane.
                let strokeDesc = FetchDescriptor<SpatialStroke>()
                let strokes = (try? modelContext.fetch(strokeDesc)) ?? []
                let strokesByID = Dictionary(uniqueKeysWithValues: strokes.map { ($0.id, $0) })
                updateSelectionCentroid(
                    strokesByID: strokesByID,
                    selectedStrokeIDs: appState.selectedStrokeIDs,
                    selectedFolderIDs: appState.selectedFolderIDs
                )
                updateSelectionMovePlane(strokesByID: strokesByID, selectedStrokeIDs: appState.selectedStrokeIDs)
                let planePoint = ARSessionManager.shared.projectToPlane(
                    normalizedPoint: rawPoint2D,
                    planeCenter: selectionMovePlaneCenter,
                    planeNormal: selectionMovePlaneNormal
                )
                let depthPoint = ARSessionManager.shared.clusterSampleWorldPosition(from: rawPoint2D)
                    ?? ARSessionManager.shared.raycastHandLandmarkDepthAware(normalizedPoint: rawPoint2D)
                updateMoveDebugOverlay(rawPoint2D: rawPoint2D, planePoint: planePoint, depthPoint: depthPoint)

                let accuratePalm = depthPoint
                    ?? planePoint
                    ?? fist3D
                lastMovePalmPosition = accuratePalm

                // Capture per-item offsets relative to the selection centroid.
                for id in appState.selectedStrokeIDs {
                    guard let stroke = strokesByID[id], !stroke.points.isEmpty else { continue }
                    let centroid = stroke.points.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(stroke.points.count)
                    strokeMoveBaseCentroids[id] = centroid
                    strokeMoveOffsets[id] = centroid - selectionCentroid
                    strokeMoveBaseRotations[id] = computeBillboardOrientation(atWorldPosition: centroid)
                    if let entity = strokeEntities[id] {
                        strokeMoveBaseTransforms[id] = entity.transform
                    }
                }
                for id in appState.selectedFolderIDs {
                    if let entity = folderEntities[id] {
                        let pos = entity.position(relativeTo: nil)
                        folderMoveBasePositions[id] = pos
                        folderMoveOffsets[id] = pos - selectionCentroid
                    }
                }

                for id in appState.selectedStrokeIDs {
                    guard let entity = strokeEntities[id],
                          let baseCentroid = strokeMoveBaseCentroids[id],
                          let offset = strokeMoveOffsets[id] else { continue }
                    
                    let targetCentroid = accuratePalm + movePalmLeftOffset + offset
                    let currentBillboardQuat = computeBillboardOrientation(atWorldPosition: targetCentroid)
                    let baseBillboardQuat = strokeMoveBaseRotations[id] ?? currentBillboardQuat
                    let deltaQuat = currentBillboardQuat * baseBillboardQuat.inverse
                    
                    let rotatedBaseCentroid = deltaQuat.act(baseCentroid)
                    let newOrigin = targetCentroid - rotatedBaseCentroid
                    
                    entity.setPosition(newOrigin, relativeTo: nil)
                    entity.setOrientation(deltaQuat, relativeTo: nil)
                }
                for id in appState.selectedFolderIDs {
                    guard let entity = folderEntities[id],
                          let offset = folderMoveOffsets[id] else { continue }
                    entity.setPosition(accuratePalm + movePalmLeftOffset + offset, relativeTo: nil)
                }
            }
            
            let planePoint = ARSessionManager.shared.projectToPlane(
                normalizedPoint: rawPoint2D,
                planeCenter: selectionMovePlaneCenter,
                planeNormal: selectionMovePlaneNormal
            )
            let depthPoint = ARSessionManager.shared.clusterSampleWorldPosition(from: rawPoint2D)
                ?? ARSessionManager.shared.raycastHandLandmarkDepthAware(normalizedPoint: rawPoint2D)
            updateMoveDebugOverlay(rawPoint2D: rawPoint2D, planePoint: planePoint, depthPoint: depthPoint)

            let accuratePalm = depthPoint
                ?? planePoint
                ?? fist3D

            // Palm-locked move: follow the latest palm projection directly.
            let trackedPalm = accuratePalm
            lastMovePalmPosition = trackedPalm
            
            var activeDeltaQuat = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            for id in appState.selectedStrokeIDs {
                guard let entity = strokeEntities[id],
                    let baseCentroid = strokeMoveBaseCentroids[id],
                    let offset = strokeMoveOffsets[id] else { continue }

                let targetCentroid = trackedPalm + movePalmLeftOffset + offset
                let currentBillboardQuat = computeBillboardOrientation(atWorldPosition: targetCentroid)
                let baseBillboardQuat = strokeMoveBaseRotations[id] ?? currentBillboardQuat
                let deltaQuat = currentBillboardQuat * baseBillboardQuat.inverse
                activeDeltaQuat = deltaQuat
                
                let rotatedBaseCentroid = deltaQuat.act(baseCentroid)
                let newOrigin = targetCentroid - rotatedBaseCentroid
                
                entity.setPosition(newOrigin, relativeTo: nil)
                entity.setOrientation(deltaQuat, relativeTo: nil)
            }
            for id in appState.selectedFolderIDs {
                guard let entity = folderEntities[id],
                      let offset = folderMoveOffsets[id] else { continue }
                // Folder visuals already billboard themselves.
                entity.setPosition(trackedPalm + movePalmLeftOffset + offset, relativeTo: nil)
            }
            
            // Update selection box
            let movementVector = (trackedPalm + movePalmLeftOffset) - selectionCentroid
            let rotatedLeftOffset = activeDeltaQuat.act(selectionCorner3DLeft - selectionCentroid)
            let rotatedRightOffset = activeDeltaQuat.act(selectionCorner3DRight - selectionCentroid)
            
            let newLeft3D = selectionCentroid + movementVector + rotatedLeftOffset
            let newRight3D = selectionCentroid + movementVector + rotatedRightOffset
            appState.selectionCornerLeft = newLeft3D
            appState.selectionCornerRight = newRight3D
            
            if let arView = self.arView {
                if let pLeft = arView.project(newLeft3D) {
                    appState.selectionCornerLeftScreen = CGPoint(x: CGFloat(pLeft.x), y: CGFloat(pLeft.y))
                }
                if let pRight = arView.project(newRight3D) {
                    appState.selectionCornerRightScreen = CGPoint(x: CGFloat(pRight.x), y: CGFloat(pRight.y))
                }
            }
            
            // Live visual confirmation that drop will absorb into a folder.
            updateFolderTargetGlow(bestAbsorptionFolderID())
        }

        private func getAccuratePalmPosition(fist3D: SIMD3<Float>) -> SIMD3<Float> {
            #if !targetEnvironment(simulator)
            guard let arView = arView,
                  let frame = ARSessionManager.shared.session.currentFrame,
                  let projected = arView.project(fist3D) else {
                return fist3D
            }

            let projectedPoint = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
            let offsets: [CGPoint] = [
                .zero,
                CGPoint(x: 10, y: 0),
                CGPoint(x: -10, y: 0),
                CGPoint(x: 0, y: 10),
                CGPoint(x: 0, y: -10)
            ]

            var minDepth: Float = .greatestFiniteMagnitude
            for offset in offsets {
                let samplePoint = CGPoint(x: projectedPoint.x + offset.x, y: projectedPoint.y + offset.y)
                if let depth = ARSessionManager.shared.sampleDepthAtScreenPoint(samplePoint),
                   depth.isFinite,
                   depth > 0.08 && depth < 2.5,
                   depth < minDepth {
                    minDepth = depth
                }
            }

            if minDepth < .greatestFiniteMagnitude {
                return ARSessionManager.shared.projectToWorldPublic(
                    screenPoint: projectedPoint,
                    depth: minDepth,
                    frame: frame,
                    viewSize: arView.bounds.size
                )
            }

            return fist3D
            #else
            return fist3D
            #endif
        }

        private func handleFolderFistMove(fist3D: SIMD3<Float>) {
            guard let folderID = hoveredFolderID,
                  let entity = folderEntities[folderID] else { return }

            if folderMoveOrigin == nil {
                folderMoveOrigin = fist3D
                folderMoveStartPos = entity.position(relativeTo: nil)
                folderMoveActiveID = folderID
            }

            guard let origin = folderMoveOrigin,
                  let startPos = folderMoveStartPos else { return }

            let delta = fist3D - origin
            entity.setPosition(startPos + delta, relativeTo: nil)
        }
        
        private func handleFistMoveEnded() {
            if appState.selectionState != .moving {
                clearFolderTargetGlow()
                if let folderID = folderMoveActiveID,
                   let entity = folderEntities[folderID] {
                    persistFolderTransform(for: folderID, entity: entity)
                }
                folderMoveOrigin = nil
                folderMoveStartPos = nil
                folderMoveActiveID = nil
                return
            }
            appState.selectionState = .selected
            clearFolderTargetGlow()
            lastMovePalmPosition = nil
            movePalmLeftOffset = .zero
            clearMoveDebugOverlay()
            
            // Check if strokes were dropped near a folder — absorption
            let folderAbsorptionRadius3D: Float = 0.135 // more forgiving drop radius
            let folderAbsorptionRadiusWeighted: Float = 0.096 // weighted threshold for depth-tolerant matching
            var absorbedByFolder: SpatialFolder? = nil

            // If we had a live target glow, trust it to avoid edge-case misses on release.
            if let candidateID = lastAbsorptionFolderID,
               let folderEntity = folderEntities[candidateID] {
                let folderDesc = FetchDescriptor<SpatialFolder>(
                    predicate: #Predicate { $0.id == candidateID }
                )
                if let folder = (try? modelContext.fetch(folderDesc))?.first,
                   !appState.selectedFolderIDs.contains(folder.id),
                   folder.spaceID == appState.activeSpaceID {
                    let folderPos = folderEntity.position(relativeTo: nil)
                    absorbStrokes(appState.selectedStrokeIDs, into: folder, folderEntity: folderEntity, folderPos: folderPos)
                    absorbedByFolder = folder
                }
            }
            
            // Find the centroid of the moved selection
            var movedCentroid = SIMD3<Float>.zero
            var count: Float = 0
            for id in appState.selectedStrokeIDs {
                if let entity = strokeEntities[id] {
                    movedCentroid += entity.position(relativeTo: nil)
                    count += 1
                }
            }
            for id in appState.selectedFolderIDs {
                if let entity = folderEntities[id] {
                    movedCentroid += entity.position(relativeTo: nil)
                    count += 1
                }
            }
            if count > 0 { movedCentroid /= count }
            
            // Check each folder for proximity (if no glow-based absorption)
            if count > 0, absorbedByFolder == nil {
                let folderDesc = FetchDescriptor<SpatialFolder>()
                if let folders = try? modelContext.fetch(folderDesc) {
                    for folder in folders {
                        guard folder.spaceID == appState.activeSpaceID,
                              let folderEntity = folderEntities[folder.id] else { continue }
                        // Never absorb into a folder that is part of the current selection.
                        if appState.selectedFolderIDs.contains(folder.id) { continue }
                        let folderPos = folderEntity.position(relativeTo: nil)
                        
                        // Smart proximity: use nearest selected stroke to folder and depth-tolerant weighting.
                        var nearestStrokeDist3D: Float = .greatestFiniteMagnitude
                        var nearestStrokeDistWeighted: Float = .greatestFiniteMagnitude
                        for id in appState.selectedStrokeIDs {
                            guard let strokeEntity = strokeEntities[id] else { continue }
                            let baseCentroid = strokeMoveBaseCentroids[id] ?? .zero
                            let p = strokeEntity.position(relativeTo: nil) + strokeEntity.orientation(relativeTo: nil).act(baseCentroid)
                            let delta = p - folderPos
                            let d3 = simd_length(delta)
                            let dWeighted = sqrt(delta.x * delta.x + delta.y * delta.y + (delta.z * 0.35) * (delta.z * 0.35))
                            nearestStrokeDist3D = min(nearestStrokeDist3D, d3)
                            nearestStrokeDistWeighted = min(nearestStrokeDistWeighted, dWeighted)
                        }
                        
                        // Fallback to centroid if we somehow have no stroke entities.
                        let centroidDelta = movedCentroid - folderPos
                        let centroidDist3D = simd_length(centroidDelta)
                        let centroidDistWeighted = sqrt(centroidDelta.x * centroidDelta.x + centroidDelta.y * centroidDelta.y + (centroidDelta.z * 0.35) * (centroidDelta.z * 0.35))
                        let best3D = min(nearestStrokeDist3D, centroidDist3D)
                        let bestWeighted = min(nearestStrokeDistWeighted, centroidDistWeighted)
                        
                        if best3D < folderAbsorptionRadius3D || bestWeighted < folderAbsorptionRadiusWeighted {
                            absorbedByFolder = folder
                            // Absorb strokes into this folder
                            absorbStrokes(appState.selectedStrokeIDs, into: folder, folderEntity: folderEntity, folderPos: folderPos)
                            break
                        }
                    }
                }
            }
            
            strokeMoveOffsets.removeAll()
            folderMoveOffsets.removeAll()
            strokeMoveBaseCentroids.removeAll()
            folderMoveBasePositions.removeAll()
            strokeMoveBaseRotations.removeAll()
            strokeMoveBaseTransforms.removeAll()
            
            if absorbedByFolder == nil {
                // Normal position lock
                persistMovedStrokes()
                persistMovedFolders()
            }
        }

        private func updateMoveDebugOverlay(rawPoint2D: CGPoint, planePoint: SIMD3<Float>?, depthPoint: SIMD3<Float>?) {
            guard appState.debugMoveOverlayEnabled,
                  let arView = arView else {
                return
            }

            if let frame = ARSessionManager.shared.session.currentFrame {
                appState.debugPalmScreenRaw = visionNormalizedToScreen(rawPoint2D, frame: frame, viewSize: arView.bounds.size)
            } else {
                appState.debugPalmScreenRaw = CGPoint(
                    x: rawPoint2D.x * arView.bounds.size.width,
                    y: (1.0 - rawPoint2D.y) * arView.bounds.size.height
                )
            }
            if appState.debugPalmScreenRaw == nil {
                appState.debugPalmScreenRaw = CGPoint(
                    x: rawPoint2D.x * arView.bounds.size.width,
                    y: (1.0 - rawPoint2D.y) * arView.bounds.size.height
                )
            }
            if let planePoint, let projected = arView.project(planePoint) {
                appState.debugPalmScreenPlane = CGPoint(x: projected.x, y: projected.y)
            } else {
                appState.debugPalmScreenPlane = nil
            }
            if let depthPoint, let projected = arView.project(depthPoint) {
                appState.debugPalmScreenDepth = CGPoint(x: projected.x, y: projected.y)
            } else {
                appState.debugPalmScreenDepth = nil
            }
        }

        private func clearMoveDebugOverlay() {
            appState.debugPalmScreenRaw = nil
            appState.debugPalmScreenPlane = nil
            appState.debugPalmScreenDepth = nil
        }
        
        /// Absorbs the given stroke IDs into a folder with spring animation.
        private func absorbStrokes(_ ids: Set<UUID>, into folder: SpatialFolder, folderEntity: Entity, folderPos: SIMD3<Float>) {
            let strokeDesc = FetchDescriptor<SpatialStroke>()
            guard let allStrokes = try? modelContext.fetch(strokeDesc) else { return }
            
            for id in ids {
                guard let entity = strokeEntities[id],
                      let stroke = allStrokes.first(where: { $0.id == id }) else { continue }
                
                stroke.folderID = folder.id
                
                // SwiftData array mutation safety
                if !folder.containedStrokeIDs.contains(id) {
                    var newIDs = folder.containedStrokeIDs
                    newIDs.append(id)
                    folder.containedStrokeIDs = newIDs
                }
                
                if folder.isOpen {
                    // If dropping into an OPEN folder, the stroke simply joins the folder's floating cluster.
                    // We record its current unbaked drop position.
                    stroke.previousWorldTransform = entity.transformMatrix(relativeTo: nil)
                    stroke.previousPosition = entity.position(relativeTo: nil)
                    stroke.previousOrientation = entity.orientation(relativeTo: nil)
                    stroke.previousScale = entity.scale.x
                } else {
                    // If dropping into a CLOSED folder, we save the transform from BEFORE the move,
                    // so that when the folder is later opened, the stroke flies back to where it came from.
                    let baseT = strokeMoveBaseTransforms[id] ?? Transform()
                    stroke.previousWorldTransform = baseT.matrix
                    stroke.previousPosition = baseT.translation
                    stroke.previousOrientation = baseT.rotation
                    stroke.previousScale = baseT.scale.x
                    
                    // Get centroid to accurately target the visual center of the stroke to the folder
                    let centroid = stroke.points.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(max(1, stroke.points.count))
                    
                    // Animate shrink into folder
                    var shrinkT = Transform()
                    shrinkT.translation = folderPos - shrinkT.rotation.act(centroid * 0.05)
                    shrinkT.scale = SIMD3<Float>(repeating: 0.05)
                    entity.move(to: shrinkT, relativeTo: nil, duration: 0.35, timingFunction: .easeIn)
                    
                    Task {
                        try? await Task.sleep(nanoseconds: 380_000_000)
                        await MainActor.run { entity.isEnabled = false }
                    }
                }
            }
            
            try? modelContext.save()
            clearSelection()
            appState.folderTransitionStatus = "Moved"
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 950_000_000)
                guard let self else { return }
                if self.appState.folderTransitionStatus == "Moved" {
                    self.appState.folderTransitionStatus = ""
                }
            }
            
            // Haptic: double tap feel
            #if !targetEnvironment(simulator)
            let gen = UINotificationFeedbackGenerator()
            gen.notificationOccurred(.success)
            #endif
        }
        
        private func persistMovedStrokes() {
            for id in appState.selectedStrokeIDs {
                guard let entity = strokeEntities[id] else { continue }
                let newPos = entity.position(relativeTo: nil)
                let orientation = entity.orientation(relativeTo: nil)
                let desc = FetchDescriptor<SpatialStroke>(predicate: #Predicate { $0.id == id })
                if let stroke = (try? modelContext.fetch(desc))?.first {
                    // Persist full rigid transform (rotation + translation), so erase/hit logic
                    // stays aligned with what's rendered after moving/billboarding.
                    let originalCentroid = stroke.points.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(stroke.points.count)
                    for i in stroke.points.indices {
                        let local = stroke.points[i].position - originalCentroid
                        let rotated = orientation.act(local)
                        stroke.points[i] = StrokePoint(
                            position: newPos + rotated,
                            pressure: stroke.points[i].pressure,
                            timestamp: stroke.points[i].timestamp
                        )
                    }
                }
            }
            try? modelContext.save()
        }
        
        private func persistMovedFolders() {
            for id in appState.selectedFolderIDs {
                guard let entity = folderEntities[id] else { continue }
                persistFolderTransform(for: id, entity: entity)
            }
        }
        
        // MARK: - Three-Finger Resize (Center Scale)
        
        private func handleThreeFingerResize(scaleDelta: Float) {
            if appState.selectedStrokeIDs.isEmpty && appState.selectedFolderIDs.isEmpty {
                handleFolderResize(scaleDelta: scaleDelta)
                return
            }
            guard !(appState.selectedStrokeIDs.isEmpty && appState.selectedFolderIDs.isEmpty),
                  appState.selectionState == .selected || appState.selectionState == .resizing
            else { return }
            appState.selectionState = .resizing
            
            for id in appState.selectedStrokeIDs {
                guard let entity = strokeEntities[id] else { continue }
                let pos = entity.position(relativeTo: nil)
                // Move entity toward/away from centroid by scaleDelta
                let vecFromCentroid = pos - selectionCentroid
                entity.setPosition(selectionCentroid + vecFromCentroid * scaleDelta, relativeTo: nil)
                // Scale the entity geometry
                entity.scale *= SIMD3<Float>(repeating: scaleDelta)
            }
            for id in appState.selectedFolderIDs {
                guard let entity = folderEntities[id] else { continue }
                entity.scale *= SIMD3<Float>(repeating: scaleDelta)
            }
        }

        private func handleFolderResize(scaleDelta: Float) {
            guard let folderID = hoveredFolderID,
                  let entity = folderEntities[folderID] else { return }
            folderResizeActiveID = folderID
            entity.scale *= SIMD3<Float>(repeating: scaleDelta)
        }
        
        private func persistResizedStrokes() {
            if appState.selectionState != .resizing {
                if let folderID = folderResizeActiveID,
                   let entity = folderEntities[folderID] {
                    persistFolderTransform(for: folderID, entity: entity)
                }
                folderResizeActiveID = nil
                return
            }
            appState.selectionState = .selected
            
            for id in appState.selectedStrokeIDs {
                guard let entity = strokeEntities[id] else { continue }
                let entityScale = entity.scale.x
                let desc = FetchDescriptor<SpatialStroke>(predicate: #Predicate { $0.id == id })
                if let stroke = (try? modelContext.fetch(desc))?.first {
                    let oldCentroid = stroke.points.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(stroke.points.count)
                    for i in stroke.points.indices {
                        let localPos = stroke.points[i].position - oldCentroid
                        stroke.points[i] = StrokePoint(
                            position: selectionCentroid + localPos * entityScale,
                            pressure: stroke.points[i].pressure,
                            timestamp: stroke.points[i].timestamp
                        )
                    }
                }
            }
            for id in appState.selectedFolderIDs {
                if let entity = folderEntities[id] {
                    persistFolderTransform(for: id, entity: entity)
                }
            }
            try? modelContext.save()
        }
        
        // MARK: - Deselect
        
        private func clearSelection() {
            clearHighlights()
            selectionRectEntity?.removeFromParent()
            selectionRectEntity = nil
            appState.selectedStrokeIDs.removeAll()
            appState.selectedFolderIDs.removeAll()
            appState.selectionState = .idle
            appState.selectionCornerLeft  = nil
            appState.selectionCornerRight = nil
            appState.selectionCornerLeftScreen = nil
            appState.selectionCornerRightScreen = nil
            lastMovePalmPosition = nil
            movePalmLeftOffset = .zero
            strokeMoveOffsets.removeAll()
            folderMoveOffsets.removeAll()
            strokeMoveBaseCentroids.removeAll()
            folderMoveBasePositions.removeAll()
            strokeMoveBaseRotations.removeAll()
            strokeMoveBaseTransforms.removeAll()
            clearFolderHighlights()
            clearFolderTargetGlow()
            selectionPlaneInitialized = false
            selectionMovePlaneCenter = .zero
            selectionMovePlaneNormal = SIMD3<Float>(0, 0, 1)
            clearMoveDebugOverlay()
            
            #if !targetEnvironment(simulator)
            let gen = UIImpactFeedbackGenerator(style: .light)
            gen.impactOccurred()
            #endif
        }
        
        // MARK: - Centroid Helper
        
        private func updateSelectionCentroid(
            strokesByID: [UUID: SpatialStroke],
            selectedStrokeIDs: Set<UUID>,
            selectedFolderIDs: Set<UUID>
        ) {
            var sum = SIMD3<Float>.zero
            var count: Float = 0

            for id in selectedStrokeIDs {
                if let stroke = strokesByID[id], !stroke.points.isEmpty {
                    let centroid = stroke.points.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(stroke.points.count)
                    sum += centroid
                    count += 1
                }
            }

            for id in selectedFolderIDs {
                if let entity = folderEntities[id] {
                    sum += entity.position(relativeTo: nil)
                    count += 1
                }
            }

            selectionCentroid = count > 0 ? sum / count : .zero
        }

        private func updateSelectionMovePlane(strokesByID: [UUID: SpatialStroke], selectedStrokeIDs: Set<UUID>) {
            selectionMovePlaneCenter = selectionCentroid
            if let estimated = estimateSelectionPlaneNormal(strokesByID: strokesByID, selectedStrokeIDs: selectedStrokeIDs) {
                selectionMovePlaneNormal = estimated
                return
            }
            let fallback = ARSessionManager.shared.drawingPlaneNormal
            selectionMovePlaneNormal = simd_length(fallback) > 0.001 ? simd_normalize(fallback) : SIMD3<Float>(0, 0, 1)
        }

        private func estimateSelectionPlaneNormal(strokesByID: [UUID: SpatialStroke], selectedStrokeIDs: Set<UUID>) -> SIMD3<Float>? {
            for id in selectedStrokeIDs {
                guard let stroke = strokesByID[id], stroke.points.count >= 3 else { continue }
                let points = stroke.points
                let p0 = points[0].position
                let p1 = points[points.count / 2].position
                let p2 = points[points.count - 1].position
                let v1 = p1 - p0
                let v2 = p2 - p0
                let cross = simd_cross(v1, v2)
                if simd_length(cross) > 0.0005 {
                    return simd_normalize(cross)
                }
            }
            return nil
        }
        
        /// Compute the billboard orientation quaternion for a given world position
        /// without applying it to any entity. Used by move code to compensate
        /// for world-space vertex rotation.
        private func computeBillboardOrientation(atWorldPosition worldPos: SIMD3<Float>) -> simd_quatf {
            let cam = ARSessionManager.shared.cameraTransform
            let camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
            let worldUp = SIMD3<Float>(0, 1, 0)
            
            let toCamera = camPos - worldPos
            guard simd_length(toCamera) > 0.001 else { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
            let dir = simd_normalize(toCamera)
            let horizontal = SIMD3<Float>(dir.x, 0, dir.z)
            guard simd_length(horizontal) > 0.001 else { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
            let h = simd_normalize(horizontal)
            
            let yaw = atan2(h.x, h.z)
            let verticalAngle = atan2(dir.y, simd_length(horizontal))
            let pitch = max(-billboardMaxTilt, min(billboardMaxTilt, verticalAngle * billboardTiltFactor))
            
            let yawRot = simd_quatf(angle: yaw, axis: worldUp)
            let pitchAxis = simd_act(yawRot, SIMD3<Float>(1, 0, 0))
            let pitchRot = simd_quatf(angle: pitch, axis: pitchAxis)
            return pitchRot * yawRot
        }

        private func applyStrokeBillboard(to entity: Entity, atWorldPosition worldPos: SIMD3<Float>) {
            entity.setOrientation(computeBillboardOrientation(atWorldPosition: worldPos), relativeTo: nil)
        }
        
        private func visionNormalizedToScreen(_ point: CGPoint, frame: ARFrame, viewSize: CGSize) -> CGPoint {
            let interfaceOrientation = arView?.window?.windowScene?.interfaceOrientation ?? .portrait
            let displayTransform = frame.displayTransform(for: interfaceOrientation, viewportSize: viewSize)
            let normalizedImagePoint = CGPoint(x: point.x, y: 1.0 - point.y)
            let transformed = normalizedImagePoint.applying(displayTransform)
            return CGPoint(x: transformed.x * viewSize.width, y: transformed.y * viewSize.height)
        }
        
        private func entityIntersectsScreenRect(entity: Entity, screenRect: CGRect, in arView: ARView) -> Bool {
            if let center = arView.project(entity.position(relativeTo: nil)), screenRect.contains(center) {
                return true
            }
            let bounds = entity.visualBounds(relativeTo: nil)
            let c = bounds.center
            let e = bounds.extents * 0.5
            let corners: [SIMD3<Float>] = [
                c + SIMD3<Float>(-e.x, -e.y, -e.z), c + SIMD3<Float>(-e.x, -e.y,  e.z),
                c + SIMD3<Float>(-e.x,  e.y, -e.z), c + SIMD3<Float>(-e.x,  e.y,  e.z),
                c + SIMD3<Float>( e.x, -e.y, -e.z), c + SIMD3<Float>( e.x, -e.y,  e.z),
                c + SIMD3<Float>( e.x,  e.y, -e.z), c + SIMD3<Float>( e.x,  e.y,  e.z)
            ]
            var minX: CGFloat = .infinity
            var minY: CGFloat = .infinity
            var maxX: CGFloat = -.infinity
            var maxY: CGFloat = -.infinity
            var any = false
            for p in corners {
                if let s = arView.project(p) {
                    any = true
                    minX = min(minX, s.x); minY = min(minY, s.y)
                    maxX = max(maxX, s.x); maxY = max(maxY, s.y)
                }
            }
            guard any else { return false }
            let projectedRect = CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
            return projectedRect.intersects(screenRect)
        }
        
        // MARK: - Folder Interaction
        
        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let arView = arView else { return }
            
            let location = gesture.location(in: arView)
            let results = arView.hitTest(location)
            
            for result in results {
                if result.entity.name.hasPrefix("Folder_") {
                    let idString = String(result.entity.name.dropFirst(7))
                    if let id = UUID(uuidString: idString) {
                        toggleFolder(id: id, entity: result.entity)
                        break
                    }
                }
            }
        }
        
        /// Toggle a folder open/closed with spring animation.
        /// OPEN  → strokes animate from folder center back to their previousPosition.
        /// CLOSE → strokes animate to folder center, then hide.
        private func toggleFolder(id: UUID, entity: Entity) {
            let descriptor = FetchDescriptor<SpatialFolder>(
                predicate: #Predicate { $0.id == id }
            )
            guard let folder = (try? modelContext.fetch(descriptor))?.first else { return }
            
            let folderWorldPos = entity.position(relativeTo: nil)
            folder.isOpen.toggle()
            try? modelContext.save()

            if folder.isOpen {
                // OPENING: fetch contained strokes, show them at previousPosition
                openFolder(folder: folder, folderEntity: entity, folderWorldPos: folderWorldPos)
            } else {
                // CLOSING: animate strokes back to folder, then hide
                closeFolder(folder: folder, folderEntity: entity, folderWorldPos: folderWorldPos)
            }
        }

        private func toggleFolderForHover(id: UUID, entity: Entity) {
            let descriptor = FetchDescriptor<SpatialFolder>(
                predicate: #Predicate { $0.id == id }
            )
            guard let folder = (try? modelContext.fetch(descriptor))?.first else { return }

            let folderWorldPos = entity.position(relativeTo: nil)
            let wasOpen = folder.isOpen
            appState.folderTransitionStatus = wasOpen ? "Closing..." : "Opening..."
            folder.isOpen.toggle()
            try? modelContext.save()

            if folder.isOpen {
                openFolder(folder: folder, folderEntity: entity, folderWorldPos: folderWorldPos)
            } else {
                closeFolder(folder: folder, folderEntity: entity, folderWorldPos: folderWorldPos)
            }
            
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 950_000_000)
                self?.appState.folderTransitionStatus = wasOpen ? "Closed" : "Opened"
                try? await Task.sleep(nanoseconds: 850_000_000)
                self?.appState.folderTransitionStatus = ""
            }
        }
        
        private func openFolder(folder: SpatialFolder, folderEntity: Entity, folderWorldPos: SIMD3<Float>) {
            let strokeDesc = FetchDescriptor<SpatialStroke>()
            guard let allStrokes = try? modelContext.fetch(strokeDesc) else { return }
            let containedStrokes = allStrokes.filter { folder.containedStrokeIDs.contains($0.id) }
            
            // Scale up folder entity slightly for "open" feel
            var openTransform = folderEntity.transform
            openTransform.scale = SIMD3<Float>(repeating: 1.15)
            folderEntity.move(to: openTransform, relativeTo: folderEntity.parent,
                              duration: 0.25, timingFunction: .easeOut)
            
            for stroke in containedStrokes {
                let targetPos = stroke.previousPosition ?? folderWorldPos
                let targetRot = stroke.previousOrientation ?? simd_quatf()
                let targetScale = max(stroke.previousScale, 0.05)
                
                // Create or reuse entity, start at folder center, tiny scale
                let entity: Entity
                if let existing = strokeEntities[stroke.id] {
                    entity = existing
                } else {
                    entity = createStrokeEntity(from: stroke)
                    strokesAnchor?.addChild(entity)
                    strokeEntities[stroke.id] = entity
                }
                
                // Get centroid to start the visual center of the stroke at the folder
                let centroid = stroke.points.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(max(1, stroke.points.count))
                
                // Start hidden at folder position (compensating for centroid)
                entity.isEnabled = true
                entity.scale = SIMD3<Float>(repeating: 0.05)
                entity.setOrientation(targetRot, relativeTo: nil)
                entity.setPosition(folderWorldPos - targetRot.act(centroid * 0.05), relativeTo: nil)
                
                // Animate to previous world position with spring
                let destTransform: Transform
                if let saved = stroke.previousWorldTransform {
                    destTransform = Transform(matrix: saved)
                } else {
                    var t = Transform()
                    t.translation = targetPos
                    t.rotation = targetRot
                    t.scale = SIMD3<Float>(repeating: targetScale)
                    destTransform = t
                }
                entity.move(to: destTransform, relativeTo: nil,
                            duration: 0.5, timingFunction: .easeOut)
            }
            
            // Haptic
            #if !targetEnvironment(simulator)
            let gen = UIImpactFeedbackGenerator(style: .medium)
            gen.impactOccurred()
            #endif
        }
        
        private func closeFolder(folder: SpatialFolder, folderEntity: Entity, folderWorldPos: SIMD3<Float>) {
            // Scale folder back to normal
            var closedTransform = folderEntity.transform
            closedTransform.scale = SIMD3<Float>(repeating: 1.0)
            folderEntity.move(to: closedTransform, relativeTo: folderEntity.parent,
                              duration: 0.25, timingFunction: .easeIn)

            // Persist the current visible layout before closing so reopening restores faithfully.
            let strokeDesc = FetchDescriptor<SpatialStroke>()
            guard let allStrokes = try? modelContext.fetch(strokeDesc) else { return }
            let strokesByID = Dictionary(uniqueKeysWithValues: allStrokes.map { ($0.id, $0) })
            
            for id in folder.containedStrokeIDs {
                guard let stroke = strokesByID[id],
                      let entity = strokeEntities[id] else { continue }
                stroke.previousWorldTransform = entity.transformMatrix(relativeTo: nil)
                stroke.previousPosition = entity.position(relativeTo: nil)
                stroke.previousOrientation = entity.orientation(relativeTo: nil)
                stroke.previousScale = entity.scale.x
            }
            try? modelContext.save()
            
            for id in folder.containedStrokeIDs {
                guard let entity = strokeEntities[id],
                      let stroke = strokesByID[id] else { continue }
                
                // Get centroid to accurately shrink the visual center of the stroke to the folder
                let centroid = stroke.points.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(max(1, stroke.points.count))
                
                // Animate shrink toward folder center
                var shrinkTransform = Transform()
                shrinkTransform.translation = folderWorldPos - shrinkTransform.rotation.act(centroid * 0.05)
                shrinkTransform.scale = SIMD3<Float>(repeating: 0.05)
                entity.move(to: shrinkTransform, relativeTo: nil,
                            duration: 0.4, timingFunction: .easeIn)
                
                // Disable after animation completes
                Task {
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    await MainActor.run { entity.isEnabled = false }
                }
            }
            
            // Haptic
            #if !targetEnvironment(simulator)
            let gen = UIImpactFeedbackGenerator(style: .light)
            gen.impactOccurred()
            #endif
        }

        private func persistFolderTransform(for id: UUID, entity: Entity) {
            let descriptor = FetchDescriptor<SpatialFolder>(
                predicate: #Predicate { $0.id == id }
            )
            if let folder = (try? modelContext.fetch(descriptor))?.first {
                let pos = entity.position(relativeTo: nil)
                var transform = matrix_identity_float4x4
                transform.columns.3 = SIMD4<Float>(pos.x, pos.y, pos.z, 1)
                folder.localTransform = transform
                folder.scale = max(entity.scale.x, 0.2)
                try? modelContext.save()
            }
        }
        

        private func handlePointing(at pointNorm: CGPoint, point3D: SIMD3<Float>?) {
            guard let arView = self.arView else { return }
            var nearestID: UUID?
            var nearestDist: CGFloat = .greatestFiniteMagnitude

            // Check 2D screen distance for much better reliability
            let viewSize = arView.bounds.size
            // Convert Vision normalized coordinates to UIKit screen coordinates
            let screenPoint = CGPoint(x: pointNorm.x * viewSize.width, y: (1.0 - pointNorm.y) * viewSize.height)

            for (id, entity) in folderEntities {
                guard entity.isEnabled else { continue }
                if let projected = arView.project(entity.position(relativeTo: nil)) {
                    let dist = hypot(CGFloat(projected.x) - screenPoint.x, CGFloat(projected.y) - screenPoint.y)
                    // About 120 points on screen is a generous hit radius
                    if dist < 120.0, dist < nearestDist {
                        nearestDist = dist
                        nearestID = id
                    }
                }
            }
            
            let now = Date()
            let acquireThreshold: CGFloat = 80.0
            let releaseThreshold: CGFloat = 140.0
            let jitterGrace: TimeInterval = 0.45

            if let nearestID, nearestDist <= acquireThreshold {
                if nearestID != hoveredFolderID {
                    folderHoverStartTime.removeAll()
                    hoveredFolderID = nearestID
                    folderHoverStartTime[nearestID] = now
                }
                folderPointingLockUntil = now.addingTimeInterval(jitterGrace)
            } else if nearestDist > releaseThreshold || nearestID == nil {
                // Keep lock briefly so micro-jitter doesn't constantly drop the timer.
                if now > folderPointingLockUntil {
                    hoveredFolderID = nil
                    folderHoverStartTime.removeAll()
                    return
                }
            }

            guard let id = hoveredFolderID, let entity = folderEntities[id] else { return }

            if folderHoverStartTime[id] == nil {
                folderHoverStartTime[id] = now
            }

            let hoverDuration = now.timeIntervalSince(folderHoverStartTime[id] ?? now)
            if hoverDuration >= 1.8 {
                toggleFolderForHover(id: id, entity: entity)
                folderHoverStartTime[id] = now
            }
        }
        
        // MARK: - Folder Billboard (Performance-throttled)

        /// Called from updateUIView every SwiftUI frame.
        /// Only updates every 2nd call to halve the camera-look math.
        func updateFolderBillboards() {
            let now = CACurrentMediaTime()
            if now - lastBillboardUpdateTime < billboardUpdateInterval {
                return
            }

            billboardFrameCount += 1
            guard billboardFrameCount % 2 == 0 else { return }
            guard !folderEntities.isEmpty else { return }

            let cam = ARSessionManager.shared.cameraTransform
            let camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
            let worldUp = SIMD3<Float>(0, 1, 0)

            let camForward = -SIMD3<Float>(cam.columns.2.x, cam.columns.2.y, cam.columns.2.z)
            let moved = simd_distance(camPos, lastBillboardCameraPos)
            let angleDelta = 1.0 - simd_dot(simd_normalize(camForward), simd_normalize(lastBillboardCameraForward))
            if moved < billboardMoveThreshold && angleDelta < billboardAngleThreshold {
                return
            }

            lastBillboardUpdateTime = now
            lastBillboardCameraPos = camPos
            lastBillboardCameraForward = camForward

            for (_, entity) in folderEntities {
                guard entity.isEnabled else { continue }
                let billboardTarget = entity.children.first(where: { $0.name == "VisualRoot" }) ?? entity
                let worldPos = entity.position(relativeTo: nil)
                let toCamera = camPos - worldPos
                guard simd_length(toCamera) > 0.001 else { continue }
                let dir = simd_normalize(toCamera)
                let horizontal = SIMD3<Float>(dir.x, 0, dir.z)
                guard simd_length(horizontal) > 0.001 else { continue }
                let h = simd_normalize(horizontal)

                // Yaw to face the camera (Minecraft-style)
                let yaw = atan2(h.x, h.z)

                // Subtle pitch based on vertical offset
                let verticalAngle = atan2(dir.y, simd_length(horizontal))
                let pitch = max(-billboardMaxTilt, min(billboardMaxTilt, verticalAngle * billboardTiltFactor))

                let yawRot = simd_quatf(angle: yaw, axis: worldUp)
                let pitchAxis = simd_act(yawRot, SIMD3<Float>(1, 0, 0))
                let pitchRot = simd_quatf(angle: pitch, axis: pitchAxis)
                if billboardTarget === entity {
                    billboardTarget.setOrientation(pitchRot * yawRot, relativeTo: nil)
                } else {
                    billboardTarget.setOrientation(pitchRot * yawRot, relativeTo: entity)
                }
            }
        }

        // MARK: - Space Switching

        /// Switches the active space with a beautiful fade-out / fade-in transition.
        /// All world positions persist — only visibility changes.
        func switchSpace(to newSpaceID: String) {
            guard newSpaceID != appState.activeSpaceID,
                  !appState.isSpaceTransitioning else { return }
            appState.isSpaceTransitioning = true

            // Phase 1: fade out current space entities (0.4s)
            fadeEntities(Array(strokeEntities.values) + Array(folderEntities.values),
                         to: 0, duration: 0.4)

            Task {
                try? await Task.sleep(nanoseconds: 420_000_000) // wait for fade-out
                await MainActor.run {
                    // Remove current entities from scene
                    self.unloadCurrentSpaceEntities()

                    // Swap active space
                    self.appState.activeSpaceID = newSpaceID

                    // Phase 2: load new space entities at alpha=0, then fade in
                    self.loadEntitiesForSpace(newSpaceID, thenFadeIn: true)
                    self.appState.isSpaceTransitioning = false
                }

                // Haptic on completion
                #if !targetEnvironment(simulator)
                await MainActor.run {
                    let gen = UIImpactFeedbackGenerator(style: .soft)
                    gen.impactOccurred()
                }
                #endif
            }
        }

        private func unloadCurrentSpaceEntities() {
            for (_, entity) in strokeEntities { entity.removeFromParent() }
            for (_, entity) in folderEntities { entity.removeFromParent() }
            strokeEntities.removeAll()
            folderEntities.removeAll()
            strokeUndoStack.removeAll()
            folderHoverStartTime.removeAll()
            hoveredFolderID = nil
            clearSelection()
        }

        private func loadEntitiesForSpace(_ spaceID: String, thenFadeIn: Bool) {
            // Load strokes — skip those inside closed folders
            let strokeDesc = FetchDescriptor<SpatialStroke>()
            if let strokes = try? modelContext.fetch(strokeDesc) {
                for stroke in strokes {
                    guard stroke.spaceID == spaceID,
                          stroke.folderID == nil else { continue } // skip folder-contained strokes
                    let entity = createStrokeEntity(from: stroke)
                    if thenFadeIn { setEntityOpacity(entity, to: 0) }
                    strokesAnchor?.addChild(entity)
                    strokeEntities[stroke.id] = entity
                }
            }

            // Load folders
            let folderDesc = FetchDescriptor<SpatialFolder>()
            if let folders = try? modelContext.fetch(folderDesc) {
                for folder in folders {
                    guard folder.spaceID == spaceID else { continue }
                    let entity = FolderEntityBuilder.createFolderEntity(from: folder)
                    if thenFadeIn { setEntityOpacity(entity, to: 0) }
                    foldersAnchor?.addChild(entity)
                    folderEntities[folder.id] = entity
                }
            }

            if thenFadeIn {
                let allNew = Array(strokeEntities.values) + Array(folderEntities.values)
                fadeEntities(allNew, to: 1, duration: 0.4)
            }
        }

        /// Fade a set of entities to a target opacity over `duration` seconds.
        /// Uses UnlitMaterial alpha for stroke entities; SimpleMaterial alpha for folders.
        private func fadeEntities(_ entities: [Entity], to targetOpacity: Float, duration: TimeInterval) {
            // RealityKit doesn't have a built-in opacity animation on components,
            // so we step it in a Task loop at ~30fps for smooth fade.
            let steps = max(Int(duration * 30), 1)
            let stepDelay = UInt64(duration / Double(steps) * 1_000_000_000)

            Task {
                for step in 0...steps {
                    let t = Float(step) / Float(steps)
                    let opacity = targetOpacity == 0 ? (1 - t) : t
                    await MainActor.run {
                        for entity in entities {
                            self.setEntityOpacity(entity, to: opacity)
                        }
                    }
                    try? await Task.sleep(nanoseconds: stepDelay)
                }
            }
        }

        private func setEntityOpacity(_ entity: Entity, to opacity: Float) {
            if var model = entity.components[ModelComponent.self] {
                // Replace materials with opacity-adjusted versions
                model.materials = model.materials.map { material in
                    if var unlit = material as? UnlitMaterial {
                        let c = unlit.color.tint
                        unlit.color = .init(tint: c.withAlphaComponent(CGFloat(opacity)))
                        return unlit
                    } else if var simple = material as? SimpleMaterial {
                        let c = simple.color.tint
                        simple.color = .init(tint: c.withAlphaComponent(CGFloat(opacity)))
                        return simple
                    }
                    return material
                }
                entity.components.set(model)
            }
            // Recurse into children (e.g., folder icon text entity)
            for child in entity.children {
                setEntityOpacity(child, to: opacity)
            }
        }

        /// Builds a RealityKit Entity from a persisted SpatialStroke.
        /// Re-uses existing drawing logic (ribbon mesh from StrokeProcessor).
        private func createStrokeEntity(from stroke: SpatialStroke) -> Entity {
            // Use the centralized StrokeProcessor to create the entity with ribbon mesh
            // Default face direction is towards camera (positive Z)
            if let entity = StrokeProcessor.shared.createStrokeEntity(from: stroke, faceDirection: [0, 0, 1]) {
                return entity
            }
            
            // Fallback: empty entity if mesh generation fails
            let entity = Entity()
            entity.name = "Stroke_\(stroke.id.uuidString)"
            return entity
        }

        // MARK: - Folder Creation (with active space tag)

        func createFolderInCurrentSpace(name: String) {
            Task { @MainActor in
                // Place 5cm in front of the camera along the center ray (LiDAR direction if available)
                let cam = ARSessionManager.shared.cameraTransform
                let camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
                var direction = -SIMD3<Float>(cam.columns.2.x, cam.columns.2.y, cam.columns.2.z)

                if let arView = arView {
                    let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
                    if let depthPoint = ARSessionManager.shared.raycastUsingDepth(from: center) {
                        let toDepth = depthPoint - camPos
                        if simd_length(toDepth) > 0.001 {
                            direction = simd_normalize(toDepth)
                        }
                    }
                }

                let position = camPos + direction * 0.12

                let anchor = await ARSessionManager.shared.createWorldAnchor(at: position, name: name)
                guard let anchorID = anchor?.id else { return }

                let hue = Float.random(in: 0...1)
                let folder = SpatialFolder(
                    name: name,
                    worldAnchorID: anchorID,
                    colorHue: hue,
                    spaceID: self.appState.activeSpaceID
                )
                var localTransform = matrix_identity_float4x4
                localTransform.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
                folder.localTransform = localTransform
                self.modelContext.insert(folder)
                try? self.modelContext.save()

                let entity = FolderEntityBuilder.createFolderEntity(from: folder)
                entity.setPosition(position, relativeTo: nil)
                self.foldersAnchor?.addChild(entity)
                self.folderEntities[folder.id] = entity

                // Quick pop-in animation
                entity.scale = SIMD3<Float>(repeating: 0.01)
                var popT = entity.transform
                popT.scale = SIMD3<Float>(repeating: 1.0)
                entity.move(to: popT, relativeTo: entity.parent, duration: 0.3, timingFunction: .easeOut)

                #if !targetEnvironment(simulator)
                let gen = UIImpactFeedbackGenerator(style: .medium)
                gen.impactOccurred()
                #endif
            }
        }

        // MARK: - Kon Learning

        
        /// Schedule Kon learning after a pause in drawing
        private func scheduleKonLearning() {
            konLearningTimer?.invalidate()
            konLearningTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.triggerKonLearning()
                }
            }
        }
        
        /// Feed recent strokes to CharacterSegmenter for Kon learning
        private func triggerKonLearning() {
            guard !recentStrokesForLearning.isEmpty else { return }
            
            // Strictly filter out any geometry the user erased or hit 'Undo' on within the 1.0s timer
            let strokesToLearn = recentStrokesForLearning.filter { stroke in
                return stroke.modelContext != nil && !stroke.isDeleted
            }
            recentStrokesForLearning.removeAll()
            
            guard !strokesToLearn.isEmpty else { return }
            
            print("[Kon] ⏰ Learning timer fired! Feeding \(strokesToLearn.count) structural strokes to ML Segmenter.")
            
            // CharacterSegmenter will recognize text and feed into Kon
            CharacterSegmenter.shared.learnFromStrokes(strokesToLearn)
        }
        
        // MARK: - Kon Math Trigger
        
        /// Start the hold progress animation when Kon gesture is detected
        private func startKonHoldProgress() {
            guard appState.konState == .idle else { return }
            
            appState.konState = .holding
            appState.konHoldProgress = 0
            appState.konAnswerText = ""
            
            // Light haptic on gesture detection
            #if !targetEnvironment(simulator)
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            #endif
            
            // Animate progress 0→1 over 1 second using a cancellable Task
            konHoldProgressTask?.cancel()
            konHoldProgressTask = Task { @MainActor [weak self] in
                let startTime = Date()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 33_000_000) // ~30fps
                    guard let self = self, self.appState.konState == .holding else { break }
                    let elapsed = Float(Date().timeIntervalSince(startTime))
                    self.appState.konHoldProgress = min(elapsed / 1.0, 1.0)
                    if elapsed >= 1.0 { break }
                }
            }
            
            print("[Kon] 🤟 Gesture detected — hold for 1s...")
        }
        
        /// Cancel hold if gesture drops before 1 second
        private func cancelKonHold() {
            guard appState.konState == .holding else { return }
            
            konHoldProgressTask?.cancel()
            konHoldProgressTask = nil
            appState.konState = .idle
            appState.konHoldProgress = 0
            
            print("[Kon] ↩️ Hold cancelled")
        }
        
        /// Triggered after 1-second hold — snapshot viewport geometry, solve math with Gemini, show answer
        private func triggerKon() {
            guard appState.konState == .holding || appState.konState == .idle else { return }
            guard let arView = arView else { return }
            
            konHoldProgressTask?.cancel()
            konHoldProgressTask = nil
            appState.konHoldProgress = 1.0
            
            print("[Kon] ✅ Hold complete! Generating vector mask...")
            
            // Heavy haptic: triggered
            #if !targetEnvironment(simulator)
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            #endif
            
            appState.konState = .capturing
            
            // --- Custom 3D to 2D Depth-Culled Frustum Projection Pipeline ---
            struct ProjectedStroke {
                let points2D: [CGPoint]
                let depth: Float
                let originalStroke: SpatialStroke
            }
            
            var projectedStrokes: [ProjectedStroke] = []
            
            // Fix SwiftData crash: ModelContext faulting when detached across MainActor ticks.
            // Create a strictly isolated transient container to aggressively fault all attribute blobs synchronously.
            let isolatedContext = ModelContext(modelContext.container)
            let descriptor = FetchDescriptor<SpatialStroke>()
            let allStrokes = (try? isolatedContext.fetch(descriptor)) ?? []
            
            let bounds = arView.bounds
            let cameraPos = arView.cameraTransform.translation
            
            // 1. Project all SpatialStrokes to 2D Screen Space
            for stroke in allStrokes {
                guard !stroke.points.isEmpty else { continue }
                
                var points2D: [CGPoint] = []
                var isVisible = false
                var totalDepth: Float = 0
                
                for point in stroke.points {
                    if let projected = arView.project(point.position) {
                        points2D.append(projected)
                        
                        // Check if it appears roughly within the camera bounds (with some margin so cropped strokes aren't completely erased)
                        let margin: CGFloat = 50
                        if projected.x > -margin && projected.x < bounds.width + margin &&
                           projected.y > -margin && projected.y < bounds.height + margin {
                            isVisible = true
                        }
                        
                        totalDepth += simd_distance(cameraPos, point.position)
                    }
                }
                
                // If any part of the stroke is on screen, parse it and record its physical depth profile
                if isVisible && !points2D.isEmpty {
                    let avgDepth = totalDepth / Float(stroke.points.count)
                    projectedStrokes.append(ProjectedStroke(points2D: points2D, depth: avgDepth, originalStroke: stroke))
                }
            }
            
            // 2. Depth Culling: Filter out background/distant strokes relying on depth topology
            if !projectedStrokes.isEmpty {
                let screenCenter = CGPoint(x: bounds.midX, y: bounds.midY)
                
                // Find the stroke that is physically closest to the center crosshairs of the screen in 2D
                let focalStroke = projectedStrokes.min(by: { a, b in
                    let distA = a.points2D.first.map { hypot($0.x - screenCenter.x, $0.y - screenCenter.y) } ?? .infinity
                    let distB = b.points2D.first.map { hypot($0.x - screenCenter.x, $0.y - screenCenter.y) } ?? .infinity
                    return distA < distB
                })
                
                let targetDepth = focalStroke?.depth ?? 0
                
                // EXTREMELY STRICT TOLERANCE: Lock to a 10-centimeter planar slab centered squarely around the focal stroke.
                // Any strokes drawn physically further back or heavily out of bounds front are actively ignored.
                let depthTolerance: Float = 0.10 
                
                projectedStrokes.removeAll { abs($0.depth - targetDepth) > depthTolerance }
            }
            
            // 3. Render purely high-contrast 2D black strokes on a white geometric board
            let renderer = UIGraphicsImageRenderer(size: bounds.size)
            let maskImage = renderer.image { ctx in
                let cgContext = ctx.cgContext
                
                // Reverting to high-contrast White on Black (matches user drawing style)
                UIColor.black.setFill()
                cgContext.fill(bounds)
                
                UIColor.white.setStroke()
                cgContext.setLineWidth(6.0) // Aggressive weight for reliable operator OCR
                cgContext.setLineCap(.round)
                cgContext.setLineJoin(.round)
                
                for stroke in projectedStrokes {
                    guard let first = stroke.points2D.first else { continue }
                    cgContext.beginPath()
                    cgContext.move(to: first)
                    for pt in stroke.points2D.dropFirst() {
                        cgContext.addLine(to: pt)
                    }
                    cgContext.strokePath()
                }
            }
            
            // 4. Feed optimized payload directly down the pipeline
            Task { @MainActor in
                self.appState.konState = .thinking
            }
            
            // Capture current style IMMEDIATELY for perfect sync
            let activeColor = self.appState.currentStrokeColor
            let activeThickness = self.appState.currentStrokeThickness
            
            Task {
                do {
                    let answer = try await GeminiService.shared.solveMath(image: maskImage)
                    
                    await MainActor.run {
                        if let answer = answer, !answer.isEmpty {
                            print("[Kon] 💡 Answer: \(answer)")
                            
                            // NEW: Aggregate ALL projected strokes to find the true physical right-most edge
                            var maxProjection: Float = -.infinity
                            var minY: Float = .infinity
                            var maxY: Float = -.infinity
                            
                            // Calculate horizontal "Right" and vertical "Up" vectors relative to the camera/plane
                            let faceNormal = drawingPlaneNormal
                            var rightVector = SIMD3<Float>(1, 0, 0)
                            var upVector = SIMD3<Float>(0, 1, 0)
                            
                            if let arView = self.arView, let cameraTransform = arView.session.currentFrame?.camera.transform {
                                // Project camera right onto the plane
                                let cameraRight = SIMD3<Float>(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z)
                                let dotRight = simd_dot(cameraRight, faceNormal)
                                rightVector = simd_normalize(cameraRight - (dotRight * faceNormal))
                                
                                // Project camera up onto the plane (ensures text is NEVER upside down regardless of user facing)
                                let cameraUp = SIMD3<Float>(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z)
                                let dotUp = simd_dot(cameraUp, faceNormal)
                                upVector = simd_normalize(cameraUp - (dotUp * faceNormal))
                            } else {
                                rightVector = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), faceNormal))
                                upVector = simd_normalize(simd_cross(faceNormal, rightVector))
                            }
                            
                            // Find Right-most edge X and Centroid Y
                            for pStroke in projectedStrokes {
                                for pPoint in pStroke.originalStroke.points {
                                    // Project onto Right vector for X
                                    let projX = simd_dot(pPoint.position, rightVector)
                                    if projX > maxProjection {
                                        maxProjection = projX
                                    }
                                    
                                    // Project onto Up vector for Y (alignment)
                                    let projY = simd_dot(pPoint.position, upVector)
                                    minY = min(minY, projY)
                                    maxY = max(maxY, projY)
                                }
                            }
                            
                            if maxProjection > -.infinity {
                                // CENTROID ALIGNMENT: Find the vertical middle center of the equation
                                let verticalCenter = (minY + maxY) / 2.0
                                
                                // Offset the Y by half the character height (0.05 height * 0.8 scale / 2) so it centers properly
                                let charHalfHeight: Float = (0.05 * 0.8) / 2.0
                                let targetY = verticalCenter - charHalfHeight
                                
                                // Construct the physical start position: Right-Edge + Tiny Buffer + Centered Y
                                // We use a base point on the plane and add our local offsets
                                let origin = projectedStrokes.first?.originalStroke.points.first?.position ?? SIMD3<Float>(0,0,0)
                                let currentProjX = simd_dot(origin, rightVector)
                                let currentProjY = simd_dot(origin, upVector)
                                
                                // TIGHT: 0.8cm buffer for a "natural next to it" look
                                let targetProjX = maxProjection + 0.008
                                
                                let startPos = origin + (rightVector * (targetProjX - currentProjX)) + (upVector * (targetY - currentProjY))
                                
                                self.updateHUD(with: "Answer: \(answer)")
                                self.startAnimatedHandwriting(
                                    answer, 
                                    from: startPos, 
                                    color: activeColor, 
                                    thickness: activeThickness,
                                    rightVector: rightVector,
                                    upwardVector: upVector
                                )
                            } else {
                                // Fallback
                                self.updateHUD(with: "4") // Fallback display
                                self.appState.konAnswerText = answer
                                self.appState.konState = .answered
                                self.scheduleKonDismiss()
                            }

                            #if !targetEnvironment(simulator)
                            let success = UINotificationFeedbackGenerator()
                            success.notificationOccurred(.success)
                            #endif
                        } else {
                            self.appState.konAnswerText = "Math not found"
                            self.appState.konState = .error
                            print("[Kon] ℹ️ No math equation detected")
                            self.scheduleKonDismiss()
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.appState.konAnswerText = "Error: \(error.localizedDescription)"
                        self.appState.konState = .error
                        self.scheduleKonDismiss()
                        print("[Kon] ❌ Error: \(error)")
                    }
                }
            }
        }
        
        /// Auto-dismiss Kon answer after delay
        private func scheduleKonDismiss() {
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await MainActor.run {
                    if self.appState.konState == .answered || self.appState.konState == .error {
                        self.appState.konState = .idle
                    }
                }
            }
        }

        /// Helper to update HUD quickly
        private func updateHUD(with text: String) {
            Task { @MainActor in
                self.appState.konStatusMessage = text
            }
        }

        /// Procedurally animate the handwriting of Kon's answer in AR space
        private func startAnimatedHandwriting(
            _ text: String, 
            from startPosition: SIMD3<Float>, 
            color: StrokeColor, 
            thickness: Float,
            rightVector: SIMD3<Float>,
            upwardVector: SIMD3<Float>
        ) {
            self.appState.konState = .writing
            
            // Note: Gemini now handles the equals sign contextually.
            let faceNormal = drawingPlaneNormal
            
            Task {
                // Generate all stroke segments via Kon (Imitation Engine)
                let results = Kon.shared.renderText(
                    text,
                    at: startPosition,
                    scale: 0.8, // Slightly smaller for professional look
                    color: color,
                    thickness: thickness,
                    faceDirection: faceNormal,
                    rightVector: rightVector,
                    upwardVector: upwardVector
                )
                
                // Update HUD with the result immediately as we start writing
                await MainActor.run {
                    self.appState.konStatusMessage = "Answer: \(text)"
                }
                
                // --- High-Fidelity Real-time Writing Animation ---
                for result in results {
                    let finalStroke = result.stroke
                    finalStroke.spaceID = self.appState.activeSpaceID
                    let finalPoints = finalStroke.points
                    
                    let entity = Entity()
                    entity.name = "KonWriting_\(finalStroke.id.uuidString)"
                    
                    await MainActor.run {
                        strokesAnchor?.addChild(entity)
                    }
                    
                    var currentPoints: [StrokePoint] = []
                    
                    // Fast fluid animation: smaller chunks and 8ms delay
                    let chunkSize = max(1, finalPoints.count / 25)
                    
                    for i in stride(from: 0, to: finalPoints.count, by: chunkSize) {
                        let end = min(i + chunkSize, finalPoints.count)
                        let nextBatch = Array(finalPoints[i..<end])
                        currentPoints.append(contentsOf: nextBatch)
                        
                        await MainActor.run {
                            if let mesh = StrokeProcessor.shared.generateRibbonMesh(
                                from: currentPoints,
                                thickness: finalStroke.thickness,
                                faceDirection: faceNormal
                            ) {
                                // Switch to standardized UNLIT material for perfect color match
                                let material = StrokeProcessor.shared.getCachedMaterial(for: color)
                                entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
                            }
                            
                            #if !targetEnvironment(simulator)
                            let generator = UISelectionFeedbackGenerator()
                            generator.selectionChanged()
                            #endif
                        }
                        
                        // 120fps pace: ~8ms delay for fast deliberate feel
                        try? await Task.sleep(nanoseconds: 8_000_000)
                    }
                    
                    await MainActor.run {
                        self.appState.konStatusMessage = "Answer: \(text)" // Keep it sticky
                        modelContext.insert(finalStroke)
                        strokeEntities[finalStroke.id] = entity
                        strokeUndoStack.append(finalStroke.id)
                    }
                }
                
                await MainActor.run {
                    self.appState.konState = .answered
                    self.appState.konStatusMessage = "Answer: \(text)"
                    try? modelContext.save()
                    self.scheduleKonDismiss()
                }
            }
        }
        
        // MARK: - Kon Text Placement
        
        /// Place text rendered by Kon into the AR scene
        func placeKonText(_ text: String) {
            // Initialize drawing plane for correct positioning
            initializeDrawingPlane()
            
            // Find a position that doesn't overlap existing content
            let textWidth = Kon.shared.measureText(text, scale: 1.0)
            let position = findNonOverlappingPosition(textWidth: textWidth)
            
            // Render text via Kon
            let results = Kon.shared.renderText(
                text,
                at: position,
                scale: 1.0,
                color: currentColor,
                thickness: currentThickness,
                faceDirection: drawingPlaneNormal
            )
            
            // Add each character's entity to the scene
            for result in results {
                let entity = result.entity
                let stroke = result.stroke
                stroke.spaceID = appState.activeSpaceID
                
                entity.name = "Stroke_\(stroke.id.uuidString)"
                strokesAnchor?.addChild(entity)
                
                // Persist
                modelContext.insert(stroke)
                strokeEntities[stroke.id] = entity
                strokeUndoStack.append(stroke.id)
            }
            
            try? modelContext.save()
            
            // Haptic feedback
            #if !targetEnvironment(simulator)
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            #endif
            
            print("[Kon] ✍️ Placed '\(text)' at (\(String(format: "%.2f", position.x)), \(String(format: "%.2f", position.y)), \(String(format: "%.2f", position.z)))")
        }
        
        /// Find a world position on the drawing plane that doesn't overlap existing strokes
        private func findNonOverlappingPosition(textWidth: Float) -> SIMD3<Float> {
            // Get all existing stroke bounding info
            let descriptor = FetchDescriptor<SpatialStroke>()
            let allStrokes = (try? modelContext.fetch(descriptor)) ?? []
            
            if allStrokes.isEmpty {
                // No existing content — place at drawing plane center
                return drawingPlaneCenter
            }
            
            // Find bounding box of all existing stroke points
            var minY: Float = .infinity
            var maxY: Float = -.infinity
            var avgX: Float = 0
            var avgZ: Float = 0
            var pointCount: Float = 0
            
            for stroke in allStrokes {
                for point in stroke.points {
                    minY = min(minY, point.position.y)
                    maxY = max(maxY, point.position.y)
                    avgX += point.position.x
                    avgZ += point.position.z
                    pointCount += 1
                }
            }
            
            if pointCount > 0 {
                avgX /= pointCount
                avgZ /= pointCount
            } else {
                return drawingPlaneCenter
            }
            
            // Place below existing content with a margin
            let margin: Float = 0.04 // 4cm gap
            let newY = minY - margin - 0.05 // 5cm char height
            
            // Center the text horizontally
            let newX = avgX - textWidth / 2.0
            
            return SIMD3<Float>(newX, newY, avgZ)
        }
        
        // MARK: - Persistence
        
        private func loadPersistedStrokes() {
            let descriptor = FetchDescriptor<SpatialStroke>()
            guard let strokes = try? modelContext.fetch(descriptor) else { return }
            
            for stroke in strokes where stroke.isCompleted {
                guard stroke.spaceID == appState.activeSpaceID,
                      stroke.folderID == nil else { continue }
                // Default face direction towards camera (negative Z in world space)
                // For persisted strokes, we use a fixed direction since we don't know
                // the original camera orientation
                let faceDirection = SIMD3<Float>(0, 0, 1)
                
                if let entity = StrokeProcessor.shared.createEntity(
                    from: stroke.points,
                    thickness: stroke.thickness,
                    color: stroke.color,
                    faceDirection: faceDirection
                ) {
                    entity.name = "Stroke_\(stroke.id.uuidString)"
                    strokesAnchor?.addChild(entity)
                    
                    // Track for undo/delete
                    strokeEntities[stroke.id] = entity
                    strokeUndoStack.append(stroke.id)
                }
            }
        }
        
        private func loadPersistedFolders() {
            let descriptor = FetchDescriptor<SpatialFolder>()
            guard let folders = try? modelContext.fetch(descriptor) else { return }
            
            for folder in folders {
                // Only load folders in the active space
                guard folder.spaceID == appState.activeSpaceID else { continue }
                let entity = FolderEntityBuilder.createFolderEntity(from: folder)
                foldersAnchor?.addChild(entity)
                folderEntities[folder.id] = entity
            }
        }
        
        private func setupNotifications() {
            // Space switching
            let spaceToken = NotificationCenter.default.addObserver(
                forName: NSNotification.Name("WhiteBoARd.performSpaceSwitch"),
                object: nil,
                queue: .main
            ) { [weak self] note in
                if let spaceID = note.userInfo?["spaceID"] as? String {
                    self?.switchSpace(to: spaceID)
                }
            }
            
            // Folder creation
            let folderToken = NotificationCenter.default.addObserver(
                forName: NSNotification.Name("CreateFolder"),
                object: nil,
                queue: .main
            ) { [weak self] note in
                if let name = note.userInfo?["name"] as? String {
                    self?.createFolderInCurrentSpace(name: name)
                }
            }
            
            notificationTokens.append(spaceToken)
            notificationTokens.append(folderToken)
        }
        
        // MARK: - ARSessionManagerDelegate
        
        nonisolated func arSessionManager(_ manager: ARSessionManager, didUpdateFrame frame: ARFrame) {
            Task { @MainActor in
                // Frame counting for debugging
                self.frameCount += 1
                
                // Process frame through gesture recognizer (internally rate-limited)
                GestureRecognizer.shared.processARFrame(frame)

                // Update folder billboards per frame for camera-facing behavior
                self.updateFolderBillboards()

                // Distance culling to avoid rendering far entities
                self.updateDistanceCulling()
                
                // PERFORMANCE: Only update UI landmarks every 5th frame (24fps is plenty for visualization)
                if self.frameCount % 5 == 0 {
                    self.appState.handLandmarks = GestureRecognizer.shared.landmarks
                }
            }
        }

        // MARK: - Distance Culling

        private func updateDistanceCulling() {
            let now = CACurrentMediaTime()
            if now - lastCullTime < cullInterval {
                return
            }
            lastCullTime = now

            let cam = ARSessionManager.shared.cameraTransform
            let camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)

            let strokeDesc = FetchDescriptor<SpatialStroke>()
            let strokes = (try? modelContext.fetch(strokeDesc)) ?? []
            let strokeByID = Dictionary(uniqueKeysWithValues: strokes.map { ($0.id, $0) })

            // Strokes
            for (id, entity) in strokeEntities {
                let dist = simd_distance(camPos, entity.position(relativeTo: nil))
                if dist > maxRenderDistance {
                    if entity.isEnabled {
                        entity.isEnabled = false
                        distanceCulledStrokeIDs.insert(id)
                    }
                } else if distanceCulledStrokeIDs.contains(id) {
                    if let stroke = strokeByID[id], stroke.folderID == nil {
                        entity.isEnabled = true
                        distanceCulledStrokeIDs.remove(id)
                    }
                }
            }

            // Folders
            for (id, entity) in folderEntities {
                let dist = simd_distance(camPos, entity.position(relativeTo: nil))
                if dist > maxRenderDistance {
                    if entity.isEnabled {
                        entity.isEnabled = false
                        distanceCulledFolderIDs.insert(id)
                    }
                } else if distanceCulledFolderIDs.contains(id) {
                    entity.isEnabled = true
                    distanceCulledFolderIDs.remove(id)
                }
            }
        }
        
        nonisolated func arSessionManager(_ manager: ARSessionManager, didAddAnchor anchor: ARAnchor) {}
        nonisolated func arSessionManager(_ manager: ARSessionManager, didUpdateAnchor anchor: ARAnchor) {}
        nonisolated func arSessionManager(_ manager: ARSessionManager, didRemoveAnchor anchor: ARAnchor) {}
        
        nonisolated func arSessionManager(_ manager: ARSessionManager, didFailWithError error: Error) {
            Task { @MainActor in
                self.appState.arSessionState = .failed
            }
        }
        
        // MARK: - ARCoachingOverlayViewDelegate
        
        #if !targetEnvironment(simulator)
        nonisolated func coachingOverlayViewWillActivate(_ coachingOverlayView: ARCoachingOverlayView) {
            // Coaching is about to appear
        }
        
        nonisolated func coachingOverlayViewDidDeactivate(_ coachingOverlayView: ARCoachingOverlayView) {
            // Coaching has been dismissed - tracking is good
            Task { @MainActor in
                self.appState.arSessionState = .tracking
            }
        }
        
        nonisolated func coachingOverlayViewDidRequestSessionReset(_ coachingOverlayView: ARCoachingOverlayView) {
            // User requested session reset
            Task { @MainActor in
                ARSessionManager.shared.resetSession()
            }
        }
        #endif
    }
}

struct FolderEntityBuilder {
    /// Cached icon texture so space switching doesn't repeatedly race image decode/texture generation.
    @MainActor private static var cachedFolderTexture: TextureResource?

    // MARK: - Public Factory
    // Root entity holds world position. updateFolderBillboards() applies
    // full billboard rotation so the icon + label face the camera.

    @MainActor
    static func createFolderEntity(from folder: SpatialFolder) -> Entity {
        let entity = Entity()
        entity.name = "Folder_\(folder.id.uuidString)"

        if let transform = folder.localTransform {
            let pos = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            entity.setPosition(pos, relativeTo: nil)
        }

        let size: Float = 0.108 * folder.scale
        
        // ── Visual Root: groups icon + label (inherits billboard rotation) ──
        let visualRoot = Entity()
        visualRoot.name = "VisualRoot"
        entity.addChild(visualRoot)

        // ── Icon plane child ────────────────────────────────────────────────
        let iconEntity = makeIcon(size: size, colorHue: folder.colorHue)
        visualRoot.addChild(iconEntity)

        // ── Centered label child, directly below icon ────────────────────────
        let labelEntity = makeLabel(name: folder.name, iconSize: size)
        visualRoot.addChild(labelEntity)

        // ── Collision shape on the world root ───────────────────────────────
        entity.components.set(
            CollisionComponent(shapes: [.generateBox(size: [size, size + 0.05, 0.01])])
        )

        return entity
    }

    // MARK: - Icon

    @MainActor
    private static func makeIcon(size: Float, colorHue: Float) -> Entity {
        let e = Entity()
        let mesh = MeshResource.generatePlane(width: size, height: size)
        var mat = UnlitMaterial()
        
        if let tex = cachedFolderTexture ?? loadFolderTexture() {
            cachedFolderTexture = tex
            mat.color = .init(tint: .white, texture: .init(tex))
            mat.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        } else {
            // Deterministic fallback: draw a folder glyph to texture so we never show a plain gray box.
            if let generated = generateFallbackFolderTexture() {
                cachedFolderTexture = generated
                mat.color = .init(tint: .white, texture: .init(generated))
                mat.blending = .transparent(opacity: .init(floatLiteral: 1.0))
            } else {
                let color = UIColor(hue: CGFloat(colorHue), saturation: 0.55,
                                    brightness: 0.9, alpha: 0.85)
                mat.color = .init(tint: color)
            }
        }

        e.components.set(ModelComponent(mesh: mesh, materials: [mat]))
        return e
    }
    
    @MainActor
    private static func loadFolderTexture() -> TextureResource? {
        let candidates: [String] = ["FolderIcon", "folder", "folder_icon", "folder.png", "FolderIcon.png"]
        for name in candidates {
            let image: UIImage?
            if name.contains(".") {
                image = UIImage(contentsOfFile: Bundle.main.bundlePath + "/" + name)
            } else {
                image = UIImage(named: name)
            }
            if let cg = image?.cgImage,
               let tex = try? TextureResource.generate(from: cg, options: .init(semantic: .color)) {
                return tex
            }
        }
        return nil
    }
    
    @MainActor
    private static func generateFallbackFolderTexture() -> TextureResource? {
        let size = CGSize(width: 256, height: 256)
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            UIColor.clear.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 1.0, green: 0.82, blue: 0.28, alpha: 1.0).setFill()
            let body = UIBezierPath(roundedRect: CGRect(x: 22, y: 66, width: 212, height: 148), cornerRadius: 20)
            body.fill()
            UIColor(red: 1.0, green: 0.90, blue: 0.45, alpha: 1.0).setFill()
            let tab = UIBezierPath(roundedRect: CGRect(x: 40, y: 42, width: 92, height: 44), cornerRadius: 14)
            tab.fill()
        }
        guard let cg = img.cgImage else { return nil }
        return try? TextureResource.generate(from: cg, options: .init(semantic: .color))
    }

    // MARK: - Label

    @MainActor
    private static func makeLabel(name: String, iconSize: Float) -> Entity {
        let e = Entity()
        let fw: CGFloat = 0.3
        let fh: CGFloat = 0.06

        let textMesh = MeshResource.generateText(
            name,
            extrusionDepth: 0.0005,
            font: .systemFont(ofSize: 0.016, weight: .semibold),
            containerFrame: CGRect(x: -fw / 2, y: -fh / 2, width: fw, height: fh),
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        var mat = UnlitMaterial()
        mat.color = .init(tint: .white)
        e.components.set(ModelComponent(mesh: textMesh, materials: [mat]))

        // Position in the local XY plane (same plane as the icon)
        // Move it down by iconSize/2 + margin.
        e.position = [0, -(iconSize / 2 + 0.025), 0]

        return e
    }
}

// MARK: - Preview

#if targetEnvironment(simulator)
struct ARCanvasView_Previews: PreviewProvider {
    static var previews: some View {
        ARCanvasView()
            .environment(AppState())
            .modelContainer(for: [SpatialStroke.self])
    }
}
#endif
