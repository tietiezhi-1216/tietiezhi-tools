import AppKit
import AVFoundation
import ImageIO
import PDFKit
import SwiftUI
import Testing
@testable import TietiezhiTools

@Suite(.serialized)
struct CaptureTests {
    @Test @MainActor func exportedAnnotationsUseImageCoordinatesAndSupportUndo() throws {
        let source = try solid(width: 200, height: 120, color: .white)
        let document = CaptureDocument(image: source)
        document.add(CaptureMark(tool: .cover, points: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 35)], color: .black, width: 3))
        let image = NSBitmapImageRep(cgImage: document.image)
        #expect(image.colorAt(x: 20, y: 20)!.brightnessComponent < 0.05)
        #expect(image.colorAt(x: 20, y: 90)!.brightnessComponent > 0.95)
        #expect(document.undoCount == 1)
        document.undo()
        #expect(NSBitmapImageRep(cgImage: document.image).colorAt(x: 20, y: 20)!.brightnessComponent > 0.95)
        document.redo()
        #expect(NSBitmapImageRep(cgImage: document.image).colorAt(x: 20, y: 20)!.brightnessComponent < 0.05)
        document.add(CaptureMark(tool: .arrow, points: [CGPoint(x: 60, y: 60), CGPoint(x: 160, y: 60)], color: .red, width: 4))
        let arrow = NSBitmapImageRep(cgImage: document.image).colorAt(x: 100, y: 60)!
        #expect(arrow.redComponent > 0.9 && arrow.greenComponent < 0.1)
        document.add(CaptureMark(tool: .crop, points: [CGPoint(x: 5, y: 5), CGPoint(x: 105, y: 85)], color: .red, width: 3))
        #expect(document.image.width == 100 && document.image.height == 80)
        document.undo()
        #expect(document.image.width == 200 && document.image.height == 120)
        document.rotate()
        #expect(document.image.width == 120 && document.image.height == 200)
    }

    @Test @MainActor func mosaicChangesExportedPixelsOnlyInsideTheRegion() throws {
        let source = try pattern(width: 180, height: 140)
        let mark = CaptureMark(tool: .mosaic, points: [CGPoint(x: 20, y: 15), CGPoint(x: 100, y: 85)], color: .red, width: 5)
        let result = try CaptureImage.render(source, marks: [mark])
        let a = NSBitmapImageRep(cgImage: source), b = NSBitmapImageRep(cgImage: result)
        #expect(a.colorAt(x: 150, y: 110) == b.colorAt(x: 150, y: 110))
        var changed = 0
        for y in 20..<75 {
            for x in 25..<90 where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { changed += 1 }
        }
        #expect(changed > 2000)
        let file = try temporary().appendingPathComponent("redacted.png")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try CaptureImage.write(result, to: file)
        let loaded = try CaptureImage.load(file)
        #expect(loaded.width == source.width && loaded.height == source.height)
        let savedColor = try #require(NSBitmapImageRep(cgImage: loaded).colorAt(x: 40, y: 40))
        let expectedColor = try #require(b.colorAt(x: 40, y: 40))
        #expect(abs(savedColor.redComponent - expectedColor.redComponent) < 1 / 255.0)
        #expect(abs(savedColor.greenComponent - expectedColor.greenComponent) < 1 / 255.0)
        #expect(abs(savedColor.blueComponent - expectedColor.blueComponent) < 1 / 255.0)
    }

    @Test func verticalAndHorizontalStitchingFindOverlapAndHandleReverseScrolling() throws {
        for axis in StitchAxis.allCases {
            let source = try pattern(width: axis == .vertical ? 180 : 900, height: axis == .vertical ? 900 : 180)
            func crop(_ position: Int) -> CGImage {
                source.cropping(to: axis == .vertical ? CGRect(x: 0, y: position, width: 180, height: 300) : CGRect(x: position, y: 0, width: 300, height: 180))!
            }
            let a = crop(0), b = crop(130), c = crop(260)
            #expect(ImageStitcher.displacement(a, b, axis: axis) == 130)
            #expect(ImageStitcher.displacement(b, a, axis: axis) == -130)
            var stitcher = ImageStitcher(image: a, axis: axis)
            #expect(try stitcher.append(b))
            #expect(try stitcher.append(c))
            #expect(try stitcher.append(b))
            #expect(!(try stitcher.append(b)))
            #expect(axis == .vertical ? stitcher.image.height == 560 : stitcher.image.width == 560)
            let output = NSBitmapImageRep(cgImage: stitcher.image)
            let expected = NSBitmapImageRep(cgImage: source)
            #expect(output.colorAt(x: 80, y: 80) == expected.colorAt(x: 80, y: 80))
            let x = axis == .vertical ? 80 : 400, y = axis == .vertical ? 400 : 80
            #expect(output.colorAt(x: x, y: y) == expected.colorAt(x: x, y: y))
        }
    }

    @Test func largeRetinaFramesKeepExactSeams() throws {
        let source = try pattern(width: 720, height: 1400)
        let first = source.cropping(to: CGRect(x: 0, y: 0, width: 720, height: 600))!
        let second = source.cropping(to: CGRect(x: 0, y: 137, width: 720, height: 600))!
        let shift = try #require(ImageStitcher.displacement(first, second, axis: .vertical))
        #expect(shift == 137)
    }

    @Test func staticAndUnrelatedImagesDoNotProduceFalseLongScreenshots() throws {
        let white = try solid(width: 180, height: 300, color: .white)
        var stitcher = ImageStitcher(image: white, axis: .vertical)
        #expect(!(try stitcher.append(white)))
        let black = try solid(width: 180, height: 300, color: .black)
        #expect(!(try stitcher.append(black)))
        #expect(stitcher.image.height == 300)
    }

    @Test func csvAndOfficeExportsPreserveQuotesUnicodeAndLiteralCells() throws {
        let rows = [["名称", "备注"], ["a,b", "他说\"你好\"\n第二行"], ["=1+1", "<tag>&"]]
        let csv = CaptureDocumentExport.csv(rows)
        #expect(CaptureDocumentExport.parseCSV(csv) == rows)
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let xlsx = directory.appendingPathComponent("table.xlsx"), docx = directory.appendingPathComponent("document.docx")
        try CaptureDocumentExport.spreadsheet(rows, to: xlsx)
        try CaptureDocumentExport.document("# 标题\n<tag>& 引号\" 测试\n| 姓名 | 年龄 |\n| --- | --- |\n| 张三 | 20 |", to: docx)
        let sheet = try unzip(xlsx, file: "xl/worksheets/sheet1.xml")
        #expect(sheet.contains("inlineStr"))
        #expect(sheet.contains("=1+1"))
        #expect(!sheet.contains("<f>"))
        let document = try unzip(docx, file: "word/document.xml")
        #expect(document.contains("&lt;tag&gt;&amp;"))
        #expect(document.contains("测试"))
        #expect(document.contains("<w:tbl>"))
        #expect(document.contains("<w:b/>"))
        let pdf = directory.appendingPathComponent("document.pdf")
        try CaptureDocumentExport.textPDF("可搜索文字 Capture 123", to: pdf)
        #expect(PDFDocument(url: pdf)?.string?.contains("Capture 123") == true)
    }

    @Test @MainActor func screenshotPluginInstallsWithoutBindingKeysAndPersistsHistory() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: URL(fileURLWithPath: "Plugins/screenshot/manifest.json")))
        try manifest.validate()
        let store = PluginStore(directory: directory.appendingPathComponent("Plugins"), captureDirectory: directory.appendingPathComponent("Images"))
        try store.installManifest(manifest)
        #expect(store.installed[0].commands.isEmpty)
        #expect(store.installed[0].manifest.hasScreenshotWorkspace)
        let command = PluginCommand(action: .captureRegion)
        try store.saveCommand(command, pluginID: manifest.id)
        #expect(store.installed[0].commands[0].title == "区域截图")
        let record = try store.screenshots.storeImage(solid(width: 100, height: 80, color: .blue))
        let reloaded = ScreenshotController(directory: directory.appendingPathComponent("Images"))
        #expect(reloaded.history.first?.id == record.id)
        #expect(!ScreenshotController.safeFilename("../../bad.png"))
        #expect(!ScreenshotController.safeFilename("not-a-uuid.png"))
        store.setEnabled(false, pluginID: manifest.id)
        #expect(store.screenshotPlugin == nil)
        #expect(!store.screenshots.canUseFeatures())
        #expect(FileManager.default.fileExists(atPath: reloaded.url(record).path))
    }

    @Test @MainActor func localOCRReadsSyntheticText() async throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = NSImage(size: CGSize(width: 900, height: 540))
        image.lockFocus()
        NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 900, height: 540).fill()
        for (index, line) in ["CAPTURE TEST 123", "Arrow / Mosaic / OCR / Translation",
                              "Name          Quantity          Price", "Apple             2                10", "Orange            3                20"].enumerated() {
            (line as NSString).draw(at: CGPoint(x: 30, y: 460 - index * 70),
                                   withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 30, weight: .medium), .foregroundColor: NSColor.black])
        }
        image.unlockFocus()
        let file = directory.appendingPathComponent("fixture.png")
        try CaptureImage.write(#require(image.cgImage(forProposedRect: nil, context: nil, hints: nil)), to: file)
        let result = try await CaptureRecognition.recognize(CaptureImage.load(file))
        #expect(result.text.contains("CAPTURE TEST 123"))
        #expect(result.text.contains("Apple"))
        #expect(result.text.contains("Orange"))
    }

    @Test func visionServiceRequiresExplicitHTTPSConfiguration() {
        #expect(CaptureAISettings(endpoint: "http://example.com", model: "vision").url == nil)
        #expect(CaptureAISettings(endpoint: "https://user:pass@example.com", model: "vision").url == nil)
        #expect(CaptureAISettings(endpoint: "https://example.com/v1/chat/completions", model: "").url == nil)
        #expect(CaptureAISettings(endpoint: "https://example.com/v1/chat/completions", model: "vision").url != nil)
    }

    @Test @MainActor func backgroundEraseFillsAPlainBackground() throws {
        let context = try CaptureImage.context(width: 160, height: 120)
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        context.setFillColor(NSColor.black.cgColor); context.fill(CGRect(x: 45, y: 40, width: 40, height: 25))
        let source = context.makeImage()!
        let result = try CaptureImage.render(source, marks: [CaptureMark(tool: .erase,
            points: [CGPoint(x: 35, y: 45), CGPoint(x: 95, y: 90)], color: .red, width: 3)])
        #expect(NSBitmapImageRep(cgImage: result).colorAt(x: 60, y: 70)!.brightnessComponent > 0.95)
    }

    @Test func cancellingRecognitionReturnsWithoutWaitingForTheVisionRequest() async throws {
        let image = try solid(width: 200, height: 120, color: .white)
        let request = Task { try await CaptureRecognition.recognize(image) }
        request.cancel()
        do {
            _ = try await request.value
            Issue.record("Cancelled recognition unexpectedly completed")
        } catch is CancellationError {
        }
    }

    @Test func localTableGroupingAlignsCentredNumbersUnderWideHeaders() {
        let text = CaptureText(lines: [
            RecognizedLine(text: "Title", rect: CGRect(x: 0.05, y: 0.9, width: 0.8, height: 0.05)),
            RecognizedLine(text: "Name", rect: CGRect(x: 0.05, y: 0.7, width: 0.1, height: 0.05)),
            RecognizedLine(text: "Quantity", rect: CGRect(x: 0.4, y: 0.7, width: 0.2, height: 0.05)),
            RecognizedLine(text: "Price", rect: CGRect(x: 0.75, y: 0.7, width: 0.12, height: 0.05)),
            RecognizedLine(text: "Apple", rect: CGRect(x: 0.05, y: 0.5, width: 0.1, height: 0.05)),
            RecognizedLine(text: "2", rect: CGRect(x: 0.48, y: 0.5, width: 0.03, height: 0.05)),
            RecognizedLine(text: "10", rect: CGRect(x: 0.79, y: 0.5, width: 0.05, height: 0.05))
        ], codes: [])
        #expect(text.table == [["Name", "Quantity", "Price"], ["Apple", "2", "10"]])
    }

    @Test func recordingExportsCreateAnimatedGIFAndTrimmedMovie() async throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("source.mp4")
        let writer = try AVAssetWriter(outputURL: video, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<12 {
            while !input.isReadyForMoreMediaData {
                if let error = writer.error { throw error }
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            if let address = CVPixelBufferGetBaseAddress(pixels) {
                let bytes = address.assumingMemoryBound(to: UInt8.self)
                for y in 0..<64 {
                    for x in 0..<64 {
                        let index = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
                        bytes[index] = 255; bytes[index + 1] = UInt8(frame * 20); bytes[index + 2] = UInt8(x * 3); bytes[index + 3] = UInt8(y * 3)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        let gif = directory.appendingPathComponent("output.gif")
        try await RecordingExporter.gif(from: video, to: gif, start: 0.2, end: 0.8, fps: 5)
        let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 3)
        let movie = directory.appendingPathComponent("trimmed.mp4")
        try await RecordingExporter.movie(from: video, to: movie, start: 0.2, end: 0.8)
        let duration = try await AVURLAsset(url: movie).load(.duration).seconds
        #expect(abs(duration - 0.6) < 0.12)
    }

    @Test @MainActor func screenshotWorkspaceFitsTheMinimumWindow() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: URL(fileURLWithPath: "Plugins/screenshot/manifest.json")))
        let store = PluginStore(directory: directory.appendingPathComponent("Plugins"), captureDirectory: directory.appendingPathComponent("Images"))
        try store.installManifest(manifest)
        let observation = Bounds()
        let view = ContentView(initialSelection: manifest.id).environmentObject(store)
            .onPreferenceChange(PanelLayoutBoundsKey.self) { value in MainActor.assumeIsolated { observation.frames = value } }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 880, height: 580),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        let root = try #require(observation.frames["panel.root"])
        let header = try #require(observation.frames["panel.header"])
        let controls = try #require(observation.frames["capture.controls"])
        let tabs = try #require(observation.frames["capture.tabs"])
        let history = try #require(observation.frames["capture.history"])
        for rect in [header, controls, tabs, history] { #expect(root.contains(rect)) }
        #expect(header.maxY <= controls.minY + 1)
        #expect(controls.maxY <= tabs.minY)
        #expect(tabs.maxY <= history.minY)
    }

    @MainActor private final class Bounds { var frames: [String: CGRect] = [:] }

    private func solid(width: Int, height: Int, color: NSColor) throws -> CGImage {
        let context = try CaptureImage.context(width: width, height: height)
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
    private func pattern(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let value = UInt64(x / 5) &* 73_856_093 ^ UInt64(y / 7) &* 19_349_663
                bytes[i] = UInt8(truncatingIfNeeded: value)
                bytes[i + 1] = UInt8(truncatingIfNeeded: value >> 8)
                bytes[i + 2] = UInt8(truncatingIfNeeded: value >> 16)
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func unzip(_ url: URL, file: String) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, file]; process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(data: data, encoding: .utf8)!
    }
}
