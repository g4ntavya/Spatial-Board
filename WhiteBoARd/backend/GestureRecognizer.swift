// GestureRecognizer.swift
// WhiteBoARd - Spatial AR Notetaking
// Vision framework hand gesture recognition - optimized for A17 Pro

import Foundation
import Vision
import AVFoundation
import ARKit
import simd
import Combine

/// Recognizes hand gestures using Vision framework hand landmarks
/// Optimized for iPhone 15 Pro / A17 Pro chip efficiency
@MainActor
@Observable
final class GestureRecognizer {
    
    // MARK: - Configuration
    
    struct Configuration {
        var pinchThreshold: Float = 0.020  // Extremely tight pinch (2cm) ensures drawing only happens upon solid contact
        var pinchReleaseThreshold: Float = 0.045  // Extended release hysteresis (4.5cm) to prevent tracking dropout during flexes
        var palmOpenThreshold: Float = 0.12  // Minimum finger spread for open palm
        var confidenceThreshold: Float = 0.35  // Lowered from 0.5 for low-light / complex background robustness
        var drawingConfidenceThreshold: Float = 0.15  // Much lower when actively drawing to prevent dropout
        var smoothingFactor: Float = 0.5  // More smoothing for stability
        var gestureDebounceTime: TimeInterval = 0.1  // Slower transitions for stability
    }
    
    // MARK: - Properties
    
    private var config: Configuration = Configuration()
    
    /// Current detected gesture mode
    private(set) var currentMode: GestureMode = .none
    
    /// Current hand landmarks
    private(set) var landmarks: HandLandmarks?
    
    /// 3D position of active gesture point (e.g., pinch midpoint)
    private(set) var gesturePosition: SIMD3<Float>?
    
    /// Confidence of current detection
    private(set) var confidence: Float = 0
    
    /// Whether a hand is currently detected
    private(set) var isHandDetected: Bool = false
    
    /// Vision request - reused to avoid allocation overhead
    private var handPoseRequest: VNDetectHumanHandPoseRequest?
    
    /// Dedicated queue for Vision processing - uses efficiency cores when possible
    private let visionQueue = DispatchQueue(label: "com.whiteboard.vision", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem)
    
    /// Reference to AR session for coordinate conversion
    private weak var arSessionManager: ARSessionManager?
    
    /// Last gesture change time for debouncing
    private var lastGestureChangeTime: Date = Date.distantPast
    
    /// Previous landmarks for smoothing
    private var previousLandmarks: HandLandmarks?
    
    /// Cancellables
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Callbacks
    
    var onGestureModeChanged: ((GestureMode) -> Void)?
    var onPinchPositionUpdated: ((SIMD3<Float>) -> Void)?
    /// Erase callback now passes the 2D normalized Vision point for stroke-aware projection
    var onEraseActivated: ((CGPoint) -> Void)?
    var onResizeGesture: ((Float) -> Void)?  // Scale factor delta (center-origin)
    var onKonTriggered: (() -> Void)?        // Kon hold completed (after 1s)
    var onKonHoldStarted: (() -> Void)?      // Kon gesture detected, hold timer started
    var onKonHoldCancelled: (() -> Void)?    // Kon gesture dropped before 1s
    var onPointUpdated: ((CGPoint, SIMD3<Float>?) -> Void)? // Index pointing (per-frame)
    
    // MARK: - New Selection Callbacks
    /// Called every frame while two-hand selection rectangle is active.
    /// Receives normalized 2D Vision points for left and right pinch.
    var onSelectionRectUpdated: ((CGPoint, CGPoint) -> Void)?
    /// Called once when both pinches are released, confirming the selection.
    var onSelectionConfirmed: ((CGPoint, CGPoint) -> Void)?
    /// Called every frame while selected-palm move gesture is detected.
    /// Passes the raw 2D Vision point and the computed 3D position.
    var onFistMoveUpdated: ((CGPoint, SIMD3<Float>) -> Void)?
    /// Called when selected-palm move gesture is released — locks selection in place.
    var onFistMoveEnded: (() -> Void)?
    /// Called every frame during three-finger pinch — passes uniform scale delta (>1 = grow, <1 = shrink).
    var onThreeFingerResizeUpdated: ((Float) -> Void)?
    /// Called when three-finger pinch is released.
    var onThreeFingerResizeEnded: (() -> Void)?
    /// Called when a double-tap (two quick pinch-release cycles) is detected → deselect.
    var onDoubleTapDetected: (() -> Void)?
    /// Query whether there is an active selection. If true, pinch drives resize instead of draw.
    var isSelectionActive: (() -> Bool)?
    
    /// Kon hold-to-trigger state
    private var konAlreadyFired: Bool = false
    private var konHoldTask: Task<Void, Never>?
    private var konHoldStartTime: Date?
    
    /// Store the current palm center 2D point for erasing
    private(set) var currentPalmNormalizedPoint: CGPoint?
    
    /// Store stable joint 2D points for depth sampling (wrist, MCP joints - more reliable than fingertips)
    private(set) var stableJointsForDepth: [CGPoint] = []
    
    // MARK: - Two-Hand Selection State
    
