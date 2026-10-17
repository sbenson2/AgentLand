import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The quip's font is selected from fonts actually present on the phone and stays stable for that quip.
/// Text still comes from QuipStore through Home; motion uses Home's visibility and shared circus clock.
struct HomePhoneQuip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flourish: CGFloat = 0
    /// The serif fallback's size, scaled with the reader's text size as the playful faces are (HO-9).
    @ScaledMetric(relativeTo: .body) private var fallbackSize: CGFloat = HomePhoneQuip.size
    let text: String
    let active: Bool
    let referenceDate: Date

    var body: some View {
        Text(text)
            .font(font.italic())
            .rotationEffect(.degrees(Double(flourish) * 0.7))
            .offset(y: min(0, flourish) * 2)
            // A sleeping task wakes only for the brief flourish near the end of each shared 26 s
            // cycle. It neither ticks the view continuously nor changes the text's measured layout.
            .task(id: motionAllowed ? referenceDate : nil) {
                defer {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { flourish = 0 }
                }
                guard motionAllowed else { return }
                while !Task.isCancelled {
                    let now = Date()
                    let elapsed = max(0, now.timeIntervalSince(referenceDate))
                    var next = referenceDate.addingTimeInterval(floor(elapsed / 26) * 26 + 24)
                    if next <= now { next = next.addingTimeInterval(26) }
                    do {
                        try await Task.sleep(for: .seconds(next.timeIntervalSince(now)))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeInOut(duration: 0.26)) { flourish = -1 }
                        try await Task.sleep(for: .milliseconds(260))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeInOut(duration: 0.26)) { flourish = 1 }
                        try await Task.sleep(for: .milliseconds(260))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeInOut(duration: 0.28)) { flourish = 0 }
                        try await Task.sleep(for: .milliseconds(280))
                    } catch { return }
                }
            }
    }

    private var motionAllowed: Bool {
        guard active, !reduceMotion else { return false }
        #if DEBUG
        return !ProcessInfo.processInfo.arguments.contains("-AgentLandUITestsDisableAnimations")
        #else
        return true
        #endif
    }

    /// The quip's size at the default text size; it scales with Dynamic Type like body text (owner's request,
    /// 2026-10-04: a bit larger than the former 16).
    static let size: CGFloat = 18

    private var font: Font {
        #if os(iOS)
        let available = ["Chalkduster", "Papyrus", "MarkerFelt-Wide", "HoltwoodOneSC"]
            .filter { UIFont(name: $0, size: 16) != nil }
        if !available.isEmpty {
            let index = text.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0x7fffffff } % available.count
            return .custom(available[index], size: Self.size, relativeTo: .body)
        }
        #endif
        return .system(size: fallbackSize, weight: .medium, design: .serif)
    }
}
