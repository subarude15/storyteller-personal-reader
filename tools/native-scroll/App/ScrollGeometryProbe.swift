import SwiftUI
import UIKit

/// Read-only UIKit introspection: no offset/inset writes, timers or geometry-derived
/// padding. Queried on demand via accessibility AFTER the test releases its drag.
struct ScrollGeometryProbe: UIViewRepresentable {
    let name: String

    func makeUIView(context: Context) -> ProbeView { ProbeView(name: name) }
    func updateUIView(_ uiView: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        init(name: String) {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = true
            accessibilityIdentifier = "geometry.metrics.\(name)"
            accessibilityLabel = "Read only native scroll geometry"
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var accessibilityValue: String? {
            get {
                var result: [String: Any] = ["found": false]
                if let scroll = findScrollView() {
                    let inset = scroll.adjustedContentInset
                    let frame = scroll.convert(scroll.bounds, to: window)
                    result = [
                        "found": true,
                        "offsetY": scroll.contentOffset.y,
                        "contentHeight": scroll.contentSize.height,
                        "viewportHeight": scroll.bounds.height,
                        "viewportMinY": frame.minY,
                        "viewportMaxY": frame.maxY,
                        "contentInsetBottom": scroll.contentInset.bottom,
                        "adjustedInsetTop": inset.top,
                        "adjustedInsetBottom": inset.bottom,
                        "safeAreaBottom": scroll.safeAreaInsets.bottom,
                        "maxRestingOffsetY": max(-inset.top,
                            scroll.contentSize.height - scroll.bounds.height + inset.bottom),
                        "isDragging": scroll.isDragging,
                        "isDecelerating": scroll.isDecelerating,
                    ]
                }
                guard let data = try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
                else { return "{\"found\":false}" }
                return String(decoding: data, as: UTF8.self)
            }
            set {} // UIKit may set this; observations are always computed fresh.
        }

        private func findScrollView() -> UIScrollView? {
            // Prefer an enclosing vertical scroll view. SwiftUI may place its
            // background alongside rather than inside the UIKit scroll host.
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView, isVertical(scroll) { return scroll }
                ancestor = view.superview
            }
            ancestor = superview
            while let view = ancestor {
                let candidates = descendants(of: view).filter(isVertical)
                if let nearest = candidates.min(by: {
                    abs($0.convert($0.bounds, to: window).midY - accessibilityFrame.midY)
                        < abs($1.convert($1.bounds, to: window).midY - accessibilityFrame.midY)
                }) { return nearest }
                ancestor = view.superview
            }
            return nil
        }

        private func isVertical(_ scroll: UIScrollView) -> Bool {
            scroll.isScrollEnabled && !scroll.isHidden
                && (scroll.alwaysBounceVertical || scroll.contentSize.height > scroll.bounds.height + 1)
        }

        private func descendants(of view: UIView) -> [UIScrollView] {
            view.subviews.flatMap { child -> [UIScrollView] in
                let own = (child as? UIScrollView).map { [$0] } ?? []
                return own + descendants(of: child)
            }
        }
    }
}
