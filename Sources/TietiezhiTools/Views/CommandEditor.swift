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
            draft.target = url.path
            draft.applicationBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    }
}
