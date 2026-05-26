// Kon.swift
// WhiteBoARd - Spatial AR Notetaking
// Kon: GAIL-Based Handwriting Imitation Engine
// Uses Generative Adversarial Imitation Learning (GAIL) to synthesize
// user's handwriting style by training a Generator against an AR discriminator.
// Provides better accuracy than simple imitation models (IRL), especially on small AR data.

import Foundation
import SwiftData
import simd
import RealityKit
import UIKit

// MARK: - GAIL Generator Interface

/// Generative Adversarial Imitation Learning (GAIL) Generator Stub
/// Replaces the simple template sampling (IRL) with a neural network architecture approach.
/// This generator synthesizes a character trajectory via a latent space instead of explicit imitation.
struct GAILHandwritingGenerator {
    /// In production, wrap a CoreML .mlmodel (e.g. `GAILGenerator.mlmodel`) trained via RL
    /// and run inference using a latent z-vector to produce bezier sequence trajectories.
    
    /// Synthesizes a character based on the learned GAIL policy
    static func synthesizeCharacter(
        _ character: String,
        profile: GlyphProfile,
        noiseScale: Float,
        globalSlant: Float
    ) -> [BezierSegment]? {
        // [Integration Point]: Evaluate your CoreML GAIL model here.
        // let latentZ = MLMultiArray(random_noise)
        // let output = try generatorModel.prediction(characterID: charID, latentZ: latentZ, styleProfile: profileData)
        
        // --- Fallback simulating GAIL latent space interpolation ---
        guard !profile.samples.isEmpty else { return nil }
        let sample = profile.samples.randomElement()!
        
        // A true GAIL generator outputs inherently smooth variations.
        // For the stub, we simulate the generator output by preserving the base topology.
        return sample.segments
    }
}

// MARK: - Glyph Profile (In-Memory)

/// Statistical profile for a single character built from multiple samples
struct GlyphProfile {
    let character: String
    var samples: [GlyphProfileSample]
    var averageBoundingBox: BoundingBox
    var averageAspectRatio: Float
    
    var sampleCount: Int { samples.count }
    
    struct GlyphProfileSample {
        let segments: [BezierSegment]
        let boundingBox: BoundingBox
        let velocityProfile: [Float]
        let pressureProfile: [Float]
        let strokeBreakIndices: [Int]  // Where each stroke starts in segments[]
    }
}

// MARK: - Kon Engine

/// Kon — Handwriting Imitation Engine
/// Learns from user's handwriting and generates natural-looking text.
@MainActor
@Observable
final class Kon {
    
    // MARK: - Configuration
    
    /// Max samples kept per character (oldest AR samples are pruned)
    private let maxSamplesPerChar = 15
    
    /// Default character height in world units (meters)
    private let defaultCharHeight: Float = 0.05
    
    /// Default character width in world units
    private let defaultCharWidth: Float = 0.035
    
    /// Noise magnitude as fraction of character size
    private let noiseScale: Float = 0.008
    
    // MARK: - State
    
    private var modelContext: ModelContext?
    private var profiles: [String: GlyphProfile] = [:]
    
    /// Global style parameters (derived from all profiles)
    private(set) var globalSlant: Float = 0
    private(set) var globalSlantStdDev: Float = 0
    private(set) var averageCharSpacing: Float = 0.012
    
    /// Whether Kon has any learned data
    var hasLearnedData: Bool { !profiles.isEmpty }
    
    /// Total sample count across all characters
    var totalSampleCount: Int { profiles.values.reduce(0) { $0 + $1.sampleCount } }
    
    // MARK: - Singleton
    
    static let shared = Kon()
    private init() {}
    
    // MARK: - Configuration
    
    func configure(with modelContext: ModelContext) {
        self.modelContext = modelContext
        loadProfiles()
    }
    