    /// Whether both hands are currently pinching (for selection rectangle)
    private var isTwoHandSelecting: Bool = false
    /// Normalized Vision points of left and right pinch (updated while selecting)
    private(set) var leftPinchPoint2D: CGPoint = .zero
    private(set) var rightPinchPoint2D: CGPoint = .zero
    /// Saved start corners for confirming selection on release
    private var selectionStartLeft: CGPoint = .zero
    private var selectionStartRight: CGPoint = .zero
    /// Smoothed points to reduce jitter while selecting
    private var smoothedLeftPinch2D: CGPoint?
    private var smoothedRightPinch2D: CGPoint?
    
    // MARK: - Selected Move State
    
    private var wasMovingWithPalm: Bool = false
    
    // MARK: - Selection Pinch Resize State
    
    private var wasSelectionPinchResizing: Bool = false
    private var selectionPinchFrames: Int = 0
    private var selectionResizeLastPinchPoint2D: CGPoint?
    
    // MARK: - Double-Tap Deselect State
    
    private var lastPinchReleaseTime: Date = .distantPast
    private var quickTapCount: Int = 0
    
    // MARK: - Performance Optimization
    
    /// Frame skipping for Vision processing (every N frames)
    private var frameCounter: Int = 0
    private let visionProcessingInterval: Int = 2  // Process every 2nd frame for better low-light responsiveness
    
    /// Last frame processing time for adaptive frame skipping
    private var lastFrameTime: TimeInterval = 0
    private let targetFrameInterval: TimeInterval = 1.0 / 30.0  // Target 30fps for Vision
    
    // MARK: - Stroke Start Handling
    
    /// Track pinch transition to skip first point (computed with old plane)
    private var strokeJustStarted: Bool = false
    
    /// Number of points to skip after stroke starts (gives time for plane to stabilize)
    private var strokeStartSkipCount: Int = 0
    private let strokeStartSkipFrames: Int = 2  // Skip first 2 points
    
    /// Check pinch state with hysteresis to prevent flickering
    private var wasPinching: Bool = false
    
    /// Grace period: frames of tracking loss tolerated while drawing before ending stroke
    private var pinchGraceFramesRemaining: Int = 0
    private let pinchGraceFramesMax: Int = 4  // Tolerate up to 4 frames of tracking loss
    
    // MARK: - Singleton
    
    static let shared = GestureRecognizer()
    
    private init() {
        setupVisionRequest()
    }
    
    // MARK: - Configuration
    
    func configure(arSessionManager: ARSessionManager, config: Configuration? = nil) {
        self.arSessionManager = arSessionManager
        if let config = config {
            self.config = config
        }
    }
    
    // MARK: - Vision Setup
    
    private func setupVisionRequest() {
        handPoseRequest = VNDetectHumanHandPoseRequest()
        // Two hands needed for selection rectangle gesture.
        // A17 Pro handles this fine; older devices may see slight Vision FPS drop.
        handPoseRequest?.maximumHandCount = 2
        handPoseRequest?.revision = VNDetectHumanHandPoseRequestRevision1 // Force lightweight graph
    }
    
    // MARK: - Processing
    
    /// Flag to prevent overlapping Vision requests
    private var isProcessingFrame: Bool = false
    
    /// Process a camera frame for hand detection
    /// PERFORMANCE: Rate-limited and non-blocking
    func processFrame(_ pixelBuffer: CVPixelBuffer) {
        #if !targetEnvironment(simulator)
        // Frame rate limiting for performance
        frameCounter += 1
        
        // Skip if already processing a frame (prevents queue buildup)
        guard !isProcessingFrame else { return }
        
        // Always process if currently drawing (need responsive input)
        // Otherwise, skip frames to reduce load
        if !wasPinching && frameCounter % visionProcessingInterval != 0 {
            return
        }
        
        // Additional time-based throttling
        let now = CACurrentMediaTime()
        if !wasPinching && (now - lastFrameTime) < targetFrameInterval {
            return
        }
        lastFrameTime = now
        
        guard let request = handPoseRequest else { return }
        
        isProcessingFrame = true
        
        // Process on dedicated queue to avoid blocking main thread
        // autoreleaseFrequency: .workItem ensures memory is released after each frame
        visionQueue.async { [weak self] in
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            
            do {
                try handler.perform([request])
                let results = request.results
                
                // Return to main thread for UI updates
                DispatchQueue.main.async {
                    self?.isProcessingFrame = false
                    self?.processResults(results)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isProcessingFrame = false
                    self?.resetDetection()
                }
            }
        }
        #else
        // Simulator: use mock gestures
        simulateMockGesture()
        #endif
    }
    
    /// Process ARFrame directly
    func processARFrame(_ frame: ARFrame) {
        processFrame(frame.capturedImage)
    }
    
    // MARK: - Result Processing
    
