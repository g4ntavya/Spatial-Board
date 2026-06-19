// WhiteBoARdApp.swift
// WhiteBoARd - Spatial AR Notetaking
// Main app entry point

import SwiftUI
import SwiftData

@main
struct WhiteBoARdApp: App {
    
    // MARK: - State

    @State private var appState = AppState()
    @State private var auth = AuthService.shared
    @Environment(\.scenePhase) private var scenePhase
    
    // MARK: - SwiftData
    
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SpatialStroke.self,
            PersistedWorldAnchor.self,
            SpatialFolder.self,
            CharacterTemplate.self,
            GlyphSample.self,
            Space.self
        ])
        
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )
        
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // If schema migration fails, try with fresh database
            print("Failed to create ModelContainer: \(error)")
            print("Attempting to create in-memory container...")
            
            let fallbackConfig = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                allowsSave: true
            )
            
            do {
                return try ModelContainer(for: schema, configurations: [fallbackConfig])
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }()
    
    // MARK: - Body
    
    var body: some Scene {
        WindowGroup {
            Group {
                if !auth.isSignedIn {
                    SignInView()
                } else {
                    ContentView()
                }
            }
            .environment(appState)
            .environment(auth)
            .onAppear {
                setupServices()
            }
        }
        .modelContainer(sharedModelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            // Drive the upload + Live Activity as the app leaves / returns.
            let ctx = sharedModelContainer.mainContext
            switch newPhase {
            case .inactive:   SyncCoordinator.shared.sceneBecameInactive(context: ctx)
            case .background:  SyncCoordinator.shared.sceneEnteredBackground(context: ctx)
            case .active:      SyncCoordinator.shared.sceneBecameActive()
            @unknown default:  break
            }
        }
    }
    
    // MARK: - Setup
    
    private func setupServices() {
        let modelContext = sharedModelContainer.mainContext
        
        // Configure AR Session Manager
        Task { @MainActor in
            ARSessionManager.shared.configure(with: modelContext)
            HandwritingStyleStore.shared.configure(with: modelContext)
            GestureRecognizer.shared.configure(arSessionManager: ARSessionManager.shared)
            Kon.shared.configure(with: modelContext)
            
            // Load config (Gemini key + AWS sync endpoint) from the bundled .env file.
            if let envPath = Bundle.main.path(forResource: ".env", ofType: nil) ?? Bundle.main.path(forResource: "env", ofType: nil),
               let contents = try? String(contentsOfFile: envPath, encoding: .utf8) {
                var env: [String: String] = [:]
                for line in contents.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
                    let k = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
                    let v = String(trimmed[trimmed.index(after: eq)...])
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !k.isEmpty { env[k] = v }
                }

                if let key = env["GEMINI_API_KEY"], !key.isEmpty {
                    await GeminiService.shared.configure(apiKey: key)
                }
                if let url = env["SPATIALBOARD_SYNC_URL"], !url.isEmpty {
                    AuthService.shared.configure(syncURL: url)
                    if let token = env["SPATIALBOARD_SYNC_TOKEN"], !token.isEmpty {
                        SyncService.shared.configure(url: url, token: token)
                    }
                }
            }
            
            // Check onboarding status
            // One-time reset to clear old broken handwriting data (post v2 fix)
            if !UserDefaults.standard.bool(forKey: "kon_v2_reset") {
                Kon.shared.resetAllSamples()
                UserDefaults.standard.set(true, forKey: "kon_v2_reset")
                appState.isOnboardingComplete = false
            } else {
                appState.isOnboardingComplete = UserDefaults.standard.bool(forKey: "onboarding_complete")
            }
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    
    // UI Dropdown Core State
    @State private var isMenuExpanded = false
    
    var body: some View {
        ZStack {
            if appState.isOnboardingComplete {
                // Main AR Canvas
                ARCanvasView()
                    .ignoresSafeArea()
                
                // Unified Glass UI Dropdown Map
                VStack {
                    Spacer()
                    
                    if isMenuExpanded {
                        VStack(spacing: 14) {
                            StrokeColorPicker()
                            ThicknessControl()
                            BottomControls()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .glassEffect(in: .rect(cornerRadius: 18))
                        .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.95)))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                    }
                    
                    // Main floating tool dock
                    HStack(spacing: 16) {
                        // Transparent Gesture State
                        GestureIndicator()

                        Spacer()
                        
                        // Active Space pill
                        ActiveSpacePill()

                        // Sync now (foreground upload to the web companion)
                        Button {
                            Task {
                                let msg = await SyncService.shared.syncNow(context: modelContext)
                                withAnimation(.spring(response: 0.3)) { appState.lastSyncMessage = msg }
                                try? await Task.sleep(for: .seconds(2.5))
                                withAnimation { if appState.lastSyncMessage == msg { appState.lastSyncMessage = nil } }
                            }
                        } label: {
                            Image(systemName: SyncService.shared.isSyncing ? "arrow.triangle.2.circlepath" : "icloud.and.arrow.up")
                                .font(.title3)
                                .foregroundColor(.white)
                                .padding(12)
                                .glassBackground()
                        }

                        // Spaces button
                        Button {
                            withAnimation(.spring(response: 0.3)) {
                                appState.showSpacePicker = true
                            }
                        } label: {
                            Image(systemName: "square.stack.3d.up")
                                .font(.title3)
                                .foregroundColor(.white)
                                .padding(12)
                                .glassBackground()
                        }
                        
                        // Create folder stays outside dropdown for quick access
                        Button {
                            appState.pendingFolderName = "New Folder"
                            appState.showFolderSheet = true
                        } label: {
                            Image(systemName: "folder.badge.plus")
                                .font(.title3)
                                .foregroundColor(.white)
                                .padding(12)
                                .glassBackground()
                        }
                        
                        // Menu toggle
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                isMenuExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: isMenuExpanded ? "xmark" : "slider.horizontal.3")
                                .font(.title3)
                                .foregroundColor(.white)
                                .padding(12)
                                .glassBackground()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                // Kon answer overlay (Errors only)
                if appState.showKonAnswer {
                    KonAnswerOverlay()
                        .environment(appState)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .animation(.spring(duration: 0.3), value: appState.showKonAnswer)
                }
                
                // New: Minimalist Kon Status HUD (Bottom center)
                if appState.konState == .capturing || appState.konState == .thinking || appState.konState == .writing {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            KonStatusHUD()
                                .environment(appState)
                            Spacer()
                        }
                        .padding(.bottom, 100) // Positioned above the main toolbar
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(duration: 0.5), value: appState.konState)
                }

                // Sync status toast (top)
                if let msg = appState.lastSyncMessage {
                    VStack {
                        SyncToast(text: msg)
                        Spacer()
                    }
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(20)
                }
            } else {
                // Onboarding flow
                OnboardingView()
            }
        }
        .preferredColorScheme(.dark)
        // Kon keyboard sheet
        .sheet(isPresented: Binding(
            get: { appState.showKonKeyboard },
            set: { appState.showKonKeyboard = $0 }
        )) {
            KonInputOverlay()
                .environment(appState)
                .presentationDetents([.height(220)])
                .presentationDragIndicator(.visible)
        }
        // Spaces picker sheet
        .sheet(isPresented: Binding(
            get: { appState.showSpacePicker },
            set: { appState.showSpacePicker = $0 }
        )) {
            SpacesPickerView()
                .environment(appState)
                .presentationDetents([.height(420)])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
        }
        // Folder naming sheet
        .sheet(isPresented: Binding(
            get: { appState.showFolderSheet },
            set: { appState.showFolderSheet = $0 }
        )) {
            FolderCreationSheet()
                .environment(appState)
                .presentationDetents([.height(200)])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
        }
        // Listen for space-switch notifications from SpacesPickerView
        .onReceive(NotificationCenter.default.publisher(for: .switchSpace)) { note in
            if let spaceID = note.userInfo?["spaceID"] as? String {
                // Post to ARCanvasView coordinator via a second notification
                NotificationCenter.default.post(
                    name: .performSpaceSwitch,
                    object: nil,
                    userInfo: ["spaceID": spaceID]
                )
            }
        }
    }
}

