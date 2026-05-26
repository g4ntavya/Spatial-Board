// DrawingOverlay.swift
// WhiteBoARd - Spatial AR Notetaking
// Overlay showing hand tracking visualization and gesture feedback

import SwiftUI
import simd

/// Overlay view showing hand landmarks and gesture feedback
struct DrawingOverlay: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Hand landmark visualization
                if let landmarks = appState.handLandmarks {
                    HandVisualization(landmarks: landmarks, size: geometry.size)
                }
                
                // Gesture feedback indicator
                if appState.currentGestureMode == .draw {
                    DrawingFeedback()
                }
                
                // Erase area indicator
                if appState.currentGestureMode == .erase {
                    EraseIndicator()
                }
                
                // Selection rectangle overlay
                SelectionOverlay(size: geometry.size)

                // Move debug overlay
                if appState.debugMoveOverlayEnabled {
                    MoveDebugOverlay(size: geometry.size)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Hand Visualization

struct HandVisualization: View {
    let landmarks: HandLandmarks
    let size: CGSize
    
    var body: some View {
        Canvas { context, canvasSize in
            // Draw finger connections
            drawFingerConnections(context: context, size: canvasSize)
            
            // Draw landmark points
            drawLandmarkPoints(context: context, size: canvasSize)
            
            // Draw pinch indicator
            if let pinchPoint = landmarks.pinchPoint,
               let pinchDist = landmarks.pinchDistance,
               pinchDist < 0.05 {
                drawPinchIndicator(context: context, point: pinchPoint, size: canvasSize)
            }
        }
    }
    
    private func drawFingerConnections(context: GraphicsContext, size: CGSize) {
        let lineColor = Color.white.opacity(0.5)
        let lineWidth: CGFloat = 2
        
        // Thumb
        drawConnection(context: context, from: landmarks.thumbCMC, to: landmarks.thumbMP, color: lineColor, width: lineWidth, size: size)
        drawConnection(context: context, from: landmarks.thumbMP, to: landmarks.thumbIP, color: lineColor, width: lineWidth, size: size)
        drawConnection(context: context, from: landmarks.thumbIP, to: landmarks.thumbTip, color: lineColor, width: lineWidth, size: size)
        
        // Index
        drawConnection(context: context, from: landmarks.indexMCP, to: landmarks.indexPIP, color: lineColor, width: lineWidth, size: size)
        drawConnection(context: context, from: landmarks.indexPIP, to: landmarks.indexDIP, color: lineColor, width: lineWidth, size: size)
        drawConnection(context: context, from: landmarks.indexDIP, to: landmarks.indexTip, color: lineColor, width: lineWidth, size: size)
        
        // Middle
        drawConnection(context: context, from: landmarks.middleMCP, to: landmarks.middlePIP, color: lineColor, width: lineWidth, size: size)
        drawConnection(context: context, from: landmarks.middlePIP, to: landmarks.middleDIP, color: lineColor, width: lineWidth, size: size)
        drawConnection(context: context, from: landmarks.middleDIP, to: landmarks.middleTip, color: lineColor, width: lineWidth, size: size)
        
        // Ring
        drawConnection(context: context, from: landmarks.ringMCP, to: landmarks.ringPIP, color: lineColor, width: lineWidth, size: size)
        drawConnection(context: context, from: landmarks.ringPIP, to: landmarks.ringDIP, color: lineColor, width: lineWidth, size: size)
        drawConnection(context: context, from: landmarks.ringDIP, to: landmarks.ringTip, color: lineColor, width: lineWidth, size: size)
        
        // Little
        drawConnection(context: context, from: landmarks.littleMCP, to: landmarks.littlePIP, color: lineColor, width: lineWidth, size: size)
        drawConnection(context: context, from: landmarks.littlePIP, to: landmarks.littleDIP, color: lineColor, width: lineWidth, size: size)
        drawConnection(context: context, from: landmarks.littleDIP, to: landmarks.littleTip, color: lineColor, width: lineWidth, size: size)
        
        // Palm connections
        drawConnection(context: context, from: landmarks.wrist, to: landmarks.thumbCMC, color: lineColor, width: lineWidth, size: size)
        drawConnection(context: context, from: landmarks.wrist, to: landmarks.indexMCP, color: lineColor, width: lineWidth, size: size)
        drawConnection(context: context, from: landmarks.wrist, to: landmarks.middleMCP, color: lineColor, width: lineWidth, size: size)
        drawConnection(context: context, from: landmarks.wrist, to: landmarks.ringMCP, color: lineColor, width: lineWidth, size: size)
        drawConnection(context: context, from: landmarks.wrist, to: landmarks.littleMCP, color: lineColor, width: lineWidth, size: size)
    }
    
    private func drawConnection(context: GraphicsContext, from: SIMD3<Float>?, to: SIMD3<Float>?, color: Color, width: CGFloat, size: CGSize) {
        guard let from = from, let to = to else { return }
        
        let fromScreen = projectToScreen(from, size: size)
        let toScreen = projectToScreen(to, size: size)
        
        var path = Path()
        path.move(to: fromScreen)
        path.addLine(to: toScreen)
        
        context.stroke(path, with: .color(color), lineWidth: width)
    }
    
    private func drawLandmarkPoints(context: GraphicsContext, size: CGSize) {
        let allPoints: [SIMD3<Float>?] = [
            landmarks.thumbTip, landmarks.thumbIP, landmarks.thumbMP, landmarks.thumbCMC,
            landmarks.indexTip, landmarks.indexDIP, landmarks.indexPIP, landmarks.indexMCP,
            landmarks.middleTip, landmarks.middleDIP, landmarks.middlePIP, landmarks.middleMCP,
            landmarks.ringTip, landmarks.ringDIP, landmarks.ringPIP, landmarks.ringMCP,
            landmarks.littleTip, landmarks.littleDIP, landmarks.littlePIP, landmarks.littleMCP,
            landmarks.wrist
        ]
        
        for point in allPoints {
            guard let point = point else { continue }
            let screenPoint = projectToScreen(point, size: size)
            
            let pointPath = Path(ellipseIn: CGRect(
                x: screenPoint.x - 4,
                y: screenPoint.y - 4,
                width: 8,
                height: 8
            ))
            
            context.fill(pointPath, with: .color(.white.opacity(0.8)))
        }
        
        // Highlight fingertips
        let fingertips: [SIMD3<Float>?] = [
            landmarks.thumbTip, landmarks.indexTip, landmarks.middleTip,
            landmarks.ringTip, landmarks.littleTip
        ]
        
        for tip in fingertips {
            guard let tip = tip else { continue }
            let screenPoint = projectToScreen(tip, size: size)
            
            let tipPath = Path(ellipseIn: CGRect(
                x: screenPoint.x - 6,
                y: screenPoint.y - 6,
                width: 12,
                height: 12
            ))
            
            context.fill(tipPath, with: .color(.cyan))
        }
    }
    
    private func drawPinchIndicator(context: GraphicsContext, point: SIMD3<Float>, size: CGSize) {
        let screenPoint = projectToScreen(point, size: size)
        
        // Outer glow
        let outerPath = Path(ellipseIn: CGRect(
            x: screenPoint.x - 20,
            y: screenPoint.y - 20,
            width: 40,
            height: 40
        ))
        context.fill(outerPath, with: .color(.white.opacity(0.2)))
        
        // Inner point
        let innerPath = Path(ellipseIn: CGRect(
            x: screenPoint.x - 8,
            y: screenPoint.y - 8,
            width: 16,
            height: 16
        ))
        context.fill(innerPath, with: .color(.green))
    }
    
    private func projectToScreen(_ point: SIMD3<Float>, size: CGSize) -> CGPoint {
        // Simple orthographic projection for visualization
        // In production, this would use the camera intrinsics
        let screenX = CGFloat(point.x + 0.5) * size.width
        let screenY = CGFloat(1.0 - (point.y - 1.0)) * size.height / 2 // Approximate
        
        return CGPoint(x: screenX, y: screenY)
    }
}

// MARK: - Drawing Feedback

struct DrawingFeedback: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        if let landmarks = appState.handLandmarks,
           let pinchPoint = landmarks.pinchPoint {
            
            // Show drawing cursor at pinch point
            GeometryReader { geometry in
                let screenPoint = projectToScreen(pinchPoint, size: geometry.size)
                
                ZStack {
                    // Pulsing outer ring
                    Circle()
                        .stroke(appState.currentStrokeColor.swiftUIColor, lineWidth: 2)
                        .frame(width: 30, height: 30)
                        .scaleEffect(appState.isDrawing ? 1.2 : 1.0)
                        .opacity(appState.isDrawing ? 0.5 : 0.3)
                        .animation(.easeInOut(duration: 0.3).repeatForever(), value: appState.isDrawing)
                    
                    // Center point
                    Circle()
                        .fill(appState.currentStrokeColor.swiftUIColor)
                        .frame(width: 10, height: 10)
                }
                .position(screenPoint)
            }
        }
    }
    
    private func projectToScreen(_ point: SIMD3<Float>, size: CGSize) -> CGPoint {
        let screenX = CGFloat(point.x + 0.5) * size.width
        let screenY = CGFloat(1.0 - (point.y - 1.0)) * size.height / 2
        return CGPoint(x: screenX, y: screenY)
    }
}

