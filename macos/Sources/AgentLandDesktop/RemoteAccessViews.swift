import SwiftUI
import AgentLandDesign
import AgentLandDesktopCore
import AgentLandWorkspace

/// The two switches of remote access as bindings on the controller.
@MainActor
extension RemoteAccessController {
    var enabledBinding: Binding<Bool> {
        Binding(get: { self.status.enabled }, set: { self.setEnabled($0) })
    }

    var fallbackBinding: Binding<Bool> {
        Binding(get: { self.status.fallback }, set: { self.setFallback($0) })
    }
}

extension RemoteAccessSummary.Tone {
    var dot: StatusDot.Status {
        switch self {
        case .off: .idle
        case .working: .working
        case .reachable: .online
        case .attention: .attention
        }
    }
}

/// Settings → Remote Access: the two switches with what they do, and the status. It is the one place for remote
/// access: General's This Mac no longer repeats the switch (2026-10-16).
struct RemoteAccessSettingsPane: View {
    @ObservedObject var remoteAccess: RemoteAccessController

    var body: some View {
        Form {
            if !remoteAccess.isAvailable {
                MacSettingsStateLine("Remote access needs AgentLand's state folder at a shorter path: the host's socket there would not fit.")
            }
            Section {
                LabeledContent("Remote access:") {
                    Toggle(RemoteAccessSummary.switchTitle, isOn: remoteAccess.enabledBinding)
                        .disabled(!remoteAccess.isAvailable || (!remoteAccess.status.enabled && !remoteAccess.status.tunnelServed))
                        .accessibilityIdentifier("settingsRemoteAccess")
                }
                MacSettingsFootnote(RemoteAccessSummary.switchExplanation)
                if remoteAccess.isAvailable, !remoteAccess.status.enabled, !remoteAccess.status.tunnelServed {
                    MacSettingsFootnote(RemoteAccessSummary.needsHTTPSDetail)
                }
            }
            if remoteAccess.status.enabled {
                Section {
                    Toggle(RemoteAccessSummary.fallbackTitle, isOn: remoteAccess.fallbackBinding)
                        .accessibilityIdentifier("settingsRemoteAccessRelay")
                        .macSettingsGroupStart()
                    MacSettingsFootnote(RemoteAccessSummary.fallbackExplanation)
                }
            }
            if remoteAccess.status.enabled {
                statusSection
            }
        }
        .formStyle(.columns)
    }

    @ViewBuilder private var statusSection: some View {
        let status = remoteAccess.status
        Section {
            // The relay's countdown depends on the time, and the service publishes only changes.
            TimelineView(.periodic(from: .now, by: RemoteAccessSummary.refreshInterval)) { context in
                let summary = status.summary(now: context.date)
                LabeledContent("Status:") {
                    HStack(spacing: 6) {
                        MacStatusLight(status: summary.tone.dot)
                        Text(summary.title).textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
                .macSettingsGroupStart()
                if let detail = summary.detail { MacSettingsFootnote(detail) }
            }
            if let node = status.nodeID {
                LabeledContent("This Mac's device ID:") {
                    Text(node.hex)
                        .font(.footnote.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(node.hex)
                }
            }
            ForEach(notes(status), id: \.self) { note in
                MacSettingsStateLine(note, systemImage: "info.circle")
            }
        }
    }

    private func notes(_ status: RemoteAccessService.Status) -> [String] {
        var notes: [String] = []
        if !status.hostSession {
            notes.append("Devices learn this Mac's address the next time AgentLand connects.")
        }
        if let problem = status.reportProblem {
            notes.append("This Mac's host didn't take the address (\(problem)). AgentLand tries again.")
        }
        if !status.recordAvailable {
            notes.append("This copy of AgentLand isn't signed for iCloud, so when this Mac's address changes, devices away from home learn it only after connecting at home or over Tailscale.")
        } else if let problem = status.record.problem {
            notes.append("iCloud didn't take this Mac's address (\(problem)). AgentLand tries again.")
        }
        return notes
    }
}
