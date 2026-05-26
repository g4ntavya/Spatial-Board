// HandwritingStyleStore.swift
// WhiteBoARd - Spatial AR Notetaking
// Storage and warping of user's handwriting style

import Foundation
import SwiftData
import simd
import UIKit

/// Manages user's handwriting style templates for LLM output rendering
@MainActor
@Observable
final class HandwritingStyleStore {
    
    // MARK: - Properties
    
    private var modelContext: ModelContext?
    private var characterTemplates: [String: CharacterTemplate] = [:]
    private var styleAnalysis: [String: HandwritingAnalysis] = [:]
    
    /// Whether onboarding has captured all required characters
    var isOnboardingComplete: Bool {
        let requiredCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let capturedCharacters = Set(characterTemplates.keys.flatMap { $0 })
        return requiredCharacters.isSubset(of: capturedCharacters)
    }
    
    /// Characters still needed for onboarding
    var missingCharacters: [String] {
        let required = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".map { String($0) }
        return required.filter { characterTemplates[$0] == nil }
    }
    
    // Global style metrics derived from captured characters
    private(set) var averageSlant: Float = 0
    private(set) var averageStrokeWidth: Float = 0.002
    private(set) var styleTendency: StyleTendency = .print
    
    // MARK: - Singleton
    
    static let shared = HandwritingStyleStore()
    
    private init() {}
    
    // MARK: - Configuration
    
    func configure(with modelContext: ModelContext) {
        self.modelContext = modelContext
        loadStoredTemplates()
    }
    