    private func processResults(_ observations: [VNHumanHandPoseObservation]?) {
        guard let observations = observations, !observations.isEmpty else {
            // Grace period: if we were actively drawing, tolerate a few frames
            // of hand loss (common in low light / complex backgrounds).
            if wasPinching && pinchGraceFramesRemaining > 0 {
                pinchGraceFramesRemaining -= 1
                // Keep last known gesture state — don't reset.
                return
            }
            // If we were selecting, confirm selection on hand loss
            if isTwoHandSelecting {
                isTwoHandSelecting = false
                onSelectionConfirmed?(selectionStartLeft, selectionStartRight)
            }
            resetDetection()
            return
        }
        // Hand detected — reset grace counter
        pinchGraceFramesRemaining = wasPinching ? pinchGraceFramesMax : 0
        
        // DEPTH GATE: Only accept hands within 1m of the camera.
        // With a 24mm ultrawide lens the user's drawing hand + forearm is typically
        // 0.3–0.7m away. Anything beyond 1m is a bystander or background object.
        let maxHandDistance: Float = 1.0
        let nearObservations = observations.filter { obs in
            guard let wrist = try? obs.recognizedPoint(.wrist) else { return false }
            let wristNorm = CGPoint(x: wrist.x, y: wrist.y)
            if let depth = arSessionManager?.sampleDepthAtNormalizedPoint(wristNorm),
               depth > maxHandDistance {
                return false  // too far — reject
            }
            return true  // close enough, or no depth data (accept to avoid blocking)
        }
        
        guard !nearObservations.isEmpty else {
            // All detected hands are too far away — treat as no hand.
            if isTwoHandSelecting {
                isTwoHandSelecting = false
                onSelectionConfirmed?(selectionStartLeft, selectionStartRight)
            }
            if !wasPinching { resetDetection() }
            return
        }
        
        isHandDetected = true
        
        // Two hands: check for selection rectangle first (takes priority over single-hand draw)
        if nearObservations.count >= 2 {
            let handled = processTwoHandGesture(nearObservations[0], nearObservations[1])
            if handled || isTwoHandSelecting {
                // While two-hand select is active, suppress single-hand draw
                updateGestureMode(.select)
                return
            }
            
            // Important: with two visible hands, suppress single-hand draw for this frame.
            // This prevents random stroke writes while user is entering two-hand selection.
            wasPinching = false
            strokeJustStarted = false
            strokeStartSkipCount = 0
            updateGestureMode(.none)
            return
        }
        
        // If we WERE two-hand selecting but one hand dropped off, confirm selection
        if isTwoHandSelecting {
            isTwoHandSelecting = false
            onSelectionConfirmed?(selectionStartLeft, selectionStartRight)
        }
        
        // Single hand: existing gesture logic (draw, erase, kon, etc.) + fist + 3-finger resize
        if let primaryHand = nearObservations.first {
            processSingleHand(primaryHand)
        }
    }
    
    private func processSingleHand(_ observation: VNHumanHandPoseObservation) {
        do {
            // PERFORMANCE OPTIMIZATION: Only extract landmarks we actually need
            // For gesture detection, we need thumb/index tips for pinch, and MCP/wrist for palm detection
            // We DON'T need all 21 landmarks converted to 3D!
            
            let thumbTip = try observation.recognizedPoint(.thumbTip)
            let indexTip = try observation.recognizedPoint(.indexTip)
            let indexMCP = try observation.recognizedPoint(.indexMCP)
            let middleMCP = try observation.recognizedPoint(.middleMCP)
            let ringMCP = try observation.recognizedPoint(.ringMCP)
            let littleMCP = try observation.recognizedPoint(.littleMCP)
            let wrist = try observation.recognizedPoint(.wrist)
            
            // For open palm detection, we need finger tips and PIPs
            let middleTip = try observation.recognizedPoint(.middleTip)
            let ringTip = try observation.recognizedPoint(.ringTip)
            let littleTip = try observation.recognizedPoint(.littleTip)
            let indexPIP = try observation.recognizedPoint(.indexPIP)
            let middlePIP = try observation.recognizedPoint(.middlePIP)
            let ringPIP = try observation.recognizedPoint(.ringPIP)
            let littlePIP = try observation.recognizedPoint(.littlePIP)
            
            // Calculate 2D palm center (normalized Vision coordinates) for erasing
            let palmCenterX = (wrist.x + indexMCP.x + middleMCP.x + ringMCP.x) / 4.0
            let palmCenterY = (wrist.y + indexMCP.y + middleMCP.y + ringMCP.y) / 4.0
            currentPalmNormalizedPoint = CGPoint(x: palmCenterX, y: palmCenterY)
            
            // Store stable joint 2D positions for depth sampling (only wrist + indexMCP for performance)
            stableJointsForDepth = [
                CGPoint(x: wrist.x, y: wrist.y),
                CGPoint(x: indexMCP.x, y: indexMCP.y)
            ]
            
            // Notify ARSessionManager about stable joints for depth tracking (throttled internally)
            arSessionManager?.updateHandDepthTracking(stableJoints: stableJointsForDepth)
            
            // Calculate confidence purely from primary pinch fingers
            // This prevents tracking from dropping if middle/ring/pinky fingers go off-screen
            let pinchAnchorPoints = [thumbTip, indexTip]
            self.confidence = pinchAnchorPoints.map { $0.confidence }.reduce(0, +) / Float(pinchAnchorPoints.count)
            
            // PERFORMANCE: Use lightweight 2D-only gesture detection
            // Only convert to 3D the points we need for callbacks (pinch point, palm center)
            let gestureResult = recognizeGesture2D(
                thumbTip: thumbTip, indexTip: indexTip,
                middleTip: middleTip, ringTip: ringTip, littleTip: littleTip,
                indexPIP: indexPIP, middlePIP: middlePIP, ringPIP: ringPIP, littlePIP: littlePIP,
                indexMCP: indexMCP, middleMCP: middleMCP, ringMCP: ringMCP, littleMCP: littleMCP,
                wrist: wrist
            )
            
            // Update stored landmarks (minimal conversion for UI display)
            // Convert only essential landmarks lazily
            var minimalLandmarks = HandLandmarks()
            if gestureResult == .draw {
                // Only convert pinch point for drawing
                let pinchX = (thumbTip.x + indexTip.x) / 2.0
                let pinchY = (thumbTip.y + indexTip.y) / 2.0
                let pinchNormalized = CGPoint(x: pinchX, y: pinchY)
                if let pinch3D = arSessionManager?.raycastHandLandmark(normalizedPoint: pinchNormalized, isDrawing: wasPinching) {
                    // Store as thumb/index so pinchPoint computed property works
                    minimalLandmarks.thumbTip = pinch3D
                    minimalLandmarks.indexTip = pinch3D
                }
            }
            
            self.landmarks = minimalLandmarks
            self.previousLandmarks = self.landmarks
            
            // Fire callbacks based on gesture
            handleGestureResult(gestureResult, thumbTip: thumbTip, indexTip: indexTip)
            
        } catch {
            resetDetection()
        }
    }
    
