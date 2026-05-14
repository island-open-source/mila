import SwiftUI

enum SidebarSelection: Hashable {
    case home
    case queue
    case category(HistoryCategory)
    case recording(Recording.ID)
}

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    @EnvironmentObject private var diarization: DiarizationSettings

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Home", systemImage: "house")
                    .tag(SidebarSelection.home)
                Label("Queue", systemImage: "list.bullet.rectangle")
                    .tag(SidebarSelection.queue)
            }

            Section("History") {
                ForEach(HistoryCategory.allCases) { cat in
                    Label(cat.displayName, systemImage: cat.sfSymbol)
                        .tag(SidebarSelection.category(cat))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                SidebarFooter(diarizationStatus: diarization.status)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .background(.bar)
        }
    }
}

private struct SidebarFooter: View {
    let diarizationStatus: DiarizationSettings.SetupStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsLink {
                HStack(spacing: 6) {
                    Image(systemName: "person.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Speakers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: diarizationStatus.sfSymbol)
                        .font(.caption)
                        .foregroundStyle(footerStatusColor)
                    Text(diarizationStatus.label)
                        .font(.caption)
                        .foregroundStyle(footerStatusColor)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                SettingsNavigation.shared.pendingTab = .speakers
            })
            .help(needsAttention ? "Click to configure speaker diarization" : diarizationStatus.label)

            SettingsLink {
                Label("Settings…", systemImage: "gear")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var needsAttention: Bool {
        switch diarizationStatus {
        case .missingDeps, .pythonNotFound, .notVerified, .verificationFailed:
            return true
        default:
            return false
        }
    }

    private var footerStatusColor: Color {
        switch diarizationStatus.color {
        case .green:     return .green
        case .orange:    return .orange
        case .red:       return .red
        case .secondary: return .secondary
        }
    }
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    } else {
        return String(format: "%d:%02d", m, s)
    }
}
