#if os(macOS)
import SwiftUI
import AppKit

final class TextCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var isSecondary = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(text: String, secondary: Bool) {
        label.stringValue = text
        isSecondary = secondary
        label.font = .systemFont(ofSize: 13)
        updateTextColor()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTextColor() }
    }

    private func updateTextColor() {
        if backgroundStyle == .emphasized {
            label.textColor = .white
        } else {
            label.textColor = isSecondary ? .secondaryLabelColor : .labelColor
        }
    }
}

final class LinkTextCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    var linkTarget: MetadataLinkTarget?
    private var trackingArea: NSTrackingArea?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(text: String, linkTarget: MetadataLinkTarget?) {
        label.stringValue = text
        self.linkTarget = linkTarget
        label.font = .systemFont(ofSize: 13)
        updateTextColor()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTextColor() }
    }

    private func updateTextColor() {
        label.textColor = backgroundStyle == .emphasized ? .white : .secondaryLabelColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil,
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        if linkTarget != nil {
            NSCursor.pointingHand.push()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if linkTarget != nil {
            NSCursor.pop()
        }
    }
}

final class TitleAuthorCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")
    private let stackView = NSStackView()
    var secondaryLinkTarget: MetadataLinkTarget?
    private var trackingArea: NSTrackingArea?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor

        secondaryLabel.lineBreakMode = .byTruncatingTail
        secondaryLabel.maximumNumberOfLines = 1
        secondaryLabel.font = .systemFont(ofSize: 11)
        secondaryLabel.textColor = .secondaryLabelColor

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 1
        stackView.translatesAutoresizingMaskIntoConstraints = false

        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(secondaryLabel)
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(
        title: String,
        secondaryText: String?,
        secondaryLinkTarget: MetadataLinkTarget?,
        showSecondary: Bool = true,
    ) {
        titleLabel.stringValue = title
        secondaryLabel.stringValue = secondaryText ?? ""
        secondaryLabel.isHidden = !showSecondary || (secondaryText?.isEmpty ?? true)
        self.secondaryLinkTarget = secondaryLabel.isHidden ? nil : secondaryLinkTarget
        updateTextColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTextColors() }
    }

    private func updateTextColors() {
        if backgroundStyle == .emphasized {
            titleLabel.textColor = .white
            secondaryLabel.textColor = .white.withAlphaComponent(0.8)
        } else {
            titleLabel.textColor = .labelColor
            secondaryLabel.textColor = .secondaryLabelColor
        }
    }

    func secondaryLabelContainsPoint(_ pointInCell: NSPoint) -> Bool {
        guard !secondaryLabel.isHidden, secondaryLinkTarget != nil else { return false }
        let pointInStack = stackView.convert(pointInCell, from: self)
        return secondaryLabel.frame.contains(pointInStack)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil,
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if secondaryLabelContainsPoint(point) {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}

final class SeriesCellView: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "")
    private let stackView = NSStackView()
    var linkTarget: MetadataLinkTarget?
    private var trackingArea: NSTrackingArea?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.textColor = .secondaryLabelColor

        positionLabel.lineBreakMode = .byClipping
        positionLabel.maximumNumberOfLines = 1
        positionLabel.textColor = .tertiaryLabelColor

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false

        stackView.addArrangedSubview(nameLabel)
        stackView.addArrangedSubview(positionLabel)
        addSubview(stackView)

        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        positionLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(series: BookSeries?) {
        if let series {
            nameLabel.stringValue = series.name
            nameLabel.font = .systemFont(ofSize: 13)
            linkTarget = .series(series.name)
            if let formatted = series.formattedPosition {
                positionLabel.stringValue = "#\(formatted)"
                positionLabel.font = .systemFont(ofSize: 11)
                positionLabel.isHidden = false
            } else {
                positionLabel.isHidden = true
            }
        } else {
            nameLabel.stringValue = ""
            linkTarget = nil
            positionLabel.isHidden = true
        }
        updateTextColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTextColors() }
    }

    private func updateTextColors() {
        if backgroundStyle == .emphasized {
            nameLabel.textColor = .white
            positionLabel.textColor = .white.withAlphaComponent(0.7)
        } else {
            nameLabel.textColor = .secondaryLabelColor
            positionLabel.textColor = .tertiaryLabelColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil,
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        if linkTarget != nil {
            NSCursor.pointingHand.push()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if linkTarget != nil {
            NSCursor.pop()
        }
    }
}

final class DateCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var parsedDate: Date?
    private var rawDateString: String = ""

    private static let fullWidthThreshold: CGFloat = 110
    private static let monthYearWidthThreshold: CGFloat = 85

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(date: Date?, rawString: String) {
        parsedDate = date
        rawDateString = rawString
        updateLabel()
        updateTextColor()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLabel()
    }

    private func updateLabel() {
        guard let date = parsedDate else {
            label.stringValue = rawDateString
            return
        }

        if bounds.width >= Self.fullWidthThreshold {
            label.stringValue = SilveranDate.full(date)
        } else if bounds.width >= Self.monthYearWidthThreshold {
            label.stringValue = SilveranDate.monthYear(date)
        } else {
            label.stringValue = SilveranDate.year(date)
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTextColor() }
    }

    private func updateTextColor() {
        label.textColor = backgroundStyle == .emphasized ? .white : .secondaryLabelColor
    }
}

