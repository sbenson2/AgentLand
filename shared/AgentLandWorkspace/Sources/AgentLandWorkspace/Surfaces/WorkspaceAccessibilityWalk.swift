import CoreGraphics
#if os(iOS)
import UIKit

/// What VoiceOver can reach in the app's windows, in order: one line per element with its identifier,
/// label and frame on screen, separated by tabs. It follows the accessibility container API as the
/// screen reader does: hidden containers and views are skipped, a modal element hides its siblings,
/// and an element's own children are not visited. Used by the UI tests (`workspaceUITestHooks`):
/// their element tree also lists elements SwiftUI hides from VoiceOver, so it cannot tell what a
/// VoiceOver user reaches.
@MainActor func reachableAccessibilityElements() -> [String] {
    var found: [String] = []
    @MainActor func visit(_ object: NSObject, depth: Int) {
        guard depth < 100, !object.accessibilityElementsHidden else { return }
        if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { return }
        if object.isAccessibilityElement {
            let frame = object.accessibilityFrame
            let label = (object.accessibilityLabel ?? "").replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            found.append([accessibilityIdentifier(of: object), label, walkFrameText(frame)].joined(separator: "\t"))
            return
        }
        var children: [NSObject] = []
        if let elements = object.accessibilityElements as? [NSObject] {
            children = elements
        } else if case let count = object.accessibilityElementCount(), count != NSNotFound, count > 0 {
            for index in 0..<count {
                if let child = object.accessibilityElement(at: index) as? NSObject {
                    children.append(child)
                }
            }
        } else if let view = object as? UIView {
            children = view.subviews
        }
        if let modal = children.last(where: { $0.accessibilityViewIsModal }) { children = [modal] }
        for child in children { visit(child, depth: depth + 1) }
    }
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    for window in windows where !window.isHidden { visit(window, depth: 0) }
    return found
}

@MainActor private func accessibilityIdentifier(of object: NSObject) -> String {
    if let identified = object as? UIAccessibilityIdentification, let identifier = identified.accessibilityIdentifier {
        return identifier
    }
    // SwiftUI's accessibility nodes answer to the property without adopting the protocol.
    let selector = NSSelectorFromString("accessibilityIdentifier")
    guard object.responds(to: selector) else { return "" }
    return object.value(forKey: "accessibilityIdentifier") as? String ?? ""
}
#else
/// The UI-test walk of what VoiceOver reaches is for the iPhone and iPad UI tests; the Mac lists nothing.
@MainActor func reachableAccessibilityElements() -> [String] { [] }
#endif

/// An element's frame as the walk writes it, `x,y,width,height` in whole points, or `null` for an element with no
/// place on screen: SwiftUI answers `CGRect.null` (whose origin is infinite) for some elements, and converting that to
/// whole points ended the app (every walk of the iPhone drawer's Files page in run 1791399122, after batch 8). An
/// infinite rectangle's huge values would end it too. The UI tests read `null` as `CGRect.null`.
func walkFrameText(_ frame: CGRect) -> String {
    let values = [frame.minX, frame.minY, frame.width, frame.height]
    guard !frame.isNull, !frame.isInfinite, values.allSatisfy({ $0.isFinite && abs($0) < 1_000_000_000 }) else { return "null" }
    return values.map { String(Int($0)) }.joined(separator: ",")
}
