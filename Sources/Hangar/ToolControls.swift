import HangarCore
import UIKit

/// The words a tool asks for, on a capsule: a field, words to start from, pictures to go by, the strokes cleared,
/// and sent (or not: a tool with a button of its own over the picture takes them with it).
@MainActor
final class WordsBar: UIView, UITextFieldDelegate {
    var onSend: ((String) -> Void)?
    var onClear: (() -> Void)?
    var onChange: (() -> Void)?
    var onAttach: (() -> Void)?

    private let capsule: UIVisualEffectView
    private let field = UITextField()
    private let suggest: UIButton
    private let attach: UIButton
    private let clear: UIButton
    private let send: UIButton
    private let price = UILabel()
    private let style: HangarStyle
    private var painted = false
    private var working = false
    private var sends = true
    private var needsPaint = false

    init(style: HangarStyle) {
        self.style = style
        capsule = Chrome.capsule(style)
        suggest = Chrome.plainButton("sparkles", label: "Suggestions", style: style)
        attach = Chrome.plainButton("photo.badge.plus", label: "Add a Picture to Go By", style: style)
        clear = Chrome.plainButton("xmark.circle.fill", label: "Clear Brush Strokes", style: style)
        send = Chrome.button("arrow.up", label: "Send", style: style, prominent: true)
        super.init(frame: .zero)
        addSubview(capsule)
        field.font = style.wordsFont
        field.textColor = style.foreground
        field.returnKeyType = .send
        field.enablesReturnKeyAutomatically = true
        field.delegate = self
        field.accessibilityIdentifier = "toolWords"
        field.addAction(UIAction { [weak self] _ in self?.changed() }, for: .editingChanged)
        suggest.showsMenuAsPrimaryAction = true
        clear.tintColor = style.secondary
        clear.addAction(UIAction { [weak self] _ in self?.onClear?() }, for: .touchUpInside)
        attach.addAction(UIAction { [weak self] _ in self?.onAttach?() }, for: .touchUpInside)
        send.addAction(UIAction { [weak self] _ in self?.sendTapped() }, for: .touchUpInside)
        price.font = .systemFont(ofSize: 12, weight: .medium)
        price.textColor = style.secondary
        for view in [suggest, attach, field, price, clear] as [UIView] { capsule.contentView.addSubview(view) }
        addSubview(send)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `sends`: its own Send (a tool without a button over the picture); `needsPaint`: only once something's painted.
    func configure(_ words: HangarWords, painted: Bool, working: Bool, sends: Bool, needsPaint: Bool, attaches: Bool, price: String?) {
        self.painted = painted
        self.working = working
        self.sends = sends
        self.needsPaint = needsPaint
        field.attributedPlaceholder = NSAttributedString(string: words.placeholder, attributes: [.foregroundColor: style.secondary])
        suggest.isHidden = words.suggestions.isEmpty
        suggest.menu = UIMenu(children: words.suggestions.map { suggestion in
            UIAction(title: suggestion.title, image: suggestion.symbol.flatMap { UIImage(systemName: $0) }) { [weak self] _ in
                self?.append(suggestion.words)
            }
        })
        attach.isHidden = !attaches
        self.price.text = price
        field.isEnabled = !working
        update()
        setNeedsLayout()
    }

    var words: String {
        (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clearWords() {
        field.text = nil
        update()
    }

    private func append(_ words: String) {
        let now = field.text ?? ""
        field.text = now.isEmpty ? words : now + (now.hasSuffix(" ") ? "" : " ") + words
        changed()
        field.becomeFirstResponder()
    }

    private func changed() {
        update()
        onChange?()
    }

    private func update() {
        send.isHidden = !sends
        send.isEnabled = !words.isEmpty && (painted || !needsPaint) && !working
        clear.isHidden = !painted || working
        price.isHidden = price.text == nil || words.isEmpty || !sends
        setNeedsLayout()
    }

    private func sendTapped() {
        guard !words.isEmpty, sends else { return }
        onSend?(words)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if sends { sendTapped() } else { textField.resignFirstResponder() }
        return false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        send.frame = CGRect(x: bounds.width - h, y: 0, width: h, height: h)
        capsule.frame = CGRect(x: 0, y: 0, width: bounds.width - (sends ? h + 8 : 0), height: h)
        Chrome.round(capsule)
        var x: CGFloat = 6
        for button in [suggest, attach] where !button.isHidden {
            button.frame = CGRect(x: x, y: 0, width: 36, height: h)
            x += 36
        }
        if x == 6 { x = 18 }
        var right = capsule.bounds.width - (clear.isHidden ? 16 : 40)
        clear.frame = CGRect(x: capsule.bounds.width - 40, y: 0, width: 36, height: h)
        if !price.isHidden {
            let w = ceil(price.sizeThatFits(bounds.size).width)
            price.frame = CGRect(x: right - w, y: 0, width: w, height: h)
            right -= w + 8
        }
        field.frame = CGRect(x: x, y: 0, width: max(0, right - x), height: h)
    }
}

/// A row of capsules, one chosen: a tool's values (Reframe's Horizontal, Vertical…) or shapes (Extend's).
@MainActor
final class Chips: UIView {
    var onChoose: ((Int) -> Void)?
    private let scroll = UIScrollView()
    private var buttons: [UIButton] = []
    private let style: HangarStyle
    private(set) var chosen = 0
    static let height: CGFloat = 34

    init(style: HangarStyle) {
        self.style = style
        super.init(frame: .zero)
        scroll.showsHorizontalScrollIndicator = false
        scroll.clipsToBounds = false
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(_ titles: [String], chosen: Int) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = titles.enumerated().map { i, title in
            let button = UIButton(configuration: .plain())
            button.addAction(UIAction { [weak self] _ in self?.choose(i, tapped: true) }, for: .touchUpInside)
            button.accessibilityLabel = title
            scroll.addSubview(button)
            return button
        }
        for (button, title) in zip(buttons, titles) { button.configurationUpdateHandler = { [weak self] b in self?.look(b, title) } }
        choose(chosen, tapped: false)
        setNeedsLayout()
    }

    private func look(_ button: UIButton, _ title: String) {
        let on = button.isSelected
        var configuration: UIButton.Configuration
        if style.glass, #available(iOS 26.0, *) {
            configuration = on ? .prominentGlass() : .glass()
        } else {
            configuration = on ? .filled() : .gray()
        }
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = on ? style.accent : nil
        configuration.baseForegroundColor = on ? .black : style.foreground
        configuration.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 13, weight: .semibold)]))
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        button.configuration = configuration
    }

    func choose(_ i: Int, tapped: Bool) {
        guard buttons.indices.contains(i) else { return }
        chosen = i
        for (j, button) in buttons.enumerated() {
            button.isSelected = j == i
            button.accessibilityTraits = j == i ? [.button, .selected] : .button
        }
        if tapped { onChoose?(i) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        var x: CGFloat = 0
        let gap: CGFloat = 6
        for button in buttons {
            let w = ceil(button.sizeThatFits(CGSize(width: 200, height: Self.height)).width)
            button.frame = CGRect(x: x, y: (bounds.height - Self.height) / 2, width: w, height: Self.height)
            x += w + gap
        }
        let width = max(0, x - gap)
        scroll.contentSize = CGSize(width: width, height: bounds.height)
        // In the middle while they fit.
        let inset = max(0, (bounds.width - width) / 2)
        scroll.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: 0)
        if inset > 0 { scroll.contentOffset = CGPoint(x: -inset, y: 0) }
    }
}

