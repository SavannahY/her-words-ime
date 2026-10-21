import Foundation

@main
private enum MacWordMemoryChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("her-memory-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MacWordMemoryFileStore(directory: directory)
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw MacWordMemoryError(message: message) }
            checks += 1
        }
        try check(store.read().entries.isEmpty, "new store")
        try store.remember(text: "张小芳", input: "zhang xiao fang")
        try store.remember(text: "GitHub", input: "gh")
        try check(store.read().entries.count == 2, "manual entries")
        try check(store.read().entries.contains { $0.input == "zhangxiaofang" }, "normalized code")
        let learned = directory.appendingPathComponent("her_memory_learned.tsv")
        let old = Int(Date().timeIntervalSince1970) - 10
        try "HER_WORD_MEMORY\t1\nL\tzhangxiaofang\t张小芳\t3\t\(old)\nL\tapi\tAPI\t2\t\(old)\n".write(to: learned, atomically: true, encoding: .utf8)
        try check(store.read().entries.count == 3, "merge Rime learned and manual")
        try store.forget(text: "张小芳")
        try check(!store.read().entries.contains { $0.text == "张小芳" }, "forget old Rime learning")
        try check(store.read().blockedWords.isEmpty, "forget is not suppression")
        try store.block(text: "张小芳")
        try check(MacWordMemoryFileStore.isBlocked("给张小芳留言", by: store.read().blockedWords), "Chinese composed suppression")
        do { try store.remember(text: "张小芳", input: "zxf"); throw MacWordMemoryError(message: "blocked remember succeeded") }
        catch { try check(store.read().entries.allSatisfy { $0.text != "张小芳" }, "blocked cannot relearn") }
        try store.unblock(text: "张小芳")
        try check(store.read().entries.allSatisfy { $0.text != "张小芳" }, "unblock does not resurrect")
        try store.remember(text: "张小芳", input: "zxf")
        try check(store.read().entries.contains { $0.text == "张小芳" }, "explicit remember after restore")
        try store.block(text: "Ann")
        try check(MacWordMemoryFileStore.isBlocked("ANN", by: store.read().blockedWords), "ASCII case")
        try check(!MacWordMemoryFileStore.isBlocked("planning", by: store.read().blockedWords), "ASCII word boundary")
        try check(MacWordMemoryFileStore.isBlocked("Ann's book", by: store.read().blockedWords), "ASCII name boundary")
        try store.setLearningEnabled(false)
        try check(!store.read().learningEnabled, "toggle persists")
        try store.clearLearned()
        try check(store.read().entries.isEmpty, "clear memory")
        try check(store.read().blockedWords == ["Ann"], "clear keeps suppression")
        let policy = directory.appendingPathComponent("her_memory_policy.tsv")
        try "damaged\n".write(to: policy, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: policy)
        var rejected = false
        do { try store.setLearningEnabled(true) } catch { rejected = true }
        try check(rejected, "corrupt policy rejected")
        try check(Data(contentsOf: policy) == before, "corrupt policy preserved")
        print("Mac word memory checks passed: \(checks)")
    }
}
