// GeminiService.swift
// WhiteBoARd - Spatial AR Notetaking
// Gemini 3 Flash API integration for math autocomplete

import Foundation
import UIKit

/// Service for interacting with Gemini 3 Flash API
actor GeminiService {
    
    // MARK: - Configuration GEMINIMODEL
    
    private let modelName = "gemini-3.1-flash-lite"
    private let fallbackModels = ["gemini-2.5-flash", "gemini-2.0-flash"]
    private let apiHost = "https://generativelanguage.googleapis.com/v1beta/models"
    
    /// API key - should be stored securely in production
    private var apiKey: String?
    
    // MARK: - Singleton
    
    static let shared = GeminiService()
    
    private init() {
        // Load API key: try .env file first, then environment variable, then UserDefaults
        if let key = Self.loadKeyFromEnvFile() {
            self.apiKey = key
        } else if let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] {
            self.apiKey = key
        } else if let key = UserDefaults.standard.string(forKey: "gemini_api_key") {
            self.apiKey = key
        }
    }
    
    /// Load GEMINI_API_KEY from backend/.env file
    private static func loadKeyFromEnvFile() -> String? {
        let bundle = Bundle.main
        // Try multiple paths for the .env file
        let possiblePaths = [
            bundle.resourcePath.map { ($0 as NSString).appendingPathComponent("backend/.env") },
            bundle.path(forResource: ".env", ofType: nil),
            bundle.path(forResource: "env", ofType: nil),
            bundle.bundlePath + "/backend/.env"
        ].compactMap { $0 }
        
        for path in possiblePaths {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                for line in contents.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("GEMINI_API_KEY=") {
                        let value = String(trimmed.dropFirst("GEMINI_API_KEY=".count))
                            .trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        if !value.isEmpty {
                            return value
                        }
                    }
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Configuration
    
    func configure(apiKey: String) {
        self.apiKey = apiKey
    }
    
    // MARK: - Math Completion
    
    /// Request math completion from handwritten stroke image
    /// - Parameters:
    ///   - image: Snapshot of current strokes as UIImage
    ///   - context: Optional context about what the user is writing
    /// - Returns: MathCompletionResponse with LaTeX and confidence
    func requestMathCompletion(
        image: UIImage,
        context: String? = nil
    ) async throws -> MathCompletionResponse {
        guard let apiKey = apiKey else {
            throw GeminiError.missingAPIKey
        }
        
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            throw GeminiError.imageEncodingFailed
        }
        
        let base64Image = imageData.base64EncodedString()
        
        let request = GeminiRequest(
            contents: [
                Content(
                    parts: [
                        Part(text: buildPrompt(context: context)),
                        Part(inlineData: InlineData(
                            mimeType: "image/jpeg",
                            data: base64Image
                        ))
                    ]
                )
            ],
            generationConfig: GenerationConfig(
                temperature: 0.1,
                topK: 1,
                topP: 0.95,
                maxOutputTokens: 256,
                thinkingConfig: ThinkingConfig(thinkingLevel: "minimal")
            ),
            safetySettings: defaultSafetySettings
        )
        
        let response = try await sendRequest(request)
        return try parseResponse(response)
    }
    
    // MARK: - Kon Math Solving
    
    /// Kon trigger: analyze the screen for math equations and return ONLY the answer.
    /// - Parameter image: AR view snapshot
    /// - Returns: The answer string, or nil if no math found
    func solveMath(image: UIImage) async throws -> String? {
        guard apiKey != nil else {
            throw GeminiError.missingAPIKey
        }
        
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            throw GeminiError.imageEncodingFailed
        }
        
        let base64Image = imageData.base64EncodedString()
        
        let prompt = """
        Look at this image of handwritten content on an AR whiteboard.
        
        Identify the mathematical expression or equation and SOLVE it.
        
        CRITICAL RULES:
        - REDUNDANCY CHECK: If the user has already drawn an equals sign ('='), return ONLY the answer (e.g. "10"). 
        - If the equals sign is MISSING, prepend it to your answer (e.g. "= 10").
        - Return ONLY the result as a plain string. No letters (unless part of a solution like x=2), no words.
        - For simple arithmetic (e.g., "2+2"), return the result concisely.
        - If multiple solutions exist (e.g., quadratic), comma-separate them.
        
        EXAMPLES:
        "2+3=" -> "5"
        "10*5" -> "= 50"
        "sin(π/2)" -> "= 1"
        "x^2 = 4" -> "x = 2, -2"
        
        If NO clear math is found, return ONLY: NO_MATH
        
        Strictly respond with the solution alone.
        """
        
        let request = GeminiRequest(
            contents: [
                Content(
                    parts: [
                        Part(text: prompt),
                        Part(inlineData: InlineData(
                            mimeType: "image/jpeg",
                            data: base64Image
                        ))
                    ]
                )
            ],
            generationConfig: GenerationConfig(
                temperature: 0.1,
                topK: 1,
                topP: 0.95,
                maxOutputTokens: 128,
                thinkingConfig: ThinkingConfig(thinkingLevel: "minimal")
            ),
            safetySettings: defaultSafetySettings
        )
        
        let response = try await sendRequest(request)
        
        // Extract text from response
        guard let candidate = response.candidates.first,
              let part = candidate.content.parts.first,
              let rawText = part.text else {
            return nil
        }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if text == "NO_MATH" || text.isEmpty {
            return nil
        }
        
        return text
    }
    
    /// Request handwriting analysis for style learning
    func analyzeHandwriting(
        characterImage: UIImage,
        character: String
    ) async throws -> HandwritingAnalysis {
        guard let apiKey = apiKey else {
            throw GeminiError.missingAPIKey
        }
        
        guard let imageData = characterImage.pngData() else {
            throw GeminiError.imageEncodingFailed
        }
        
        let base64Image = imageData.base64EncodedString()
        
        let prompt = """
        Analyze this handwritten character '\(character)'. 
        Describe the stroke characteristics:
        1. Stroke order and direction
        2. Relative proportions
        3. Distinctive style features (slant, loops, serifs, etc.)
        4. Connection points for cursive
        
        Respond in JSON format:
        {
            "strokeCount": number,
            "slantAngle": number (-45 to 45 degrees),
            "hasLoops": boolean,
            "hasSerifs": boolean,
            "proportions": {"width": number, "height": number},
            "style": "print" | "cursive" | "mixed",
            "characteristics": [string]
        }
        """
        
        let request = GeminiRequest(
            contents: [
                Content(
                    parts: [
                        Part(text: prompt),
                        Part(inlineData: InlineData(
                            mimeType: "image/png",
                            data: base64Image
                        ))
                    ]
                )
            ],
            generationConfig: GenerationConfig(
                temperature: 0.2,
                topK: 1,
                topP: 0.9,
                maxOutputTokens: 512,
                thinkingConfig: ThinkingConfig(thinkingLevel: "minimal")
            ),
            safetySettings: defaultSafetySettings
        )
        
        let response = try await sendRequest(request)
        return try parseHandwritingAnalysis(response)
    }
    
    // MARK: - Private Methods
    
    private func buildPrompt(context: String?) -> String {
        var prompt = """
        You are a math equation completion assistant. Analyze the handwritten mathematical expression in the image.
        
        Your task:
        1. Recognize the partial math expression
        2. Predict the most likely completion
        3. Return the COMPLETE expression (original + completion) in LaTeX format
        
        Rules:
        - Only complete mathematical expressions (equations, formulas, etc.)
        - If it's not math, return {"latex": "", "completion": "", "confidence": 0}
        - Be conservative - only complete when confident
        - Match the apparent complexity level
        
        Respond ONLY with valid JSON in this exact format:
        {
            "recognized": "what you see in the image",
            "latex": "complete LaTeX expression",
            "completion": "just the completion part in LaTeX",
            "confidence": 0.0 to 1.0,
            "type": "equation" | "expression" | "formula" | "unknown"
        }
        """
        
        if let context = context {
            prompt += "\n\nContext: \(context)"
        }
        
        return prompt
    }
    
    private func sendRequest(_ request: GeminiRequest) async throws -> GeminiResponse {
        guard let apiKey = apiKey else {
            throw GeminiError.missingAPIKey
        }
        
        let modelsToTry = [modelName] + fallbackModels
        var lastError: Error = GeminiError.invalidResponse
        
        for model in modelsToTry {
            guard let url = URL(string: "\(apiHost)/\(model):generateContent?key=\(apiKey)") else {
                continue
            }
            
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.timeoutInterval = 18
            urlRequest.httpBody = try JSONEncoder().encode(request)
            
            do {
                let (data, response) = try await URLSession.shared.data(for: urlRequest)
                guard let httpResponse = response as? HTTPURLResponse else {
                    lastError = GeminiError.invalidResponse
                    continue
                }
                guard httpResponse.statusCode == 200 else {
                    if let errorResponse = try? JSONDecoder().decode(GeminiErrorResponse.self, from: data) {
                        lastError = GeminiError.apiError(errorResponse.error.message)
                    } else {
                        lastError = GeminiError.httpError(httpResponse.statusCode)
                    }
                    continue
                }
                return try JSONDecoder().decode(GeminiResponse.self, from: data)
            } catch {
                if let urlError = error as? URLError {
                    switch urlError.code {
                    case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet, .networkConnectionLost:
                        lastError = GeminiError.apiError("Network unavailable. Check internet and try Kon again.")
                    default:
                        lastError = urlError
                    }
                } else {
                    lastError = error
                }
                continue
            }
        }
        
        throw lastError
    }
    
    private func parseResponse(_ response: GeminiResponse) throws -> MathCompletionResponse {
        guard let candidate = response.candidates.first,
              let part = candidate.content.parts.first,
              let text = part.text else {
            throw GeminiError.emptyResponse
        }
        
        // Extract JSON from response (may have markdown code blocks)
        let jsonString = extractJSON(from: text)
        
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw GeminiError.parseError("Invalid JSON string")
        }
        
        let result = try JSONDecoder().decode(MathCompletionResult.self, from: jsonData)
        
        return MathCompletionResponse(
            recognizedText: result.recognized,
            fullLatex: result.latex,
            completionLatex: result.completion,
            confidence: result.confidence,
            expressionType: result.type
        )
    }
    
    private func parseHandwritingAnalysis(_ response: GeminiResponse) throws -> HandwritingAnalysis {
        guard let candidate = response.candidates.first,
              let part = candidate.content.parts.first,
              let text = part.text else {
            throw GeminiError.emptyResponse
        }
        
        let jsonString = extractJSON(from: text)
        
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw GeminiError.parseError("Invalid JSON string")
        }
        
        return try JSONDecoder().decode(HandwritingAnalysis.self, from: jsonData)
    }
    
    private func extractJSON(from text: String) -> String {
        // Remove markdown code blocks if present
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if cleaned.hasPrefix("```json") {
            cleaned = String(cleaned.dropFirst(7))
        } else if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst(3))
        }
        
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private var defaultSafetySettings: [SafetySetting] {
        [
            SafetySetting(category: "HARM_CATEGORY_HARASSMENT", threshold: "BLOCK_NONE"),
            SafetySetting(category: "HARM_CATEGORY_HATE_SPEECH", threshold: "BLOCK_NONE"),
            SafetySetting(category: "HARM_CATEGORY_SEXUALLY_EXPLICIT", threshold: "BLOCK_NONE"),
            SafetySetting(category: "HARM_CATEGORY_DANGEROUS_CONTENT", threshold: "BLOCK_NONE")
        ]
    }
}

