import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import AgentLandBranding
import AgentLandDesign
import AgentLandDesktopCore

/// Pair a Device, as a sheet over the AgentLand window (or its own window from the menu bar): the QR code, and Done.
/// It closes by itself once a device has paired.
struct PairingSheet: View {
    @EnvironmentObject private var host: HostController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: AgentLandSpacing.medium) {
                    HStack(spacing: AgentLandSpacing.small) {
                        AgentLandMark(animated: false).frame(width: 34, height: 34)
                            .accessibilityHidden(true)
                        Text("Pair a Device").font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                    }
                    if let message = host.errorMessage {
                        Label(message, systemImage: "exclamationmark.circle").foregroundStyle(AgentLandColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    PairingPanel(onPaired: { dismiss() })
                }
                .padding(AgentLandSpacing.large)
                .frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("pairingDone")
            }
            .padding(AgentLandSpacing.medium)
        }
        .background(AgentLandColor.canvas)
        .foregroundStyle(AgentLandColor.text)
        .frame(minWidth: 420, idealWidth: 440, minHeight: 480, idealHeight: 520)
    }
}

/// The pairing QR code alone (QR-only pairing, 2026-10-16): the code, one line saying what to do, and this Mac's
/// name. While it shows, a new code replaces the current one shortly before it expires (`keepPairingCodeFresh`), and
/// the devices are read every 2 s: a device that pairs shows "Paired with <name>" and, 2 s later, `onPaired`. A device
/// that pairs again over its own record (docs/HOST-API.md, "Pairing again") keeps its ID, and its paired time changes:
/// "Paired again with <name>".
struct PairingPanel: View {
    @EnvironmentObject private var host: HostController
    var instruction = "Open AgentLand on your iPhone or iPad and tap Scan QR Code."
    var onPaired: (() -> Void)?
    @State private var pairedName: String?
    @State private var pairedAgain = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { clock in
            VStack(spacing: AgentLandSpacing.small) {
                if let pairedName {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(AgentLandColor.success)
                        .accessibilityHidden(true)
                    Text("\(pairedAgain ? "Paired again" : "Paired") with \(pairedName)").font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("pairingPaired")
                } else if let invitation = host.pairingInvitation,
                          host.status == .running,
                          invitation.expiresAt > clock.date,
                          let encoded = try? invitation.encoded() {
                    QRCodeImage(value: encoded)
                        .equatable()
                        .padding(AgentLandSpacing.small)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .frame(width: 240, height: 240)
                        .accessibilityLabel("Pairing QR code for \(invitation.advertisement.name)")
                        .accessibilityIdentifier("pairingQRCode")
                    Text(instruction)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(invitation.advertisement.name)
                        .font(.callout).foregroundStyle(AgentLandColor.textSecondary)
                } else if host.status == .running, host.activeAdvertisement != nil {
                    ProgressView().frame(width: 240, height: 240)
                    Text("Making a pairing code…").foregroundStyle(AgentLandColor.textSecondary)
                } else if host.status == .starting {
                    ProgressView()
                    Text("Waiting for this Mac’s secure connection.").foregroundStyle(AgentLandColor.textSecondary)
                } else {
                    Text("Connect this Mac to show its pairing code. Set its hostname and certificate in Settings first.")
                        .foregroundStyle(AgentLandColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .task(id: host.status) { await follow() }
    }

    /// While the panel shows and the host runs: keeps the code fresh and watches for a device that pairs. Ends when
    /// the panel goes, which stops both.
    private func follow() async {
        guard host.status == .running, pairedName == nil else { return }
        var known: [String: String]?
        while !Task.isCancelled {
            host.keepPairingCodeFresh()
            if let devices = await host.readDevices() {
                let active = devices.filter(\.isActive)
                if let known, let paired = Self.paired(active, known: known) {
                    guard !Task.isCancelled else { return }
                    pairedName = paired.device.name.isEmpty ? "your device" : paired.device.name
                    pairedAgain = paired.again
                    AccessibilityNotification.Announcement("\(paired.again ? "Paired again" : "Paired") with \(pairedName ?? "your device")").post()
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    onPaired?()
                    return
                }
                known = (known ?? [:]).merging(active.map { ($0.id, $0.createdAt) }) { $1 }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

extension PairingPanel {
    /// The device that paired since `known` (device ID → its paired time) was read: one with a new ID, or one that
    /// paired again over its own record, whose paired time changed.
    static func paired(_ active: [ManagedDevice], known: [String: String]) -> (device: ManagedDevice, again: Bool)? {
        if let new = active.first(where: { known[$0.id] == nil }) { return (new, false) }
        return active.first(where: { known[$0.id] != $0.createdAt }).map { ($0, true) }
    }
}

struct QRCodeImage: View, Equatable {
    let value: String

    var body: some View {
        if let image = qrImage {
            Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
        }
    }

    private var qrImage: NSImage? {
        guard let cgImage = Self.renderedImage(value: value) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    static func renderedImage(value: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
