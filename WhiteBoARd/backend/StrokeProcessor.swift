// StrokeProcessor.swift
// WhiteBoARd - Spatial AR Notetaking
// Stroke processing: 2D strokes rendered as flat ribbons in 3D space
// Optimized with GPU acceleration for iPhone 15 Pro

import Foundation
import RealityKit
import simd
import UIKit

/// Processes strokes from input points to 2D ribbon mesh entities
@MainActor
final class StrokeProcessor {
    
    // MARK: - Configuration
    
    struct Configuration {
        var smoothingFactor: Float = 0.3        // Less aggressive smoothing for fluid feel
        var minimumPointDistance: Float = 0.003 // 3mm minimum - capture more detail
        var defaultThickness: Float = 0.003     // 3mm stroke width
        var ribbonDepth: Float = 0.0005         // Very thin ribbon (0.5mm)
        var smoothingPasses: Int = 3            // More passes for smoother curves
        var catmullRomTension: Float = 0.3      // Lower tension = smoother, more flowing curves
    }
    
    private var config: Configuration
    
    // Material caching for performance (iPhone 15 Pro optimization)
    private var materialCache: [String: UnlitMaterial] = [:]
    
    // MARK: - Singleton
    
    static let shared = StrokeProcessor()
    
    private init() {
        self.config = Configuration()
    }
    
    // MARK: - Configuration
    
    func configure(_ config: Configuration) {
        self.config = config
    }
    
    // MARK: - Point Processing
    
    /// Filter and smooth raw input points - CPU only for real-time drawing
    /// GPU acceleration is only used for final stroke processing
    func processPoints(_ rawPoints: [StrokePoint]) -> [StrokePoint] {
        guard rawPoints.count >= 2 else { return rawPoints }
        
        // CPU path for real-time - simple and fast
        // 1. Remove points that are too close together
        var filteredPoints = [rawPoints[0]]
        
        for point in rawPoints.dropFirst() {
            let lastPoint = filteredPoints.last!
            let distance = simd_length(point.position - lastPoint.position)
            
            if distance >= config.minimumPointDistance {
                filteredPoints.append(point)
            }
        }
        
        guard filteredPoints.count >= 2 else { return filteredPoints }
        
        // 2. Interpolate with Catmull-Rom spline for smoother curves
        let interpolated = catmullRomInterpolate(filteredPoints, subdivisions: 2)
        
        // 3. Apply multi-pass Gaussian smoothing
        var smoothed = interpolated
        for _ in 0..<config.smoothingPasses {
            smoothed = smoothPass(smoothed)
        }
        
        return smoothed
    }
    
    /// GPU-accelerated point processing (async version for background processing)
    func processPointsAsync(_ rawPoints: [StrokePoint]) async -> [StrokePoint] {
        guard rawPoints.count >= 2 else { return rawPoints }
        
        // Use Metal GPU acceleration if available
        if let metalProcessor = MetalStrokeProcessor.shared {
            return await metalProcessor.processPoints(rawPoints)
        }
        
        // Fallback to CPU processing
        return processPoints(rawPoints)
    }
    
    /// Catmull-Rom spline interpolation for fluid, natural curves
    private func catmullRomInterpolate(_ points: [StrokePoint], subdivisions: Int) -> [StrokePoint] {
        guard points.count >= 2 else { return points }
        
        var result: [StrokePoint] = []
        let tension = config.catmullRomTension
        
        for i in 0..<points.count - 1 {
            let p0 = i > 0 ? points[i - 1].position : points[i].position
            let p1 = points[i].position
            let p2 = points[i + 1].position
            let p3 = i < points.count - 2 ? points[i + 2].position : points[i + 1].position
            
            let pressure1 = points[i].pressure
            let pressure2 = points[i + 1].pressure
            
            // Add the start point
            result.append(points[i])
            
            // Add subdivided points
            for j in 1..<subdivisions {
                let t = Float(j) / Float(subdivisions)
                
                // Catmull-Rom interpolation with tension control
                let t2 = t * t
                let t3 = t2 * t
                
                let v0 = (p2 - p0) * tension
                let v1 = (p3 - p1) * tension
                
                let position = (2 * t3 - 3 * t2 + 1) * p1 +
                               (t3 - 2 * t2 + t) * v0 +
                               (-2 * t3 + 3 * t2) * p2 +
                               (t3 - t2) * v1
                
                // Interpolate pressure linearly
                let pressure = simd_mix(pressure1, pressure2, t)
                
                result.append(StrokePoint(
                    position: position,
                    pressure: pressure,
                    timestamp: points[i].timestamp + (points[i + 1].timestamp - points[i].timestamp) * Double(t)
                ))
            }
        }
        
        // Add the last point
        result.append(points.last!)
        
        return result
    }
    