// MARK: - Request/Response Types

struct GeminiRequest: Encodable {
    let contents: [Content]
    let generationConfig: GenerationConfig
    let safetySettings: [SafetySetting]
}

struct Content: Encodable {
    let parts: [Part]
}

struct Part: Encodable {
    var text: String?
    var inlineData: InlineData?
    
    init(text: String) {
        self.text = text
    }
    
    init(inlineData: InlineData) {
        self.inlineData = inlineData
    }
    
    enum CodingKeys: String, CodingKey {
        case text
        case inlineData = "inline_data"
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let text = text {
            try container.encode(text, forKey: .text)
        }
        if let inlineData = inlineData {
            try container.encode(inlineData, forKey: .inlineData)
        }
    }
}

struct InlineData: Encodable {
    let mimeType: String
    let data: String
    
    enum CodingKeys: String, CodingKey {
        case mimeType = "mime_type"
        case data
    }
}

struct GenerationConfig: Encodable {
    let temperature: Double
    let topK: Int
    let topP: Double
    let maxOutputTokens: Int
    let thinkingConfig: ThinkingConfig
    
    enum CodingKeys: String, CodingKey {
        case temperature
        case topK = "top_k"
        case topP = "top_p"
        case maxOutputTokens = "max_output_tokens"
        case thinkingConfig = "thinking_config"
    }
}