// MARK: - Top Toolbar

struct TopToolbar: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        HStack {
            // AR Session status
            ARStatusIndicator()
            
            Spacer()
            
            // Color picker
            StrokeColorPicker()
            
            Spacer()
            
            // Settings
            Button {
                // Open settings
            } label: {
                Image(systemName: "gear")
                    .font(.title2)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.glass)
        }
    }
}

// MARK: - AR Status Indicator

struct ARStatusIndicator: View {
    @Environment(AppState.self) private var appState
    
    var statusColor: Color {
        if !appState.folderTransitionStatus.isEmpty {
            return .cyan
        }
        switch appState.arSessionState {
        case .tracking:
            return .green
        case .ready, .initializing:
            return .yellow
        case .limited:
            return .orange
        case .notAvailable, .failed:
            return .red
        }
    }
    
    var statusText: String {
        if !appState.folderTransitionStatus.isEmpty {
            return appState.folderTransitionStatus
        }
        switch appState.arSessionState {
        case .tracking:
            return "Tracking"
        case .ready:
            return "Ready"
        case .initializing:
            return "Initializing..."
        case .limited:
            return "Limited"
        case .notAvailable:
            return "Not Available"
        case .failed:
            return "Failed"
        }
    }
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassBackground()
    }
}

// MARK: - Color Picker

