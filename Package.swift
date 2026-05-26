// swift-tools-version:6.0
// Package.swift
// WhiteBoARd - Spatial AR Notetaking
// Swift Package Manager configuration

import PackageDescription

let package = Package(
    name: "WhiteBoARd",
    platforms: [
        .iOS(.v26)
    ],
    products: [
        .library(
            name: "WhiteBoARd",
            targets: ["WhiteBoARd"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "WhiteBoARd",
            dependencies: [],
            path: "WhiteBoARd",
            sources: [
                "backend/Models.swift",
                "backend/ARSessionManager.swift",
                "backend/GeminiService.swift",
                "backend/StrokeProcessor.swift",
                "backend/HandwritingStyleStore.swift",
                "backend/GestureRecognizer.swift",
                "frontend/WhiteBoARdApp.swift",
                "frontend/ARCanvasView.swift",
                "frontend/DrawingOverlay.swift",
                "frontend/OnboardingView.swift",
                "frontend/MathCompletionView.swift"
            ]
        ),
        .testTarget(
            name: "WhiteBoARdTests",
            dependencies: ["WhiteBoARd"],
            path: "Tests"
        )
    ]
)
