import AppKit
import SwiftUI
import Vision

struct CaptureRedactionTarget: Identifiable, Sendable, Equatable {
    enum Kind: String, CaseIterable, Sendable {
        case sensitive = "敏感文字", text = "其他文字", face = "人脸", barcode = "条码"
    }
    let id: UUID
    let groupID: String
    let label: String
    let kind: Kind
    let rect: CGRect
    let isSuggested: Bool
    init(groupID: String, label: String, kind: Kind, rect: CGRect, isSuggested: Bool) {
        id = UUID(); self.groupID = groupID; self.label = label; self.kind = kind; self.rect = rect; self.isSuggested = isSuggested
    }
}

enum CaptureRedactionDetector {
    private static let patterns = [#"https?://[^\s]+"#, #"(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)"#,
        #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, #"(?<!\d)(?:\+?86[- ]?)?1[3-9]\d{9}(?!\d)"#,
        #"(?<!\d)\d{17}[0-9X](?!\d)"#, #"(?:password|密码|token|api.?key|验证码)\s*[:：=]\s*(\S+)"#]
    static func textTargets(_ text: CaptureText, size: CGSize) -> [CaptureRedactionTarget] {
        var output: [CaptureRedactionTarget] = []
        for line in text.lines {
            let string = line.text as NSString
            var ranges: [NSRange] = []
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
                for match in regex.matches(in: line.text, range: NSRange(location: 0, length: string.length)) {
                    let range = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
                    if !ranges.contains(where: { NSIntersectionRange($0, range).length > 0 }) { ranges.append(range) }
                }
            }
            for range in ranges {
                let value = string.substring(with: range)
                output.append(.init(groupID: "text:" + value.lowercased(), label: value, kind: .sensitive,
                                    rect: pixels(line.bounds(for: range), size: size), isSuggested: true))
            }
            if ranges.isEmpty, !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let value = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                output.append(.init(groupID: "text:" + value.lowercased(), label: value, kind: .text,
                                    rect: pixels(line.rect, size: size), isSuggested: false))
            }
        }
        return output
    }
    static func targets(in image: CGImage) async throws -> [CaptureRedactionTarget] {
        let recognized = try await CaptureRecognition.recognize(image)
        let size = CGSize(width: image.width, height: image.height)
        var targets = textTargets(recognized, size: size)
        let shapes = try await Task.detached { () -> [CaptureRedactionTarget] in
            let faces = VNDetectFaceRectanglesRequest(), codes = VNDetectBarcodesRequest()
            try VNImageRequestHandler(cgImage: image).perform([faces, codes])
            var result: [CaptureRedactionTarget] = []
            var signatures: [(UInt64, Int)] = []
            for (index, observation) in (faces.results ?? []).enumerated() {
                let rect = pixels(observation.boundingBox, size: size)
                let signature = image.cropping(to: rect).flatMap(hash)
                let group: Int
                if let signature, let match = signatures.first(where: { ($0.0 ^ signature).nonzeroBitCount <= 3 }) { group = match.1 }
                else { group = index; if let signature { signatures.append((signature, group)) } }
                result.append(.init(groupID: "face:\(group)", label: "人脸 \(group + 1)", kind: .face, rect: rect, isSuggested: true))
            }
            for (index, code) in (codes.results ?? []).enumerated() {
                let label = code.payloadStringValue ?? "条码 \(index + 1)"
                result.append(.init(groupID: "code:" + label, label: label, kind: .barcode, rect: pixels(code.boundingBox, size: size), isSuggested: true))
            }
            return result
        }.value
        targets.append(contentsOf: shapes)
        try Task.checkCancellation()
        return targets
    }
    private static func pixels(_ rect: CGRect, size: CGSize) -> CGRect {
        CGRect(x: rect.minX * size.width, y: (1 - rect.maxY) * size.height, width: rect.width * size.width, height: rect.height * size.height)
            .insetBy(dx: -3, dy: -3).integral.intersection(CGRect(origin: .zero, size: size))
    }
    private static func hash(_ image: CGImage) -> UInt64? {
        guard let context = CGContext(data: nil, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let raw = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
        let data = raw.assumingMemoryBound(to: UInt8.self)
        var value: UInt64 = 0
        for y in 0..<8 { for x in 0..<8 { if data[y * 9 + x] > data[y * 9 + x + 1] { value |= UInt64(1) << UInt64(y * 8 + x) } } }
        return value
    }
}

struct CaptureRedactionReview: View {
    let image: CGImage
    let apply: ([CGRect]) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var targets: [CaptureRedactionTarget] = []
    @ViewState private var selected = Set<UUID>()
    @ViewState private var linked = true
    @ViewState private var busy = true
    @ViewState private var error = ""
    @ViewState private var showText = false
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("自动马赛克").font(.headline)
                Spacer()
                Toggle("同步选择相同内容", isOn: $linked).toggleStyle(.checkbox)
                Toggle("显示其他文字", isOn: $showText).toggleStyle(.checkbox)
            }
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSImage(cgImage: image, size: .zero)).resizable().aspectRatio(contentMode: .fit)
                    .overlay { GeometryReader { geometry in
                        ForEach(targets.filter { showText || $0.kind != .text }) { target in
                            let rect = target.rect
                            Rectangle().fill(selected.contains(target.id) ? Color.orange.opacity(0.4) : Color.blue.opacity(0.08))
                                .overlay { Rectangle().stroke(selected.contains(target.id) ? .orange : .blue, lineWidth: 1) }
                                .frame(width: rect.width / CGFloat(image.width) * geometry.size.width, height: rect.height / CGFloat(image.height) * geometry.size.height)
                                .position(x: rect.midX / CGFloat(image.width) * geometry.size.width, y: rect.midY / CGFloat(image.height) * geometry.size.height)
                                .onTapGesture { toggle(target) }.help(target.label)
                        }
                    }}
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(targets.filter { showText || $0.kind != .text }) { target in
                            Toggle(isOn: Binding(get: { selected.contains(target.id) }, set: { _ in toggle(target) })) {
                                VStack(alignment: .leading) {
                                    Text(target.label).lineLimit(2)
                                    Text(target.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                                }
                            }.toggleStyle(.checkbox)
                        }
                    }
                }.frame(width: 200)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Text(error.isEmpty ? (busy ? "正在本地识别…" : "已选择 \(selected.count) 处") : error).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                Button("应用马赛克") { apply(targets.filter { selected.contains($0.id) }.map(\.rect)); dismiss() }
                    .buttonStyle(.borderedProminent).disabled(busy || selected.isEmpty)
            }
        }.padding(20).frame(minWidth: 750, idealWidth: 900, minHeight: 500, idealHeight: 640)
        .task {
            do { targets = try await CaptureRedactionDetector.targets(in: image); selected = Set(targets.filter(\.isSuggested).map(\.id)) }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
    private func toggle(_ target: CaptureRedactionTarget) {
        let ids = linked ? Set(targets.filter { $0.groupID == target.groupID }.map(\.id)) : [target.id]
        if selected.contains(target.id) { selected.subtract(ids) } else { selected.formUnion(ids) }
    }
}