struct ThinkingConfig: Encodable {
    let thinkingLevel: String
    
    enum CodingKeys: String, CodingKey {
        case thinkingLevel = "thinking_level"
    }
}

struct SafetySetting: Encodable {
    let category: String
    let threshold: String
}

struct GeminiResponse: Decodable {
    let candidates: [Candidate]
}

struct Candidate: Decodable {
    let content: ResponseContent
}

struct ResponseContent: Decodable {
    let parts: [ResponsePart]
}

struct ResponsePart: Decodable {
    let text: String?
}

struct GeminiErrorResponse: Decodable {
    let error: GeminiAPIError
}

struct GeminiAPIError: Decodable {
    let code: Int
    let message: String
    let status: String
}

struct MathCompletionResult: Decodable {
    let recognized: String
    let latex: String
    let completion: String
    let confidence: Float
    let type: String
}

// MARK: - Response Types

struct MathCompletionResponse {
    let recognizedText: String
    let fullLatex: String
    let completionLatex: String
    let confidence: Float
    let expressionType: String
    
    var isValid: Bool {
        confidence > 0.5 && !completionLatex.isEmpty
    }
}

struct HandwritingAnalysis: Decodable {
    let strokeCount: Int
    let slantAngle: Float
    let hasLoops: Bool
    let hasSerifs: Bool
    let proportions: Proportions
    let style: String
    let characteristics: [String]
    