    private func smoothPass(_ points: [StrokePoint]) -> [StrokePoint] {
        guard points.count >= 3 else { return points }
        
        var smoothed = [points[0]]
        
        for i in 1..<(points.count - 1) {
            let prev = points[i - 1]
            let current = points[i]
            let next = points[i + 1]
            
            // Gaussian-style weighted average (1-2-1 kernel)
            let avgPosition = (prev.position + 2.0 * current.position + next.position) / 4.0
            let smoothedPosition = simd_mix(
                current.position,
                avgPosition,
                SIMD3<Float>(repeating: config.smoothingFactor)
            )
            
            // Also smooth pressure for consistent stroke width
            let avgPressure = (prev.pressure + 2.0 * current.pressure + next.pressure) / 4.0
            let smoothedPressure = simd_mix(current.pressure, avgPressure, config.smoothingFactor)
            
            smoothed.append(StrokePoint(
                position: smoothedPosition,
                pressure: smoothedPressure,
                timestamp: current.timestamp
            ))
        }
        
        smoothed.append(points.last!)
        return smoothed
    }
    
    // MARK: - Bezier Conversion
    
    /// Convert points to bezier segments using Catmull-Rom spline
    func pointsToBezierSegments(_ points: [StrokePoint]) -> [BezierSegment] {
        guard points.count >= 2 else { return [] }
        
        if points.count == 2 {
            return [BezierSegment(
                startPoint: points[0].position,
                controlPoint1: simd_mix(points[0].position, points[1].position, SIMD3(repeating: 0.33)),
                controlPoint2: simd_mix(points[0].position, points[1].position, SIMD3(repeating: 0.67)),
                endPoint: points[1].position
            )]
        }
        
        var segments: [BezierSegment] = []
        
        for i in 0..<(points.count - 1) {
            let p0 = i > 0 ? points[i - 1].position : points[i].position
            let p1 = points[i].position
            let p2 = points[i + 1].position
            let p3 = i < points.count - 2 ? points[i + 2].position : points[i + 1].position
            
            let tension: Float = 0.5
            let cp1 = p1 + (p2 - p0) * tension / 3.0
            let cp2 = p2 - (p3 - p1) * tension / 3.0
            
            segments.append(BezierSegment(
                startPoint: p1,
                controlPoint1: cp1,
                controlPoint2: cp2,
                endPoint: p2
            ))
        }
        
        return segments
    }
    
    // MARK: - 2D Ribbon Mesh Generation (Optimized)
    
