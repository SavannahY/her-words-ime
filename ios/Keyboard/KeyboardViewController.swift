import UIKit

/// All composition stays inside this extension until the user selects a candidate.
/// No network, shared container, clipboard access, or keystroke persistence.
final class KeyboardViewController: UIInputViewController {
    private var engine: HerPinyinEngine?
    private var input = ""
    private var mode: HerWordingMode = .neutral
    private var candidates: [HerCandidate] = []
    private var english = false
    private var forcedASCII = false
    private var languageBeforeASCII = false
    private var uppercase = false
    private var numeric = false
    private var symbols = false
    private var loadFailed = false
    private var engineLoading = false
    private var deleteTimer: Timer?
    private var documentID: UUID?
    private var heightConstraint: NSLayoutConstraint?
    private let compositionLabel = UILabel()
    private let modeButton = UIButton(type: .system)
    private let candidateScroll = UIScrollView()
    private let candidateStack = UIStackView()
    private let rows = UIStackView()
    private let root = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGray5
        inputView?.allowsSelfSizing = true
        primaryLanguage = "zh-Hans"
        documentID = textDocumentProxy.documentIdentifier
        configureInterface()
        loadEngine()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let currentDocument = textDocumentProxy.documentIdentifier
        if documentID != currentDocument { input = "" }
        documentID = currentDocument
        if loadFailed { loadEngine() }
        updateInputType()
        updateCandidates()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        deleteTimer?.invalidate()
        deleteTimer = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let compactHeight = view.bounds.width > 600
        let height: CGFloat = compactHeight ? 264 : 328
        if heightConstraint?.constant != height { heightConstraint?.constant = height }
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        if documentID != textDocumentProxy.documentIdentifier {
            input = ""
            documentID = textDocumentProxy.documentIdentifier
            updateCandidates()
        }
        updateInputType()
    }

    private func loadEngine() {
        guard !engineLoading else { return }
        engineLoading = true
        loadFailed = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                guard let lexicon = Bundle.main.url(forResource: "lexicon", withExtension: "json"),
                      let rules = Bundle.main.url(forResource: "rules", withExtension: "json") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let engine = try HerPinyinEngine(lexiconData: Data(contentsOf: lexicon),
                                                rulesData: Data(contentsOf: rules))
                DispatchQueue.main.async { [weak self] in
                    self?.engine = engine
                    self?.engineLoading = false
                    self?.updateCandidates()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.loadFailed = true
                    self?.engineLoading = false
                    self?.updateCandidates()
                }
            }
        }
    }

    private func configureInterface() {
        root.axis = .vertical
        root.spacing = 5
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            root.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4)
        ])
        heightConstraint = view.heightAnchor.constraint(equalToConstant: 328)
        heightConstraint?.priority = .init(999)
        heightConstraint?.isActive = true

        let toolbar = UIStackView()
        toolbar.alignment = .center
        toolbar.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let brand = UILabel()
        brand.text = "她说"
        brand.font = .systemFont(ofSize: 13, weight: .semibold)
        brand.textColor = .secondaryLabel
        toolbar.addArrangedSubview(brand)
        toolbar.addArrangedSubview(UIView())
        modeButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        modeButton.tintColor = .systemPurple
        modeButton.showsMenuAsPrimaryAction = true
        toolbar.addArrangedSubview(modeButton)
        root.addArrangedSubview(toolbar)
        updateModeMenu()

        let compositionRow = UIStackView()
        compositionRow.alignment = .center
        compositionRow.heightAnchor.constraint(equalToConstant: 20).isActive = true
        compositionLabel.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        compositionLabel.textColor = .systemPurple
        compositionLabel.accessibilityLabel = "正在输入的拼音"
        compositionRow.addArrangedSubview(compositionLabel)
        let clear = UIButton(type: .system)
        clear.setTitle("清除", for: .normal)
        clear.titleLabel?.font = .systemFont(ofSize: 12)
        clear.addAction(UIAction { [weak self] _ in
            self?.input = ""
            self?.updateCandidates()
        }, for: .touchUpInside)
        clear.widthAnchor.constraint(equalToConstant: 42).isActive = true
        compositionRow.addArrangedSubview(clear)
        root.addArrangedSubview(compositionRow)

        candidateScroll.showsHorizontalScrollIndicator = false
        candidateScroll.heightAnchor.constraint(equalToConstant: 42).isActive = true
        candidateStack.axis = .horizontal
        candidateStack.spacing = 3
        candidateStack.translatesAutoresizingMaskIntoConstraints = false
        candidateScroll.addSubview(candidateStack)
        NSLayoutConstraint.activate([
            candidateStack.leadingAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.leadingAnchor),
            candidateStack.trailingAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.trailingAnchor),
            candidateStack.topAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.topAnchor),
            candidateStack.bottomAnchor.constraint(equalTo: candidateScroll.contentLayoutGuide.bottomAnchor),
            candidateStack.heightAnchor.constraint(equalTo: candidateScroll.frameLayoutGuide.heightAnchor)
        ])
        root.addArrangedSubview(candidateScroll)
        rows.axis = .vertical
        rows.spacing = 6
        rows.distribution = .fillEqually
        root.addArrangedSubview(rows)
        rebuildKeys()
        updateCandidates()
    }

    private func updateModeMenu() {
        let choices: [(HerWordingMode, String)] = [(.neutral, "友好表达"), (.community, "社群写法"), (.original, "保留措辞")]
        let name = choices.first { $0.0 == mode }?.1 ?? "友好表达"
        modeButton.setTitle(name + " ▾", for: .normal)
        modeButton.accessibilityLabel = "措辞选项，当前" + name
        modeButton.menu = UIMenu(children: choices.map { choice in
            UIAction(title: choice.1, state: choice.0 == mode ? .on : .off) { [weak self] _ in
                self?.mode = choice.0
                self?.updateModeMenu()
                self?.updateCandidates()
            }
        })
    }

    private func updateInputType() {
        let type = textDocumentProxy.keyboardType
        let ascii = type == .asciiCapable || type == .emailAddress || type == .URL || type == .asciiCapableNumberPad
        if ascii != forcedASCII {
            input = ""
            if ascii { languageBeforeASCII = english; english = true }
            else { english = languageBeforeASCII }
            forcedASCII = ascii
            rebuildKeys()
            updateCandidates()
        }
    }

    private func rebuildKeys() {
        rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }
        let lines: [[String]]
        if numeric {
            lines = [Array("1234567890").map(String.init),
                     symbols ? ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="] : ["-", "/", ":", ";", "(", ")", "¥", "&", "@", "\""],
                     [symbols ? "123" : "#+=", ".", ",", "?", "!", "'", "⌫"]]
        } else {
            lines = [Array("qwertyuiop").map(String.init),
                     Array("asdfghjkl").map(String.init),
                     ["⇧"] + Array("zxcvbnm").map(String.init) + ["⌫"]]
        }
        for (index, line) in lines.enumerated() {
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = 5
            if index == 1 && !numeric {
                let wrap = UIView()
                row.translatesAutoresizingMaskIntoConstraints = false
                wrap.addSubview(row)
                NSLayoutConstraint.activate([
                    row.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 12),
                    row.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -12),
                    row.topAnchor.constraint(equalTo: wrap.topAnchor),
                    row.bottomAnchor.constraint(equalTo: wrap.bottomAnchor)
                ])
                rows.addArrangedSubview(wrap)
            } else { rows.addArrangedSubview(row) }
            for key in line {
                let title = key == "⇧" && !english ? "分词" : !numeric && english && uppercase && key.count == 1 ? key.uppercased() : key
                row.addArrangedSubview(makeKey(title, action: key))
            }
        }
        let bottom = UIStackView()
        bottom.axis = .horizontal
        bottom.spacing = 5
        let number = makeKey(numeric ? "ABC" : "123", action: "layout")
        number.widthAnchor.constraint(equalToConstant: 43).isActive = true
        bottom.addArrangedSubview(number)
        if needsInputModeSwitchKey {
            let globe = makeKey("🌐", action: "globe")
            globe.accessibilityLabel = "切换键盘"
            globe.widthAnchor.constraint(equalToConstant: 38).isActive = true
            bottom.addArrangedSubview(globe)
        }
        let language = makeKey(english ? "英" : "中", action: "language")
        language.accessibilityLabel = "切换中文或英文"
        language.widthAnchor.constraint(equalToConstant: 37).isActive = true
        bottom.addArrangedSubview(language)
        let space = makeKey(english ? "space" : "空格 · 她优先", action: "space")
        space.titleLabel?.font = .systemFont(ofSize: 14)
        bottom.addArrangedSubview(space)
        let punctuation = makeKey(english ? "." : "。", action: "punctuation")
        punctuation.widthAnchor.constraint(equalToConstant: 32).isActive = true
        bottom.addArrangedSubview(punctuation)
        let enter = makeKey(returnTitle(), action: "return")
        enter.widthAnchor.constraint(equalToConstant: 50).isActive = true
        enter.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        bottom.addArrangedSubview(enter)
        rows.addArrangedSubview(bottom)
    }

    private func makeKey(_ title: String, action: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 21)
        if title == "分词" { button.titleLabel?.font = .systemFont(ofSize: 13) }
        button.setTitleColor(.label, for: .normal)
        button.backgroundColor = .secondarySystemGroupedBackground
        button.layer.cornerRadius = 6
        button.accessibilityLabel = action == "⌫" ? "删除" : title
        button.addAction(UIAction { [weak self] _ in self?.press(action) }, for: .touchUpInside)
        if action == "⌫" {
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(repeatDelete(_:)))
            longPress.minimumPressDuration = 0.35
            button.addGestureRecognizer(longPress)
        }
        if action == "globe" {
            button.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        return button
    }

    private func returnTitle() -> String {
        switch textDocumentProxy.returnKeyType {
        case .search, .google, .yahoo: return "搜索"
        case .send: return "发送"
        case .go: return "前往"
        case .done: return "完成"
        case .next: return "下一项"
        default: return "换行"
        }
    }

    private func press(_ key: String) {
        switch key {
        case "globe": break // System handler supports both tap and long press.
        case "layout": numeric.toggle(); symbols = false; rebuildKeys()
        case "#+=", "123": symbols.toggle(); rebuildKeys()
        case "language":
            guard commitAllComposition() else { return }
            english.toggle(); uppercase = false; rebuildKeys(); updateCandidates()
        case "⇧":
            if english { uppercase.toggle(); rebuildKeys() }
            else { input.append("'"); updateCandidates() }
        case "⌫": deleteOne()
        case "space":
            if input.isEmpty { textDocumentProxy.insertText(" ") }
            else { _ = commitComposition() }
        case "return":
            if input.isEmpty { textDocumentProxy.insertText("\n") }
            else { _ = commitComposition() }
        case "punctuation":
            if commitAllComposition() { textDocumentProxy.insertText(english ? "." : "。") }
        default:
            if !numeric && !english {
                guard input.count < 64 else { return }
                input.append(key)
                updateCandidates()
            } else {
                guard commitAllComposition() else { return }
                let punctuation = [",": "，", ".": "。", "?": "？", "!": "！", ";": "；", ":": "："]
                let text = !english ? punctuation[key] ?? key : uppercase ? key.uppercased() : key
                textDocumentProxy.insertText(text)
            }
        }
    }

    @objc private func repeatDelete(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            deleteOne()
            deleteTimer?.invalidate()
            deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.085, repeats: true) { [weak self] _ in self?.deleteOne() }
        } else if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            deleteTimer?.invalidate()
            deleteTimer = nil
        }
    }

    private func deleteOne() {
        if !input.isEmpty { input.removeLast(); updateCandidates() }
        else { textDocumentProxy.deleteBackward() }
    }

    @discardableResult private func commitComposition() -> Bool {
        guard !input.isEmpty else { return true }
        guard engine != nil else { return false }
        if let candidate = candidates.first { select(candidate) }
        else {
            textDocumentProxy.insertText(input)
            input = ""
            updateCandidates()
        }
        return true
    }

    private func commitAllComposition() -> Bool {
        for _ in 0..<64 {
            if input.isEmpty { return true }
            let previousCount = input.count
            if !commitComposition() || input.count >= previousCount { return false }
        }
        return input.isEmpty
    }

    private func select(_ candidate: HerCandidate) {
        textDocumentProxy.insertText(candidate.text)
        input = String(input.dropFirst(candidate.consumedInputCount))
        while input.first == "'" { input.removeFirst() }
        updateCandidates()
    }

    private func updateCandidates() {
        compositionLabel.text = input.isEmpty ? (english ? "English" : "全拼 · v 代表 ü") : input
        candidateStack.arrangedSubviews.forEach { candidateStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        candidates = input.isEmpty ? [] : engine?.candidates(for: input, mode: mode, limit: 40) ?? []
        if candidates.isEmpty {
            let hint = UILabel()
            hint.font = .systemFont(ofSize: 13)
            hint.textColor = .secondaryLabel
            hint.text = loadFailed ? "词库载入失败，请切换其他键盘后重试" : engine == nil ? "正在准备离线词库…" : input.isEmpty ? "输入拼音，左右滑动候选选词" : "暂无候选，空格可输入原拼音"
            candidateStack.addArrangedSubview(hint)
        } else {
            for (index, candidate) in candidates.enumerated() {
                let button = UIButton(type: .system)
                var configuration = UIButton.Configuration.plain()
                configuration.title = candidate.text
                configuration.subtitle = [candidate.isCompletion ? "补全" : "", candidate.annotation]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                configuration.titleAlignment = .center
                configuration.baseForegroundColor = index == 0 ? .systemPurple : .label
                configuration.contentInsets = NSDirectionalEdgeInsets(top: 1, leading: 11, bottom: 1, trailing: 11)
                configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                    var result = attributes
                    result.font = .systemFont(ofSize: 20, weight: index == 0 ? .semibold : .regular)
                    return result
                }
                configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                    var result = attributes
                    result.font = .systemFont(ofSize: 9)
                    result.foregroundColor = .secondaryLabel
                    return result
                }
                button.configuration = configuration
                button.accessibilityLabel = candidate.text + (candidate.annotation.isEmpty ? "" : "，" + candidate.annotation)
                button.addAction(UIAction { [weak self] _ in self?.select(candidate) }, for: .touchUpInside)
                candidateStack.addArrangedSubview(button)
            }
        }
        candidateScroll.setContentOffset(.zero, animated: false)
    }
}
