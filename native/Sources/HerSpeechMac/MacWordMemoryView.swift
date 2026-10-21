import AppKit
import Foundation
import SwiftUI

@MainActor
final class MacWordMemoryModel: ObservableObject {
    @Published private(set) var snapshot = MacWordMemorySnapshot()
    @Published private(set) var status = ""
    @Published private(set) var failed = false
    private let store: MacWordMemoryFileStore

    init(directory: URL = MacWordMemoryFileStore.defaultDirectory) {
        store = MacWordMemoryFileStore(directory: directory)
        refresh()
    }

    func refresh() {
        do { snapshot = try store.read(); failed = false; status = "词库仅保存在这台 Mac。" }
        catch { failed = true; status = error.localizedDescription }
    }

    private func change(_ message: String, _ operation: () throws -> Void) {
        do {
            try operation()
            snapshot = try store.read()
            failed = false
            status = message
        } catch { failed = true; status = error.localizedDescription }
    }

    func remember(text: String, input: String) { change("已加入本地词库。") { try store.remember(text: text, input: input) } }
    func forget(_ text: String) { change("已忘记个人记忆。基础词典中仍可能有这个词；需要隐藏时请选择「不再推荐」。") { try store.forget(text: text) } }
    func block(_ text: String) { change("已设为不再推荐，停止学习这个词。") { try store.block(text: text) } }
    func unblock(_ text: String) { change("已恢复推荐；旧的个人记忆不会因此恢复。") { try store.unblock(text: text) } }
    func clear() { change("已清空个人词语，保留不再推荐列表。") { try store.clearLearned() } }
    func setLearning(_ enabled: Bool) { change(enabled ? "自动记忆已开启。" : "自动记忆已关闭，已保存的词仍可管理。") { try store.setLearningEnabled(enabled) } }

    func speechHints() throws -> [String] {
        snapshot = try store.read()
        failed = false
        var seen = Set<String>()
        return snapshot.entries.map(\.text).filter {
            !MacWordMemoryFileStore.isBlocked($0, by: snapshot.blockedWords) && seen.insert(MacWordMemoryFileStore.key($0)).inserted
        }
    }

    func isBlocked(_ text: String) -> Bool { MacWordMemoryFileStore.isBlocked(text, by: snapshot.blockedWords) }
}

struct MacWordMemoryView: View {
    @ObservedObject var model: MacWordMemoryModel
    var onDone: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var input = ""
    @State private var search = ""
    @State private var confirmClear = false
    @State private var showBlocked = false

    private var visibleEntries: [MacRememberedWord] {
        model.snapshot.entries.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) || $0.input.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("本地词库").font(.title.bold())
                Spacer()
                Button("刷新") { model.refresh() }
                Button("完成") { if let onDone { onDone() } else { dismiss() } }.keyboardShortcut(.defaultAction)
            }
            Text("记住人名与英文词，也可以让一个名字不再出现在她说键盘的候选里。")
                .foregroundStyle(.secondary)
            Toggle("自动记住已确认输入的词", isOn: Binding(get: { model.snapshot.learningEnabled }, set: { model.setLearning($0) }))
            GroupBox("添加词语或隐藏名字") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("词语，例如张小芳、GitHub", text: $text).textFieldStyle(.roundedBorder)
                    TextField("全拼或输入缩写，例如 zhangxiaofang、zxf、gh", text: $input).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("加入词库") {
                            model.remember(text: text, input: input)
                            if !model.failed { text = ""; input = "" }
                        }.disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || input.isEmpty)
                        Button("这个词不再推荐") {
                            model.block(text)
                            if !model.failed { text = ""; input = "" }
                        }.disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("Mac 英文词可手动添加并指定输入码；在中文模式输入该缩写即可选词。西文直输不会自动记忆。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(5)
            }
            Text(model.status).font(.callout).foregroundStyle(model.failed ? .red : .secondary).textSelection(.enabled)
            TextField("搜索已记住的词或输入码", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Text("已记住 · \(model.snapshot.entries.count)").font(.headline)
                    if visibleEntries.isEmpty { Text("暂无匹配词语。也可以在上方手动加入。").foregroundStyle(.secondary) }
                    ForEach(visibleEntries) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.text).textSelection(.enabled)
                                Text(entry.input + (entry.manual ? " · 手动添加" : " · 使用 \(entry.count) 次"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("忘记") { model.forget(entry.text) }
                            Button("不再推荐") { model.block(entry.text) }
                        }
                        Divider()
                    }
                    DisclosureGroup("不再推荐 · \(model.snapshot.blockedWords.count)", isExpanded: $showBlocked) {
                        if model.snapshot.blockedWords.isEmpty { Text("暂未隐藏词语。").foregroundStyle(.secondary) }
                        ForEach(model.snapshot.blockedWords, id: \.self) { word in
                            HStack {
                                Text(word).textSelection(.enabled)
                                Spacer()
                                Button("恢复推荐") { model.unblock(word) }
                            }.padding(.vertical, 4)
                        }
                    }.padding(.top, 8)
                }.padding(5)
            }.frame(minHeight: 170)
            HStack {
                Button("清空已记住的词…", role: .destructive) { confirmClear = true }
                Spacer()
                Text("隐藏列表会保留").font(.caption).foregroundStyle(.secondary)
            }
            Text("「忘记」去掉个人记忆；「不再推荐」还会隐藏基础词典和组合候选中的该词，并阻止重新学习。隐藏词不用于语音提示；真实录音仍可能识别出这些词，原文供你校对。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22).frame(minWidth: 650, idealWidth: 720, minHeight: 640, idealHeight: 780)
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
        .confirmationDialog("清空已记住的词？不再推荐列表会保留。", isPresented: $confirmClear) {
            Button("清空个人词语", role: .destructive) { model.clear() }
            Button("取消", role: .cancel) { }
        }
    }
}