    /// Generate a flat 2D ribbon mesh from points - optimized for real-time
    /// The ribbon is rendered in 3D space but flat (like a tape/ribbon)
    func generateRibbonMesh(
        from points: [StrokePoint],
        thickness: Float? = nil,
        faceDirection: SIMD3<Float> = SIMD3<Float>(0, 0, 1)
    ) -> MeshResource? {
        guard points.count >= 2 else { return nil }
        
        let halfWidth = (thickness ?? config.defaultThickness) / 2.0
        
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var texCoords: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        
        // Normalize face direction
        let normalizedFaceDir = simd_length(faceDirection) > 0.001 
            ? simd_normalize(faceDirection) 
            : SIMD3<Float>(0, 0, 1)
        
        // Calculate perpendicular vectors for ribbon width
        for i in 0..<points.count {
            // Calculate taper factor for smooth flowy edges
            var taperFactor: Float = 1.0
            let taperPoints = min(15, max(3, points.count / 20))
            if taperPoints > 0 {
                if i < taperPoints {
                    let t = Float(i) / Float(taperPoints)
                    // Circular arc taper for a "rounded" brush-like feel
                    taperFactor = 0.2 + 0.8 * sqrt(1.0 - pow(1.0 - t, 2.0))
                } else if i >= points.count - taperPoints {
                    let stepsFromEnd = points.count - 1 - i
                    let t = Float(stepsFromEnd) / Float(taperPoints)
                    taperFactor = 0.2 + 0.8 * sqrt(1.0 - pow(1.0 - t, 2.0))
                }
            }
            
            let pressure = points[i].pressure * taperFactor
            let tangent = calculateTangent(at: i, in: points.map { $0.position })
            
            // Skip degenerate tangents
            let tangentLength = simd_length(tangent)
            guard tangentLength > 0.0001 else {
                // Use previous perpendicular or default
                let defaultPerp = SIMD3<Float>(0, 1, 0)
                let p = points[i].position
                let adjustedWidth = halfWidth * pressure
                positions.append(p - defaultPerp * adjustedWidth)
                positions.append(p + defaultPerp * adjustedWidth)
                normals.append(normalizedFaceDir)
                normals.append(normalizedFaceDir)
                let t = Float(i) / Float(max(points.count - 1, 1))
                texCoords.append(SIMD2<Float>(0, t))
                texCoords.append(SIMD2<Float>(1, t))
                continue
            }
            
            let normalizedTangent = tangent / tangentLength
            
            // Perpendicular in the drawing plane (cross with face direction)
            // This gives us a vector perpendicular to both tangent and face direction
            var perpendicular = simd_cross(normalizedTangent, normalizedFaceDir)
            var perpLength = simd_length(perpendicular)
            
            // If tangent is parallel to face direction, try alternative up vectors
            if perpLength < 0.001 {
                // Try world up
                perpendicular = simd_cross(normalizedTangent, SIMD3<Float>(0, 1, 0))
                perpLength = simd_length(perpendicular)
            }
            
            if perpLength < 0.001 {
                // Try world right
                perpendicular = simd_cross(normalizedTangent, SIMD3<Float>(1, 0, 0))
                perpLength = simd_length(perpendicular)
            }
            
            // Final fallback - use a default perpendicular
            if perpLength < 0.001 {
                perpendicular = SIMD3<Float>(0, 1, 0)
            } else {
                perpendicular = perpendicular / perpLength
            }
            
            let p = points[i].position
            let adjustedWidth = halfWidth * pressure
            
            // Two vertices per point (left and right of center)
            let left = p - perpendicular * adjustedWidth
            let right = p + perpendicular * adjustedWidth
            
            // Validate vertices are not NaN or infinite
            guard left.x.isFinite && left.y.isFinite && left.z.isFinite &&
                  right.x.isFinite && right.y.isFinite && right.z.isFinite else {
                // Skip invalid points
                let defaultPerp = SIMD3<Float>(0, 1, 0)
                positions.append(p - defaultPerp * adjustedWidth)
                positions.append(p + defaultPerp * adjustedWidth)
                normals.append(normalizedFaceDir)
                normals.append(normalizedFaceDir)
                let t = Float(i) / Float(max(points.count - 1, 1))
                texCoords.append(SIMD2<Float>(0, t))
                texCoords.append(SIMD2<Float>(1, t))
                continue
            }
            
            positions.append(left)
            positions.append(right)
            
            // All normals face the same direction (flat ribbon)
            normals.append(normalizedFaceDir)
            normals.append(normalizedFaceDir)
            
            // Texture coordinates for potential stylization
            let t = Float(i) / Float(max(points.count - 1, 1))
            texCoords.append(SIMD2<Float>(0, t))
            texCoords.append(SIMD2<Float>(1, t))
        }
        
        // Ensure we have enough vertices
        guard positions.count >= 4 else { return nil }
        
        // Generate triangle indices (quad strip)
        let numQuads = (positions.count / 2) - 1
        for i in 0..<numQuads {
            let bl = UInt32(i * 2)       // bottom-left
            let br = UInt32(i * 2 + 1)   // bottom-right
            let tl = UInt32(i * 2 + 2)   // top-left
            let tr = UInt32(i * 2 + 3)   // top-right
            
            // Two triangles per quad (front face)
            indices.append(contentsOf: [bl, tl, br])
            indices.append(contentsOf: [br, tl, tr])
            
            // Back face (for double-sided rendering)
            indices.append(contentsOf: [bl, br, tl])
            indices.append(contentsOf: [br, tr, tl])
        }
        
        // Create mesh descriptor
        var descriptor = MeshDescriptor(name: "RibbonStroke")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(texCoords)
        descriptor.primitives = .triangles(indices)
        
        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            print("Failed to generate ribbon mesh: \(error)")
            return nil
        }
    }
    
    /// Incrementally extend an existing ribbon mesh with new points
    func extendRibbonMesh(
        existingPoints: [StrokePoint],
        newPoints: [StrokePoint],
        thickness: Float? = nil,
        faceDirection: SIMD3<Float> = SIMD3<Float>(0, 0, 1)
    ) -> MeshResource? {
        // Combine and regenerate (for simplicity; true incremental would be more complex)
        var allPoints = existingPoints
        allPoints.append(contentsOf: newPoints)
        return generateRibbonMesh(from: allPoints, thickness: thickness, faceDirection: faceDirection)
    }
    
    // MARK: - Helper Methods
    
    private func calculateTangent(at index: Int, in points: [SIMD3<Float>]) -> SIMD3<Float> {
        guard points.count >= 2 else { return SIMD3<Float>(1, 0, 0) }
        
        var tangent: SIMD3<Float>
        
        if index == 0 {
            tangent = points[1] - points[0]
        } else if index == points.count - 1 {
            tangent = points[index] - points[index - 1]
        } else {
            tangent = points[index + 1] - points[index - 1]
        }
        
        // Ensure tangent is valid (not zero length)
        let length = simd_length(tangent)
        if length < 0.0001 {
            // Try to find a non-zero tangent by looking further
            if index > 0 {
                tangent = points[index] - points[0]
            } else if index < points.count - 1 {
                tangent = points[points.count - 1] - points[index]
            }
            
            // Final fallback
            if simd_length(tangent) < 0.0001 {
                return SIMD3<Float>(1, 0, 0)
            }
        }
        
        return simd_normalize(tangent)
    }
    
    private func sampleBezier(_ segment: BezierSegment, count: Int) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        
        for i in 0...count {
            let t = Float(i) / Float(count)
            let point = cubicBezierPoint(
                t,
                p0: segment.startPoint,
                p1: segment.controlPoint1,
                p2: segment.controlPoint2,
                p3: segment.endPoint
            )
            points.append(point)
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
    
    // MARK: - 2D to 3D Conversion
    
    /// Convert 2D bezier paths to 3D bezier segments (for math completion rendering)
    func convert2DBezierTo3D(
        paths: [[SIMD2<Float>]],
        basePosition: SIMD3<Float>,
        scale: Float = 1.0,
        orientation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    ) -> [BezierSegment] {
        var segments: [BezierSegment] = []
        
        for path in paths {
            guard path.count >= 2 else { continue }
            
            // Convert 2D points to 3D (on the XY plane, offset by basePosition)
            let points3D = path.map { point2D -> SIMD3<Float> in
                let localPoint = SIMD3<Float>(point2D.x * scale, point2D.y * scale, 0)
                let rotated = orientation.act(localPoint)
                return basePosition + rotated
            }
            
            // Convert to stroke points and then bezier
            let strokePoints = points3D.map { StrokePoint(position: $0) }
            segments.append(contentsOf: pointsToBezierSegments(strokePoints))
        }
        
        return segments
    }
    
    // MARK: - Entity Creation
    
    /// Create a RealityKit entity from processed stroke points (2D ribbon)
    func createStrokeEntity(
        from stroke: SpatialStroke,
        faceDirection: SIMD3<Float> = SIMD3<Float>(0, 0, 1)
    ) -> Entity? {
        guard stroke.points.count >= 2 else { return nil }
        
        guard let mesh = generateRibbonMesh(
            from: stroke.points,
            thickness: stroke.thickness,
            faceDirection: faceDirection
        ) else { return nil }
        
        let entity = Entity()
        
        // Use cached material for better performance
        let material = getCachedMaterial(for: stroke.color)
        
        entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
        
        if let transform = stroke.localTransform {
            entity.transform = Transform(matrix: transform)
        }
        
        entity.name = "Stroke_\(stroke.id.uuidString)"
        
        return entity
    }
    
    /// Create entity directly from points (for live drawing)
    func createEntity(
        from points: [StrokePoint],
        thickness: Float = 0.003,
        color: StrokeColor = .white,
        faceDirection: SIMD3<Float> = SIMD3<Float>(0, 0, 1)
    ) -> Entity? {
        guard let mesh = generateRibbonMesh(from: points, thickness: thickness, faceDirection: faceDirection) else {
            return nil
        }
        
        let entity = Entity()
        
        // Use cached material for better performance
        let material = getCachedMaterial(for: color)
        
        entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
        
        return entity
    }
    
    // MARK: - Material Caching (iPhone 15 Pro Optimization)
    
    /// Get or create a cached material for the given color
    func getCachedMaterial(for color: StrokeColor) -> UnlitMaterial {
        let key = color.rawValue
        
        if let cached = materialCache[key] {
            return cached
        }
        
        // Create new material
        var material = UnlitMaterial()
        let rgb = color.rgbColor
        material.color = .init(tint: UIColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1.0))
        
        // Cache it
        materialCache[key] = material
        
        return material
    }
    
    /// Create entity from bezier segments (samples them to points first)
    func createEntity(
        from segments: [BezierSegment],
        thickness: Float = 0.003,
        color: StrokeColor = .white,
        faceDirection: SIMD3<Float> = SIMD3<Float>(0, 0, 1)
    ) -> Entity? {
        // Sample bezier segments to points
        var points: [StrokePoint] = []
        for segment in segments {
            let sampled = sampleBezier(segment, count: 8)
            for pos in sampled {
                if points.isEmpty || simd_length(pos - points.last!.position) > 0.001 {
                    points.append(StrokePoint(position: pos))
                }
            }
        }
        
        return createEntity(from: points, thickness: thickness, color: color, faceDirection: faceDirection)
    }
    
    // MARK: - Ramer-Douglas-Peucker Decimation
    
    /// Mathematically simplifies a high-density 3D stroke path by culling redundant straight-line vertices.
    /// Radically reduces SwiftData load and rendering geometry bounds by up to 70%.
    func simplifyRDP(points: [StrokePoint], epsilon: Float) -> [StrokePoint] {
        guard points.count > 2 else { return points }
        
        var maxDistance: Float = 0.0
        var index = 0
        
        let startPoint = points.first!.position
        let endPoint = points.last!.position
        
        // Find the point furthest from the baseline segment
        for i in 1..<(points.count - 1) {
            let dist = perpendicularDistance(point: points[i].position, lineStart: startPoint, lineEnd: endPoint)
            if dist > maxDistance {
                maxDistance = dist
                index = i
            }
        }
        
        // If distance exceeds epsilon threshold, keep the point and recursively simplify sub-bounds
        if maxDistance > epsilon {
            let leftRec = simplifyRDP(points: Array(points[0...index]), epsilon: epsilon)
            let rightRec = simplifyRDP(points: Array(points[index...points.count - 1]), epsilon: epsilon)
            
            // Re-merge (dropping the duplicated shared index point)
            return leftRec.dropLast() + rightRec
        } else {
            // Cull all internal points natively
            return [points.first!, points.last!]
        }
    }
    
    private func perpendicularDistance(point: SIMD3<Float>, lineStart: SIMD3<Float>, lineEnd: SIMD3<Float>) -> Float {
        let lineLength = simd_distance(lineStart, lineEnd)
        if lineLength == 0 { return simd_distance(point, lineStart) }
        
        let crossP = simd_cross(point - lineStart, lineEnd - lineStart)
        return simd_length(crossP) / lineLength
    }
}

// MARK: - SIMD Extensions

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> {
        SIMD3<Float>(x, y, z)
    }
}
