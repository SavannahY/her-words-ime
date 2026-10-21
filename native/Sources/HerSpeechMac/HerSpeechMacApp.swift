import AppKit
import Darwin
import HerBilingualASR
import HerSpeechTextCore
import SwiftUI

@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: MacSpeechModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.shutdown()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
@MainActor
private enum MacSpeechLauncher {
    static func main() {
        if CommandLine.arguments.contains("--check-resources") {
            do {
                for name in ["rules.json", "profiles.json", "asr-model.json", "Speech-Notice.txt",
                             "Sherpa-LICENSE.txt", "ONNXRuntime-LICENSE.txt", "ONNXRuntime-ThirdPartyNotices.txt"] {
                    let filename = name as NSString
                    guard let url = Bundle.main.url(forResource: filename.deletingPathExtension,
                                                    withExtension: filename.pathExtension),
                          !(try Data(contentsOf: url)).isEmpty else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                }
                let rules = Bundle.main.url(forResource: "rules", withExtension: "json")!
                _ = try HerSpeechWording(rulesData: Data(contentsOf: rules))
                let store = try HerASRModelStore()
                print("Bundle resources verified; model: \(store.manifest.id) @ \(store.manifest.revision)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data(("资源自检失败：" + error.localizedDescription + "\n").utf8))
                exit(1)
            }
        }
        HerSpeechMacApp.main()
    }
}

@MainActor
struct HerSpeechMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @StateObject private var model = MacSpeechModel()

    var body: some Scene {
        Window("她说语音", id: "main") {
            MacSpeechView(model: model)
                .onAppear { delegate.model = model }
                .onDisappear { model.shutdown() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    model.resignActive()
                }
        }
        .defaultSize(width: 790, height: 850)
    }
}

private struct MacSpeechView: View {
    @ObservedObject var model: MacSpeechModel
    @State private var showWordMemory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("她说语音").font(.largeTitle.bold())
                Text("本机中英双语转写 · 默认她 · 中性表达优先")
                    .font(.title3).foregroundStyle(.secondary)
                Text("先下载模型，再点击开始。离开 App 或关闭窗口会停止录音；检查结果后复制到目标 App。")
                GroupBox("离线模型") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.downloadStatus).frame(maxWidth: .infinity, alignment: .leading)
                        if model.isDownloading { ProgressView(value: model.downloadFraction) }
                        Button(model.isDownloading ? "取消模型下载" : model.modelReady ? "校验或重新下载模型" : "下载离线中英模型 · 约 60 MB") {
                            model.downloadModel()
                        }.disabled(model.state.isBusy)
                    }.padding(6)
                }
                HStack {
                    Picker("措辞", selection: $model.mode) {
                        Text("中性表达").tag(HerWordingMode.neutral)
                        Text("社群写法").tag(HerWordingMode.community)
                        Text("保留措辞").tag(HerWordingMode.original)
                    }.pickerStyle(.segmented)
                }
                Text("三种模式都在最后将中文「他／它」改为「她」，保留英文代词、网址、邮箱和显式代码。社群借字是个人选择，不代表规范。")
                    .font(.caption).foregroundStyle(.secondary)
                GroupBox("词汇提示") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("启用词汇提示", isOn: $model.hotwordsEnabled)
                        Picker("词汇配置", selection: $model.profile) {
                            Text("常规").tag("neutral")
                            Text("中文与英文").tag("contextual")
                            Text("技术词").tag("hotword")
                        }.pickerStyle(.segmented)
                        TextField("追加专名，用逗号或分号分隔", text: $model.customHotwords)
                            .textFieldStyle(.roundedBorder)
                        Button("管理本地词库与不再推荐的名字") { showWordMemory = true }
                        Text("已保存的人名和英文词也会用作语音提示，可以在本地词库删除或隐藏。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("提示只调整识别概率，不能保证出现。英文保持原文，不进行翻译。每项最多 80 字，最多使用 128 项。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(6)
                }.disabled(model.state.isBusy)
                HStack(spacing: 12) {
                    Button(recordTitle) {
                        if model.state == .listening { model.stopRecording() }
                        else { model.startRecording() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!(model.canStart || model.state == .listening))
                    Button("取消录音") { model.cancelRecording() }.disabled(!model.state.isBusy)
                    Spacer()
                    Text(model.state == .listening ? "麦克风开启" : "麦克风关闭")
                        .foregroundStyle(model.state == .listening ? .red : .secondary)
                }
                Text(model.status).font(.callout).textSelection(.enabled)
                if !model.resourceError.isEmpty {
                    Text(model.resourceError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                Text("原文 · 可编辑").font(.headline)
                TextEditor(text: $model.originalText)
                    .font(.body).frame(minHeight: 140)
                    .border(Color.secondary.opacity(0.3))
                    .disabled(model.state.isBusy)
                    .accessibilityLabel("识别原文，可编辑")
                Text("整理结果").font(.headline)
                ScrollView {
                    Text(model.resultText.isEmpty ? "整理结果将在这里显示" : model.resultText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled).padding(10)
                }
                .frame(minHeight: 130, maxHeight: 200)
                .background(Color.secondary.opacity(0.07))
                HStack {
                    Button("复制整理结果") { model.copyResult() }
                        .buttonStyle(.borderedProminent).disabled(model.resultText.isEmpty)
                    Spacer()
                    Button("开源组件与许可") { model.showLicenses() }
                }
                Text("识别可能出错，请校对原文。这个工具不会接管其他 App 的听写，也不会自动向其他 App 插入文字。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.frame(minWidth: 670, minHeight: 700)
            .sheet(isPresented: $showWordMemory) { MacWordMemoryView(model: model.wordMemory) }
    }

    private var recordTitle: String {
        switch model.state {
        case .idle: return "开始录音"
        case .authorizing: return "准备／等待授权…"
        case .listening: return "停止录音"
        case .finishing: return "整理中…"
        }
    }
}
