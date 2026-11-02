import AppKit

public extension NSTextView {
    @discardableResult
    func replaceKeepingAttributes(_ range: NSRange, with text: NSAttributedString) -> Bool {
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: text.string) else { return false }
        storage.replaceCharacters(in: range, with: text)
        didChangeText()
        return true
    }
}

public extension NSAttributedString {
    func slideNoteWrapped(_ range: NSRange) -> NSAttributedString {
        let wrapped = NSMutableAttributedString(attributedString: attributedSubstring(from: range))
        func plain(at location: Int) -> [NSAttributedString.Key: Any] {
            var attributes = self.attributes(at: location, effectiveRange: nil)
            attributes[.attachment] = nil
            return attributes
        }
        wrapped.insert(NSAttributedString(string: "(", attributes: plain(at: range.location)), at: 0)
        wrapped.append(NSAttributedString(string: ")", attributes: plain(at: NSMaxRange(range) - 1)))
        return wrapped
    }
}
