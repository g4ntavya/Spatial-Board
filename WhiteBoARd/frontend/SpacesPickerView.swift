// SpacesPickerView.swift
// WhiteBoARd — Focus-Mode style spatial workspace switcher

import SwiftUI
import SwiftData

// MARK: - Spaces Picker Sheet

struct SpacesPickerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Space.createdAt) private var spaces: [Space]

    @State private var newSpaceName: String = ""
    @FocusState private var isNewNameFocused: Bool
    @State private var showDeleteConfirm: Space? = nil

    // Pastel palette for auto-assigned colors
    private let palettes: [String] = [
        "#FF6B6B", "#FFB347", "#FFD93D", "#6BCB77",
        "#4D96FF", "#C77DFF", "#F72585", "#43BCCD"
    ]

    var body: some View {
        NavigationView {
            ZStack {
                // Background blur
                Color.clear
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header
                    header
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 12)

                    Divider().opacity(0.3)

                    // Space list
                    List {
                        // Default space (always present, not deletable)
                        SpaceRow(
                            name: "Default",
                            colorHex: "#8E8E93",
                            isActive: appState.activeSpaceID == "Default",
                            isDeletable: false
                        ) {
                            selectSpace(id: "Default")
                        } onDelete: {}
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        
                        // User-created spaces
                        ForEach(spaces) { space in
                            SpaceRow(
                                name: space.name,
                                colorHex: space.colorHex,
                                isActive: appState.activeSpaceID == space.id.uuidString,
                                isDeletable: appState.activeSpaceID != space.id.uuidString
                            ) {
                                selectSpace(id: space.id.uuidString)
                            } onDelete: {
                                showDeleteConfirm = space
                            }
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)

                    Divider().opacity(0.3)

                    // New Space row
                    newSpaceRow
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }
            .navigationBarHidden(true)
            .alert("Delete Space?", isPresented: Binding(
                get: { showDeleteConfirm != nil },
                set: { if !$0 { showDeleteConfirm = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let space = showDeleteConfirm { deleteSpace(space) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let space = showDeleteConfirm {
                    Text("\"\(space.name)\" and its content will move to Default space.")
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title3)
                    .foregroundStyle(.linearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                Text("Spaces")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - New Space Row

    private var newSpaceRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(.blue)

            TextField("New space name…", text: $newSpaceName)
                .font(.system(.body, design: .rounded))
                .focused($isNewNameFocused)
                .onSubmit { createSpace() }
                .submitLabel(.done)

            if !newSpaceName.isEmpty {
                Button(action: createSpace) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .animation(.spring(response: 0.3), value: newSpaceName.isEmpty)
    }

    // MARK: - Actions

    private func selectSpace(id: String) {
        guard id != appState.activeSpaceID else { dismiss(); return }
        // Trigger space transition in ARCanvasView via ARCanvasView coordinator
        // We route through ARCanvasView's coordinator via a notification
        NotificationCenter.default.post(
            name: .switchSpace,
            object: nil,
            userInfo: ["spaceID": id]
        )
        dismiss()
    }

    private func createSpace() {
        let name = newSpaceName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        let colorHex = palettes[spaces.count % palettes.count]
        let space = Space(name: name, colorHex: colorHex)
        modelContext.insert(space)
        try? modelContext.save()

        newSpaceName = ""
        isNewNameFocused = false

        // Immediately switch to the new space
        selectSpace(id: space.id.uuidString)
    }

    private func deleteSpace(_ space: Space) {
        // Move all strokes/folders in this space to Default
        let strokeDesc = FetchDescriptor<SpatialStroke>()
        if let strokes = try? modelContext.fetch(strokeDesc) {
            for stroke in strokes where stroke.spaceID == space.id.uuidString {
                stroke.spaceID = "Default"
            }
        }
        let folderDesc = FetchDescriptor<SpatialFolder>()
        if let folders = try? modelContext.fetch(folderDesc) {
            for folder in folders where folder.spaceID == space.id.uuidString {
                folder.spaceID = "Default"
            }
        }

        // If this was active, switch to Default first
        if appState.activeSpaceID == space.id.uuidString {
            selectSpace(id: "Default")
        }

        modelContext.delete(space)
        try? modelContext.save()
        showDeleteConfirm = nil
    }
}

// MARK: - Space Row

private struct SpaceRow: View {
    let name: String
    let colorHex: String
    let isActive: Bool
    let isDeletable: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isPressed: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            // Color circle
            Circle()
                .fill(Color(hex: colorHex))
                .frame(width: 26, height: 26)
                .overlay {
                    if isActive {
                        Circle()
                            .stroke(Color.white, lineWidth: 2.5)
                    }
                }
                .shadow(color: Color(hex: colorHex).opacity(0.5), radius: isActive ? 6 : 2)
                .animation(.spring(response: 0.3), value: isActive)

            // Name
            Text(name)
                .font(.system(.body, design: .rounded, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)

            Spacer()

            // Active checkmark / badge count placeholder
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.title3)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isActive ? Color.blue.opacity(0.12) : Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isActive ? Color.blue.opacity(0.35) : Color.clear, lineWidth: 1)
                )
        )
        .scaleEffect(isPressed ? 0.97 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isPressed)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            isPressed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isPressed = false
                onSelect()
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isDeletable {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let switchSpace = Notification.Name("WhiteBoARd.switchSpace")
    static let performSpaceSwitch = Notification.Name("WhiteBoARd.performSpaceSwitch")
}

// MARK: - Color from Hex

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
