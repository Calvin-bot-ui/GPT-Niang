import AppKit
import SwiftUI
import Combine

struct PersonaDraft {
    var name = ""
    var role = ""
    var background = ""
    var personality = ""
    var tone = ""
    var responseStyle = ""
    var preferences = ""
    var boundaries = ""
    var additionalInstructions = ""

    static func from(_ value: [String: Any]) -> PersonaDraft {
        func text(_ key: String) -> String {
            if let value = value[key] as? String { return value }
            if let values = value[key] as? [String] { return values.joined(separator: "\n") }
            return ""
        }
        var draft = PersonaDraft()
        draft.name = text("name"); draft.role = text("role"); draft.background = text("background")
        draft.personality = text("personality"); draft.tone = text("tone"); draft.responseStyle = text("responseStyle")
        draft.preferences = text("preferences"); draft.boundaries = text("boundaries")
        draft.additionalInstructions = [text("additionalInstructions"), text("instructions")].filter { !$0.isEmpty }.joined(separator: "\n")
        return draft
    }

    func json() -> [String: Any] {
        func lines(_ value: String) -> [String] {
            value.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        return ["schemaVersion": 1, "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
                "role": role.trimmingCharacters(in: .whitespacesAndNewlines),
                "background": background.trimmingCharacters(in: .whitespacesAndNewlines),
                "personality": lines(personality), "tone": tone.trimmingCharacters(in: .whitespacesAndNewlines),
                "responseStyle": responseStyle.trimmingCharacters(in: .whitespacesAndNewlines),
                "preferences": lines(preferences), "boundaries": lines(boundaries),
                "additionalInstructions": additionalInstructions.trimmingCharacters(in: .whitespacesAndNewlines)]
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    struct Message: Identifiable {
        let id = UUID()
        let role: String
        var text: String
    }
    struct Memory: Identifiable, Equatable {
        let id: String
        let text: String
        let createdAt: String
    }

    @Published var messages: [Message] = []
    @Published var input = ""
    @Published var busy = false
    @Published var error: String?
    @Published var memories: [Memory] = []
    @Published var memoryNotice: String?
    var onProactiveMessage: ((String) -> Void)?
    let personaURL: URL
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private var buffer = Data()
    private var activeAssistant: UUID?

    init(model: WidgetModel) {
        personaURL = model.dataDirectory.appendingPathComponent("chat-persona.json")
        guard let node = model.findNode() else {
            error = "找不到 Node.js 20+。请安装 Node.js 后重新打开 GPT 娘。"
            return
        }
        process.executableURL = node
        process.arguments = [model.resources.appendingPathComponent("Backend/runtime/chat.mjs").path]
        var environment = ProcessInfo.processInfo.environment
        environment["GPT_NIANG_DATA_DIR"] = model.dataDirectory.path
        environment["GPT_NIANG_PERSONA_TEMPLATE"] = model.resources.appendingPathComponent("chat-persona.json").path
        environment["PATH"] = [node.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", environment["PATH"] ?? ""].joined(separator: ":")
        process.environment = environment
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.receive(data) }
        }
        do { try process.run() }
        catch { self.error = "聊天服务无法启动：\(error.localizedDescription)" }
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        input = ""; error = nil; busy = true
        messages.append(Message(role: "user", text: text))
        let assistant = Message(role: "assistant", text: "")
        messages.append(assistant); activeAssistant = assistant.id
        _ = write(["type": "send", "text": text])
    }

    @discardableResult
    func sendProactive() -> Bool {
        guard !busy, process.isRunning else { return false }
        error = nil
        busy = true
        return write(["type": "proactive"])
    }

    func clear() {
        guard !busy else { return }
        messages.removeAll(); error = nil
        _ = write(["type": "clear"])
    }

    func loadMemories() { _ = write(["type": "memory-list"]) }

    func addMemory(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = write(["type": "memory-add", "text": text])
    }

    func deleteMemory(_ memory: Memory) {
        _ = write(["type": "memory-delete", "id": memory.id])
    }

    func loadPersonaDraft() -> PersonaDraft {
        guard let data = try? Data(contentsOf: personaURL),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return PersonaDraft() }
        return PersonaDraft.from(value)
    }

