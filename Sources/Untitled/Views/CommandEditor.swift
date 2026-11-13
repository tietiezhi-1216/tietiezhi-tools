import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CommandEditor: View {
    @EnvironmentObject private var store: PluginStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var draft: PluginCommand
    @ViewState private var error: String?
    let pluginID: String
    let actions: [ActionKind]

    init(pluginID: String, command: PluginCommand, actions: [ActionKind]) {
        self.pluginID = pluginID
        self.actions = actions
        _draft = ViewState(wrappedValue: command)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(draft.title)
                .font(.headline)
                .lineLimit(2)
                .help(draft.title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PanelLayout.contentInset)
                .padding(.top, PanelLayout.contentInset)
            Form {
                Picker("操作", selection: $draft.action) {
                    ForEach(actions, id: \.self) { action in Text(action.title).tag(action) }
                }
                .onChange(of: draft.action) { _, _ in
                    draft.target = ""
                    draft.applicationBookmark = nil
                    draft.templateID = nil
                    error = nil
                }

                switch draft.action {
                case .openApplication:
                    LabeledContent("应用") {
                        HStack {
                            Text(draft.target.isEmpty ? "尚未选择" : URL(fileURLWithPath: draft.target).deletingPathExtension().lastPathComponent)
                                .foregroundStyle(.secondary).lineLimit(1)
                            Button("选择…", action: chooseApplication)
                        }
                    }
                case .openURL:
                    TextField("网址", text: $draft.target, prompt: Text("https://example.com"))
                case .runShortcut:
                    TextField("快捷指令名称", text: $draft.target)
                    Text("填写 macOS「快捷指令」中已有的名称。该指令会按你在系统中配置的步骤执行。")
                        .font(.caption).foregroundStyle(.secondary)
                case .showMainWindow:
                    Text("将主面板带到前台；窗口已关闭时会重新打开。")
                        .font(.callout).foregroundStyle(.secondary)
                case .sharePeripherals, .switchPeripheralControl, .stopPeripheralSharing:
                    Text("使用外设共享插件中已配对的设备。切换控制需要两端明确开启键鼠共享；停止操作始终释放键鼠和麦克风。")
                        .font(.callout).foregroundStyle(.secondary)
                default:
                    Text("绑定后可在任意应用中执行此截图操作。首次截屏或录屏时需要允许屏幕录制权限。")
                        .font(.callout).foregroundStyle(.secondary)
                }

                LabeledContent("全局快捷键") {
                    HStack {
                        ShortcutRecorder(hotKey: $draft.hotKey, error: $error)
                            .frame(width: 190, height: 28)
                        Button("清除") { draft.hotKey = nil }.disabled(draft.hotKey == nil)
                    }
                }
                Toggle("启用此操作", isOn: $draft.isEnabled)
                if let error { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            }
            .formStyle(.grouped)
            HStack(spacing: 12) {
                Text("至少包含 ⌘、⌥ 或 ⌃。留空则仅手动执行。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, PanelLayout.contentInset)
            .padding(.bottom, PanelLayout.contentInset)
            .padding(.top, 12)
        }
        .controlSize(.regular)
        .frame(width: 600, height: 400)
    }

    private func save() {
        do {
            draft.target = draft.target.trimmingCharacters(in: .whitespacesAndNewlines)
            try store.saveCommand(draft, pluginID: pluginID)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "选择要打开的应用"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let bookmark = try ActionExecutor.applicationBookmark(for: url)
                draft.target = url.path
                draft.applicationBookmark = bookmark
                error = nil
            } catch {
                self.error = "无法保存应用位置，请重新选择：\(error.localizedDescription)"
            }
        }
    }
}