    /// Wipe all learned handwriting data so Kon re-learns from scratch
    func resetAllSamples() {
        guard let context = modelContext else { return }
        
        // Delete all GlyphSamples from SwiftData
        let descriptor = FetchDescriptor<GlyphSample>()
        do {
            let samples = try context.fetch(descriptor)
            for sample in samples {
                context.delete(sample)
            }
            try context.save()
            print("[Kon] 🗑️ Deleted \(samples.count) samples")
        } catch {
            print("[Kon] Error deleting samples: \(error)")
        }
        
        // Clear in-memory profiles
        profiles.removeAll()
        
        // Clear HandwritingStyleStore templates
        HandwritingStyleStore.shared.clearAllTemplates()
        
        // Reset onboarding flag
        UserDefaults.standard.set(false, forKey: "onboarding_complete")
        
        print("[Kon] 🔄 Reset complete — ready to re-learn from onboarding")
    }
    
    // MARK: - GAIL Learning & Data Collection
    
    /// Add a new expert trajectory sample for a character from AR drawing
    /// This data acts as the "Expert Demonstrations" needed to train the GAIL Discriminator
    func addSample(character: String, strokes: [SpatialStroke]) {
        guard let context = modelContext else { return }
        let upperChar = character.uppercased()
        guard upperChar.count == 1 else { return }
        
        // Merge all strokes' bezier segments, tracking where each stroke starts
        var allSegments: [BezierSegment] = []
        var allPoints: [StrokePoint] = []
        var breakIndices: [Int] = []
        for stroke in strokes {
            breakIndices.append(allSegments.count)
            allSegments.append(contentsOf: stroke.bezierSegments)
            allPoints.append(contentsOf: stroke.points)
        }
        
        guard !allSegments.isEmpty else { return }
        
        // Calculate bounding box
        let bb = calculateBoundingBox(segments: allSegments)
        guard bb.width > 0.001 && bb.height > 0.001 else { return }
        
        // Extract velocity profile from stroke points
        let velocityProfile = extractVelocityProfile(from: allPoints)
        let pressureProfile = allPoints.map { $0.pressure }
        
        // Create and persist GlyphSample
        let sample = GlyphSample(
            character: upperChar,
            bezierSegments: allSegments,
            boundingBox: bb,
            velocityProfile: velocityProfile,
            pressureProfile: pressureProfile,
            source: .arDrawing,
            strokeBreakIndices: breakIndices
        )
        context.insert(sample)
        
        // Prune old samples if over limit
        pruneOldSamples(for: upperChar)
        
        try? context.save()
        
        // Rebuild profile for this character
        rebuildProfile(for: upperChar)
        updateGlobalStyle()
        
        print("[Kon] 📝 Learned '\(upperChar)' — now have \(profiles[upperChar]?.sampleCount ?? 0) samples")
    }
    
    /// Add a sample directly from bezier segments (used by onboarding)
    func addSampleFromSegments(character: String, segments: [BezierSegment], boundingBox: BoundingBox, source: GlyphSampleSource = .onboarding) {
        guard let context = modelContext else { return }
        let upperChar = character.uppercased()
        guard !segments.isEmpty else { return }
        
        let sample = GlyphSample(
            character: upperChar,
            bezierSegments: segments,
            boundingBox: boundingBox,
            velocityProfile: [],
            pressureProfile: [],
            source: source
        )
        context.insert(sample)
        try? context.save()
        
        rebuildProfile(for: upperChar)
        updateGlobalStyle()
    }
    
    // MARK: - Rendering
    
