// CharacterSegmenter.swift
// WhiteBoARd - Spatial AR Notetaking
// Segments AR drawing strokes into individual characters
// and feeds them into Kon for continuous learning.

import Foundation
import Vision
import UIKit
import simd

/// Segments groups of AR strokes into individual characters
/// using on-device Vision text recognition, then feeds into Kon.
@MainActor
final class CharacterSegmenter {
    
    // MARK: - Singleton
    
    static let shared = CharacterSegmenter()
    private init() {}
    
    // MARK: - Public API
    
    /// Process a batch of recent strokes: recognize text and learn each character.
    /// - Parameter strokes: recently completed SpatialStrokes (not yet learned)
    @MainActor
    func learnFromStrokes(_ strokes: [SpatialStroke]) {
        guard !strokes.isEmpty else { return }
        
        // 1. Render strokes to a 2D image for Vision recognition
        guard let image = renderStrokesToImage(strokes) else {
            print("[Segmenter] ⚠️ Could not render strokes to image")
            return
        }
        
        // 2. Run on-device text recognition using concurrency
        Task {
            let recognizedText = await recognizeText(in: image)
            
            guard let text = recognizedText, !text.isEmpty else {
                print("[Segmenter] ℹ️ No text recognized from strokes")
                return
            }
            
            print("[Segmenter] 🔍 Recognized: \"\(text)\"")
            
            // 3. Segment strokes into individual characters safely within bounds of MainActor
            await MainActor.run {
                self.mapCharactersToStrokes(text: text, strokes: strokes)
            }
        }
    }
    
    // MARK: - Text Recognition (On-Device Vision)
    