    /// 2D-only gesture recognition (FAST - no 3D conversion needed)
    private func recognizeGesture2D(
        thumbTip: VNRecognizedPoint, indexTip: VNRecognizedPoint,
        middleTip: VNRecognizedPoint, ringTip: VNRecognizedPoint, littleTip: VNRecognizedPoint,
        indexPIP: VNRecognizedPoint, middlePIP: VNRecognizedPoint, ringPIP: VNRecognizedPoint, littlePIP: VNRecognizedPoint,
        indexMCP: VNRecognizedPoint, middleMCP: VNRecognizedPoint, ringMCP: VNRecognizedPoint, littleMCP: VNRecognizedPoint,
        wrist: VNRecognizedPoint
    ) -> GestureMode {
        
        // Use a lower confidence threshold when actively drawing so brief
        // tracking noise in low light doesn't kill the stroke.
        let effectiveConfidence = wasPinching ? config.drawingConfidenceThreshold : config.confidenceThreshold
        guard confidence >= effectiveConfidence else {
            return .none
        }
        
        let selectionActive = isSelectionActive?() ?? false
        
        // Resize is intentionally disabled when nothing is selected.
        // Only selected pinch-resize path is allowed below.
        
        // ── Pointing → Interact with UI/Folders ──────────────────────────────
        if isPointing2D(
            thumbTip: thumbTip, indexTip: indexTip,
            middleTip: middleTip, ringTip: ringTip, littleTip: littleTip,
            indexPIP: indexPIP, middlePIP: middlePIP, ringPIP: ringPIP, littlePIP: littlePIP,
            wrist: wrist
        ) {
            let pointNorm = CGPoint(x: indexTip.x, y: indexTip.y)
            let point3D = arSessionManager?.raycastHandLandmarkDepthAware(normalizedPoint: pointNorm)
            onPointUpdated?(pointNorm, point3D)
            return .point
        }
        
        // ── Selected-move gesture (joined palm) ───────────────────────────────
        // When selection is active, use a tighter open-palm shape to move selected content.
        if selectionActive && isMovePalm2D(
            thumbTip: thumbTip, indexTip: indexTip, middleTip: middleTip, ringTip: ringTip, littleTip: littleTip,
            indexPIP: indexPIP, middlePIP: middlePIP, ringPIP: ringPIP, littlePIP: littlePIP,
            indexMCP: indexMCP, wrist: wrist
        ) {
            wasMovingWithPalm = true
            // Palm anchor projected slightly toward fingertips so tracking doesn't
            // drift to wrist/forearm depth on back-of-hand poses.
            let mcpCenter = CGPoint(x: (indexMCP.x + middleMCP.x + ringMCP.x + littleMCP.x) / 4.0,
                                    y: (indexMCP.y + middleMCP.y + ringMCP.y + littleMCP.y) / 4.0)
            let tipCenter = CGPoint(x: (indexTip.x + middleTip.x + ringTip.x + littleTip.x) / 4.0,
                                    y: (indexTip.y + middleTip.y + ringTip.y + littleTip.y) / 4.0)
            let computedPalm = CGPoint(
                x: mcpCenter.x + (tipCenter.x - mcpCenter.x) * 0.35,
                y: mcpCenter.y + (tipCenter.y - mcpCenter.y) * 0.35
            )
            let palmNorm = currentPalmNormalizedPoint ?? computedPalm
            if let palm3D = arSessionManager?.raycastHandLandmarkDepthAware(normalizedPoint: palmNorm)
                ?? arSessionManager?.raycastToNearestPlane(normalizedPoint: palmNorm) {
                onFistMoveUpdated?(palmNorm, palm3D)
            }
            return .fistMove
        }
        if wasMovingWithPalm {
            wasMovingWithPalm = false
            onFistMoveEnded?()
        }
        
        // ── Single-finger pinch (index + thumb only) → draw ───────────────────
        let pinchDist2D = distance(thumbTip, indexTip)
        // Middle touching thumb invalidates a draw pinch (but that case is caught by 3-finger above)
        let ringTouching   = ringTip.confidence   > config.confidenceThreshold && distance(thumbTip, ringTip)   < config.pinchThreshold
        let littleTouching = littleTip.confidence > config.confidenceThreshold && distance(thumbTip, littleTip) < config.pinchThreshold
        let invalidPinch   = ringTouching || littleTouching
        
        let wasPinchingBefore = wasPinching
        if wasPinching {
            if pinchDist2D > config.pinchReleaseThreshold || invalidPinch {
                // Pinch released — check for double-tap deselect
                let now = Date()
                let timeSinceLast = now.timeIntervalSince(lastPinchReleaseTime)
                if timeSinceLast < 0.40 {
                    quickTapCount += 1
                    if quickTapCount >= 2 {
                        quickTapCount = 0
                        onDoubleTapDetected?()
                    }
                } else {
                    quickTapCount = 1
                }
                lastPinchReleaseTime = now
                wasPinching = false
            }
        } else {
            if pinchDist2D < config.pinchThreshold && !invalidPinch {
                wasPinching = true
                if selectionActive {
                    selectionPinchFrames = 0
                }
            }
        }
        
        if wasPinching {
            if !wasPinchingBefore {
                strokeJustStarted = true
                strokeStartSkipCount = strokeStartSkipFrames
            }
            if selectionActive {
                // Pinch while selected = resize; require a few stable frames so double-tap deselect
                // doesn't accidentally trigger resize.
                selectionPinchFrames += 1
                if selectionPinchFrames >= 3 {
                    let pinchPoint = CGPoint(x: (thumbTip.x + indexTip.x) / 2.0, y: (thumbTip.y + indexTip.y) / 2.0)
                    let prev = selectionResizeLastPinchPoint2D ?? pinchPoint
                    let dx = Float(pinchPoint.x - prev.x)
                    let dy = Float(pinchPoint.y - prev.y)
                    // Intentional directional resize:
                    // right/up movement => upscale, left/down => downscale
                    let directional = (dx + dy) * 2.1
                    let scaleDelta = min(max(1.0 + directional, 0.982), 1.018)
                    selectionResizeLastPinchPoint2D = pinchPoint
                    wasSelectionPinchResizing = true
                    onThreeFingerResizeUpdated?(scaleDelta)
                    return .resize
                } else {
                    return .none
                }
            } else {
                return .draw
            }
        }
        
        strokeJustStarted = false
        strokeStartSkipCount = 0
        selectionPinchFrames = 0
        selectionResizeLastPinchPoint2D = nil
        if selectionActive && wasSelectionPinchResizing {
            wasSelectionPinchResizing = false
            onThreeFingerResizeEnded?()
        }
        
        // While something is selected, palm is reserved for move only.
        // Prevent erase from stealing selected-move interaction.
        if selectionActive {
            return .none
        }
        
        // ── Open palm → erase ─────────────────────────────────────────────────
        if isOpenPalm2D(
            thumbTip: thumbTip, indexTip: indexTip, middleTip: middleTip, ringTip: ringTip, littleTip: littleTip,
            indexPIP: indexPIP, middlePIP: middlePIP, ringPIP: ringPIP, littlePIP: littlePIP,
            indexMCP: indexMCP, wrist: wrist
        ) {
            return .erase
        }
        
        // ── Kon gesture ───────────────────────────────────────────────────────
        let isAlreadyKon = currentMode == .kon
        if isKonGesture2D(
            thumbTip: thumbTip, indexTip: indexTip, middleTip: middleTip, ringTip: ringTip, littleTip: littleTip,
            indexPIP: indexPIP, middlePIP: middlePIP, ringPIP: ringPIP, littlePIP: littlePIP,
            wrist: wrist,
            isAlreadyKon: isAlreadyKon
        ) {
            return .kon
        }
        
        return .none
    }
    