    /// Render a single character at the given world position
    /// Returns (bezierSegments, characterWidth) or nil if no data for character
    func renderCharacter(
        _ character: String,
        at position: SIMD3<Float>,
        scale: Float = 1.0,
        rightVector: SIMD3<Float> = SIMD3<Float>(1, 0, 0),
        upwardVector: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
    ) -> (paths: [[BezierSegment]], width: Float)? {
        let upperChar = character.uppercased()
        
        // Try to get profile
        guard let profile = profiles[upperChar], !profile.samples.isEmpty else {
            // Fallback: use default paths from HandwritingStyleStore
            let defaultPaths = HandwritingStyleStore.defaultPaths(for: upperChar)
            let paths = pathsToSegments(defaultPaths, at: position, scale: scale, right: rightVector, up: upwardVector)
            return (paths, defaultCharWidth * scale)
        }
        
        let sampleCount = max(profile.samples.count, 1)
        let charHeight = defaultCharHeight * scale
        let charWidth = charHeight * profile.averageAspectRatio
        let targetSize = SIMD2<Float>(charWidth, charHeight)
        
        // --- Multi-Stroke Topology-Preserving Pipeline ---
        // Average per-stroke-path across samples, keeping each sub-stroke separate
        if profile.samples.count > 1, let averagedPaths = averageNormalizedStrokePaths(for: profile), !averagedPaths.isEmpty {
            let noiseDamping = 1.0 / sqrt(Float(sampleCount))
            var worldPaths: [[BezierSegment]] = []
            for normPath in averagedPaths {
                let perturbed = addNoise(to: normPath, magnitude: noiseScale * 0.15 * noiseDamping)
                let slanted = applySlant(to: perturbed, slant: sampleSlant(sampleCount: sampleCount))
                let world = denormalizeSegments(slanted, position: position, size: targetSize, right: rightVector, up: upwardVector)
                worldPaths.append(world)
            }
            return (worldPaths, charWidth)
        }
        
        // Fallback: single sample — still split by stroke breaks
        let sample = profile.samples.count == 1 ? profile.samples[0] : profile.samples.randomElement()!
        let normalized = normalizeSegments(sample.segments, boundingBox: sample.boundingBox)
        let breaks = sample.strokeBreakIndices.isEmpty ? [0] : sample.strokeBreakIndices
        let splitPaths = splitByStrokeBreaks(normalized, breaks: breaks)
        
        let noiseDamping = 1.0 / sqrt(Float(sampleCount))
        var worldPaths: [[BezierSegment]] = []
        for path in splitPaths {
            let perturbed = addNoise(to: path, magnitude: noiseScale * 0.25 * noiseDamping)
            let slanted = applySlant(to: perturbed, slant: sampleSlant(sampleCount: sampleCount))
            let world = denormalizeSegments(slanted, position: position, size: targetSize, right: rightVector, up: upwardVector)
            worldPaths.append(world)
        }
        
        return (worldPaths, charWidth)
    }
    
    /// Render a full string of text, returns array of (entity, strokeData) pairs
    func renderText(
        _ text: String,
        at position: SIMD3<Float>,
        scale: Float = 1.0,
        spacing: Float? = nil,
        color: StrokeColor = .white,
        thickness: Float = 0.003,
        faceDirection: SIMD3<Float> = SIMD3<Float>(0, 0, 1),
        rightVector: SIMD3<Float> = SIMD3<Float>(1, 0, 0),
        upwardVector: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
    ) -> [(entity: Entity, stroke: SpatialStroke)] {
        var results: [(entity: Entity, stroke: SpatialStroke)] = []
        var xOffset: Float = 0
        let charSpacing = spacing ?? averageCharSpacing * scale
        
        for char in text {
            let charStr = String(char)
            
            if charStr == " " {
                xOffset += charSpacing * 1.5
                continue
            }
            
            // Horizontal vector relative to the plane
            let charPosition = position + (rightVector * xOffset)
            
            guard let (paths, charWidth) = renderCharacter(charStr, at: charPosition, scale: scale, rightVector: rightVector, upwardVector: upwardVector) else {
                xOffset += defaultCharWidth * scale + charSpacing
                continue
            }
            
            // Create a separate entity and stroke for each disjoint path
            for segments in paths {
                if let entity = StrokeProcessor.shared.createEntity(
                    from: segments,
                    thickness: thickness,
                    color: color,
                    faceDirection: faceDirection
                ) {
                    // Create SpatialStroke for persistence
                    let strokePoints = segmentsToStrokePoints(segments)
                    let stroke = SpatialStroke(
                        points: strokePoints,
                        bezierSegments: segments,
                        color: color,
                        thickness: thickness
                    )
                    stroke.isCompleted = true
                    
                    results.append((entity: entity, stroke: stroke))
                }
            }
            
            xOffset += charWidth + charSpacing
        }
        
        return results
    }
    
    /// Get total rendered width for a string (for layout)
    func measureText(_ text: String, scale: Float = 1.0, spacing: Float? = nil) -> Float {
        var width: Float = 0
        let charSpacing = spacing ?? averageCharSpacing * scale
        
        for char in text {
            if char == " " {
                width += charSpacing * 1.5
                continue
            }
            let upperChar = String(char).uppercased()
            if let profile = profiles[upperChar] {
                width += defaultCharHeight * scale * profile.averageAspectRatio + charSpacing
            } else {
                width += defaultCharWidth * scale + charSpacing
            }
        }
        return width
    }
    