/// A step's takes after it's made, over the picture: the one used chosen (‹ 1 / 3 ›), another asked for (Again),
/// and how it's laid (only where it was asked to change, or all of it; where that is shown).
@MainActor
final class ResultPill: UIView {
    var onTake: ((Int) -> Void)?
    var onAgain: (() -> Void)?
    var onMasked: ((Bool) -> Void)?
    var onShowKept: ((Bool) -> Void)?

    private let capsule: UIVisualEffectView
    private let back: UIButton
    private let forward: UIButton
    private let count = UILabel()
    private let again = UIButton(configuration: .plain())
    private let more: UIButton
    private let style: HangarStyle
    private var take = 0
    private var takes = 1
    static let height: CGFloat = 40

    init(style: HangarStyle) {
        self.style = style
        capsule = Chrome.capsule(style)
        back = Chrome.plainButton("chevron.left", label: "Previous Take", style: style)
        forward = Chrome.plainButton("chevron.right", label: "Next Take", style: style)
        more = Chrome.plainButton("ellipsis", label: "More", style: style)
        super.init(frame: .zero)
        addSubview(capsule)
        count.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        count.textColor = style.foreground
        count.textAlignment = .center
        var configuration = UIButton.Configuration.plain()
        configuration.attributedTitle = AttributedString("Again", attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15, weight: .semibold)]))
        configuration.image = UIImage(systemName: "arrow.clockwise", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        configuration.imagePadding = 5
        configuration.baseForegroundColor = style.foreground
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
        again.configuration = configuration
        again.accessibilityLabel = "Make Another Take"
        back.addAction(UIAction { [weak self] _ in self.map { $0.onTake?($0.take - 1) } }, for: .touchUpInside)
        forward.addAction(UIAction { [weak self] _ in self.map { $0.onTake?($0.take + 1) } }, for: .touchUpInside)
        again.addAction(UIAction { [weak self] _ in self?.onAgain?() }, for: .touchUpInside)
        more.showsMenuAsPrimaryAction = true
        for view in [back, count, forward, again, more] as [UIView] { capsule.contentView.addSubview(view) }
        alpha = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The step's takes and the one used; whether it's laid only where it was asked (`masked`, nil for a step laid
    /// whole), whether that's shown; and whether another can be asked for.
    func show(take: Int, of takes: Int, masked: Bool?, showingKept: Bool, canAgain: Bool) {
        self.take = take
        self.takes = takes
        count.text = "\(take + 1) / \(takes)"
        count.accessibilityLabel = "Take \(take + 1) of \(takes)"
        back.isEnabled = take > 0
        forward.isEnabled = take < takes - 1
        for view in [back, count, forward] { view.isHidden = takes < 2 }
        again.isEnabled = canAgain
        more.isHidden = masked == nil
        if let masked {
            more.menu = UIMenu(children: [
                UIMenu(options: .displayInline, children: [
                    UIAction(title: "Keep Only What Changed", state: masked ? .on : .off) { [weak self] _ in self?.onMasked?(true) },
                    UIAction(title: "Use the Whole Result", state: masked ? .off : .on) { [weak self] _ in self?.onMasked?(false) },
                ]),
                UIAction(title: showingKept ? "Hide What’s Kept" : "Show What’s Kept", image: UIImage(systemName: "square.dashed"),
                         attributes: masked ? [] : .disabled) { [weak self] _ in self?.onShowKept?(!showingKept) },
            ])
        }
        setNeedsLayout()
    }

    var fittingWidth: CGFloat {
        var w: CGFloat = 8
        if takes >= 2 { w += 36 + 52 + 36 }
        w += ceil(again.sizeThatFits(CGSize(width: 200, height: Self.height)).width)
        if !more.isHidden { w += 40 }
        return w + 8
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        capsule.frame = bounds
        Chrome.round(capsule)
        let h = bounds.height
        var x: CGFloat = 8
        if takes >= 2 {
            back.frame = CGRect(x: x, y: 0, width: 36, height: h)
            count.frame = CGRect(x: x + 36, y: 0, width: 52, height: h)
            forward.frame = CGRect(x: x + 88, y: 0, width: 36, height: h)
            x += 124
        }
        let w = ceil(again.sizeThatFits(CGSize(width: 200, height: h)).width)
        again.frame = CGRect(x: x, y: 0, width: w, height: h)
        x += w
        more.frame = CGRect(x: x, y: 0, width: 40, height: h)
    }
}

/// Pictures to go by, small, each taken off with a tap: over the words they go with.
@MainActor
final class ReferenceRow: UIView {
    var onRemove: ((Int) -> Void)?
    private var views: [UIButton] = []
    static let side: CGFloat = 40

    func show(_ pictures: [CGImage]) {
        views.forEach { $0.removeFromSuperview() }
        views = pictures.enumerated().map { i, picture in
            var configuration = UIButton.Configuration.plain()
            configuration.background.image = UIImage(cgImage: picture)
            configuration.background.imageContentMode = .scaleAspectFill
            configuration.background.cornerRadius = 8
            configuration.background.strokeColor = .white
            configuration.background.strokeWidth = 1.5
            let button = UIButton(configuration: configuration)
            let badge = UIImageView(image: UIImage(systemName: "xmark.circle.fill"))
            badge.tintColor = .white
            badge.backgroundColor = .black
            badge.layer.cornerRadius = 8
            badge.clipsToBounds = true
            badge.frame = CGRect(x: Self.side - 12, y: -4, width: 16, height: 16)
            button.addSubview(badge)
            button.accessibilityLabel = "Remove Picture \(i + 1)"
            button.addAction(UIAction { [weak self] _ in self?.onRemove?(i) }, for: .touchUpInside)
            addSubview(button)
            return button
        }
        setNeedsLayout()
    }

    var isEmpty: Bool { views.isEmpty }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (i, view) in views.enumerated() {
            view.frame = CGRect(x: CGFloat(i) * (Self.side + 8), y: 0, width: Self.side, height: Self.side)
        }
    }
}

