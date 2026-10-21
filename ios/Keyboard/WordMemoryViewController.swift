import UIKit

/// This editor uses the extension's own keys. It never asks the host for its
/// surrounding text, and needs neither a shared container nor full access.
final class WordMemoryViewController: UIViewController {
    private enum Field { case word, input, search }
    private let store: HerWordMemoryStore
    private var field: Field = .word
    private var word = ""
    private var reading = ""
    private var query = ""
    private var blockedTab = false
    private var revealingBlockedWords = false
    private var visibleLimit = 40
    private var confirmingClear = false
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let wordButton = UIButton(type: .system)
    private let readingButton = UIButton(type: .system)
    private let searchButton = UIButton(type: .system)
    private let status = UILabel()
    private let learning = UISwitch()
    private let tabs = UISegmentedControl(items: ["已记住", "不再推荐"])
    private let list = UIStackView()
    private let saveButton = UIButton(type: .system)
    var onFieldChanged: (() -> Void)?
    var onStoreChanged: (() -> Void)?
    var onClose: (() -> Void)?
    var isReadingField: Bool { field == .input }

    init(store: HerWordMemoryStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemGroupedBackground
        view.layer.cornerRadius = 8
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        stack.axis = .vertical
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -8),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -16)
        ])
        let heading = UIStackView()
        heading.alignment = .center
        let title = UILabel()
        title.text = "本地词库 · 仅此设备"
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        heading.addArrangedSubview(title)
        heading.addArrangedSubview(UIView())
        heading.addArrangedSubview(action("完成") { [weak self] in self?.onClose?() })
        stack.addArrangedSubview(heading)
        let explanation = UILabel()
        explanation.text = "只保存确认输入的短词，不读取聊天记录。忘记会删除记忆；不再推荐还会隐藏含该词的候选，并阻止重新学习。"
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabel
        explanation.numberOfLines = 0
        stack.addArrangedSubview(explanation)
        let learningRow = UIStackView()
        learningRow.alignment = .center
        let learningTitle = UILabel()
        learningTitle.text = "自动记住确认输入的词"
        learningTitle.font = .systemFont(ofSize: 13)
        learningRow.addArrangedSubview(learningTitle)
        learningRow.addArrangedSubview(UIView())
        learning.isOn = store.learningEnabled
        learning.accessibilityLabel = "自动记住确认输入的词"
        learning.addTarget(self, action: #selector(changeLearning), for: .valueChanged)
        learningRow.addArrangedSubview(learning)
        stack.addArrangedSubview(learningRow)
        tabs.selectedSegmentIndex = 0
        tabs.addTarget(self, action: #selector(changeTab), for: .valueChanged)
        stack.addArrangedSubview(tabs)
        configureEditor(wordButton, field: .word)
        configureEditor(readingButton, field: .input)
        configureEditor(searchButton, field: .search)
        stack.addArrangedSubview(wordButton)
        stack.addArrangedSubview(readingButton)
        saveButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        saveButton.addAction(UIAction { [weak self] _ in self?.save() }, for: .touchUpInside)
        stack.addArrangedSubview(saveButton)
        stack.addArrangedSubview(searchButton)
        status.font = .systemFont(ofSize: 11)
        status.numberOfLines = 0
        status.textColor = .secondaryLabel
        status.text = "点击上面的词语、拼音或搜索栏，再使用下方键盘输入。"
        stack.addArrangedSubview(status)
        list.axis = .vertical
        list.spacing = 5
        stack.addArrangedSubview(list)
        refreshEditors()
        refreshList()
    }

    private func action(_ title: String, destructive: Bool = false, handler: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 12)
        if destructive { button.tintColor = .systemRed }
        button.addAction(UIAction { _ in handler() }, for: .touchUpInside)
        return button
    }

    private func configureEditor(_ button: UIButton, field selected: Field) {
        button.titleLabel?.font = .systemFont(ofSize: 13)
        button.titleLabel?.numberOfLines = 2
        button.contentHorizontalAlignment = .leading
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 7, bottom: 6, right: 7)
        button.layer.cornerRadius = 5
        button.layer.borderWidth = 1
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.field = selected
            self.confirmingClear = false
            self.refreshEditors()
            self.onFieldChanged?()
        }, for: .touchUpInside)
    }

    private func refreshEditors() {
        wordButton.setTitle("词语：" + (word.isEmpty ? "点此输入人名或英文词" : word), for: .normal)
        readingButton.setTitle("拼音／缩写：" + (reading.isEmpty ? "如 wangxiaoming、wxm、github" : reading), for: .normal)
        searchButton.setTitle("搜索：" + (query.isEmpty ? "点此输入要找的词" : query), for: .normal)
        for (button, value) in [(wordButton, Field.word), (readingButton, Field.input), (searchButton, Field.search)] {
            button.layer.borderColor = (field == value ? UIColor.systemPurple : UIColor.separator).cgColor
            button.backgroundColor = field == value ? UIColor.systemPurple.withAlphaComponent(0.08) : .clear
            button.accessibilityTraits = field == value ? [.button, .selected] : [.button]
            button.accessibilityValue = field == value ? "正在编辑，使用下方键盘输入" : "点击后使用下方键盘编辑"
        }
        readingButton.isHidden = blockedTab
        saveButton.setTitle(blockedTab ? "加入不再推荐" : "记住这个词", for: .normal)
    }

    func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        switch field {
        case .word: if word.count + text.count <= 64 { word += text }
        case .input: if reading.count + text.count <= 128 { reading += text }
        case .search: if query.count + text.count <= 64 { query += text }
        }
        confirmingClear = false
        refreshEditors()
        if field == .search { visibleLimit = 40; refreshList() }
    }

    func deleteBackward() {
        switch field {
        case .word: if !word.isEmpty { word.removeLast() }
        case .input: if !reading.isEmpty { reading.removeLast() }
        case .search: if !query.isEmpty { query.removeLast() }
        }
        confirmingClear = false
        refreshEditors()
        if field == .search { visibleLimit = 40; refreshList() }
    }

    func acceptReturn() {
        if field == .word && !blockedTab {
            field = .input
            refreshEditors()
            onFieldChanged?()
        } else if field != .search { save() }
    }

    func clearCurrentField() {
        switch field {
        case .word: word = ""
        case .input: reading = ""
        case .search: query = ""
        }
        refreshEditors()
        refreshList()
    }

    @objc private func changeLearning() {
        mutate(success: learning.isOn ? "已开启自动记忆。" : "已暂停自动记忆；仍可手动添加。") {
            try store.setLearningEnabled(learning.isOn)
        }
        learning.isOn = store.learningEnabled
    }

    @objc private func changeTab() {
        blockedTab = tabs.selectedSegmentIndex == 1
        revealingBlockedWords = false
        visibleLimit = 40
        confirmingClear = false
        if blockedTab && field == .input { field = .word; onFieldChanged?() }
        refreshEditors()
        refreshList()
    }

    private func save() {
        let text = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = reading.trimmingCharacters(in: .whitespacesAndNewlines)
        let success = blockedTab ? "已停止推荐这个词；需要恢复时，可主动展开隐藏词语。" : "已保存到本地词库。"
        if mutate(success: success, operation: {
            if blockedTab { try store.block(text: text) }
            else { try store.remember(text: text, input: key) }
        }) {
            word = ""
            reading = ""
            refreshEditors()
        }
    }

    @discardableResult private func mutate(success: String, operation: () throws -> Void) -> Bool {
        do {
            try operation()
            status.textColor = .secondaryLabel
            status.text = success
            confirmingClear = false
            refreshList()
            onStoreChanged?()
            return true
        } catch {
            status.textColor = .systemRed
            status.text = "未保存：" + error.localizedDescription
            return false
        }
    }

    private func refreshList() {
        list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if blockedTab {
            let hiddenCount = UILabel()
            hiddenCount.font = .systemFont(ofSize: 11)
            hiddenCount.textColor = .secondaryLabel
            hiddenCount.text = "已隐藏 " + String(store.blockedWords.count) + " 个词，默认不显示内容。"
            list.addArrangedSubview(hiddenCount)
            list.addArrangedSubview(action(revealingBlockedWords ? "收起隐藏词语" : "查看隐藏词语") { [weak self] in
                guard let self else { return }
                self.revealingBlockedWords.toggle()
                self.refreshList()
            })
            guard revealingBlockedWords else { return }
            let words = store.blockedWords.filter { term.isEmpty || $0.localizedCaseInsensitiveContains(term) }
            for text in words.prefix(visibleLimit) {
                let row = itemRow(text, detail: "不再推荐")
                row.addArrangedSubview(action("恢复推荐") { [weak self] in
                    guard let self else { return }
                    self.mutate(success: "已恢复推荐；不会恢复之前的使用记忆。") { try self.store.unblock(text: text) }
                })
                list.addArrangedSubview(row)
            }
            addCount(words.count)
        } else {
            let words = store.entries.filter {
                term.isEmpty || $0.text.localizedCaseInsensitiveContains(term) || $0.input.localizedCaseInsensitiveContains(term)
            }
            for item in words.prefix(visibleLimit) {
                let row = itemRow(item.text, detail: item.input + " · 已确认 " + String(item.count) + " 次")
                row.addArrangedSubview(action("忘记", destructive: true) { [weak self] in
                    guard let self else { return }
                    self.mutate(success: "已忘记使用记忆。基础词典仍可能提供这个词；可选择不再推荐。") {
                        try self.store.forget(text: item.text)
                    }
                })
                row.addArrangedSubview(action("不再推荐", destructive: true) { [weak self] in
                    guard let self else { return }
                    self.mutate(success: "已删除记忆并停止推荐。") { try self.store.block(text: item.text) }
                })
                list.addArrangedSubview(row)
            }
            addCount(words.count)
            let clear = action(confirmingClear ? "再次点击：清空全部使用记忆" : "清空全部使用记忆", destructive: true) { [weak self] in
                guard let self else { return }
                if self.confirmingClear {
                    self.mutate(success: "已清空使用记忆；不再推荐列表仍然保留。") { try self.store.clearLearned() }
                } else {
                    self.confirmingClear = true
                    self.status.text = "再次点击清空即可删除全部使用记忆；此操作无法撤销。"
                    self.refreshList()
                }
            }
            clear.isEnabled = !store.entries.isEmpty
            list.addArrangedSubview(clear)
        }
    }

    private func itemRow(_ text: String, detail: String) -> UIStackView {
        let row = UIStackView()
        row.alignment = .center
        row.spacing = 5
        let labels = UIStackView()
        labels.axis = .vertical
        let title = UILabel()
        title.text = text
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.numberOfLines = 2
        let subtitle = UILabel()
        subtitle.text = detail
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 2
        labels.addArrangedSubview(title)
        labels.addArrangedSubview(subtitle)
        row.addArrangedSubview(labels)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func addCount(_ count: Int) {
        let label = UILabel()
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabel
        label.text = count == 0 ? "没有匹配的词。" : "显示 " + String(min(visibleLimit, count)) + " / " + String(count) + " 个词"
        list.addArrangedSubview(label)
        if count > visibleLimit {
            list.addArrangedSubview(action("再显示 40 个") { [weak self] in
                guard let self else { return }
                self.visibleLimit += 40
                self.refreshList()
            })
        }
    }
}