    struct Proportions: Decodable {
        let width: Float
        let height: Float
    }
}

// MARK: - Errors

enum GeminiError: Error, LocalizedError {
    case missingAPIKey
    case invalidURL
    case imageEncodingFailed
    case invalidResponse
    case httpError(Int)
    case apiError(String)
    case emptyResponse
    case parseError(String)
    
    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Gemini API key not configured"
        case .invalidURL:
            return "Invalid API URL"
        case .imageEncodingFailed:
            return "Failed to encode image"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .apiError(let message):
            return "API error: \(message)"
        case .emptyResponse:
            return "Empty response from API"
        case .parseError(let message):
            return "Parse error: \(message)"
        }
    }
}

// MARK: - LaTeX to Bezier Conversion

extension GeminiService {
    
    /// Convert LaTeX expression to stroke paths for rendering
    /// This is a simplified implementation - production would use a full LaTeX renderer
    func latexToStrokePaths(_ latex: String) -> [[SIMD2<Float>]] {
        // Basic symbol mapping to stroke paths
        var paths: [[SIMD2<Float>]] = []
        var xOffset: Float = 0
        
        let tokens = tokenizeLatex(latex)
        
        for token in tokens {
            let (symbolPaths, width) = strokePathsForSymbol(token)
            
            // Offset paths by current x position
            for path in symbolPaths {
                let offsetPath = path.map { point in
                    SIMD2<Float>(point.x + xOffset, point.y)
                }
                paths.append(offsetPath)
            }
            
            xOffset += width + 0.01 // Add spacing
        }
        
        return paths
    }
    
