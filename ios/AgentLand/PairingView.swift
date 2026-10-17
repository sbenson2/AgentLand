import SwiftUI
import UIKit
import AgentLandCore
import AgentLandPairing
import AgentLandBranding
import AgentLandDesign

/// Pairing is the Mac's QR code alone (owner, 2026-10-16): one Scan QR Code button, the camera asked for when it is
/// tapped, and a valid code pairs at once, since the code carries the Mac's address, routes and certificate
/// fingerprint out of band. The first screen of a new install, Settings → Connection → Pair Another Host, and iPad.
struct PairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var showingScanner = false
    /// Why the last scan failed; a failed pairing is the model's `error`.
    @State private var scanProblem: ScanProblem?
    @ScaledMetric(relativeTo: .largeTitle) private var markSide: CGFloat = 88

    private enum ScanProblem: Equatable {
        case expired, notAgentLand, newerVersion, cameraDenied
        case camera(String)

        var message: String {
            switch self {
            case .expired: AppModel.expiredPairingCode
            case .notAgentLand: "That isn’t an AgentLand pairing code. Scan the QR code AgentLand shows on your Mac."
            case .newerVersion: "This code is from a newer AgentLand. Update this app, then scan again."
            case .cameraDenied: "AgentLand needs the camera to scan your Mac’s QR code. Turn on Camera for AgentLand in Settings."
            case let .camera(message): message
            }
        }
    }

    /// What went wrong with the last attempt, once it is over.
    private var problem: String? {
        if let scanProblem { return scanProblem.message }
        return model.busy ? nil : model.error
    }

    var body: some View {
        NavigationStack {
            GeometryReader { page in
            ScrollView {
                VStack(spacing: AgentLandSpacing.large) {
                    AgentLandMark().frame(width: markSide, height: markSide)
                        .accessibilityHidden(true)
                    VStack(spacing: AgentLandSpacing.xSmall) {
                        Text("Pair with your Mac")
                            .font(.title.weight(.bold))
                            .foregroundStyle(AgentLandColor.text)
                            .accessibilityAddTraits(.isHeader)
                        Text("Open AgentLand on your Mac. It shows a QR code — scan it with this \(deviceWord).")
                            .font(.body)
                            .foregroundStyle(AgentLandColor.textSecondary)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                    if let name = model.pairingHostName {
                        HStack(spacing: AgentLandSpacing.xSmall) {
                            ProgressView()
                            Text("Pairing with \(name)…").foregroundStyle(AgentLandColor.text)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("pairingProgress")
                    } else {
                        Button { scan() } label: {
                            Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                                .foregroundStyle(AgentLandColor.onTint)
                                .frame(maxWidth: 360)
                        }
                        .buttonStyle(.agentLandPrimary)
                        .disabled(model.busy)
                        .accessibilityIdentifier("pairingScan")
                    }

                    if let problem {
                        VStack(spacing: AgentLandSpacing.small) {
                            Label {
                                Text(problem).foregroundStyle(AgentLandColor.text)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AgentLandColor.warning)
                            }
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("pairingProblem")
                            if scanProblem == .cameraDenied {
                                Button("Open Settings") {
                                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                                }
                                .buttonStyle(.bordered)
                                .minimumTapTarget()
                                .accessibilityIdentifier("pairingOpenSettings")
                            }
                        }
                        .frame(maxWidth: 480)
                    }

                    if model.selectedHost == nil, !model.hosts.isEmpty, model.pairingHostName == nil {
                        savedHosts
                    }
                }
                .padding(.horizontal, AgentLandSpacing.large)
                .padding(.vertical, AgentLandSpacing.xLarge)
                .frame(maxWidth: 560)
                // Centred in the page while it fits; larger text scrolls.
                .frame(maxWidth: .infinity, minHeight: page.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            }
            .groupedPageBackground()
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: problem) { _, message in
                if let message { AccessibilityNotification.Announcement(message).post() }
            }
            .sheet(isPresented: $showingScanner) {
                NavigationStack {
                    PairingQRScanner(onCode: { text in
                        showingScanner = false
                        scanned(text)
                    }, onFailure: { failure in
                        showingScanner = false
                        switch failure {
                        case .cameraDenied: scanProblem = .cameraDenied
                        case let .unavailable(message): scanProblem = .camera(message)
                        }
                    })
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Scan Your Mac’s QR Code")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { showingScanner = false } } }
                }
            }
            .onDisappear { showingScanner = false }
            .onChange(of: scenePhase) { _, phase in if phase == .background { showingScanner = false } }
            .onChange(of: model.locked) { _, locked in if locked { showingScanner = false } }
        }
    }

    /// Saved hosts, for the screen this is after Disconnect: one tap goes back to a Mac this device already paired with.
    private var savedHosts: some View {
        VStack(alignment: .leading, spacing: AgentLandSpacing.xSmall) {
            Text("Paired Macs").font(.footnote.weight(.semibold)).foregroundStyle(AgentLandColor.textSecondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(model.hosts) { host in
                Button { model.select(host) } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text(host.name).foregroundStyle(AgentLandColor.text)
                            Text(host.address).font(.caption).foregroundStyle(AgentLandColor.textSecondary)
                        }
                    } icon: { Image(systemName: "desktopcomputer") }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .minimumTapTarget()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: 480)
        .padding(.top, AgentLandSpacing.medium)
    }

    private var deviceWord: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    private func scan() {
        scanProblem = nil
        model.error = nil
        showingScanner = true
    }

    /// A valid, current code pairs at once; anything else says why in place.
    private func scanned(_ text: String) {
        do {
            let invitation = try PairingInvitation.parse(text)
            scanProblem = nil
            Task { await model.pair(invitation: invitation) }
        } catch PairingError.expired {
            scanProblem = .expired
        } catch PairingError.unsupportedVersion {
            scanProblem = .newerVersion
        } catch {
            scanProblem = .notAgentLand
        }
    }
}
