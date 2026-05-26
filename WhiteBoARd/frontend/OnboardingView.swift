// OnboardingView.swift
// WhiteBoARd - Spatial AR Notetaking
// Handwriting capture onboarding flow

import SwiftUI
import SwiftData

/// Onboarding flow for capturing user's handwriting style
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    
    @State private var currentStep: OnboardingStep = .welcome
    @State private var currentCharacter: String = "A"
    @State private var currentStrokes: [CapturedStroke] = []
    @State private var capturedCharacters: Set<String> = []
    @State private var isCapturing: Bool = false
    
    private let allCharacters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".map { String($0) }
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color.black, Color(white: 0.1)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 32) {
                switch currentStep {
                case .welcome:
                    WelcomeStep(onContinue: { currentStep = .instructions })
                    
                case .instructions:
                    InstructionsStep(onContinue: { currentStep = .capture })
                    
                case .capture:
                    CaptureStep(
                        currentCharacter: currentCharacter,
                        currentStrokes: $currentStrokes,
                        isCapturing: $isCapturing,
                        onCharacterComplete: handleCharacterComplete,
                        onSkip: skipCharacter,
                        progress: Float(capturedCharacters.count) / Float(allCharacters.count)
                    )
                    
                case .complete:
                    CompleteStep(onFinish: finishOnboarding)
                }
            }
            .padding(32)
        }
        .preferredColorScheme(.dark)
    }
    
    private func handleCharacterComplete() {
        guard !currentStrokes.isEmpty else { return }
        
        // Find the bounding box of ALL strokes to normalize consistently
        var allPoints: [CGPoint] = []
        for s in currentStrokes { allPoints.append(contentsOf: s.points) }
        guard !allPoints.isEmpty else { return }
        
        let minX = allPoints.map { $0.x }.min()!
        let maxX = allPoints.map { $0.x }.max()!
        let minY = allPoints.map { $0.y }.min()!
        let maxY = allPoints.map { $0.y }.max()!
        let bboxW = max(maxX - minX, 1)
        let bboxH = max(maxY - minY, 1)
        
        // Target world-space size: 0.05m height (matches Kon's defaultCharHeight)
        let targetHeight: Float = 0.05
        let aspect = Float(bboxW / bboxH)
        let targetWidth = targetHeight * aspect
        
        // Convert captured strokes to spatial strokes with proper normalization
        // Each captured stroke stays as a SEPARATE SpatialStroke to preserve multi-stroke topology
        let spatialStrokes = currentStrokes.map { capturedStroke -> SpatialStroke in
            let points = capturedStroke.points.map { point -> StrokePoint in
                // Normalize to [0,1] range within bounding box
                let nx = Float((point.x - minX) / bboxW)
                // Flip Y: screen Y goes down, AR world Y goes up
                let ny = 1.0 - Float((point.y - minY) / bboxH)
                
                // Scale to world-space size
                return StrokePoint(
                    position: SIMD3<Float>(nx * targetWidth, ny * targetHeight, 0),
                    pressure: 1.0
                )
            }
            
            let stroke = SpatialStroke(points: points)
            stroke.bezierSegments = StrokeProcessor.shared.pointsToBezierSegments(points)
            return stroke
        }
        
        // Store character template + feed into Kon
        Task { @MainActor in
            // Analyze handwriting using Gemini
            if let image = renderStrokesToImage() {
                do {
                    let analysis = try await GeminiService.shared.analyzeHandwriting(
                        characterImage: image,
                        character: currentCharacter
                    )
                    
                    HandwritingStyleStore.shared.storeCharacterTemplate(
                        character: currentCharacter,
                        strokes: spatialStrokes,
                        analysis: analysis
                    )
                } catch {
                    // Store without analysis
                    HandwritingStyleStore.shared.storeCharacterTemplate(
                        character: currentCharacter,
                        strokes: spatialStrokes,
                        analysis: nil
                    )
                }
            }
            
            // Also feed into Kon for imitation learning
            Kon.shared.addSample(character: currentCharacter, strokes: spatialStrokes)
            
            capturedCharacters.insert(currentCharacter)
            moveToNextCharacter()
        }
    }
    
    private func skipCharacter() {
        moveToNextCharacter()
    }
    
    private func moveToNextCharacter() {
        currentStrokes.removeAll()
        
        // Find next character
        if let currentIndex = allCharacters.firstIndex(of: currentCharacter) {
            let nextIndex = allCharacters.index(after: currentIndex)
            
            if nextIndex < allCharacters.endIndex {
                currentCharacter = allCharacters[nextIndex]
            } else {
                // All characters done
                currentStep = .complete
            }
        }
    }
    
    private func finishOnboarding() {
        appState.isOnboardingComplete = true
        UserDefaults.standard.set(true, forKey: "onboarding_complete")
    }
    
    private func renderStrokesToImage() -> UIImage? {
        let size = CGSize(width: 200, height: 200)
        
        UIGraphicsBeginImageContextWithOptions(size, false, 2.0)
        defer { UIGraphicsEndImageContext() }
        
        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        
        // White background
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        
        // Draw strokes
        context.setStrokeColor(UIColor.black.cgColor)
        context.setLineWidth(3)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        
        for stroke in currentStrokes {
            guard let firstPoint = stroke.points.first else { continue }
            
            context.beginPath()
            context.move(to: firstPoint)
            
            for point in stroke.points.dropFirst() {
                context.addLine(to: point)
            }
            
            context.strokePath()
        }
        
        return UIGraphicsGetImageFromCurrentImageContext()
    }
}