    func savePersona(_ draft: PersonaDraft) -> String? {
        do {
            var data = try JSONSerialization.data(withJSONObject: draft.json(), options: [.prettyPrinted, .sortedKeys])
            data.append(contentsOf: [10])
            try data.write(to: personaURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: personaURL.path)
            return nil
        } catch { return "无法保存人设：\(error.localizedDescription)" }
    }

    func stop() {
        stdout.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    private func write(_ value: [String: String]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: value), var line = String(data: data, encoding: .utf8) else { return false }
        line.append("\n")
        do { try stdin.fileHandleForWriting.write(contentsOf: Data(line.utf8)); return true }
        catch { self.error = "无法发送消息：\(error.localizedDescription)"; busy = false; return false }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstRange(of: Data([10])) {
            let line = buffer[..<newline.lowerBound]; buffer.removeSubrange(..<newline.upperBound)
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let type = event["type"] as? String else { continue }
            switch type {
            case "history":
                guard let items = event["items"] as? [[String: Any]] else { continue }
                messages = items.flatMap { item -> [Message] in
                    guard let assistant = item["assistant"] as? String else { return [] }
                    if item["type"] as? String == "proactive" { return [Message(role: "assistant", text: assistant)] }
                    guard let user = item["user"] as? String else { return [] }
                    return [Message(role: "user", text: user), Message(role: "assistant", text: assistant)]
                }
            case "memories":
                let items = event["items"] as? [[String: Any]] ?? []
                memories = items.compactMap { item in
                    guard let id = item["id"] as? String, let text = item["text"] as? String else { return nil }
                    return Memory(id: id, text: text, createdAt: item["createdAt"] as? String ?? "")
                }
                memoryNotice = event["notice"] as? String
            case "memoryError": memoryNotice = event["text"] as? String ?? "记忆操作失败。"
            case "delta":
                guard let text = event["text"] as? String, let id = activeAssistant,
                      let index = messages.firstIndex(where: { $0.id == id }) else { continue }
                messages[index].text += text
            case "complete": busy = false; activeAssistant = nil
            case "proactive":
                let text = event["text"] as? String ?? ""
                if !text.isEmpty { messages.append(Message(role: "assistant", text: text)); onProactiveMessage?(text) }
                busy = false; activeAssistant = nil
            case "proactiveError":
                error = event["text"] as? String ?? "主动聊天暂时不可用。"
                busy = false; activeAssistant = nil
            case "cleared": messages.removeAll()
            case "error":
                error = event["text"] as? String ?? "聊天暂时不可用。"
                if let id = activeAssistant, let index = messages.firstIndex(where: { $0.id == id }), messages[index].text.isEmpty {
                    messages.remove(at: index)
                }
                busy = false; activeAssistant = nil
            default: break
            }
        }
    }
}