struct StrokeColorPicker: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        HStack(spacing: 12) {
            ForEach(StrokeColor.allCases, id: \.self) { color in
                ColorButton(color: color, isSelected: appState.currentStrokeColor == color) {
                    appState.currentStrokeColor = color
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassBackground()
    }
}

struct ColorButton: View {
    let color: StrokeColor
    let isSelected: Bool
    let action: () -> Void
    
    var uiColor: Color {
        let rgb = color.rgbColor
        return Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }
    
    var body: some View {
        Button(action: action) {
            Circle()
                .fill(uiColor)
                .frame(width: 24, height: 24)
                .overlay {
                    if isSelected {
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                    }
                }
        }
    }
}

// MARK: - Gesture Indicator

struct GestureIndicator: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        Group {
            if appState.konState != .idle {
                // Show Kon processing indicator
                konIndicator
            } else {
                // Normal gesture indicator
                normalIndicator
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.currentGestureMode)
        .animation(.easeInOut(duration: 0.3), value: appState.konState)
    }
    
    // MARK: - Normal Gesture Indicator
    
    private var normalIndicator: some View {
        HStack(spacing: 8) {
            Image(systemName: gestureIcon)
                .font(.title3)
                .fontWeight(.semibold)
            
            Text(gestureText)
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .frame(minWidth: 134, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .shadow(color: .black.opacity(0.65), radius: 2, x: 0, y: 1)
        .opacity(appState.currentGestureMode == .none ? 0.6 : 1.0)
    }
    
    // MARK: - Kon Processing Indicator
    
    private var konIndicator: some View {
        HStack(spacing: 12) {
            // Animated icon
            ZStack {
                // Progress ring (visible during hold)
                if appState.konState == .holding {
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 3)
                        .frame(width: 30, height: 30)
                    
                    Circle()
                        .trim(from: 0, to: CGFloat(appState.konHoldProgress))
                        .stroke(
                            LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .frame(width: 30, height: 30)
                        .rotationEffect(.degrees(-90))
                }
                
                // Spinner for capturing/thinking
                if appState.konState == .capturing || appState.konState == .thinking {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.8)
                }
                
                // Checkmark for answered
                if appState.konState == .answered {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                }
                
                // Error icon
                if appState.konState == .error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                }
                
                // Sparkle icon during hold
                if appState.konState == .holding {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14))
                        .foregroundStyle(.linearGradient(
                            colors: [.blue, .cyan],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                }
            }
            .frame(width: 30, height: 30)
            
            // Status text
            VStack(alignment: .leading, spacing: 2) {
                Text("Kon")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.linearGradient(
                        colors: [.blue, .cyan],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                
                Text(konStatusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 134, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .shadow(color: .black.opacity(0.65), radius: 2, x: 0, y: 1)
    }
    
    // MARK: - Helpers
    
    private var gestureIcon: String {
        switch appState.currentGestureMode {
        case .none:     return "hand.raised"
        case .draw:     return "pencil.tip"
        case .erase:    return "eraser"
        case .resize:   return "arrow.up.left.and.arrow.down.right"
        case .select:   return "rectangle.dashed"
        case .fistMove: return "arrow.up.and.down.and.arrow.left.and.right"
        case .kon:      return "sparkles"
        case .point:    return "hand.point.up.left"
        }
    }
    
    private var gestureText: String {
        if !appState.folderTransitionStatus.isEmpty {
            return appState.folderTransitionStatus
        }
        switch appState.currentGestureMode {
        case .none:     return "Ready"
        case .draw:     return "Drawing"
        case .erase:    return "Erasing"
        case .resize:   return "Resizing"
        case .select:   return "Selecting"
        case .fistMove: return "Moving"
        case .kon:      return "Kon"
        case .point:    return "Pointing"
        }
    }
    
    private var konStatusText: String {
        switch appState.konState {
        case .idle: return ""
        case .holding: return "Hold \(Int(appState.konHoldProgress * 100))%"
        case .capturing: return "Capturing..."
        case .thinking: return "Thinking..."
        case .writing: return "Writing..."
        case .answered: return "Done"
        case .error: return "Failed"
        }
    }
}

// MARK: - Bottom Controls

struct BottomControls: View {
    @Environment(AppState.self) private var appState
    @State private var showingResetAlert = false
    
    var body: some View {
        HStack(spacing: 12) {
            Button {
                appState.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.title3)
            }
            .buttonStyle(.glass)
            
            // Kon keyboard — type text in user's handwriting
            Button {
                appState.showKonKeyboard = true
            } label: {
                Image(systemName: "keyboard")
                    .font(.title2)
            }
            .buttonStyle(.glass)
            
            // Re-train Kon
            Button {
                showingResetAlert = true
            } label: {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.title3)
            }
            .buttonStyle(.glass)
            .alert("Reset Handwriting Engine?", isPresented: $showingResetAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Reset & Re-learn", role: .destructive) {
                    Kon.shared.resetAllSamples()
                    appState.isOnboardingComplete = false
                }
            } message: {
                Text("This will delete all learned handwriting data and return you to the onboarding screen to re-capture your style. This cannot be undone.")
            }
            
            Button {
                appState.clearAll()
            } label: {
                Image(systemName: "trash")
                    .font(.title3)
            }
            .buttonStyle(.glass)
        }
    }
}

// MARK: - Thickness Control

struct ThicknessControl: View {
    @Environment(AppState.self) private var appState
    @State private var isExpanded = false
    