// MARK: - Onboarding Steps

enum OnboardingStep {
    case welcome
    case instructions
    case capture
    case complete
}

// MARK: - Welcome Step

struct WelcomeStep: View {
    let onContinue: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "pencil.and.scribble")
                .font(.system(size: 80))
                .foregroundStyle(.linearGradient(
                    colors: [.blue, .purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            
            Text("WhiteBoARd")
                .font(.system(size: 42, weight: .bold, design: .rounded))
            
            Text("Spatial AR Notetaking")
                .font(.title2)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Text("Let's learn your handwriting style so your notes look like you wrote them.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            
            Spacer()
            
            Button(action: onContinue) {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}

// MARK: - Instructions Step

struct InstructionsStep: View {
    let onContinue: () -> Void
    
    var body: some View {
        VStack(spacing: 32) {
            Text("How It Works")
                .font(.title.bold())
            
            VStack(alignment: .leading, spacing: 24) {
                InstructionRow(
                    icon: "hand.draw",
                    title: "Write Each Letter",
                    description: "You'll write A-Z and 0-9 one at a time"
                )
                
                InstructionRow(
                    icon: "brain",
                    title: "AI Learns Your Style",
                    description: "We capture your unique letterforms"
                )
                
                InstructionRow(
                    icon: "sparkles",
                    title: "Math Autocomplete",
                    description: "Completions render in your handwriting"
                )
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            
            Spacer()
            
            VStack(spacing: 16) {
                Text("This takes about 5 minutes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Button(action: onContinue) {
                    Text("Start Writing")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }
}

struct InstructionRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title)
                .frame(width: 44)
                .foregroundStyle(.blue)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Capture Step

struct CaptureStep: View {
    let currentCharacter: String
    @Binding var currentStrokes: [CapturedStroke]
    @Binding var isCapturing: Bool
    let onCharacterComplete: () -> Void
    let onSkip: () -> Void
    let progress: Float
    
    var body: some View {
        VStack(spacing: 24) {
            // Progress bar
            VStack(spacing: 8) {
                ProgressView(value: Double(progress))
                    .tint(.blue)
                
                Text("\(Int(progress * 100))% complete")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            // Current character prompt
            Text("Write the letter")
                .font(.headline)
                .foregroundStyle(.secondary)
            
            Text(currentCharacter)
                .font(.system(size: 120, weight: .light, design: .serif))
                .foregroundStyle(.primary)
            
            // Drawing canvas
            DrawingCanvas(strokes: $currentStrokes, isCapturing: $isCapturing)
                .frame(height: 300)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
            
            // Controls
            HStack(spacing: 16) {
                Button("Clear") {
                    currentStrokes.removeAll()
                }
                .buttonStyle(.bordered)
                
                Button("Skip") {
                    onSkip()
                }
                .buttonStyle(.bordered)
                
                Button("Done") {
                    onCharacterComplete()
                }
                .buttonStyle(.borderedProminent)
                .disabled(currentStrokes.isEmpty)
            }
        }
    }
}

// MARK: - Drawing Canvas

struct DrawingCanvas: View {
    @Binding var strokes: [CapturedStroke]
    @Binding var isCapturing: Bool
    
    @State private var currentPoints: [CGPoint] = []
    
    var body: some View {
        Canvas { context, size in
            // Draw completed strokes
            for stroke in strokes {
                drawStroke(stroke.points, in: context, color: .black)
            }
            
            // Draw current stroke
            if !currentPoints.isEmpty {
                drawStroke(currentPoints, in: context, color: .black)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isCapturing {
                        isCapturing = true
                        currentPoints = []
                    }
                    currentPoints.append(value.location)
                }
                .onEnded { _ in
                    if !currentPoints.isEmpty {
                        strokes.append(CapturedStroke(points: currentPoints))
                    }
                    currentPoints = []
                    isCapturing = false
                }
        )
    }
    
    private func drawStroke(_ points: [CGPoint], in context: GraphicsContext, color: Color) {
        guard points.count >= 2 else { return }
        
        var path = Path()
        path.move(to: points[0])
        
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        
        context.stroke(path, with: .color(color), lineWidth: 4)
    }
}

// MARK: - Captured Stroke

struct CapturedStroke: Identifiable {
    let id = UUID()
    let points: [CGPoint]
}

// MARK: - Complete Step

struct CompleteStep: View {
    let onFinish: () -> Void
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 100))
                .foregroundStyle(.green)
            
            Text("All Done!")
                .font(.largeTitle.bold())
            
            Text("We've captured your handwriting style. Your math completions will now render in your unique style.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            
            Spacer()
            
            Button(action: onFinish) {
                Text("Start Using WhiteBoARd")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}

// MARK: - Preview

#Preview {
    OnboardingView()
        .environment(AppState())
        .modelContainer(for: [CharacterTemplate.self])
}
