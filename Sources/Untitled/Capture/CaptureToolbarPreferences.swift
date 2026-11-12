import SwiftUI

enum CaptureToolbarPreferences {
    static let defaults: [CaptureTool] = [.move,.select,.arrow,.rectangle,.ellipse,.line,.pen,.highlight,.text,.number,.mosaic,.cover,.deleteMarks,.erase,.inpaint,.spotlight,.magnify,.watermark,.crop]
    static func ordered(_ value: String) -> [CaptureTool] {
        guard let data = value.data(using: .utf8), let items = try? JSONDecoder().decode([CaptureTool].self, from: data) else { return defaults }
        var seen = Set<CaptureTool>()
        // Earlier versions allowed hidden tools. Keep their order, but show every tool now.
        return (items + defaults).filter { seen.insert($0).inserted }
    }
    static func encoded(_ items: [CaptureTool]) -> String { String(data: (try? JSONEncoder().encode(items)) ?? Data(), encoding: .utf8) ?? "" }
}

struct CaptureToolbarSettingsView: View {
    @AppStorage("capture.toolbarOrder") private var order = ""
    @Environment(\.dismiss) private var dismiss
    var tools: [CaptureTool] { CaptureToolbarPreferences.ordered(order) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("工具顺序").font(.headline); Spacer(); Button("完成") { dismiss() } }
            Text("所有工具始终显示在同一行，拖动可调整顺序。").font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(tools) { tool in
                    Label(tool.title, systemImage: tool.symbol)
                }.onMove { from, to in var value = tools; value.move(fromOffsets: from, toOffset: to); save(value) }
            }
            HStack {
                Spacer(); Button("恢复默认") { order = "" }
            }
        }.padding(18).frame(width: 360, height: 480)
    }
    private func save(_ value: [CaptureTool]) { order = CaptureToolbarPreferences.encoded(value) }
}
