import UIKit

/// All composition stays inside this extension until the user selects a candidate.
/// Confirmed short words may be kept in a private local dictionary. No surrounding
/// chat text, network, clipboard or shared-container access is used.
final class KeyboardViewController: UIInputViewController {
    private var engine: HerPinyinEngine?
    private var wordMemory: HerWordMemoryStore?
    private var memoryError = ""
    private var memoryEditor: WordMemoryViewController?
    private var memoryEditorHeight: NSLayoutConstraint?
    private var performingOwnEdit = false
    private var combinedInput = ""
    private var combinedText = ""
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
    private let memoryButton = UIButton(type: .system)
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
        loadWordMemory()
        configureInterface()
        loadEngine()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let currentDocument = textDocumentProxy.documentIdentifier
        if documentID != currentDocument { clearComposition() }
        documentID = currentDocument
        if loadFailed { loadEngine() }
        if let wordMemory {
            do { try wordMemory.refresh(); memoryError = "" }
            catch { memoryError = error.localizedDescription }
        }
        updateInputType()
        updateCandidates()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        deleteTimer?.invalidate()
        deleteTimer = nil
        clearComposition()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let compactHeight = view.bounds.width > 600
        let desiredHeight: CGFloat = memoryEditor == nil ? (compactHeight ? 264 : 328) : (compactHeight ? 410 : 520)
        let height = min(desiredHeight, max(264, UIScreen.main.bounds.height - (compactHeight ? 48 : 120)))
        memoryEditorHeight?.constant = min(compactHeight ? 140 : 190, max(90, height - 310))
        if heightConstraint?.constant != height { heightConstraint?.constant = height }
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        if documentID != textDocumentProxy.documentIdentifier {
            clearComposition()
            documentID = textDocumentProxy.documentIdentifier
            updateCandidates()
        }
        updateInputType()
    }

    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        clearForHostChange()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        clearForHostChange()
    }

    private func clearForHostChange() {
        // Some hosts may deliver these callbacks asynchronously after our own
        // insertText call. Without reading host text, they cannot be reliably
        // distinguished from a real cursor/document edit. Prefer discarding an
        // uncommitted composition over inserting it into a changed host field.
        // This can clear remaining pinyin during segmented name selection; real
        // device/host validation is still required. No host text is deleted.
        if !performingOwnEdit && memoryEditor == nil { clearComposition(); updateCandidates() }
    }

    private func clearComposition() {
        input = ""
        combinedInput = ""
        combinedText = ""
    }

    private func loadWordMemory() {
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HerWordsKeyboardMemory", isDirectory: true)
            wordMemory = try HerWordMemoryStore(directory: directory)
            memoryError = ""
        } catch { memoryError = error.localizedDescription }
    }

    private func toggleWordMemory() {
        clearComposition()
        if let editor = memoryEditor {
            editor.willMove(toParent: nil)
            root.removeArrangedSubview(editor.view)
            editor.view.removeFromSuperview()
            editor.removeFromParent()
            memoryEditor = nil
            memoryEditorHeight = nil
            memoryButton.setTitle("词库", for: .normal)
            if forcedASCII { english = true }
        } else {
            if wordMemory == nil {
                loadWordMemory()
                if wordMemory != nil { loadEngine() }
            }
            guard let wordMemory else { updateCandidates(); return }
            let editor = WordMemoryViewController(store: wordMemory)
            editor.onClose = { [weak self] in self?.toggleWordMemory() }
            editor.onFieldChanged = { [weak self] in
                self?.clearComposition()
                self?.rebuildKeys()
                self?.updateCandidates()
            }
            editor.onStoreChanged = { [weak self] in self?.memoryError = ""; self?.updateCandidates() }
            addChild(editor)
            root.insertArrangedSubview(editor.view, at: 1)
            memoryEditorHeight = editor.view.heightAnchor.constraint(equalToConstant: 190)
            memoryEditorHeight?.isActive = true
            editor.didMove(toParent: self)
            memoryEditor = editor
            memoryButton.setTitle("收起词库", for: .normal)
        }
        view.setNeedsLayout()
        rebuildKeys()
        updateCandidates()
    }

    private func insertText(_ text: String) {
        if let editor = memoryEditor { editor.insertText(text); return }
        performingOwnEdit = true
        textDocumentProxy.insertText(text)
        performingOwnEdit = false
    }

    private func canRemember(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 64 else { return false }
        let han = text.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) }
        if han && text.count > 16 { return false }
        return text.unicodeScalars.allSatisfy {
            (0x3400...0x9fff).contains($0.value) || (65...90).contains($0.value)
                || (97...122).contains($0.value) || (48...57).contains($0.value)
                || $0 == "'" || $0 == "-" || $0 == "_"
        }
    }

    private func learn(_ text: String, reading: String) {
        guard memoryEditor == nil, !forcedASCII, let wordMemory, canRemember(text) else { return }
        do { try wordMemory.learn(text: text, input: reading); memoryError = "" }
        catch { memoryError = error.localizedDescription }
    }

    private func loadEngine() {
        guard !engineLoading else { return }
        engineLoading = true
        loadFailed = false
        let memory = wordMemory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                guard let lexicon = Bundle.main.url(forResource: "lexicon", withExtension: "json"),
                      let rules = Bundle.main.url(forResource: "rules", withExtension: "json") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let engine = try HerPinyinEngine(lexiconData: Data(contentsOf: lexicon),
                                                rulesData: Data(contentsOf: rules), memory: memory)
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
        memoryButton.setTitle("词库", for: .normal)
        memoryButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        memoryButton.accessibilityLabel = "管理本地词库、删除记忆与不再推荐"
        memoryButton.addAction(UIAction { [weak self] _ in self?.toggleWordMemory() }, for: .touchUpInside)
        toolbar.addArrangedSubview(memoryButton)
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
            guard let self else { return }
            if self.input.isEmpty { self.memoryEditor?.clearCurrentField() }
            self.clearComposition()
            self.updateCandidates()
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
        let ascii: Bool
        switch type {
        case .asciiCapable, .emailAddress, .URL, .asciiCapableNumberPad,
             .numberPad, .decimalPad, .phonePad, .numbersAndPunctuation:
            ascii = true
        default: ascii = false
        }
        if ascii != forcedASCII {
            clearComposition()
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
        language.isEnabled = !forcedASCII || memoryEditor != nil
        language.accessibilityHint = language.isEnabled ? "" : "此输入框使用英文或数字，不提供个人词库候选"
        language.widthAnchor.constraint(equalToConstant: 37).isActive = true
        bottom.addArrangedSubview(language)
        let space = makeKey(english || memoryEditor?.isReadingField == true ? "space" : "空格 · 她优先", action: "space")
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
        let editingReading = memoryEditor?.isReadingField == true
        switch key {
        case "globe": clearComposition() // System handler supports both tap and long press.
        case "layout": numeric.toggle(); symbols = false; rebuildKeys()
        case "#+=", "123": symbols.toggle(); rebuildKeys()
        case "language":
            guard !forcedASCII || memoryEditor != nil else { return }
            guard commitAllComposition() else { return }
            english.toggle(); uppercase = false; rebuildKeys(); updateCandidates()
        case "⇧":
            if english || editingReading { uppercase.toggle(); rebuildKeys() }
            else { combinedInput = ""; combinedText = ""; input.append("'"); updateCandidates() }
        case "⌫": deleteOne()
        case "space":
            if editingReading { insertText(" ") }
            else if english && !forcedASCII { commitEnglish(separator: " ") }
            else if input.isEmpty { insertText(" ") }
            else { _ = commitComposition() }
        case "return":
            if memoryEditor != nil {
                if input.isEmpty { memoryEditor?.acceptReturn() }
                else if english { commitEnglish() }
                else { _ = commitComposition() }
            } else if english && !forcedASCII { commitEnglish(separator: "\n") }
            else if input.isEmpty { insertText("\n") }
            else { _ = commitComposition() }
        case "punctuation":
            if english && !forcedASCII { commitEnglish(separator: ".") }
            else if commitAllComposition() { insertText(english ? "." : "。") }
        default:
            if editingReading {
                insertText(uppercase ? key.uppercased() : key)
            } else if !numeric && !english && (!forcedASCII || memoryEditor != nil) {
                guard input.count < 64 else { return }
                combinedInput = ""
                combinedText = ""
                input.append(key)
                updateCandidates()
            } else {
                let punctuation = [",": "，", ".": "。", "?": "？", "!": "！", ";": "；", ":": "："]
                let text = !english ? punctuation[key] ?? key : uppercase ? key.uppercased() : key
                let tokenCharacter = text.unicodeScalars.allSatisfy {
                    (65...90).contains($0.value) || (97...122).contains($0.value)
                        || (48...57).contains($0.value) || $0 == "'" || $0 == "-" || $0 == "_"
                }
                if english && !forcedASCII && tokenCharacter {
                    guard input.count < 64 else { return }
                    input += text
                    updateCandidates()
                } else if english && !forcedASCII { commitEnglish(separator: text) }
                else if commitAllComposition() { insertText(text) }
            }
        }
    }

    private func commitEnglish(separator: String = "") {
        let text = input
        clearComposition()
        if !text.isEmpty { insertText(text); learn(text, reading: text) }
        if !separator.isEmpty { insertText(separator) }
        updateCandidates()
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
        combinedInput = ""
        combinedText = ""
        if !input.isEmpty { input.removeLast(); updateCandidates() }
        else if let memoryEditor { memoryEditor.deleteBackward() }
        else {
            performingOwnEdit = true
            textDocumentProxy.deleteBackward()
            performingOwnEdit = false
        }
    }

    @discardableResult private func commitComposition() -> Bool {
        guard !input.isEmpty else { return true }
        if english && !forcedASCII { commitEnglish(); return true }
        guard engine != nil else { return false }
        if let candidate = candidates.first { select(candidate) }
        else {
            let raw = input
            clearComposition()
            insertText(raw)
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
        guard !forcedASCII || memoryEditor != nil else { clearComposition(); updateCandidates(); return }
        let before = input
        guard !before.isEmpty else { return }
        let consumed = String(before.prefix(candidate.consumedInputCount))
        input = String(before.dropFirst(candidate.consumedInputCount))
        while input.first == "'" { input.removeFirst() }
        if !english {
            if combinedInput.isEmpty && !input.isEmpty {
                combinedInput = before
                combinedText = candidate.originalText
            } else if !combinedInput.isEmpty { combinedText += candidate.originalText }
        }
        let wholeReading = combinedInput
        let wholeWord = combinedText
        if input.isEmpty { combinedInput = ""; combinedText = "" }
        insertText(candidate.text)
        learn(candidate.originalText, reading: consumed)
        if input.isEmpty && !wholeReading.isEmpty { learn(wholeWord, reading: wholeReading) }
        updateCandidates()
    }

    private func candidateMenu(_ candidate: HerCandidate) -> UIMenu? {
        guard let wordMemory else { return nil }
        return UIMenu(children: [
            UIAction(title: "忘记使用记忆", image: UIImage(systemName: "eraser"), attributes: .destructive) { [weak self] _ in
                do { try wordMemory.forget(text: candidate.originalText); self?.memoryError = "" }
                catch { self?.memoryError = error.localizedDescription }
                self?.updateCandidates()
            },
            UIAction(title: "不再推荐这个词", image: UIImage(systemName: "eye.slash"), attributes: .destructive) { [weak self] _ in
                do {
                    // Block source and displayed spellings so a wording-mode
                    // change cannot reveal the same candidate again.
                    try wordMemory.block(text: candidate.originalText)
                    if candidate.originalText != candidate.text { try wordMemory.block(text: candidate.text) }
                    self?.memoryError = ""
                }
                catch { self?.memoryError = error.localizedDescription }
                self?.updateCandidates()
            }
        ])
    }

    private func updateCandidates() {
        compositionLabel.text = !memoryError.isEmpty ? "本地词库：" + memoryError : input.isEmpty
            ? (memoryEditor?.isReadingField == true ? "拼音／缩写 · 直接输入英文" : english ? "英文词 · 空格确认，点击候选补全" : "全拼 · v 代表 ü") : input
        compositionLabel.textColor = memoryError.isEmpty ? .systemPurple : .systemRed
        memoryButton.tintColor = memoryError.isEmpty ? .systemPurple : .systemRed
        candidateStack.arrangedSubviews.forEach { candidateStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        if input.isEmpty || memoryEditor?.isReadingField == true || (forcedASCII && memoryEditor == nil) { candidates = [] }
        else if english {
            var seen = Set<String>()
            candidates = (wordMemory?.suggestions(for: input, limit: 40) ?? []).compactMap { item in
                let text = engine?.rewrite(item.text, mode: mode) ?? item.text
                guard wordMemory?.isBlocked(text) != true, seen.insert(text).inserted else { return nil }
                return HerCandidate(text: text, originalText: item.text, consumedInputCount: input.count,
                                    annotation: "本地词库", isCompletion: text != input, score: Double(item.count))
            }
        } else { candidates = engine?.candidates(for: input, mode: mode, limit: 40) ?? [] }
        if candidates.isEmpty {
            let hint = UILabel()
            hint.font = .systemFont(ofSize: 13)
            hint.textColor = .secondaryLabel
            hint.text = loadFailed ? "词库载入失败，请切换其他键盘后重试" : engine == nil ? "正在准备离线词库…" : input.isEmpty ? "长按候选可忘记或不再推荐；词库可手动添加人名" : english ? "空格确认原词；词库补全需点击选择" : "暂无候选，空格可输入原拼音"
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
                button.menu = candidateMenu(candidate)
                button.accessibilityLabel = candidate.text + (candidate.annotation.isEmpty ? "" : "，" + candidate.annotation)
                button.addAction(UIAction { [weak self] _ in self?.select(candidate) }, for: .touchUpInside)
                candidateStack.addArrangedSubview(button)
            }
        }
        candidateScroll.setContentOffset(.zero, animated: false)
    }
}