    /// Remove all stored character templates (used when resetting Kon)
    func clearAllTemplates() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<CharacterTemplate>()
        if let templates = try? context.fetch(descriptor) {
            for template in templates {
                context.delete(template)
            }
            try? context.save()
        }
        characterTemplates.removeAll()
        styleAnalysis.removeAll()
    }
    
    // MARK: - Template Management
    
    /// Store a character template from user input
    func storeCharacterTemplate(
        character: String,
        strokes: [SpatialStroke],
        analysis: HandwritingAnalysis? = nil
    ) {
        guard let context = modelContext else { return }
        
        // Convert strokes to bezier segments
        var allSegments: [BezierSegment] = []
        for stroke in strokes {
            allSegments.append(contentsOf: stroke.bezierSegments)
        }
        
        // Calculate bounding box
        let boundingBox = calculateBoundingBox(segments: allSegments)
        
        // Create or update template
        let upperChar = character.uppercased()
        let template = CharacterTemplate(
            character: upperChar,
            bezierSegments: allSegments,
            boundingBox: boundingBox
        )
        
        // Check if exists
        let descriptor = FetchDescriptor<CharacterTemplate>(
            predicate: #Predicate { $0.character == upperChar }
        )
        
        if let existing = try? context.fetch(descriptor).first {
            existing.bezierSegments = allSegments
            existing.boundingBox = boundingBox
            existing.createdAt = Date()
        } else {
            context.insert(template)
        }
        
        try? context.save()
        
        // Update local cache
        characterTemplates[upperChar] = template
        
        // Store analysis if provided
        if let analysis = analysis {
            styleAnalysis[upperChar] = analysis
        }
        
        // Update global style metrics
        updateGlobalStyleMetrics()
    }
    
    /// Get template for a character
    func getTemplate(for character: String) -> CharacterTemplate? {
        let key = character.uppercased()
        return characterTemplates[key]
    }
    
    /// Load stored templates from SwiftData
    private func loadStoredTemplates() {
        guard let context = modelContext else { return }
        
        let descriptor = FetchDescriptor<CharacterTemplate>()
        guard let templates = try? context.fetch(descriptor) else { return }
        
        for template in templates {
            characterTemplates[template.character] = template
        }
        
        updateGlobalStyleMetrics()
    }
    
    // MARK: - Style Warping
    
    /// Warp standard letterform paths to match user's style
    func warpToUserStyle(
        standardPaths: [[SIMD2<Float>]],
        targetCharacter: String,
        position: SIMD3<Float>,
        scale: Float = 1.0
    ) -> [BezierSegment] {
        guard let template = getTemplate(for: targetCharacter) else {
            // No template: apply only global style transforms
            return applyGlobalStyle(to: standardPaths, position: position, scale: scale)
        }
        
        // Get template bounding box and segments
        let templateBB = template.boundingBox
        
        // Calculate standard paths bounding box
        let standardBB = calculateBoundingBox2D(paths: standardPaths)
        
        // Calculate scale factors
        let scaleX = templateBB.width / max(standardBB.width, 0.001)
        let scaleY = templateBB.height / max(standardBB.height, 0.001)
        
        // Apply warping transformation
        var warpedSegments: [BezierSegment] = []
        
        for path in standardPaths {
            let warpedPath = path.map { point -> SIMD2<Float> in
                // Normalize to 0-1
                let normalizedX = (point.x - standardBB.minX) / max(standardBB.width, 0.001)
                let normalizedY = (point.y - standardBB.minY) / max(standardBB.height, 0.001)
                
                // Apply template proportions
                let warpedX = normalizedX * templateBB.width * scaleX
                let warpedY = normalizedY * templateBB.height * scaleY
                
                // Apply slant
                let slantOffset = warpedY * tan(averageSlant * .pi / 180.0)
                
                return SIMD2<Float>(warpedX + slantOffset, warpedY)
            }
            
            // Convert to 3D and create bezier segments
            let points3D = warpedPath.map { point2D -> StrokePoint in
                let pos = SIMD3<Float>(
                    position.x + point2D.x * scale,
                    position.y + point2D.y * scale,
                    position.z
                )
                return StrokePoint(position: pos)
            }
            
            let segments = StrokeProcessor.shared.pointsToBezierSegments(points3D)
            warpedSegments.append(contentsOf: segments)
        }
        
        return warpedSegments
    }
    
    /// Apply global style transforms without character-specific warping
    private func applyGlobalStyle(
        to paths: [[SIMD2<Float>]],
        position: SIMD3<Float>,
        scale: Float
    ) -> [BezierSegment] {
        var segments: [BezierSegment] = []
        
        for path in paths {
            let transformedPath = path.map { point -> SIMD2<Float> in
                // Apply slant
                let slantOffset = point.y * tan(averageSlant * .pi / 180.0)
                return SIMD2<Float>(point.x + slantOffset, point.y)
            }
            
            let points3D = transformedPath.map { point2D -> StrokePoint in
                let pos = SIMD3<Float>(
                    position.x + point2D.x * scale,
                    position.y + point2D.y * scale,
                    position.z
                )
                return StrokePoint(position: pos)
            }
            
            let bezierSegments = StrokeProcessor.shared.pointsToBezierSegments(points3D)
            segments.append(contentsOf: bezierSegments)
        }
        
        return segments
    }
    
    /// Render a full string in user's handwriting style
    /// Uses Kon imitation engine as primary renderer for natural variation
    func renderString(
        _ text: String,
        at position: SIMD3<Float>,
        scale: Float = 1.0,
        spacing: Float = 0.01
    ) async -> [BezierSegment] {
        var allSegments: [BezierSegment] = []
        var xOffset: Float = 0
        
        for char in text.uppercased() {
            let charString = String(char)
            
            if charString == " " {
                xOffset += spacing * 2
                continue
            }
            
            let charPosition = SIMD3<Float>(position.x + xOffset, position.y, position.z)
            
            // Try Kon first (learned profiles with natural variation)
            if let (konPaths, konWidth) = Kon.shared.renderCharacter(charString, at: charPosition, scale: scale) {
                // Flatten paths for general style synthesis
                allSegments.append(contentsOf: konPaths.flatMap { $0 })
                xOffset += konWidth + spacing
            } else {
                // Fallback: old warp approach
                let standardPaths = await GeminiService.shared.latexToStrokePaths(charString)
                let warpedSegments = warpToUserStyle(
                    standardPaths: standardPaths,
                    targetCharacter: charString,
                    position: charPosition,
                    scale: scale
                )
                allSegments.append(contentsOf: warpedSegments)
                
                if let template = getTemplate(for: charString) {
                    xOffset += template.boundingBox.width * scale + spacing
                } else {
                    xOffset += 0.04 * scale + spacing
                }
            }
        }
        
        return allSegments
    }
    
    // MARK: - Helper Methods
    
    private func calculateBoundingBox(segments: [BezierSegment]) -> BoundingBox {
        guard !segments.isEmpty else { return .zero }
        
        var minX: Float = .infinity
        var minY: Float = .infinity
        var maxX: Float = -.infinity
        var maxY: Float = -.infinity
        
        for segment in segments {
            for point in [segment.startPoint, segment.controlPoint1, segment.controlPoint2, segment.endPoint] {
                minX = min(minX, point.x)
                minY = min(minY, point.y)
                maxX = max(maxX, point.x)
                maxY = max(maxY, point.y)
            }
        }
        
        return BoundingBox(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }
    
    private func calculateBoundingBox2D(paths: [[SIMD2<Float>]]) -> BoundingBox {
        var minX: Float = .infinity
        var minY: Float = .infinity
        var maxX: Float = -.infinity
        var maxY: Float = -.infinity
        
        for path in paths {
            for point in path {
                minX = min(minX, point.x)
                minY = min(minY, point.y)
                maxX = max(maxX, point.x)
                maxY = max(maxY, point.y)
            }
        }
        
        if minX == .infinity {
            return .zero
        }
        
        return BoundingBox(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }
    
    private func updateGlobalStyleMetrics() {
        guard !styleAnalysis.isEmpty else { return }
        
        // Calculate average slant
        let slants = styleAnalysis.values.map { $0.slantAngle }
        averageSlant = slants.reduce(0, +) / Float(slants.count)
        
        // Determine style tendency
        let printCount = styleAnalysis.values.filter { $0.style == "print" }.count
        let cursiveCount = styleAnalysis.values.filter { $0.style == "cursive" }.count
        
        if printCount > cursiveCount * 2 {
            styleTendency = .print
        } else if cursiveCount > printCount * 2 {
            styleTendency = .cursive
        } else {
            styleTendency = .mixed
        }
    }
    
    /// Reset all stored templates
    func resetAllTemplates() {
        guard let context = modelContext else { return }
        
        let descriptor = FetchDescriptor<CharacterTemplate>()
        if let templates = try? context.fetch(descriptor) {
            for template in templates {
                context.delete(template)
            }
            try? context.save()
        }
        
        characterTemplates.removeAll()
        styleAnalysis.removeAll()
        averageSlant = 0
        styleTendency = .print
    }
}

// MARK: - Supporting Types

enum StyleTendency: String {
    case print
    case cursive
    case mixed
}

// MARK: - Character Path Definitions

extension HandwritingStyleStore {
    
    /// Default stroke paths for standard characters (fallback when no template exists)
    static func defaultPaths(for character: String) -> [[SIMD2<Float>]] {
        let c = character.uppercased().first ?? Character(" ")
        let h: Float = 0.05  // Height
        let w: Float = 0.035 // Width
        
        switch c {
        case "A":
            return [
                [SIMD2(0, 0), SIMD2(w/2, h), SIMD2(w, 0)],
                [SIMD2(w*0.2, h*0.4), SIMD2(w*0.8, h*0.4)]
            ]
        case "B":
            return [
                [SIMD2(0, 0), SIMD2(0, h)],
                [SIMD2(0, h), SIMD2(w*0.8, h), SIMD2(w, h*0.8), SIMD2(w*0.8, h*0.5), SIMD2(0, h*0.5)],
                [SIMD2(0, h*0.5), SIMD2(w*0.8, h*0.5), SIMD2(w, h*0.2), SIMD2(w*0.8, 0), SIMD2(0, 0)]
            ]
        case "C":
            return [
                [SIMD2(w, h*0.8), SIMD2(w*0.5, h), SIMD2(0, h*0.5), SIMD2(w*0.5, 0), SIMD2(w, h*0.2)]
            ]
        case "0":
            return [[SIMD2(w*0.5, h), SIMD2(w, h*0.8), SIMD2(w, h*0.2), SIMD2(w*0.5, 0), SIMD2(0, h*0.2), SIMD2(0, h*0.8), SIMD2(w*0.5, h)]]
        case "1":
            return [[SIMD2(w*0.2, h*0.8), SIMD2(w*0.5, h), SIMD2(w*0.5, 0)]]
        case "2":
            return [[SIMD2(0, h*0.8), SIMD2(w*0.5, h), SIMD2(w, h*0.8), SIMD2(w, h*0.6), SIMD2(0, 0), SIMD2(w, 0)]]
        case "3":
            return [
                [SIMD2(0, h), SIMD2(w, h), SIMD2(w, h*0.5), SIMD2(w*0.3, h*0.5)],
                [SIMD2(w*0.3, h*0.5), SIMD2(w, h*0.5), SIMD2(w, 0), SIMD2(0, 0)]
            ]
        case "4":
            return [[SIMD2(w*0.7, h), SIMD2(0, h*0.3), SIMD2(w, h*0.3)], [SIMD2(w*0.7, h), SIMD2(w*0.7, 0)]]
        case "5":
            return [[SIMD2(w, h), SIMD2(0, h), SIMD2(0, h*0.5), SIMD2(w, h*0.5), SIMD2(w, 0), SIMD2(0, 0)]]
        case "6":
            return [[SIMD2(w, h), SIMD2(0, h*0.5), SIMD2(0, 0), SIMD2(w, 0), SIMD2(w, h*0.5), SIMD2(0, h*0.5)]]
        case "7":
            return [[SIMD2(0, h), SIMD2(w, h), SIMD2(w*0.3, 0)]]
        case "8":
            return [[SIMD2(w*0.5, h*0.5), SIMD2(0, h*0.75), SIMD2(w*0.5, h), SIMD2(w, h*0.75), SIMD2(w*0.5, h*0.5), SIMD2(0, h*0.25), SIMD2(w*0.5, 0), SIMD2(w, h*0.25), SIMD2(w*0.5, h*0.5)]]
        case "9":
            return [[SIMD2(w, h*0.5), SIMD2(0, h*0.5), SIMD2(0, h), SIMD2(w, h), SIMD2(w, 0)]]
        case "=":
            return [[SIMD2(w*0.2, h*0.6), SIMD2(w*0.8, h*0.6)], [SIMD2(w*0.2, h*0.4), SIMD2(w*0.8, h*0.4)]]
        case "+":
            return [[SIMD2(w*0.2, h*0.5), SIMD2(w*0.8, h*0.5)], [SIMD2(w*0.5, h*0.8), SIMD2(w*0.5, h*0.2)]]
        case "-":
            return [[SIMD2(w*0.2, h*0.5), SIMD2(w*0.8, h*0.5)]]
        case ".":
            return [[SIMD2(w*0.4, h*0.1), SIMD2(w*0.6, h*0.1), SIMD2(w*0.6, 0), SIMD2(w*0.4, 0), SIMD2(w*0.4, h*0.1)]]
        default:
            // Generic placeholder: Square box
            return [[SIMD2(0, 0), SIMD2(0, h), SIMD2(w, h), SIMD2(w, 0), SIMD2(0, 0)]]
        }
    }
}