// MARK: - Erase Indicator

struct EraseIndicator: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        if let landmarks = appState.handLandmarks {
            GeometryReader { geometry in
                // Calculate palm center
                if let palmCenter = calculatePalmCenter(landmarks) {
                    let screenPoint = projectToScreen(palmCenter, size: geometry.size)
                    
                    ZStack {
                        // Erase area circle
                        Circle()
                            .stroke(Color.red, lineWidth: 3)
                            .frame(width: 80, height: 80)
                        
                        // X symbol
                        Image(systemName: "xmark")
                            .font(.title)
                            .foregroundColor(.red)
                    }
                    .position(screenPoint)
                }
            }
        }
    }
    
    private func calculatePalmCenter(_ landmarks: HandLandmarks) -> SIMD3<Float>? {
        guard let wrist = landmarks.wrist,
              let indexMCP = landmarks.indexMCP,
              let middleMCP = landmarks.middleMCP,
              let ringMCP = landmarks.ringMCP else {
            return nil
        }
        
        return (wrist + indexMCP + middleMCP + ringMCP) / 4.0
    }
    
    private func projectToScreen(_ point: SIMD3<Float>, size: CGSize) -> CGPoint {
        let screenX = CGFloat(point.x + 0.5) * size.width
        let screenY = CGFloat(1.0 - (point.y - 1.0)) * size.height / 2
        return CGPoint(x: screenX, y: screenY)
    }
}

