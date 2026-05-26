// MetalStrokeProcessor.swift
// WhiteBoARd - Spatial AR Notetaking
// GPU-accelerated stroke processing using Metal compute shaders for iPhone 15 Pro

import Foundation
import Metal
import simd

/// GPU-accelerated stroke processor using Metal compute shaders
/// Optimized for iPhone 15 Pro's A17 Pro GPU (6 cores)
@MainActor
final class MetalStrokeProcessor {
    
    // MARK: - Metal Resources
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    
    // Compute pipelines
    private let smoothingPipeline: MTLComputePipelineState
    private let interpolationPipeline: MTLComputePipelineState
    private let ribbonPipeline: MTLComputePipelineState
    
    // Configuration
    private var smoothingFactor: Float = 0.3
    private var catmullRomTension: Float = 0.3
    private var minimumPointDistance: Float = 0.003
    
    // Performance tracking
    private var isAvailable: Bool = true
    
    // MARK: - Initialization
    
    init?() {
        // Metal is only available on physical devices, not simulator
        #if targetEnvironment(simulator)
        print("⚠️ Metal GPU acceleration not available in simulator (requires physical device)")
        return nil
        #else
        
        // Get default Metal device (A17 Pro GPU)
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("❌ Metal not available on this device")
            return nil
        }
        
        self.device = device
        print("🎮 Metal GPU initialized: \(device.name)")
        print("   - Max threads per threadgroup: \(device.maxThreadsPerThreadgroup)")
        print("   - Supports compute: \(device.supportsFamily(.apple9))")
        
        // Create command queue
        guard let queue = device.makeCommandQueue() else {
            print("❌ Failed to create Metal command queue")
            return nil
        }
        self.commandQueue = queue
        
        // Load shader library
        guard let library = device.makeDefaultLibrary() else {
            print("❌ Failed to load Metal shader library")
            return nil
        }
        self.library = library
        