final class LinkDateCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var parsedDate: Date?
    private var rawDateString: String = ""
    var linkTarget: MetadataLinkTarget?
    private var trackingArea: NSTrackingArea?

    private static let fullWidthThreshold: CGFloat = 110
    private static let monthYearWidthThreshold: CGFloat = 85

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(date: Date?, rawString: String, linkTarget: MetadataLinkTarget?) {
        parsedDate = date
        rawDateString = rawString
        self.linkTarget = linkTarget
        updateLabel()
        updateTextColor()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLabel()
    }

    private func updateLabel() {
        guard let date = parsedDate else {
            label.stringValue = rawDateString
            return
        }

        if bounds.width >= Self.fullWidthThreshold {
            label.stringValue = SilveranDate.full(date)
        } else if bounds.width >= Self.monthYearWidthThreshold {
            label.stringValue = SilveranDate.monthYear(date)
        } else {
            label.stringValue = SilveranDate.year(date)
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTextColor() }
    }

    private func updateTextColor() {
        label.textColor = backgroundStyle == .emphasized ? .white : .secondaryLabelColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil,
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        if linkTarget != nil {
            NSCursor.pointingHand.push()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if linkTarget != nil {
            NSCursor.pop()
        }
    }
}

final class ProgressCellView: NSTableCellView {
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private let percentLabel = NSTextField(labelWithString: "")
    private var currentProgress: Double = 0
    private var percentLabelCenterConstraint: NSLayoutConstraint?
    private var percentLabelTrailingConstraint: NSLayoutConstraint?
    private static let compactWidthThreshold: CGFloat = 75

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        trackLayer.cornerRadius = 2
        trackLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
        layer?.addSublayer(trackLayer)

        fillLayer.cornerRadius = 2
        fillLayer.backgroundColor = NSColor.controlAccentColor.cgColor
        layer?.addSublayer(fillLayer)

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.alignment = .right
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(percentLabel)

        percentLabelTrailingConstraint = percentLabel.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -4,
        )
        percentLabelCenterConstraint = percentLabel.centerXAnchor.constraint(equalTo: centerXAnchor)

        NSLayoutConstraint.activate([
            percentLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            percentLabel.widthAnchor.constraint(equalToConstant: 32),
            percentLabelTrailingConstraint!,
        ])
    }

    override func layout() {
        super.layout()
        updateLayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLayout()
    }

    private func updateLayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let isCompact = bounds.width < Self.compactWidthThreshold
        trackLayer.isHidden = isCompact
        fillLayer.isHidden = isCompact

        if isCompact {
            percentLabelTrailingConstraint?.isActive = false
            percentLabelCenterConstraint?.isActive = true
            percentLabel.alignment = .center
        } else {
            percentLabelCenterConstraint?.isActive = false
            percentLabelTrailingConstraint?.isActive = true
            percentLabel.alignment = .right

            let barHeight: CGFloat = 4
            let barWidth = bounds.width - 48
            let y = (bounds.height - barHeight) / 2
            trackLayer.frame = CGRect(x: 4, y: y, width: barWidth, height: barHeight)
            fillLayer.frame = CGRect(
                x: 4,
                y: y,
                width: barWidth * currentProgress,
                height: barHeight,
            )
        }

        CATransaction.commit()
    }

    func configure(progress: Double) {
        currentProgress = min(max(progress, 0), 1)
        percentLabel.stringValue = "\(Int(currentProgress * 100))%"
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)

        let barHeight: CGFloat = 4
        trackLayer.cornerRadius = barHeight / 2
        fillLayer.cornerRadius = barHeight / 2

        updateTextColor()
        needsLayout = true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTextColor() }
    }

    private func updateTextColor() {
        percentLabel.textColor = backgroundStyle == .emphasized ? .white : .secondaryLabelColor
    }
}

#endif