// MARK: - Selection Overlay

/// Draws the two-hand selection rectangle in 2D screen space.
/// While .selecting  → animated dashed rectangle follows the two pinch points.
/// While .selected / .moving / .resizing → solid glowing border + mode label.
struct SelectionOverlay: View {
    @Environment(AppState.self) private var appState
    let size: CGSize
    
    /// Dash animation phase
    @State private var dashPhase: CGFloat = 0
    
    var body: some View {
        Canvas { ctx, _ in
            switch appState.selectionState {
            case .selecting:
                drawLiveRect(ctx: ctx)
            case .selected, .moving, .resizing:
                drawSelectedRect(ctx: ctx)
            case .idle:
                break
            }
        }
        // Animate the dash phase for a marching-ants effect
        .onAppear {
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                dashPhase = -20
            }
        }
        .onChange(of: appState.selectionState) { _, _ in
            // Reset phase so it starts cleanly
            dashPhase = 0
        }
        .overlay(alignment: .center) {
            selectionLabel
        }
    }
    
    // MARK: Live dashed rectangle (marching ants)
    
    private func drawLiveRect(ctx: GraphicsContext) {
        let tlScreen: CGPoint
        let brScreen: CGPoint
        if let l = appState.selectionCornerLeftScreen,
           let r = appState.selectionCornerRightScreen {
            tlScreen = l
            brScreen = r
        } else if let l = appState.selectionCornerLeft,
                  let r = appState.selectionCornerRight {
            tlScreen = visionToScreen(l)
            brScreen = visionToScreen(r)
        } else {
            return
        }
        
        let rect = CGRect(
            x: min(tlScreen.x, brScreen.x),
            y: min(tlScreen.y, brScreen.y),
            width:  abs(brScreen.x - tlScreen.x),
            height: abs(brScreen.y - tlScreen.y)
        )
        
        // Blue filled region at very low opacity
        ctx.fill(Path(rect), with: .color(.blue.opacity(0.08)))
        
        // Dashed outline
        let dash = StrokeStyle(lineWidth: 2, dash: [8, 4], dashPhase: dashPhase)
        ctx.stroke(Path(rect), with: .color(.white.opacity(0.85)), style: dash)
        
        // Corner accent circles
        for corner in [CGPoint(x: rect.minX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY),
                       CGPoint(x: rect.maxX, y: rect.maxY)] {
            ctx.fill(Path(ellipseIn: CGRect(x: corner.x-4, y: corner.y-4, width: 8, height: 8)),
                     with: .color(.white))
        }
    }
    
    // MARK: Confirmed selection border
    
    private func drawSelectedRect(ctx: GraphicsContext) {
        let tlScreen: CGPoint
        let brScreen: CGPoint
        if let l = appState.selectionCornerLeftScreen,
           let r = appState.selectionCornerRightScreen {
            tlScreen = l
            brScreen = r
        } else if let l = appState.selectionCornerLeft,
                  let r = appState.selectionCornerRight {
            tlScreen = visionToScreen(l)
            brScreen = visionToScreen(r)
        } else {
            return
        }
        let rect = CGRect(
            x: min(tlScreen.x, brScreen.x) - 4,
            y: min(tlScreen.y, brScreen.y) - 4,
            width:  abs(brScreen.x - tlScreen.x) + 8,
            height: abs(brScreen.y - tlScreen.y) + 8
        )
        
        // Subtle fill
        ctx.fill(RoundedRectangle(cornerRadius: 6).path(in: rect),
                 with: .color(.blue.opacity(0.07)))
        // Solid border
        let color: Color = appState.selectionState == .moving ? .yellow :
                           appState.selectionState == .resizing ? .green : .blue
        ctx.stroke(RoundedRectangle(cornerRadius: 6).path(in: rect),
                   with: .color(color.opacity(0.9)),
                   lineWidth: 2)
    }
    
    // MARK: State label
    
    @ViewBuilder
    private var selectionLabel: some View {
        if appState.selectionState != .idle {
            VStack(spacing: 4) {
                Image(systemName: labelIcon)
                    .font(.caption2)
                Text(labelText)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(labelColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .offset(y: -80)
        }
    }
    
    private var labelIcon: String {
        switch appState.selectionState {
        case .selecting:  return "rectangle.dashed"
        case .selected:   return "checkmark.circle"
        case .moving:     return "arrow.up.and.down.and.arrow.left.and.right"
        case .resizing:   return "arrow.up.left.and.arrow.down.right"
        case .idle:       return ""
        }
    }
    private var labelText: String {
        switch appState.selectionState {
        case .selecting:  return "Selecting…"
        case .selected:
            return "\(appState.selectedStrokeIDs.count + appState.selectedFolderIDs.count) selected"
        case .moving:     return "Moving"
        case .resizing:   return "Resizing"
        case .idle:       return ""
        }
    }
    private var labelColor: Color {
        switch appState.selectionState {
        case .moving:  return .yellow
        case .resizing: return .green
        default:        return .blue
        }
    }
    
    // MARK: Coordinate helper
    // The 3D SIMD3<Float> corner coords from AppState are world-space;
    // we re-use the same approximate projection as HandVisualization.
    private func visionToScreen(_ point: SIMD3<Float>) -> CGPoint {
        let screenX = CGFloat(point.x + 0.5) * size.width
        let screenY = CGFloat(1.0 - (point.y - 1.0)) * size.height / 2
        return CGPoint(x: screenX, y: screenY)
    }
}

// MARK: - Move Debug Overlay

struct MoveDebugOverlay: View {
    @Environment(AppState.self) private var appState
    let size: CGSize

    var body: some View {
        Canvas { ctx, _ in
            if let raw = appState.debugPalmScreenRaw {
                drawPoint(ctx: ctx, point: raw, color: .yellow, radius: 6)
            }
            if let plane = appState.debugPalmScreenPlane {
                drawPoint(ctx: ctx, point: plane, color: .cyan, radius: 6)
            }
            if let depth = appState.debugPalmScreenDepth {
                drawPoint(ctx: ctx, point: depth, color: Color(red: 1.0, green: 0.0, blue: 0.7), radius: 6)
            }
        }
        .overlay(alignment: .topLeading) {
            legend
        }
    }

    private func drawPoint(ctx: GraphicsContext, point: CGPoint, color: Color, radius: CGFloat) {
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.9)))
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            labelRow(color: .yellow, text: "Raw 2D")
            labelRow(color: .cyan, text: "Plane")
            labelRow(color: Color(red: 1.0, green: 0.0, blue: 0.7), text: "Depth")
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(8)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
        .padding([.top, .leading], 12)
    }

    private func labelRow(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .foregroundStyle(.white)
        }
    }
}