    private func tokenizeLatex(_ latex: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inCommand = false
        
        for char in latex {
            if char == "\\" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                inCommand = true
                current = "\\"
            } else if inCommand {
                if char.isLetter {
                    current.append(char)
                } else {
                    tokens.append(current)
                    current = ""
                    inCommand = false
                    if !char.isWhitespace {
                        tokens.append(String(char))
                    }
                }
            } else if char == "{" || char == "}" || char == "^" || char == "_" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                // Skip structural characters for now
            } else if !char.isWhitespace {
                tokens.append(String(char))
            }
        }
        
        if !current.isEmpty {
            tokens.append(current)
        }
        
        return tokens
    }
    
    private func strokePathsForSymbol(_ symbol: String) -> ([[SIMD2<Float>]], Float) {
        // Simplified stroke paths for common math symbols
        // In production, these would come from the user's handwriting templates
        
        switch symbol {
        case "0"..."9":
            return (digitPaths(symbol), 0.05)
        case "+":
            return ([
                [SIMD2<Float>(0, 0.025), SIMD2<Float>(0.05, 0.025)],
                [SIMD2<Float>(0.025, 0), SIMD2<Float>(0.025, 0.05)]
            ], 0.05)
        case "-", "\\minus":
            return ([
                [SIMD2<Float>(0, 0.025), SIMD2<Float>(0.05, 0.025)]
            ], 0.05)
        case "=":
            return ([
                [SIMD2<Float>(0, 0.02), SIMD2<Float>(0.05, 0.02)],
                [SIMD2<Float>(0, 0.03), SIMD2<Float>(0.05, 0.03)]
            ], 0.05)
        case "\\times", "×":
            return ([
                [SIMD2<Float>(0, 0), SIMD2<Float>(0.05, 0.05)],
                [SIMD2<Float>(0.05, 0), SIMD2<Float>(0, 0.05)]
            ], 0.05)
        case "\\div", "÷":
            return ([
                [SIMD2<Float>(0, 0.025), SIMD2<Float>(0.05, 0.025)],
                [SIMD2<Float>(0.025, 0.04), SIMD2<Float>(0.025, 0.045)],
                [SIMD2<Float>(0.025, 0.005), SIMD2<Float>(0.025, 0.01)]
            ], 0.05)
        case "\\sqrt":
            return ([
                [SIMD2<Float>(0, 0.03), SIMD2<Float>(0.015, 0.02), SIMD2<Float>(0.03, 0.05), SIMD2<Float>(0.08, 0.05), SIMD2<Float>(0.08, 0.045)]
            ], 0.08)
        case "\\pi", "π":
            return ([
                [SIMD2<Float>(0, 0.04), SIMD2<Float>(0.05, 0.04)],
                [SIMD2<Float>(0.015, 0.04), SIMD2<Float>(0.015, 0)],
                [SIMD2<Float>(0.035, 0.04), SIMD2<Float>(0.035, 0)]
            ], 0.05)
        case "x", "y", "z", "a", "b", "c":
            return (letterPaths(symbol), 0.04)
        default:
            // Default: single character as simple path
            return (letterPaths(symbol), 0.04)
        }
    }
    
    private func digitPaths(_ digit: String) -> [[SIMD2<Float>]] {
        // Simplified digit stroke paths
        let h: Float = 0.05
        let w: Float = 0.035
        
        switch digit {
        case "0":
            return [[
                SIMD2<Float>(w/2, 0),
                SIMD2<Float>(w, h/4),
                SIMD2<Float>(w, 3*h/4),
                SIMD2<Float>(w/2, h),
                SIMD2<Float>(0, 3*h/4),
                SIMD2<Float>(0, h/4),
                SIMD2<Float>(w/2, 0)
            ]]
        case "1":
            return [[
                SIMD2<Float>(w/4, h*0.8),
                SIMD2<Float>(w/2, h),
                SIMD2<Float>(w/2, 0)
            ]]
        case "2":
            return [[
                SIMD2<Float>(0, h*0.8),
                SIMD2<Float>(w/2, h),
                SIMD2<Float>(w, h*0.8),
                SIMD2<Float>(0, 0),
                SIMD2<Float>(w, 0)
            ]]
        case "3":
            return [[
                SIMD2<Float>(0, h),
                SIMD2<Float>(w, h),
                SIMD2<Float>(w/2, h/2),
                SIMD2<Float>(w, 0),
                SIMD2<Float>(0, 0)
            ]]
        default:
            // Simplified fallback
            return [[SIMD2<Float>(0, 0), SIMD2<Float>(w, h)]]
        }
    }
    
    private func letterPaths(_ letter: String) -> [[SIMD2<Float>]] {
        let h: Float = 0.04
        let w: Float = 0.03
        
        switch letter.lowercased() {
        case "x":
            return [
                [SIMD2<Float>(0, h), SIMD2<Float>(w, 0)],
                [SIMD2<Float>(0, 0), SIMD2<Float>(w, h)]
            ]
        case "y":
            return [
                [SIMD2<Float>(0, h), SIMD2<Float>(w/2, h/2)],
                [SIMD2<Float>(w, h), SIMD2<Float>(w/2, h/2), SIMD2<Float>(w/2, 0)]
            ]
        default:
            return [[SIMD2<Float>(0, 0), SIMD2<Float>(w/2, h), SIMD2<Float>(w, 0)]]
        }
    }
}