    /// Handle gesture result and fire appropriate callbacks
    private func handleGestureResult(_ mode: GestureMode, thumbTip: VNRecognizedPoint, indexTip: VNRecognizedPoint) {
        
        updateGestureMode(mode)
        
        switch mode {
        case .draw:
            if strokeStartSkipCount > 0 {
                strokeStartSkipCount -= 1
                return
            }
            let pinchX = (thumbTip.x + indexTip.x) / 2.0
            let pinchY = (thumbTip.y + indexTip.y) / 2.0
            let pinchNormalized = CGPoint(x: pinchX, y: pinchY)
            if let pinch3D = arSessionManager?.raycastHandLandmark(normalizedPoint: pinchNormalized, isDrawing: true) {
                gesturePosition = pinch3D
                onPinchPositionUpdated?(pinch3D)
            }
            
        case .erase:
            if let palmPoint = currentPalmNormalizedPoint {
                onEraseActivated?(palmPoint)
            }
            
        case .select, .fistMove, .resize, .none, .point:
            // Handled inline in recognizeGesture2D / processTwoHandGesture
            break
            
        case .kon:
            // Start hold
            if !konAlreadyFired && konHoldStartTime == nil {
                konHoldStartTime = Date()
                onKonHoldStarted?()
                
                // Start 1-second task
                konHoldTask?.cancel()
                konHoldTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if !Task.isCancelled {
                        guard let self = self, self.currentMode == .kon else { return }
                        self.konAlreadyFired = true
                        self.onKonTriggered?()
                    }
                }
            }
        }
        
