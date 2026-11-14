#if os(iOS)
import SwiftUI
import UIKit

/// iPhone-Eingabefeld: wächst mit dem Text bis `maxLines` Zeilen und scrollt danach in sich – die Leiste mit dem
/// Ablegen-Knopf bleibt so immer gleich hoch und sichtbar, auch bei sehr langen Notizen (das SwiftUI-Textfeld mit
/// `lineLimit` wuchs ab etwa 10 Zeilen über die Leiste hinaus).
struct GrowingTextView: UIViewRepresentable {
    @Binding var text: String
    var placeholder: LocalizedStringKey
    var maxLines = 8

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.font = .preferredFont(forTextStyle: .body)
        tv.adjustsFontForContentSizeCategory = true
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = false
        tv.delegate = context.coordinator
        tv.accessibilityIdentifier = "input.text"
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.text = text
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        if tv.text != text { tv.text = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView tv: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 240
        let line = tv.font?.lineHeight ?? 22
        let full = tv.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let limit = ceil(line * CGFloat(maxLines))
        let scroll = full > limit + 1
        if tv.isScrollEnabled != scroll {
            tv.isScrollEnabled = scroll
            if scroll { DispatchQueue.main.async { tv.scrollRangeToVisible(tv.selectedRange) } }
        }
        return CGSize(width: width, height: max(ceil(line), min(full, limit)))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: GrowingTextView
        init(_ p: GrowingTextView) { parent = p }

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            if tv.isScrollEnabled { tv.scrollRangeToVisible(tv.selectedRange) }
        }
    }
}
#endif