    var body: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.3)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: "pencil.tip.crop.circle")
                    .font(.title2)
            }
            
            if isExpanded {
                Slider(value: Binding(
                    get: { Double(appState.currentStrokeThickness * 500) },
                    set: { appState.currentStrokeThickness = Float($0) / 500 }
                ), in: 0.5...5)
                .frame(width: 100)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassBackground()
    }
}


// MARK: - Kon Keyboard Input Overlay

struct KonInputOverlay: View {
    @Environment(AppState.self) private var appState
    @State private var inputText: String = ""
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Kon")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.linearGradient(
                        colors: [.blue, .cyan],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                
                Text("Type in your handwriting")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                if Kon.shared.hasLearnedData {
                    Text("\(Kon.shared.totalSampleCount) samples")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            
            HStack(spacing: 12) {
                TextField("Type a word or phrase...", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        placeText()
                    }
                
                Button(action: placeText) {
                    HStack(spacing: 6) {
                        Image(systemName: "arkit")
                        Text("Place")
                    }
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(inputText.isEmpty ? Color.gray : Color.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(inputText.isEmpty)
            }
        }
        .padding(24)
        .onAppear {
            isTextFieldFocused = true
        }
    }
    
    private func placeText() {
        guard !inputText.isEmpty else { return }
        appState.pendingKonText = inputText
        inputText = ""
        appState.showKonKeyboard = false
    }
}

// MARK: - Kon Answer Overlay

struct KonAnswerOverlay: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        VStack {
            HStack(spacing: 12) {
                // Header Icon
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.linearGradient(
                        colors: [.blue, .cyan],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                
                // Status content
                switch appState.konState {
                case .capturing:
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.8)
                    Text("Capturing...")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    
                case .thinking:
                    ProgressView()
                        .tint(.cyan)
                        .scaleEffect(0.8)
                    Text("Solving...")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                    
                case .answered:
                    Text(appState.konAnswerText)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    
                    Text("✅")
                        .font(.system(size: 14))
                
                case .error:
                    Text(appState.konAnswerText)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                    
                default:
                    EmptyView()
                }
                
                // Dismiss button only when complete
                if appState.konState == .answered || appState.konState == .error {
                    Divider()
                        .frame(height: 16)
                        .background(Color.white.opacity(0.3))
                        .padding(.horizontal, 4)
                    
                    Button {
                        appState.konState = .idle
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(LinearGradient(
                        colors: [.blue.opacity(0.5), .cyan.opacity(0.5)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
            .padding(.top, 70) // Push below toolbar
            
            Spacer() // Push all the way to the top!
        }
        .onTapGesture {
            if appState.konState == .answered || appState.konState == .error {
                appState.konState = .idle
            }
        }
    }
}

struct KonStatusHUD: View {
    @Environment(AppState.self) private var appState
    
    @State private var isPulsing = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Animated indicator dot
            Circle()
                .fill(appState.konState == .error ? Color.red : Color.blue)
                .frame(width: 8, height: 8)
                .opacity(isPulsing ? 0.4 : 1.0)
                .scaleEffect(isPulsing ? 0.8 : 1.2)
            
            Text(statusText)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassBackground()
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
    
    private var statusText: String {
        if !appState.konStatusMessage.isEmpty && (appState.konState == .writing || appState.konState == .answered) {
            return appState.konStatusMessage
        }
        
        switch appState.konState {
        case .capturing: return "Capturing..."
        case .thinking: return "Thinking..."
        case .writing: return "Writing..."
        case .error: return "Error"
        case .answered: return "Done"
        default: return ""
        }
    }
}

// MARK: - Active Space Pill

struct ActiveSpacePill: View {
    @Environment(AppState.self) private var appState
    @Query private var spaces: [Space]
    
    var body: some View {
        let activeSpace = spaces.first(where: { $0.id.uuidString == appState.activeSpaceID })
        let name = activeSpace?.name ?? "Default"
        let color = Color(hex: activeSpace?.colorHex ?? "#8E8E93")
        
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            
            Text(name)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassBackground()
        .transition(.scale.combined(with: .opacity))
        .animation(.spring(), value: appState.activeSpaceID)
    }
}

// MARK: - Sync Toast

struct SyncToast: View {
    let text: String

    private var isError: Bool { text.localizedCaseInsensitiveContains("fail") || text.localizedCaseInsensitiveContains("not signed") }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isError ? Color.orange : Color.green)
            Text(text)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
    }
}

// MARK: - Folder Creation Sheet

struct FolderCreationSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    
    @State private var folderName: String = "New Folder"
    @FocusState private var isFocused: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Name Folder")
                .font(.headline)
            
            TextField("Folder Name", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { create() }
            
            HStack(spacing: 16) {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .buttonStyle(.bordered)
                
                Button("Create") {
                    create()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .onAppear {
            isFocused = true
        }
    }
    
    private func create() {
        let trimmed = folderName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            NotificationCenter.default.post(
                name: NSNotification.Name("CreateFolder"),
                object: nil,
                userInfo: ["name": trimmed]
            )
        }
        dismiss()
    }
}

// MARK: - Glass Background Style

extension View {
    /// Applies iOS 26 Liquid Glass effect to the view
    /// Uses the regular (darker) variant for better contrast over AR content
    func glassBackground() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(in: .rect(cornerRadius: 16))
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    ContentView()
        .environment(AppState())
        .modelContainer(for: [SpatialStroke.self, PersistedWorldAnchor.self, SpatialFolder.self, CharacterTemplate.self, GlyphSample.self, Space.self])
}
#endif