/// A light where it's placed on the picture: a small sun.
@MainActor
final class LightDot: UIView {
    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 38, height: 38))
        let disc = UIView(frame: bounds)
        disc.backgroundColor = UIColor.white.withAlphaComponent(0.92)
        disc.layer.cornerRadius = 19
        disc.layer.shadowColor = UIColor.black.cgColor
        disc.layer.shadowOpacity = 0.35
        disc.layer.shadowRadius = 4
        disc.layer.shadowOffset = .zero
        addSubview(disc)
        let sun = UIImageView(image: UIImage(systemName: "sun.max.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)))
        sun.tintColor = .systemOrange
        sun.center = CGPoint(x: 19, y: 19)
        addSubview(sun)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "Light"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Fingers over the picture for a tool that moves it rather than paints it: one finger dragged (and tapped), two
/// moved, pinched and turned, all at once.
@MainActor
final class TouchPad: UIView, UIGestureRecognizerDelegate {
    /// One finger: where it is, how far it's gone since it was last told, and whether it's begun or ended.
    var onOne: ((_ at: CGPoint, _ moved: CGPoint, _ state: UIGestureRecognizer.State) -> Void)?
    /// Two: how far they've moved, how much nearer or further apart, how far turned, each since last told.
    var onTwo: ((_ moved: CGPoint, _ scale: CGFloat, _ turned: CGFloat, _ state: UIGestureRecognizer.State) -> Void)?
    /// Whether two fingers count.
    var takesTwo = true { didSet { for g in [two, pinch, turn] { g.isEnabled = takesTwo } } }

    private let one = UIPanGestureRecognizer()
    private let tap = UITapGestureRecognizer()
    private let two = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()
    private let turn = UIRotationGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        one.maximumNumberOfTouches = 1
        two.minimumNumberOfTouches = 2
        one.addTarget(self, action: #selector(dragged(_:)))
        tap.addTarget(self, action: #selector(tapped(_:)))
        for g in [two, pinch, turn] as [UIGestureRecognizer] { g.addTarget(self, action: #selector(moved(_:))) }
        for g in [one, tap, two, pinch, turn] as [UIGestureRecognizer] {
            g.delegate = self
            addGestureRecognizer(g)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        let moved = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        onOne?(g.location(in: self), moved, g.state)
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        onOne?(g.location(in: self), .zero, .ended)
    }

    @objc private func moved(_ g: UIGestureRecognizer) {
        var moved = CGPoint.zero, scale: CGFloat = 1, turned: CGFloat = 0
        if let pan = g as? UIPanGestureRecognizer {
            moved = pan.translation(in: self)
            pan.setTranslation(.zero, in: self)
        } else if let pinch = g as? UIPinchGestureRecognizer {
            scale = pinch.scale
            pinch.scale = 1
        } else if let turn = g as? UIRotationGestureRecognizer {
            turned = turn.rotation
            turn.rotation = 0
        }
        onTwo?(moved, scale, turned, g.state)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g !== one && other !== one && g !== tap && other !== tap
    }
}