// MARK: - StrokeColor SwiftUI Extension

extension StrokeColor {
    var swiftUIColor: Color {
        let rgb = rgbColor
        return Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black
        
        DrawingOverlay()
            .environment({
                let state = AppState()
                state.currentGestureMode = .draw
                state.isDrawing = true
                
                var landmarks = HandLandmarks()
                landmarks.thumbTip = SIMD3<Float>(0.1, 1.5, -0.5)
                landmarks.indexTip = SIMD3<Float>(0.12, 1.52, -0.5)
                landmarks.middleTip = SIMD3<Float>(0.14, 1.54, -0.5)
                landmarks.ringTip = SIMD3<Float>(0.16, 1.52, -0.5)
                landmarks.littleTip = SIMD3<Float>(0.18, 1.5, -0.5)
                landmarks.wrist = SIMD3<Float>(0.1, 1.4, -0.45)
                landmarks.thumbCMC = SIMD3<Float>(0.08, 1.42, -0.47)
                landmarks.thumbMP = SIMD3<Float>(0.085, 1.45, -0.48)
                landmarks.thumbIP = SIMD3<Float>(0.09, 1.48, -0.49)
                landmarks.indexMCP = SIMD3<Float>(0.11, 1.45, -0.48)
                landmarks.indexPIP = SIMD3<Float>(0.115, 1.48, -0.49)
                landmarks.indexDIP = SIMD3<Float>(0.118, 1.50, -0.495)
                landmarks.middleMCP = SIMD3<Float>(0.13, 1.45, -0.48)
                landmarks.middlePIP = SIMD3<Float>(0.135, 1.48, -0.49)
                landmarks.middleDIP = SIMD3<Float>(0.138, 1.51, -0.495)
                landmarks.ringMCP = SIMD3<Float>(0.15, 1.45, -0.48)
                landmarks.ringPIP = SIMD3<Float>(0.155, 1.48, -0.49)
                landmarks.ringDIP = SIMD3<Float>(0.158, 1.50, -0.495)
                landmarks.littleMCP = SIMD3<Float>(0.17, 1.44, -0.48)
                landmarks.littlePIP = SIMD3<Float>(0.175, 1.47, -0.49)
                landmarks.littleDIP = SIMD3<Float>(0.178, 1.49, -0.495)
                
                state.handLandmarks = landmarks
                return state
            }())
    }
}
