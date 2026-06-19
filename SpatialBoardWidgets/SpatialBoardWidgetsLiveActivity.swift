// SpatialBoardWidgetsLiveActivity.swift
// SpatialBoardWidgets — Widget Extension
//
// The sync Live Activity: Lock Screen banner + Dynamic Island (compact, minimal,
// expanded). Driven by SyncActivityAttributes (shared with the app target — make
// sure that file's Target Membership includes SpatialBoardWidgets).

import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - Visual tokens per phase

private struct Look {
    let symbol: String
    let tint: [Color]
    let label: String
}

private extension SyncActivityAttributes.ContentState {
    var look: Look {
        switch phase {
        case .uploading:  return Look(symbol: "arrow.up.circle.fill", tint: [Color(red: 0.29, green: 0.56, blue: 1.0), Color(red: 0.36, green: 0.84, blue: 1.0)], label: "Uploading")
        case .processing: return Look(symbol: "sparkles", tint: [Color(red: 0.48, green: 0.4, blue: 1.0), Color(red: 0.36, green: 0.84, blue: 1.0)], label: "Indexing")
        case .done:       return Look(symbol: "checkmark.circle.fill", tint: [Color(red: 0.2, green: 0.78, blue: 0.45), Color(red: 0.3, green: 0.86, blue: 0.55)], label: "Synced")
        case .failed:     return Look(symbol: "exclamationmark.triangle.fill", tint: [Color(red: 0.95, green: 0.45, blue: 0.2), Color(red: 1.0, green: 0.32, blue: 0.32)], label: "Failed")
        }
    }
    var isActive: Bool { phase == .uploading || phase == .processing }
}

// MARK: - Widget

struct SpatialBoardWidgetsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SyncActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        PhaseIcon(state: s, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("SpatialBoard").font(.system(size: 13, weight: .semibold, design: .rounded))
                            Text(s.look.label).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if s.isActive {
                        ProgressView().tint(.cyan).scaleEffect(0.85)
                    } else if s.phase == .done {
                        Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.green)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(s.message).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        ProgressBar(state: s)
                    }
                }
            } compactLeading: {
                PhaseIcon(state: s, size: 18)
            } compactTrailing: {
                if s.isActive {
                    ProgressView().tint(.cyan).scaleEffect(0.7)
                } else if s.phase == .done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } minimal: {
                PhaseIcon(state: s, size: 16)
            }
            .keylineTint(.cyan)
        }
    }
}

// MARK: - Pieces

private struct PhaseIcon: View {
    let state: SyncActivityAttributes.ContentState
    var size: CGFloat
    var body: some View {
        Image(systemName: state.look.symbol)
            .font(.system(size: size * 0.7, weight: .bold))
            .foregroundStyle(LinearGradient(colors: state.look.tint, startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
    }
}

private struct ProgressBar: View {
    let state: SyncActivityAttributes.ContentState
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule()
                    .fill(LinearGradient(colors: state.look.tint, startPoint: .leading, endPoint: .trailing))
                    .frame(width: state.isActive ? geo.size.width * 0.55 : geo.size.width)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: state.isActive)
            }
        }
        .frame(height: 5)
    }
}

private struct LockScreenView: View {
    let state: SyncActivityAttributes.ContentState
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LinearGradient(colors: state.look.tint.map { $0.opacity(0.22) }, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 46, height: 46)
                PhaseIcon(state: state, size: 26)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("SpatialBoard").font(.system(size: 15, weight: .semibold, design: .rounded))
                    Spacer()
                    if state.isActive { ProgressView().tint(.white).scaleEffect(0.8) }
                }
                Text(state.message).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                ProgressBar(state: state)
            }
        }
        .padding(16)
    }
}