struct ChatWindowView: View {
    @ObservedObject var model: ChatViewModel
    @ObservedObject var widgetModel: WidgetModel
    let onOpenSettings: () -> Void
    @FocusState private var focused: Bool
    @State private var selectedMessageID: UUID?
    @State private var showMemoryManager = false
    @State private var showPersonaEditor = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("和 GPT 娘聊天").font(.system(size: 17, weight: .semibold))
                    Text("使用 Codex · GPT-6 Luna · 日常聊天").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { onOpenSettings() } label: { Image(systemName: "slider.horizontal.3") }
                    .help("主动聊天开关、免打扰时段和每日次数")
                Button("记忆") { model.loadMemories(); showMemoryManager = true }
                    .help("查看和管理独立保存在本机的长期记忆")
                Button("编辑人设") { showPersonaEditor = true }
                    .help("在桌宠窗口中编辑人设，保存后对下一条消息生效")
                Button("清空记录") { model.clear() }.disabled(model.busy || model.messages.isEmpty)
                    .help("清空本地保存的聊天记录")
            }.padding(16)
            Divider()
            if widgetModel.proactiveEnabled && !widgetModel.proactiveQuotaSafe {
                Label(widgetModel.proactiveQuotaStatus, systemImage: "pause.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if model.messages.isEmpty {
                            Text("点击桌宠就能来聊天啦。最近 3 轮会保存在这台 Mac 上。")
                                .font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                        }
                        ForEach(model.messages) { message in
                            VStack(alignment: message.role == "assistant" ? .leading : .trailing, spacing: 4) {
                                HStack {
                                    if message.role == "assistant" { bubble(message.text.isEmpty && model.busy ? "正在想…" : message.text, mine: false); Spacer(minLength: 36) }
                                    else { Spacer(minLength: 36); bubble(message.text, mine: true) }
                                }
                                if selectedMessageID == message.id {
                                    Button("加入记忆") { model.addMemory(message.text); selectedMessageID = nil }
                                        .font(.system(size: 11)).buttonStyle(.borderless).foregroundStyle(.purple)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { selectedMessageID = selectedMessageID == message.id ? nil : message.id }
                            .id(message.id)
                        }
                    }.padding(16)
                }.onChange(of: model.messages.count) { _ in
                    if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }.onChange(of: model.messages.last?.text) { _ in
                    if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            if let error = model.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 8)
            }
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("说点什么…", text: $model.input, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { if !model.busy { model.send() } }
                Button { model.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 25)) }
                    .buttonStyle(.plain).disabled(model.busy || model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("发送消息")
            }.padding(14)
        }.frame(minWidth: 440, minHeight: 480).background(Color(nsColor: .windowBackgroundColor))
            .onAppear { focused = true }
            .sheet(isPresented: $showMemoryManager) { MemoryManagerView(model: model).frame(minWidth: 420, minHeight: 380) }
            .sheet(isPresented: $showPersonaEditor) { PersonaEditorView(model: model).frame(minWidth: 500, minHeight: 600) }
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        Text(text.isEmpty ? " " : text).font(.system(size: 13)).textSelection(.enabled)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(mine ? Color.purple.opacity(0.14) : Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: 300, alignment: mine ? .trailing : .leading)
    }
}

private struct MemoryManagerView: View {
    @ObservedObject var model: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("长期记忆").font(.system(size: 17, weight: .semibold))
            Text("只保存你在聊天气泡上主动选择的内容；它与最近 3 轮聊天记录分开存放在本机，并会作为背景信息用于后续回复。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let memoryNotice = model.memoryNotice {
                Text(memoryNotice).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if model.memories.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "brain.head.profile").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("还没有长期记忆").font(.system(size: 14, weight: .medium))
                    Text("点击一条聊天气泡，再选择“加入记忆”。").font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.memories) { memory in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(memory.text).textSelection(.enabled)
                                if !memory.createdAt.isEmpty { Text(memory.createdAt).font(.system(size: 10)).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 4)
                            Button(role: .destructive) { model.deleteMemory(memory) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("删除这条记忆")
                        }.padding(.vertical, 3)
                    }
                }.listStyle(.plain)
            }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(16)
    }

    @Environment(\.dismiss) private var dismiss
}

private struct PersonaEditorView: View {
    @ObservedObject var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PersonaDraft
    @State private var saveError: String?

    init(model: ChatViewModel) {
        self.model = model
        _draft = State(initialValue: model.loadPersonaDraft())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑 GPT 娘人设").font(.system(size: 18, weight: .semibold))
            Text("在这里直接调整人设，不需要打开外部编辑器。保存后对下一条消息生效；多项内容可每行填写一条。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    textField("名字", text: $draft.name)
                    textField("身份", text: $draft.role)
                    editor("背景", text: $draft.background, height: 55)
                    editor("性格（每行一项）", text: $draft.personality, height: 65)
                    editor("语气", text: $draft.tone, height: 60)
                    editor("回复风格", text: $draft.responseStyle, height: 70)
                    editor("交流偏好（每行一项）", text: $draft.preferences, height: 65)
                    editor("边界（每行一项）", text: $draft.boundaries, height: 65)
                    editor("补充要求", text: $draft.additionalInstructions, height: 70)
                }
            }
            if let saveError { Text(saveError).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存人设") {
                    if let error = model.savePersona(draft) { saveError = error }
                    else { dismiss() }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(16)
    }

    private func textField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium))
            TextField(title, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func editor(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium))
            TextEditor(text: text).font(.system(size: 12)).frame(height: height)
                .padding(4).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