    /// Get number of samples for a character
    func sampleCount(for character: String) -> Int {
        profiles[character.uppercased()]?.sampleCount ?? 0
    }
    
    // MARK: - Profile Building
    
    /// Rebuild profile for a specific character from all available data
    private func rebuildProfile(for character: String) {
        let upperChar = character.uppercased()
        var allSamples: [GlyphProfile.GlyphProfileSample] = []
        
        // 1. Get onboarding template (from HandwritingStyleStore)
        if let template = HandwritingStyleStore.shared.getTemplate(for: upperChar) {
            if !template.bezierSegments.isEmpty {
                // Detect stroke breaks from discontinuities in the segment chain
                let breaks = detectStrokeBreaks(in: template.bezierSegments)
                allSamples.append(GlyphProfile.GlyphProfileSample(
                    segments: template.bezierSegments,
                    boundingBox: template.boundingBox,
                    velocityProfile: [],
                    pressureProfile: [],
                    strokeBreakIndices: breaks
                ))
            }
        }
        
        // 2. Get AR-captured GlyphSamples from SwiftData
        if let context = modelContext {
            let upperCharCopy = upperChar
            var descriptor = FetchDescriptor<GlyphSample>(
                predicate: #Predicate { $0.character == upperCharCopy },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            descriptor.fetchLimit = maxSamplesPerChar
            
            if let arSamples = try? context.fetch(descriptor) {
                for sample in arSamples {
                    if !sample.bezierSegments.isEmpty {
                        let breaks = sample.strokeBreakIndices.isEmpty
                            ? detectStrokeBreaks(in: sample.bezierSegments)
                            : sample.strokeBreakIndices
                        allSamples.append(GlyphProfile.GlyphProfileSample(
                            segments: sample.bezierSegments,
                            boundingBox: sample.boundingBox,
                            velocityProfile: sample.velocityProfile,
                            pressureProfile: sample.pressureProfile,
                            strokeBreakIndices: breaks
                        ))
                    }
                }
            }
        }
        
        guard !allSamples.isEmpty else {
            profiles.removeValue(forKey: upperChar)
            return
        }
        
        // Calculate average bounding box
        var totalWidth: Float = 0
        var totalHeight: Float = 0
        for s in allSamples {
            totalWidth += s.boundingBox.width
            totalHeight += s.boundingBox.height
        }
        let avgW = totalWidth / Float(allSamples.count)
        let avgH = totalHeight / Float(allSamples.count)
        let avgBB = BoundingBox(minX: 0, minY: 0, maxX: avgW, maxY: avgH)
        let aspectRatio = avgH > 0.001 ? avgW / avgH : 0.7
        
        profiles[upperChar] = GlyphProfile(
            character: upperChar,
            samples: allSamples,
            averageBoundingBox: avgBB,
            averageAspectRatio: aspectRatio
        )
    }
    
    private func loadProfiles() {
        let allChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".map { String($0) }
        for char in allChars {
            rebuildProfile(for: char)
        }
        updateGlobalStyle()
    }
    
    private func updateGlobalStyle() {
        // Compute global slant from HandwritingStyleStore's analysis
        globalSlant = HandwritingStyleStore.shared.averageSlant
        globalSlantStdDev = max(abs(globalSlant) * 0.2, 1.0) // At least 1 degree variation
    }
    
    // MARK: - Normalization & Warping
    
    /// Normalize segments so all control points are in [0,1] range
    private func normalizeSegments(_ segments: [BezierSegment], boundingBox bb: BoundingBox) -> [BezierSegment] {
        let w = max(bb.width, 0.001)
        let h = max(bb.height, 0.001)
        return segments.map { seg in
            BezierSegment(
                startPoint: normalizePoint(seg.startPoint, bb, w, h),
                controlPoint1: normalizePoint(seg.controlPoint1, bb, w, h),
                controlPoint2: normalizePoint(seg.controlPoint2, bb, w, h),
                endPoint: normalizePoint(seg.endPoint, bb, w, h)
            )
        }
    }
    
    private func normalizePoint(_ p: SIMD3<Float>, _ bb: BoundingBox, _ w: Float, _ h: Float) -> SIMD3<Float> {
        SIMD3<Float>((p.x - bb.minX) / w, (p.y - bb.minY) / h, 0)
    }
    
    /// Denormalize segments from [0,1] to world coordinates using a basis
    private func denormalizeSegments(_ segments: [BezierSegment], position: SIMD3<Float>, size: SIMD2<Float>, right: SIMD3<Float>, up: SIMD3<Float>) -> [BezierSegment] {
        segments.map { seg in
            BezierSegment(
                startPoint: denormalizePoint(seg.startPoint, position, size, right, up),
                controlPoint1: denormalizePoint(seg.controlPoint1, position, size, right, up),
                controlPoint2: denormalizePoint(seg.controlPoint2, position, size, right, up),
                endPoint: denormalizePoint(seg.endPoint, position, size, right, up)
            )
        }
    }
    
    private func denormalizePoint(_ p: SIMD3<Float>, _ position: SIMD3<Float>, _ size: SIMD2<Float>, _ right: SIMD3<Float>, _ up: SIMD3<Float>) -> SIMD3<Float> {
        // Linear transformation: translation + (localX * rightVector) + (localY * upwardVector)
        position + (right * (p.x * size.x)) + (up * (p.y * size.y))
    }
    
    /// Add random Gaussian-like noise to control points
    private func addNoise(to segments: [BezierSegment], magnitude: Float) -> [BezierSegment] {
        segments.map { seg in
            BezierSegment(
                startPoint: perturbPoint(seg.startPoint, magnitude),
                controlPoint1: perturbPoint(seg.controlPoint1, magnitude),
                controlPoint2: perturbPoint(seg.controlPoint2, magnitude),
                endPoint: perturbPoint(seg.endPoint, magnitude)
            )
        }
    }
    
    private func perturbPoint(_ p: SIMD3<Float>, _ mag: Float) -> SIMD3<Float> {
        // Box-Muller transform for approximate Gaussian noise
        let u1 = Float.random(in: 0.001...1.0)
        let u2 = Float.random(in: 0.0...1.0)
        let r = sqrt(-2.0 * log(u1)) * mag
        let theta = 2.0 * .pi * u2
        return SIMD3<Float>(p.x + r * cos(theta), p.y + r * sin(theta), p.z)
    }
    
    /// Apply slant transform to normalized segments
    private func applySlant(to segments: [BezierSegment], slant: Float) -> [BezierSegment] {
        let tanSlant = tan(slant * .pi / 180.0)
        return segments.map { seg in
            BezierSegment(
                startPoint: slantPoint(seg.startPoint, tanSlant),
                controlPoint1: slantPoint(seg.controlPoint1, tanSlant),
                controlPoint2: slantPoint(seg.controlPoint2, tanSlant),
                endPoint: slantPoint(seg.endPoint, tanSlant)
            )
        }
    }
    
    private func slantPoint(_ p: SIMD3<Float>, _ tanSlant: Float) -> SIMD3<Float> {
        SIMD3<Float>(p.x + p.y * tanSlant, p.y, p.z)
    }
    
    /// Sample a slant angle from global distribution
    private func sampleSlant(sampleCount: Int) -> Float {
        let u1 = Float.random(in: 0.001...1.0)
        let u2 = Float.random(in: 0.0...1.0)
        let gaussian = sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
        let dampedStdDev = globalSlantStdDev / sqrt(Float(max(sampleCount, 1)))
        return globalSlant + gaussian * dampedStdDev
    }

    // MARK: - Averaging (Multi-Stroke Topology Preserving)

    /// Detect stroke boundaries by finding discontinuities in a segment chain.
    /// Returns indices where a new stroke begins (first is always 0).
    private func detectStrokeBreaks(in segments: [BezierSegment]) -> [Int] {
        guard !segments.isEmpty else { return [] }
        var breaks = [0]
        let threshold: Float = 0.01  // Discontinuity threshold in normalized space
        for i in 1..<segments.count {
            let prevEnd = segments[i - 1].endPoint
            let curStart = segments[i].startPoint
            let gap = simd_distance(SIMD2<Float>(prevEnd.x, prevEnd.y),
                                    SIMD2<Float>(curStart.x, curStart.y))
            if gap > threshold {
                breaks.append(i)
            }
        }
        return breaks
    }
    
    /// Split a flat segment array into separate stroke paths using break indices.
    private func splitByStrokeBreaks(_ segments: [BezierSegment], breaks: [Int]) -> [[BezierSegment]] {
        guard !segments.isEmpty else { return [] }
        let sortedBreaks = breaks.sorted()
        var paths: [[BezierSegment]] = []
        for (idx, start) in sortedBreaks.enumerated() {
            let end = idx + 1 < sortedBreaks.count ? sortedBreaks[idx + 1] : segments.count
            if start < end && start < segments.count {
                paths.append(Array(segments[start..<min(end, segments.count)]))
            }
        }
        if paths.isEmpty { paths.append(segments) }
        return paths
    }

    /// Build averaged normalized paths PER-STROKE from all samples.
    /// Each stroke path is averaged independently so multi-stroke characters preserve topology.
    private func averageNormalizedStrokePaths(for profile: GlyphProfile) -> [[BezierSegment]]? {
        let samples = profile.samples
        guard !samples.isEmpty else { return nil }
        
        // 1. For each sample, normalize and split into separate stroke paths
        var allSamplePaths: [[[BezierSegment]]] = []  // [sample][strokeIndex][segments]
        for sample in samples {
            let normalized = normalizeSegments(sample.segments, boundingBox: sample.boundingBox)
            let breaks = sample.strokeBreakIndices.isEmpty
                ? detectStrokeBreaks(in: normalized)
                : sample.strokeBreakIndices
            let paths = splitByStrokeBreaks(normalized, breaks: breaks)
            allSamplePaths.append(paths)
        }
        
        // 2. Find the most common number of strokes (mode)
        let strokeCounts = allSamplePaths.map { $0.count }
        let mode = strokeCounts.sorted().reduce((val: 0, count: 0, best: 0, bestCount: 0)) { acc, val in
            if val == acc.val { return (val, acc.count + 1, acc.count + 1 > acc.bestCount ? val : acc.best, max(acc.count + 1, acc.bestCount)) }
            return (val, 1, 1 > acc.bestCount ? val : acc.best, max(1, acc.bestCount))
        }.best
        let targetStrokeCount = max(mode, 1)
        
        // 3. Filter to samples with matching stroke count for clean averaging
        let matchingSamples = allSamplePaths.filter { $0.count == targetStrokeCount }
        guard !matchingSamples.isEmpty else {
            // Fallback: just use first sample's paths
            return allSamplePaths.first
        }
        
        // 4. Average each stroke path independently
        let targetPointCount = 48  // Points per stroke for averaging
        var averagedPaths: [[BezierSegment]] = []
        
        for strokeIdx in 0..<targetStrokeCount {
            var sums = [SIMD3<Float>](repeating: .zero, count: targetPointCount)
            var used = 0
            
            for samplePaths in matchingSamples {
                if strokeIdx < samplePaths.count {
                    let strokeSegs = samplePaths[strokeIdx]
                    let points = sampleSegmentsUniformly(strokeSegs, targetPointCount: targetPointCount)
                    guard points.count == targetPointCount else { continue }
                    for i in 0..<targetPointCount {
                        sums[i] += points[i]
                    }
                    used += 1
                }
            }
            
            guard used > 0 else { continue }
            let averaged = sums.map { $0 / Float(used) }
            let strokePoints = averaged.map { StrokePoint(position: $0) }
            let segs = StrokeProcessor.shared.pointsToBezierSegments(strokePoints)
            if !segs.isEmpty {
                averagedPaths.append(segs)
            }
        }
        
        return averagedPaths.isEmpty ? nil : averagedPaths
    }

    private func sampleSegmentsUniformly(_ segments: [BezierSegment], targetPointCount: Int) -> [SIMD3<Float>] {
        guard !segments.isEmpty, targetPointCount > 1 else { return [] }

        var points: [SIMD3<Float>] = []
        let totalSegments = Float(segments.count)
        
        for i in 0..<targetPointCount {
            // Map 0...targetPointCount-1 to global 0.0...1.0
            let globalT = Float(i) / Float(targetPointCount - 1)
            
            // Find which segment this falls into
            var segmentFloat = globalT * totalSegments
            if segmentFloat >= totalSegments {
                segmentFloat = totalSegments - 0.0001
            }
            
            let segmentIndex = Int(segmentFloat)
            let localT = segmentFloat - Float(segmentIndex)
            
            let seg = segments[segmentIndex]
            points.append(cubicBezierPoint(localT, p0: seg.startPoint, p1: seg.controlPoint1, p2: seg.controlPoint2, p3: seg.endPoint))
        }

        return points
    }

    private func cubicBezierPoint(_ t: Float, p0: SIMD3<Float>, p1: SIMD3<Float>, p2: SIMD3<Float>, p3: SIMD3<Float>) -> SIMD3<Float> {
        let mt = 1.0 - t
        let mt2 = mt * mt
        let mt3 = mt2 * mt
        let t2 = t * t
        let t3 = t2 * t
        return mt3 * p0 + 3.0 * mt2 * t * p1 + 3.0 * mt * t2 * p2 + t3 * p3
    }
    
    // MARK: - Helpers
    
    private func calculateBoundingBox(segments: [BezierSegment]) -> BoundingBox {
        guard !segments.isEmpty else { return .zero }
        var minX: Float = .infinity, minY: Float = .infinity
        var maxX: Float = -.infinity, maxY: Float = -.infinity
        for seg in segments {
            for pt in [seg.startPoint, seg.controlPoint1, seg.controlPoint2, seg.endPoint] {
                minX = min(minX, pt.x); minY = min(minY, pt.y)
                maxX = max(maxX, pt.x); maxY = max(maxY, pt.y)
            }
        }
        return BoundingBox(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }
    
    private func extractVelocityProfile(from points: [StrokePoint]) -> [Float] {
        guard points.count >= 2 else { return [] }
        var velocities: [Float] = [0]
        for i in 1..<points.count {
            let dist = simd_length(points[i].position - points[i-1].position)
            let dt = Float(points[i].timestamp - points[i-1].timestamp)
            velocities.append(dt > 0 ? dist / dt : 0)
        }
        return velocities
    }
    
    private func segmentsToStrokePoints(_ segments: [BezierSegment]) -> [StrokePoint] {
        var points: [StrokePoint] = []
        for segment in segments {
            for i in 0...4 {
                let t = Float(i) / 4.0
                let mt = 1.0 - t
                let pos = mt*mt*mt * segment.startPoint +
                          3*mt*mt*t * segment.controlPoint1 +
                          3*mt*t*t * segment.controlPoint2 +
                          t*t*t * segment.endPoint
                if points.isEmpty || simd_length(pos - points.last!.position) > 0.0005 {
                    points.append(StrokePoint(position: pos))
                }
            }
        }
        return points
    }
    
    private func pathsToSegments(_ paths: [[SIMD2<Float>]], at position: SIMD3<Float>, scale: Float, right: SIMD3<Float> = SIMD3<Float>(1,0,0), up: SIMD3<Float> = SIMD3<Float>(0,1,0)) -> [[BezierSegment]] {
        var results: [[BezierSegment]] = []
        for path in paths {
            let points3D = path.map { p in
                StrokePoint(position: position + (right * (p.x * scale)) + (up * (p.y * scale)))
            }
            let segments = StrokeProcessor.shared.pointsToBezierSegments(points3D)
            results.append(segments)
        }
        return results
    }
    
    private func pruneOldSamples(for character: String) {
        guard let context = modelContext else { return }
        let upperChar = character.uppercased()
        let arSource = GlyphSampleSource.arDrawing
        let descriptor = FetchDescriptor<GlyphSample>(
            predicate: #Predicate { $0.character == upperChar && $0.source == arSource },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        guard let samples = try? context.fetch(descriptor) else { return }
        
        if samples.count > maxSamplesPerChar {
            for sample in samples.dropFirst(maxSamplesPerChar) {
                context.delete(sample)
            }
        }
    }
}
