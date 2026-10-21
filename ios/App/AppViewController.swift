import UIKit

final class AppViewController: UIViewController, UITextViewDelegate {
    private var engine: HerPinyinEngine?
    private let speech = SpeechTranscriber()
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let trialTextView = UITextView()
    private let originalTextView = UITextView()
    private let resultTextView = UITextView()
    private let modeControl = UISegmentedControl(items: ["中性表达", "社群写法", "保留措辞"])
    private let routeControl = UISegmentedControl(items: ["仅设备端", "允许联网"])
    private let modeHint = UILabel()
    private let routeHint = UILabel()
    private let speechStatus = UILabel()
    private let resourceStatus = UILabel()
    private let recordButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private var recordingPrefix = ""
    private var wordingMode: HerWordingMode = .neutral
    private var latestResult = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "她说"
        buildInterface()
        loadEngine()
        speech.onUpdate = { [weak self] update in self?.applySpeechUpdate(update) }
        updateModeHint()
        updateRouteHint()
        updateResult()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSpeechForBackground()
    }

    func stopSpeechForBackground() {
        speech.cancel(message: "已停止录音，已保留当前文字。回到 App 后可继续编辑或重新录音。")
    }

    private func buildInterface() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        view.addSubview(scrollView)
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -32),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40)
        ])

        stack.addArrangedSubview(label("她说", style: .largeTitle, color: .label))
        stack.addArrangedSubview(label("默认她 · 中性表达优先", style: .title3, color: .secondaryLabel))
        stack.addArrangedSubview(sectionTitle("把「她说键盘」加入 iPhone"))
        stack.addArrangedSubview(label("1. 打开系统设置 → 通用 → 键盘 → 键盘\n2. 轻点「添加新键盘」，选择「她说键盘」\n3. 输入时长按地球图标，切换到她说键盘", style: .body))
        stack.addArrangedSubview(label("键盘无需「允许完全访问」。密码框、部分电话号码框及限制第三方键盘的 App 会使用系统键盘。", style: .footnote, color: .secondaryLabel))

        stack.addArrangedSubview(sectionTitle("键盘试打"))
        stack.addArrangedSubview(label("轻点下方输入区，切换到「她说键盘」试打。这里保留实际输入的文字。", style: .footnote, color: .secondaryLabel))
        configureTextView(trialTextView, editable: true, height: 110, accessibility: "键盘试打输入区")
        stack.addArrangedSubview(trialTextView)

        stack.addArrangedSubview(sectionTitle("语音与文字整理"))
        stack.addArrangedSubview(label("可直接编辑或粘贴原文，也可录音转文字。检查结果后复制回要使用的 App。", style: .body))
        modeControl.selectedSegmentIndex = 0
        modeControl.accessibilityLabel = "本 App 的措辞模式"
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        stack.addArrangedSubview(modeControl)
        configureHint(modeHint)
        stack.addArrangedSubview(modeHint)

        routeControl.selectedSegmentIndex = 0
        routeControl.accessibilityLabel = "语音识别方式"
        routeControl.addTarget(self, action: #selector(routeChanged), for: .valueChanged)
        stack.addArrangedSubview(routeControl)
        configureHint(routeHint)
        stack.addArrangedSubview(routeHint)

        configureButton(recordButton, title: "开始录音", prominent: true)
        recordButton.addTarget(self, action: #selector(recordPressed), for: .touchUpInside)
        configureButton(cancelButton, title: "取消录音", prominent: false)
        cancelButton.addTarget(self, action: #selector(cancelPressed), for: .touchUpInside)
        cancelButton.isEnabled = false
        let actions = UIStackView(arrangedSubviews: [recordButton, cancelButton])
        actions.axis = .horizontal
        actions.spacing = 12
        actions.distribution = .fillEqually
        stack.addArrangedSubview(actions)
        configureHint(speechStatus)
        speechStatus.text = "点击开始后才会申请麦克风和语音识别权限。"
        speechStatus.accessibilityTraits.insert(.updatesFrequently)
        stack.addArrangedSubview(speechStatus)

        stack.addArrangedSubview(label("原文 · 可编辑", style: .headline))
        configureTextView(originalTextView, editable: true, height: 150, accessibility: "语音或粘贴原文，可编辑")
        originalTextView.delegate = self
        stack.addArrangedSubview(originalTextView)
        stack.addArrangedSubview(label("录音会接在已有原文后；录音时暂不能编辑，停止后可修改。", style: .footnote, color: .secondaryLabel))

        stack.addArrangedSubview(label("整理结果", style: .headline))
        configureTextView(resultTextView, editable: false, height: 150, accessibility: "整理后的文字结果")
        stack.addArrangedSubview(resultTextView)
        configureHint(resourceStatus)
        resourceStatus.textColor = .systemRed
        resourceStatus.isHidden = true
        stack.addArrangedSubview(resourceStatus)
        configureButton(copyButton, title: "复制结果", prominent: true)
        copyButton.addTarget(self, action: #selector(copyResult), for: .touchUpInside)
        stack.addArrangedSubview(copyButton)
        stack.addArrangedSubview(label("按词包规则调整措辞，不能判断所有引文与专名；请在使用前检查。语音录制在这个 App 内进行，键盘不录音。", style: .footnote, color: .secondaryLabel))
    }

    private func label(_ text: String, style: UIFont.TextStyle, color: UIColor = .label) -> UILabel {
        let result = UILabel()
        result.text = text
        result.font = .preferredFont(forTextStyle: style)
        result.adjustsFontForContentSizeCategory = true
        result.textColor = color
        result.numberOfLines = 0
        return result
    }

    private func sectionTitle(_ text: String) -> UILabel {
        let result = label(text, style: .title2)
        result.accessibilityTraits.insert(.header)
        return result
    }

    private func configureHint(_ label: UILabel) {
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
    }

    private func configureTextView(_ textView: UITextView, editable: Bool, height: CGFloat, accessibility: String) {
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 12
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.layer.borderWidth = 0.5
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        textView.isEditable = editable
        textView.isSelectable = true
        textView.accessibilityLabel = accessibility
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.heightAnchor.constraint(equalToConstant: height).isActive = true
        if editable {
            let toolbar = UIToolbar()
            toolbar.sizeToFit()
            toolbar.items = [
                UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(dismissEditing))
            ]
            textView.inputAccessoryView = toolbar
        }
    }

    private func configureButton(_ button: UIButton, title: String, prominent: Bool) {
        var configuration = prominent ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        configuration.title = title
        configuration.baseBackgroundColor = .systemPurple
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        button.configuration = configuration
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
    }

    private func loadEngine() {
        do {
            guard let lexiconURL = Bundle.main.url(forResource: "lexicon", withExtension: "json"),
                  let rulesURL = Bundle.main.url(forResource: "rules", withExtension: "json") else {
                throw NSError(domain: "HerWords.Resources", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "安装包缺少离线词包。"])
            }
            engine = try HerPinyinEngine(lexiconData: Data(contentsOf: lexiconURL),
                                        rulesData: Data(contentsOf: rulesURL))
        } catch {
            resourceStatus.text = "文字改写暂不可用：" + error.localizedDescription
            resourceStatus.isHidden = false
        }
    }

    @objc private func modeChanged() {
        switch modeControl.selectedSegmentIndex {
        case 1: wordingMode = .community
        case 2: wordingMode = .original
        default: wordingMode = .neutral
        }
        updateModeHint()
        updateResult()
    }

    private func updateModeHint() {
        let detail: String
        switch wordingMode {
        case .neutral: detail = "默认采用中性表达。"
        case .community: detail = "采用可选社群借字；这些写法不是统一规范。"
        case .original: detail = "保留原措辞，仍将「他／他们」写作「她／她们」。"
        }
        modeHint.text = detail + "这里的选择只影响主 App，键盘里的模式需单独选择。"
    }

    @objc private func routeChanged() {
        updateRouteHint()
    }

    private func updateRouteHint() {
        routeHint.text = routeControl.selectedSegmentIndex == 0
            ? "仅设备端：不支持中文设备端识别时会停下，不会自动改用联网识别。"
            : "允许联网：Apple 可能通过服务器处理音频，需要网络；请按需要选择。"
    }

    @objc private func recordPressed() {
        switch speech.state {
        case .idle:
            view.endEditing(true)
            recordingPrefix = originalTextView.text ?? ""
            if !recordingPrefix.isEmpty && !recordingPrefix.hasSuffix("\n") {
                recordingPrefix += "\n"
            }
            speech.start(route: routeControl.selectedSegmentIndex == 0 ? .onDevice : .allowNetwork)
        case .listening:
            speech.stop()
        case .authorizing, .finishing:
            break
        }
    }

    @objc private func cancelPressed() {
        speech.cancel()
    }

    private func applySpeechUpdate(_ update: SpeechTranscriber.Update) {
        if !update.transcript.isEmpty {
            originalTextView.text = recordingPrefix + update.transcript
            updateResult()
        }
        originalTextView.isEditable = !update.state.isBusy
        routeControl.isEnabled = !update.state.isBusy
        cancelButton.isEnabled = update.state.isBusy
        speechStatus.text = update.message
        var configuration = recordButton.configuration
        switch update.state {
        case .idle:
            configuration?.title = "开始录音"
            recordButton.isEnabled = true
        case .authorizing:
            configuration?.title = "等待授权…"
            recordButton.isEnabled = false
        case .listening:
            configuration?.title = "停止录音"
            recordButton.isEnabled = true
        case .finishing:
            configuration?.title = "整理中…"
            recordButton.isEnabled = false
        }
        recordButton.configuration = configuration
    }

    func textViewDidChange(_ textView: UITextView) {
        if textView === originalTextView { updateResult() }
    }

    private func updateResult() {
        guard let engine = engine else {
            latestResult = ""
            resultTextView.text = ""
            copyButton.isEnabled = false
            return
        }
        latestResult = engine.rewrite(originalTextView.text ?? "", mode: wordingMode)
        resultTextView.text = latestResult
        copyButton.isEnabled = !latestResult.isEmpty
    }

    @objc private func copyResult() {
        guard !latestResult.isEmpty else { return }
        UIPasteboard.general.string = latestResult
        var configuration = copyButton.configuration
        configuration?.title = "已复制"
        copyButton.configuration = configuration
        UIAccessibility.post(notification: .announcement, argument: "结果已复制")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            var configuration = self.copyButton.configuration
            configuration?.title = "复制结果"
            self.copyButton.configuration = configuration
        }
    }

    @objc private func dismissEditing() {
        view.endEditing(true)
    }
}