        // Reset Kon state when gesture changes away from .kon
        if mode != .kon {
            if konHoldStartTime != nil && !konAlreadyFired {
                // Gesture dropped before 1s — cancelled
                onKonHoldCancelled?()
            }
            konAlreadyFired = false
            konHoldTask?.cancel()
            konHoldTask = nil
            konHoldStartTime = nil
        }
    }
    
    /// 2D open palm detection (no 3D conversion needed)
    private func isOpenPalm2D(
        thumbTip: VNRecognizedPoint, indexTip: VNRecognizedPoint,
        middleTip: VNRecognizedPoint, ringTip: VNRecognizedPoint, littleTip: VNRecognizedPoint,
        indexPIP: VNRecognizedPoint, middlePIP: VNRecognizedPoint, ringPIP: VNRecognizedPoint, littlePIP: VNRecognizedPoint,
        indexMCP: VNRecognizedPoint, wrist: VNRecognizedPoint
    ) -> Bool {
        // Thumb not pinching index
        let thumbIndexDist = distance(thumbTip, indexTip)
        if thumbIndexDist < config.pinchThreshold * 1.5 {
            return false
        }
        
        // Open palm logic applies when all fingers are extended outwards
        // We use distance from wrist rather than simple up/down to be rotation independent
        
        let indexExtended = distance(indexTip, wrist) > distance(indexPIP, wrist) * 1.2
        let middleExtended = distance(middleTip, wrist) > distance(middlePIP, wrist) * 1.2
        let ringExtended = distance(ringTip, wrist) > distance(ringPIP, wrist) * 1.2
        let littleExtended = distance(littleTip, wrist) > distance(littlePIP, wrist) * 1.2
        
        if !(indexExtended && middleExtended && ringExtended && littleExtended) {
            return false
        }
        
        // Fingers not too spread
        let indexMiddleDist = distance(indexTip, middleTip)
        let middleRingDist = distance(middleTip, ringTip)
        let ringLittleDist = distance(ringTip, littleTip)
        let avgSpread = (indexMiddleDist + middleRingDist + ringLittleDist) / 3.0
        
        return avgSpread < 0.08
    }
    
    /// 2D Kon gesture detection
    /// Gesture: index + pinky extended (in air), middle + ring curled and touching thumb
    private func isKonGesture2D(
        thumbTip: VNRecognizedPoint, indexTip: VNRecognizedPoint,
        middleTip: VNRecognizedPoint, ringTip: VNRecognizedPoint, littleTip: VNRecognizedPoint,
        indexPIP: VNRecognizedPoint, middlePIP: VNRecognizedPoint, ringPIP: VNRecognizedPoint, littlePIP: VNRecognizedPoint,
        wrist: VNRecognizedPoint,
        isAlreadyKon: Bool
    ) -> Bool {
        // Add gesture stickiness: if already holding Kon, loosen criteria significantly prevents flickering on/off
        let extensionMult: Float = isAlreadyKon ? 1.0 : 1.1
        let touchThreshold: Float = isAlreadyKon ? 0.20 : 0.12
        let separationThreshold: Float = isAlreadyKon ? 0.06 : 0.08
        
        // Index and Pinky must be largely extended
        let indexExtended = distance(indexTip, wrist) > distance(indexPIP, wrist) * extensionMult
        let pinkyExtended = distance(littleTip, wrist) > distance(littlePIP, wrist) * extensionMult
        guard indexExtended && pinkyExtended else { return false }
        
        // Middle and Ring must be curled closely to the thumb
        let middleThumbDist = distance(middleTip, thumbTip)
        let ringThumbDist = distance(ringTip, thumbTip)
        guard middleThumbDist < touchThreshold && ringThumbDist < touchThreshold else { return false }
        
        // Index and Pinky must NOT be touching the thumb (prevent false pinch)
        let indexThumbDist = distance(indexTip, thumbTip)
        let pinkyThumbDist = distance(littleTip, thumbTip)
        guard indexThumbDist > separationThreshold && pinkyThumbDist > separationThreshold else { return false }
        
        return true
    }
    
    /// Returns true if a two-hand selection gesture was detected (suppresses single-hand logic).
    @discardableResult
    private func processTwoHandGesture(_ hand1: VNHumanHandPoseObservation, _ hand2: VNHumanHandPoseObservation) -> Bool {
        do {
            let thumb1 = try hand1.recognizedPoint(.thumbTip)
            let index1 = try hand1.recognizedPoint(.indexTip)
            let thumb2 = try hand2.recognizedPoint(.thumbTip)
            let index2 = try hand2.recognizedPoint(.indexTip)
            
            guard thumb1.confidence > config.confidenceThreshold,
                  index1.confidence > config.confidenceThreshold,
                  thumb2.confidence > config.confidenceThreshold,
                  index2.confidence > config.confidenceThreshold else {
                return false
            }
            
            let pinch1Dist = distance(thumb1, index1)
            let pinch2Dist = distance(thumb2, index2)
            
            // Both hands must be pinching for a selection gesture
            let threshold = isTwoHandSelecting ? config.pinchReleaseThreshold : config.pinchThreshold
            let bothPinching = pinch1Dist < threshold && pinch2Dist < threshold
            
            if bothPinching {
                // Determine which hand is "left" by X coordinate
                let mid1 = midpoint(thumb1, index1)
                let mid2 = midpoint(thumb2, index2)
                let leftPoint  = mid1.x < mid2.x ? mid1 : mid2
                let rightPoint = mid1.x < mid2.x ? mid2 : mid1
                
                // Extra smoothing just for selection to keep the rectangle intentional.
                let smoothing = CGFloat(min(max(config.smoothingFactor, 0.75), 0.95))
                let filteredLeft = smoothedLeftPinch2D.map { lerpPoint($0, leftPoint, t: 1 - smoothing) } ?? leftPoint
                let filteredRight = smoothedRightPinch2D.map { lerpPoint($0, rightPoint, t: 1 - smoothing) } ?? rightPoint
                
                leftPinchPoint2D  = filteredLeft
                rightPinchPoint2D = filteredRight
                smoothedLeftPinch2D = filteredLeft
                smoothedRightPinch2D = filteredRight
                
                // Avoid accidental "selection" when both pinches collapse to nearly one point.
                if distance2D(filteredLeft, filteredRight) < 0.035 {
                    return false
                }
                
                if !isTwoHandSelecting {
                    // First frame of selection — record starting corners
                    isTwoHandSelecting = true
                    selectionStartLeft  = filteredLeft
                    selectionStartRight = filteredRight
                }
                
                onSelectionRectUpdated?(filteredLeft, filteredRight)
                return true
            } else if isTwoHandSelecting {
                // One or both pinches released — confirm selection
                isTwoHandSelecting = false
                onSelectionConfirmed?(leftPinchPoint2D, rightPinchPoint2D)
                smoothedLeftPinch2D = nil
                smoothedRightPinch2D = nil
                return true  // Still consume this frame to avoid spurious draw
            }
            
            return false
        } catch {
            return false
        }
    }
    
    // MARK: - Three-Finger Pinch Detection
    
    /// Returns the average distance among index, middle, and thumb tips.
    /// Returns nil if any tip has low confidence.
    private func threeFingerPinchDistance(
        thumbTip: VNRecognizedPoint,
        indexTip: VNRecognizedPoint,
        middleTip: VNRecognizedPoint
    ) -> Float? {
        guard thumbTip.confidence  > config.confidenceThreshold,
              indexTip.confidence  > config.confidenceThreshold,
              middleTip.confidence > config.confidenceThreshold else { return nil }
        let d1 = distance(thumbTip, indexTip)
        let d2 = distance(thumbTip, middleTip)
        let d3 = distance(indexTip, middleTip)
        return (d1 + d2 + d3) / 3.0
    }
    
    /// Public accessor for drawing state (true when actively pinching/drawing)
    var isDrawing: Bool {
        return wasPinching
    }
    
    // MARK: - State Management
    
    private func updateGestureMode(_ newMode: GestureMode) {
        let now = Date()
        
        // Debounce rapid mode changes
        guard now.timeIntervalSince(lastGestureChangeTime) >= config.gestureDebounceTime else {
            return
        }
        
        if newMode != currentMode {
            lastGestureChangeTime = now
            currentMode = newMode
            onGestureModeChanged?(newMode)
        }
    }
    
    private func resetDetection() {
        isHandDetected = false
        landmarks = nil
        gesturePosition = nil
        confidence = 0
        updateGestureMode(.none)
    }
    
    // MARK: - Helper Methods
    
    private func distance(_ p1: VNRecognizedPoint, _ p2: VNRecognizedPoint) -> Float {
        let dx = p1.x - p2.x
        let dy = p1.y - p2.y
        return Float(sqrt(dx * dx + dy * dy))
    }
    
    private func distance2D(_ p1: CGPoint, _ p2: CGPoint) -> CGFloat {
        let dx = p1.x - p2.x
        let dy = p1.y - p2.y
        return sqrt(dx * dx + dy * dy)
    }
    
    private func midpoint(_ p1: VNRecognizedPoint, _ p2: VNRecognizedPoint) -> CGPoint {
        CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
    }
    
    private func lerpPoint(_ from: CGPoint, _ to: CGPoint, t: CGFloat) -> CGPoint {
        CGPoint(
            x: from.x + (to.x - from.x) * t,
            y: from.y + (to.y - from.y) * t
        )
    }
    
    private func isPointing2D(
        thumbTip: VNRecognizedPoint, indexTip: VNRecognizedPoint,
        middleTip: VNRecognizedPoint, ringTip: VNRecognizedPoint, littleTip: VNRecognizedPoint,
        indexPIP: VNRecognizedPoint, middlePIP: VNRecognizedPoint, ringPIP: VNRecognizedPoint, littlePIP: VNRecognizedPoint,
        wrist: VNRecognizedPoint
    ) -> Bool {
        // "Only index out" recognizer:
        // index strongly extended, all other fingers not extended, and not thumb-index pinch.
        let indexExtended = distance(indexTip, wrist) > distance(indexPIP, wrist) * 1.28
        
        let middleNotExtended = distance(middleTip, wrist) < distance(middlePIP, wrist) * 1.03
        let ringNotExtended = distance(ringTip, wrist) < distance(ringPIP, wrist) * 1.03
        let littleNotExtended = distance(littleTip, wrist) < distance(littlePIP, wrist) * 1.03
        
        let thumbIndexDist = distance(thumbTip, indexTip)
        let notPinching = thumbIndexDist > max(config.pinchReleaseThreshold, 0.04)
        
        return indexExtended && middleNotExtended && ringNotExtended && littleNotExtended && notPinching
    }
    
    /// Joined-palm gesture for move while selection is active.
    /// Allows slight gaps between fingers but prevents loose wide-spread palm.
    private func isMovePalm2D(
        thumbTip: VNRecognizedPoint, indexTip: VNRecognizedPoint,
        middleTip: VNRecognizedPoint, ringTip: VNRecognizedPoint, littleTip: VNRecognizedPoint,
        indexPIP: VNRecognizedPoint, middlePIP: VNRecognizedPoint, ringPIP: VNRecognizedPoint, littlePIP: VNRecognizedPoint,
        indexMCP: VNRecognizedPoint, wrist: VNRecognizedPoint
    ) -> Bool {
        let thumbIndexDist = distance(thumbTip, indexTip)
        if thumbIndexDist < config.pinchThreshold * 1.25 { return false }
        
        let indexExtended = distance(indexTip, wrist) > distance(indexPIP, wrist) * 1.12
        let middleExtended = distance(middleTip, wrist) > distance(middlePIP, wrist) * 1.12
        let ringExtended = distance(ringTip, wrist) > distance(ringPIP, wrist) * 1.10
        let littleExtended = distance(littleTip, wrist) > distance(littlePIP, wrist) * 1.10
        guard indexExtended && middleExtended && ringExtended && littleExtended else { return false }
        
        // Joined fingers: tighter than a relaxed open palm, but not fully pinched.
        let dIM = distance(indexTip, middleTip)
        let dMR = distance(middleTip, ringTip)
        let dRL = distance(ringTip, littleTip)
        let avgSpread = (dIM + dMR + dRL) / 3.0
        if avgSpread < 0.010 || avgSpread > 0.060 { return false }
        
        // Keep move gesture stable around palm center.
        let palmToIndexMCP = distance(indexMCP, wrist)
        let tipHeight = (distance(indexTip, wrist) + distance(middleTip, wrist) + distance(ringTip, wrist)) / 3.0
        return tipHeight > palmToIndexMCP * 1.10
    }
    
    // MARK: - Simulator Mock
    
    #if targetEnvironment(simulator)
    private var mockGestureTimer: Timer?
    private var mockGestureIndex = 0
    
    private func simulateMockGesture() {
        // Cycle through mock gestures for testing
        isHandDetected = true
        confidence = 0.9
        
        // Create mock landmarks
        var mockLandmarks = HandLandmarks()
        mockLandmarks.thumbTip = SIMD3<Float>(0.1, 1.5, -0.5)
        mockLandmarks.indexTip = SIMD3<Float>(0.12, 1.52, -0.5)
        mockLandmarks.middleTip = SIMD3<Float>(0.14, 1.54, -0.5)
        mockLandmarks.ringTip = SIMD3<Float>(0.16, 1.52, -0.5)
        mockLandmarks.littleTip = SIMD3<Float>(0.18, 1.5, -0.5)
        mockLandmarks.wrist = SIMD3<Float>(0.1, 1.4, -0.45)
        mockLandmarks.indexMCP = SIMD3<Float>(0.11, 1.45, -0.48)
        mockLandmarks.middleMCP = SIMD3<Float>(0.13, 1.45, -0.48)
        mockLandmarks.ringMCP = SIMD3<Float>(0.15, 1.45, -0.48)
        
        self.landmarks = mockLandmarks
        
        // Simulate pinch gesture
        gesturePosition = mockLandmarks.pinchPoint
        updateGestureMode(.draw)
    }
    #endif
}

// MARK: - Frame Delegate Integration

extension GestureRecognizer {
    
    /// Start processing AR frames automatically
    func startProcessing() {
        #if !targetEnvironment(simulator)
        // The ARSessionManager will call processARFrame for each frame
        #endif
    }
    
    /// Stop processing
    func stopProcessing() {
        resetDetection()
    }
}