    private func recognizeText(in image: UIImage) async -> String? {
        // Deep copy the CGImage to ensure memory survives across background threads
        guard let cgImageRaw = image.cgImage, let cgImage = cgImageRaw.copy() else {
            return nil
        }
        
        // Use a detached task to perform Vision AI off the MainActor smoothly
        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false // CRITICAL: Stop Vision from translating 2+2 into English words like 2T2
            request.customWords = ["+", "-", "=", "/", "x", "y", "z", "(", ")", "sin", "cos", "tan", "π"]
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            
            do {
                // Perform is synchronous. We don't need a completion handler.
                try handler.perform([request])
                
                guard let observations = request.results as? [VNRecognizedTextObservation],
                      !observations.isEmpty else {
                    return nil
                }
                
                // Combine all recognized text
                let fullText = observations.compactMap { obs in
                    obs.topCandidates(1).first?.string
                }.joined(separator: " ")
                
                return Self.sanitizeMathOCR(fullText)
            } catch {
                print("[Segmenter] ⚠️ Handler perform failed: \(error.localizedDescription)")
                return nil
            }
        }.value
    }
    
    nonisolated private static func sanitizeMathOCR(_ text: String) -> String {
        // We protect known math functions so their letters don't get replaced (e.g. 's' in 'sin')
        let protectedWords = ["sin", "cos", "tan", "lim", "log", "ln", "pi", "min", "max"]
        var protectedText = text
        for (i, word) in protectedWords.enumerated() {
            protectedText = protectedText.replacingOccurrences(of: word, with: "[[P\(i)]]", options: .caseInsensitive)
        }
        
        // Force common OCR misclassifications of messy handwriting to their likely digit counterparts.
        // This is safe because this app is highly biased towards math equations and digits.
        let replacements: [String: String] = [
            "S": "5", "s": "5",
            "O": "0", "o": "0",
            "B": "8",
            "I": "1", "l": "1", // lowercase L, uppercase I
            "g": "9", "q": "9",
            "Z": "2", "z": "2"
        ]
        
        for (bad, good) in replacements {
            protectedText = protectedText.replacingOccurrences(of: bad, with: good)
        }
        
        // Restore protected words
        for (i, word) in protectedWords.enumerated() {
            protectedText = protectedText.replacingOccurrences(of: "[[P\(i)]]", with: word)
        }
        
        return protectedText
    }
    
    // MARK: - Character-to-Stroke Mapping
    
    /// Map recognized characters to spatial strokes and feed into Kon.
    private func mapCharactersToStrokes(text: String, strokes: [SpatialStroke]) {
        // Filter to non-whitespace characters only (so mathematical operators pass through)
        let chars = text.uppercased().filter { !$0.isWhitespace }.map { String($0) }
        guard !chars.isEmpty, !strokes.isEmpty else { return }
        
        // Sort strokes by their centroid X position (left-to-right writing)
        let sortedStrokes = strokes.sorted { s1, s2 in
            centroidX(of: s1) < centroidX(of: s2)
        }
        
        // Unreliable segmentation for multi-char cursive. Bank it and abort Kon learning.
        if chars.count > 1 && chars.count > strokes.count {
            print("[Segmenter] 📝 Style Bank: Learning complex cursive '\(text)'...")
            
            // 1. Save to SwiftData (DB reference)
            if let context = strokes.first?.modelContext {
                let sample = CursiveTrainingSample(recognizedText: text, strokes: strokes)
                context.insert(sample)
                try? context.save()
            }
            return
        }
        
        // We now allow digits and operators to be banked for total style imitation, but WE DO NOT RETURN!
        if text.rangeOfCharacter(from: .decimalDigits) != nil {
            print("[Segmenter] 📝 Style Bank: Learning digit '\(text)'...")
            
            // 1. Save to SwiftData (DB reference)
            if let context = strokes.first?.modelContext {
                let sample = CursiveTrainingSample(recognizedText: text, strokes: strokes)
                context.insert(sample)
                try? context.save()
                
                // 2. Export to Physical File (Persists across app deletions)
                let exportData = CursiveExportData(from: sample)
                if let encoded = try? JSONEncoder().encode(exportData) {
                    let fileName = "sample_\(Int(Date().timeIntervalSince1970))_\(text.lowercased()).json"
                    let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                    let fileURL = documentsDir.appendingPathComponent(fileName)
                    
                    try? encoded.write(to: fileURL)
                    print("[Segmenter] 📂 Style Persisted: \(fileName)")
                }
            }
        }
        
        if chars.count == 1 {
            // Single character — all strokes belong to it
            Kon.shared.addSample(character: chars[0], strokes: sortedStrokes)
            return
        }
        
        // Multiple characters — cluster strokes by spatial proximity
        let clusters = clusterStrokes(sortedStrokes, expectedCount: chars.count)
        
        // Map clusters to characters (left-to-right)
        for (i, char) in chars.enumerated() {
            if i < clusters.count && !clusters[i].isEmpty {
                Kon.shared.addSample(character: char, strokes: clusters[i])
            }
        }
    }
    
    /// Cluster strokes into N groups based on X-position gaps
    private func clusterStrokes(_ strokes: [SpatialStroke], expectedCount: Int) -> [[SpatialStroke]] {
        guard strokes.count >= expectedCount else {
            // Fewer strokes than characters — assign one per character
            return strokes.map { [$0] }
        }
        
        if expectedCount == 1 {
            return [strokes]
        }
        
        // Calculate centroid X for each stroke
        let centroids = strokes.map { centroidX(of: $0) }
        
        // Calculate gaps between consecutive strokes
        var gaps: [(index: Int, gap: Float)] = []
        for i in 0..<(centroids.count - 1) {
            gaps.append((index: i, gap: centroids[i + 1] - centroids[i]))
        }
        
        // Sort gaps by size (largest first) — these are character boundaries
        gaps.sort { $0.gap > $1.gap }
        
        // Take the top (expectedCount - 1) gaps as split points
        let splitCount = min(expectedCount - 1, gaps.count)
        let splitIndices = gaps.prefix(splitCount).map { $0.index }.sorted()
        
        // Build clusters from split points
        var clusters: [[SpatialStroke]] = []
        var startIdx = 0
        
        for splitIdx in splitIndices {
            let cluster = Array(strokes[startIdx...(splitIdx)])
            clusters.append(cluster)
            startIdx = splitIdx + 1
        }
        
        // Last cluster
        if startIdx < strokes.count {
            clusters.append(Array(strokes[startIdx...]))
        }
        
        return clusters
    }
    
    // MARK: - Stroke Rendering (for Vision recognition)
    
    /// Render strokes to a 2D image suitable for text recognition
    private func renderStrokesToImage(_ strokes: [SpatialStroke], imageSize: CGSize = CGSize(width: 800, height: 200)) -> UIImage? {
        // Find bounding box of all stroke points
        var minX: Float = .infinity, minY: Float = .infinity
        var maxX: Float = -.infinity, maxY: Float = -.infinity
        
        for stroke in strokes {
            for point in stroke.points {
                minX = min(minX, point.position.x)
                minY = min(minY, point.position.y)
                maxX = max(maxX, point.position.x)
                maxY = max(maxY, point.position.y)
            }
        }
        
        guard minX < maxX && minY < maxY else { return nil }
        
        let margin: Float = 0.01
        let worldWidth = maxX - minX + 2 * margin
        let worldHeight = maxY - minY + 2 * margin
        
        // Calculate scale to fit in image
        let scaleX = Float(imageSize.width - 20) / worldWidth
        let scaleY = Float(imageSize.height - 20) / worldHeight
        let scale = min(scaleX, scaleY)
        
        // Center offset
        let renderedWidth = worldWidth * scale
        let renderedHeight = worldHeight * scale
        let offsetX = (Float(imageSize.width) - renderedWidth) / 2.0
        let offsetY = (Float(imageSize.height) - renderedHeight) / 2.0
        
        UIGraphicsBeginImageContextWithOptions(imageSize, true, 1.0)
        defer { UIGraphicsEndImageContext() }
        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        
        // White background
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: imageSize))
        
        // Draw strokes in black
        context.setStrokeColor(UIColor.black.cgColor)
        context.setLineWidth(4)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        
        for stroke in strokes {
            guard let first = stroke.points.first else { continue }
            
            context.beginPath()
            let startX = CGFloat(offsetX + (first.position.x - minX + margin) * scale)
            // Flip Y: in UIKit, Y grows downward; in AR, Y grows upward
            let startY = CGFloat(Float(imageSize.height) - offsetY - (first.position.y - minY + margin) * scale)
            context.move(to: CGPoint(x: startX, y: startY))
            
            for point in stroke.points.dropFirst() {
                let px = CGFloat(offsetX + (point.position.x - minX + margin) * scale)
                let py = CGFloat(Float(imageSize.height) - offsetY - (point.position.y - minY + margin) * scale)
                context.addLine(to: CGPoint(x: px, y: py))
            }
            
            context.strokePath()
        }
        
        return UIGraphicsGetImageFromCurrentImageContext()
    }
    
    // MARK: - Helpers
    
    private func centroidX(of stroke: SpatialStroke) -> Float {
        guard !stroke.points.isEmpty else { return 0 }
        let sumX = stroke.points.reduce(Float(0)) { $0 + $1.position.x }
        return sumX / Float(stroke.points.count)
    }
}
