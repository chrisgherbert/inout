import AppKit

private final class TranscriptSidebarSearchCell: NSSearchFieldCell {
    var accessoryWidth: CGFloat = 0

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        var textRect = super.searchTextRect(forBounds: rect)
        textRect.size.width = max(0, textRect.width - accessoryWidth)
        return textRect
    }
}

/// Keep the native search and clear buttons, with match navigation inside the bezel.
final class TranscriptSidebarSearchField: NSSearchField {
    private let matchLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let accessories = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let nativeFont = font
        cell = TranscriptSidebarSearchCell(textCell: "")
        font = nativeFont
        isEditable = true
        isSelectable = true
        (cell as? NSTextFieldCell)?.usesSingleLineMode = true
        (cell as? NSTextFieldCell)?.isScrollable = true
        isBezeled = true
        bezelStyle = .roundedBezel
        matchLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        matchLabel.textColor = .secondaryLabelColor
        matchLabel.lineBreakMode = .byTruncatingMiddle
        matchLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        accessories.orientation = .horizontal
        accessories.alignment = .centerY
        accessories.spacing = 2
        accessories.addArrangedSubview(matchLabel)
        for (button, symbol, label) in [
            (previousButton, "chevron.up", "Previous match"),
            (nextButton, "chevron.down", "Next match")
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.refusesFirstResponder = true
            button.controlSize = .small
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 22),
                button.heightAnchor.constraint(equalToConstant: 20)
            ])
            accessories.addArrangedSubview(button)
        }
        accessories.isHidden = true
        addSubview(accessories)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setNavigationTarget(_ target: AnyObject, previous: Selector, next: Selector) {
        previousButton.target = target
        previousButton.action = previous
        nextButton.target = target
        nextButton.action = next
    }

    func configureMatches(displayText: String?, hasMatches: Bool) {
        let text = displayText ?? ""
        guard matchLabel.stringValue != text || accessories.isHidden != (displayText == nil) ||
              previousButton.isEnabled != hasMatches else { return }
        matchLabel.stringValue = text
        matchLabel.setAccessibilityLabel("Search result \(text)")
        accessories.isHidden = displayText == nil
        previousButton.isEnabled = hasMatches
        nextButton.isEnabled = hasMatches
        needsLayout = true
        needsDisplay = true
    }

    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        if !accessories.isHidden {
            for child in [matchLabel, previousButton, nextButton] {
                if !children.contains(where: { ($0 as? NSObject) === child }) { children.append(child) }
            }
        }
        return children
    }

    override func layout() {
        super.layout()
        guard let searchCell = cell as? TranscriptSidebarSearchCell else { return }
        let preferredWidth = accessories.isHidden ? 0 : accessories.fittingSize.width
        // Preserve room for the query, magnifier, and native clear button on narrow sidebars.
        let width = min(preferredWidth, max(0, bounds.width - 90))
        searchCell.accessoryWidth = width > 0 ? width + 6 : 0
        let clearRect = searchCell.cancelButtonRect(forBounds: bounds)
        accessories.frame = NSRect(x: max(0, clearRect.minX - width - 6),
                                   y: (bounds.height - 20) / 2, width: width, height: 20)
        accessories.layoutSubtreeIfNeeded()

        // The first typed character reveals the accessories while the native field
        // editor is already active. Resize its clipping view without resetting selection.
        if let editor = currentEditor(), let container = editor.superview {
            let textRect = searchCell.searchTextRect(forBounds: bounds)
            if let clip = container as? NSClipView, let parent = clip.superview {
                clip.frame = convert(textRect, to: parent)
            } else {
                editor.frame = convert(textRect, to: container)
            }
        }
        needsDisplay = true
    }
}