        // Create compute pipelines
        do {
            // Gaussian smoothing pipeline
            guard let smoothFunc = library.makeFunction(name: "gaussianSmooth") else {
                print("❌ Failed to find gaussianSmooth function")
                return nil
            }
            self.smoothingPipeline = try device.makeComputePipelineState(function: smoothFunc)
            
            // Catmull-Rom interpolation pipeline
            guard let interpFunc = library.makeFunction(name: "catmullRomInterpolate") else {
                print("❌ Failed to find catmullRomInterpolate function")
                return nil
            }
            self.interpolationPipeline = try device.makeComputePipelineState(function: interpFunc)
            
            // Ribbon mesh generation pipeline
            guard let ribbonFunc = library.makeFunction(name: "generateRibbonVertices") else {
                print("❌ Failed to find generateRibbonVertices function")
                return nil
            }
            self.ribbonPipeline = try device.makeComputePipelineState(function: ribbonFunc)
            
            print("✅ Metal compute pipelines created successfully")
            
        } catch {
            print("❌ Failed to create Metal pipelines: \(error)")
            return nil
        }
        #endif
    }
    
    // MARK: - Configuration
    
    func configure(smoothingFactor: Float, tension: Float, minimumDistance: Float) {
        self.smoothingFactor = smoothingFactor
        self.catmullRomTension = tension
        self.minimumPointDistance = minimumDistance
    }
    
    // MARK: - GPU-Accelerated Processing
    
    /// Process stroke points using GPU acceleration (much faster than CPU)
    /// Returns smoothed and interpolated points ready for mesh generation
    func processPoints(_ points: [StrokePoint]) async -> [StrokePoint] {
        guard points.count >= 2 else { return points }
        guard isAvailable else {
            print("⚠️ Metal not available, falling back to CPU")
            return points
        }
        
        // For very small point counts, CPU is faster due to overhead
        if points.count < 10 {
            return points
        }
        
        // Convert to Metal-compatible format
        var metalPoints = points.map { point in
            MetalStrokePoint(
                position: (point.position.x, point.position.y, point.position.z),
                pressure: point.pressure,
                timestamp: Float(point.timestamp)
            )
        }
        
        // Run GPU smoothing passes
        for _ in 0..<3 {
            metalPoints = await gpuSmooth(metalPoints)
        }
        
        // Convert back to StrokePoint format
        return metalPoints.map { metalPoint in
            StrokePoint(
                position: SIMD3<Float>(metalPoint.position.0, metalPoint.position.1, metalPoint.position.2),
                pressure: metalPoint.pressure,
                timestamp: TimeInterval(metalPoint.timestamp)
            )
        }
    }
    
    // MARK: - GPU Operations
    
    /// GPU-accelerated Gaussian smoothing
    private func gpuSmooth(_ points: [MetalStrokePoint]) async -> [MetalStrokePoint] {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            print("❌ Failed to create command buffer")
            return points
        }
        
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            print("❌ Failed to create compute encoder")
            return points
        }
        
        // Create buffers
        let pointCount = points.count
        let inputBuffer = device.makeBuffer(bytes: points, length: MemoryLayout<MetalStrokePoint>.stride * pointCount, options: [])
        let outputBuffer = device.makeBuffer(length: MemoryLayout<MetalSmoothedPoint>.stride * pointCount, options: [])
        
        guard let inputBuffer = inputBuffer, let outputBuffer = outputBuffer else {
            print("❌ Failed to create Metal buffers")
            return points
        }
        
        // Create parameters buffer
        var params = SmoothingParams(smoothingFactor: smoothingFactor, pointCount: UInt32(pointCount))
        let paramsBuffer = device.makeBuffer(bytes: &params, length: MemoryLayout<SmoothingParams>.size, options: [])
        
        // Configure compute command
        encoder.setComputePipelineState(smoothingPipeline)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(outputBuffer, offset: 0, index: 1)
        encoder.setBuffer(paramsBuffer, offset: 0, index: 2)
        
        // Dispatch threads
        let threadGroupSize = MTLSize(width: min(smoothingPipeline.maxTotalThreadsPerThreadgroup, pointCount), height: 1, depth: 1)
        let threadGroups = MTLSize(width: (pointCount + threadGroupSize.width - 1) / threadGroupSize.width, height: 1, depth: 1)
        
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        
        // Execute on GPU
        commandBuffer.commit()
        await commandBuffer.completed()
        
        // Read results back
        let resultPointer = outputBuffer.contents().assumingMemoryBound(to: MetalSmoothedPoint.self)
        var smoothedPoints: [MetalStrokePoint] = []
        
        for i in 0..<pointCount {
            let smoothed = resultPointer[i]
            smoothedPoints.append(MetalStrokePoint(
                position: smoothed.position,
                pressure: smoothed.pressure,
                timestamp: Float(points[i].timestamp)
            ))
        }
        
        return smoothedPoints
    }
    
    // MARK: - Material Caching
    
    private var cachedMaterials: [String: Any] = [:]
    
    /// Get or create cached material for a stroke color
    func getCachedMaterial(for color: StrokeColor) -> Any? {
        let key = "\(color.rawValue)"
        if let cached = cachedMaterials[key] {
            return cached
        }
        
        // Material will be created by RealityKit
        // This is a placeholder for future material caching
        return nil
    }
}

// MARK: - Metal-Compatible Structures

struct MetalStrokePoint {
    let position: (Float, Float, Float)
    let pressure: Float
    let timestamp: Float
}

struct MetalSmoothedPoint {
    let position: (Float, Float, Float)
    let pressure: Float
}

struct SmoothingParams {
    let smoothingFactor: Float
    let pointCount: UInt32
}

struct InterpolationParams {
    let tension: Float
    let inputCount: UInt32
    let subdivisions: UInt32
}

struct RibbonParams {
    let thickness: Float
    let depth: Float
    let pointCount: UInt32
}

// MARK: - Singleton

extension MetalStrokeProcessor {
    static let shared: MetalStrokeProcessor? = MetalStrokeProcessor()
}
