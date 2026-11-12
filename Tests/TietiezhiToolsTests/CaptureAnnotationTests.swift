import AppKit
import Testing
@testable import TietiezhiTools

@Suite(.serialized)
struct CaptureAnnotationTests {
    @Test @MainActor func roundedRectangleAndFillChangeOnlyTheExpectedPixels() throws {
        let image=try blank()
        var mark=CaptureMark(tool:.rectangle,points:[CGPoint(x:40,y:40),CGPoint(x:180,y:140)],color:.red,width:4)
        mark.style.cornerRadius=24
        let rounded=NSBitmapImageRep(cgImage:try CaptureImage.render(image,marks:[mark]))
        #expect(rounded.colorAt(x:41,y:41)!.greenComponent>0.9)
        #expect(rounded.colorAt(x:100,y:40)!.redComponent>0.9 && rounded.colorAt(x:100,y:40)!.greenComponent<0.2)
        #expect(rounded.colorAt(x:100,y:90)!.greenComponent>0.9)
        mark.style.fill = .solid
        let filled=NSBitmapImageRep(cgImage:try CaptureImage.render(image,marks:[mark]))
        #expect(filled.colorAt(x:100,y:90)!.greenComponent<0.2)
        mark.style.fill = .translucent
        let translucent=NSBitmapImageRep(cgImage:try CaptureImage.render(image,marks:[mark]))
        #expect(translucent.colorAt(x:100,y:90)!.greenComponent>0.65)
    }
    @Test @MainActor func curveMiddleHandleMovesThePathAndUndoKeepsOneGesture() throws {
        let document=CaptureDocument(image:try blank())
        let mark=CaptureMark(tool:.arrow,points:[CGPoint(x:40,y:160),CGPoint(x:300,y:160)],color:.red,width:4)
        document.add(mark)
        let target=CGPoint(x:170,y:70)
        let curved=mark.adjusting(.bend,to:target)
        #expect(curved.curveMidpoint == target)
        #expect(curved.hit(target,tolerance:5))
        #expect(!curved.hit(CGPoint(x:170,y:160),tolerance:5))
        document.beginMarkEdit(mark.id)
        document.previewMark(mark.adjusting(.bend,to:CGPoint(x:170,y:100)))
        document.previewMark(curved);document.finishMarkEdit()
        #expect(document.undoCount == 2)
        let pixels=NSBitmapImageRep(cgImage:document.image)
        #expect(pixels.colorAt(x:170,y:70)!.greenComponent<0.3)
        #expect(pixels.colorAt(x:170,y:160)!.greenComponent>0.9)
        document.undo();#expect(document.marks[0].control == nil)
        document.redo();#expect(document.marks[0].curveMidpoint == target)
    }
    @Test @MainActor func allArrowStylesHaveDistinctRenderedShapes() throws {
        let image=try blank()
        var outputs=Set<Data>()
        for style in CaptureArrowStyle.allCases {
            var mark=CaptureMark(tool:.arrow,points:[CGPoint(x:40,y:120),CGPoint(x:300,y:80)],color:.red,width:5)
            mark.style.arrow=style
            outputs.insert(try CaptureImage.png(CaptureImage.render(image,marks:[mark])))
        }
        #expect(outputs.count == CaptureArrowStyle.allCases.count)
    }
    @Test @MainActor func serialNumbersIncrementRenumberAndKeepFormats() throws {
        let document=CaptureDocument(image:try blank())
        for i in 1...5 {
            var mark=CaptureMark(tool:.number,points:[CGPoint(x:CGFloat(i)*55,y:80),CGPoint(x:CGFloat(i)*55,y:80)],color:.blue,width:3)
            mark.numberValue=document.nextNumber(format:.decimal);document.add(mark)
        }
        #expect(document.marks.map { $0.numberValue } == [1,2,3,4,5])
        document.removeMark(at:1)
        #expect(document.marks.map { $0.numberValue } == [1,2,3,4])
        document.undo();#expect(document.marks.map { $0.numberValue } == [1,2,3,4,5])
        #expect(CaptureNumberFormat.upperAlpha.label(27) == "AA")
        #expect(CaptureNumberFormat.roman.label(14) == "XIV")
        #expect(CaptureNumberFormat.padded.label(5) == "05")
        #expect(document.nextNumber(format:.upperAlpha) == 1)
    }
    @Test @MainActor func mosaicsAndBlurWorkForRectangleAndBrushAndSurviveExport() throws {
        let context=try CaptureImage.context(width:360,height:240)
        for y in 0..<240 { for x in 0..<360 {
            context.setFillColor((x/3+y/3)%2==0 ? NSColor.white.cgColor:NSColor.black.cgColor)
            context.fill(CGRect(x:x,y:y,width:1,height:1))
        }}
        let original=try #require(context.makeImage()),source=NSBitmapImageRep(cgImage:original)
        for mode in [CaptureMosaicMode.pixels,.blur] {
            for coverage in CaptureCoverage.allCases {
                var mark=CaptureMark(tool:.mosaic,points:[CGPoint(x:60,y:70),CGPoint(x:120,y:90),CGPoint(x:220,y:140)],color:.red,width:3)
                mark.style.mosaic=mode;mark.style.coverage=coverage;mark.style.strength=24;mark.style.brushSize=40
                let result=try CaptureImage.render(original,marks:[mark]),pixels=NSBitmapImageRep(cgImage:result)
                #expect(pixels.colorAt(x:10,y:10) == source.colorAt(x:10,y:10))
                var changed=0
                for y in 78..<105 { for x in 95..<145 where pixels.colorAt(x:x,y:y) != source.colorAt(x:x,y:y) { changed += 1 } }
                #expect(changed>100)
                if coverage == .brush { #expect(pixels.colorAt(x:70,y:135) == source.colorAt(x:70,y:135)) }
                let data=try CaptureImage.png(result)
                #expect(!data.isEmpty)
            }
        }
    }
    @Test @MainActor func editableArchiveKeepsStylesCurvesAndSourceAfterReopening() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("AnnotationArchive-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let url=folder.appendingPathComponent(UUID().uuidString+".png")
        let document=CaptureDocument(image:try blank())
        var mark=CaptureMark(tool:.arrow,points:[CGPoint(x:40,y:180),CGPoint(x:300,y:150)],color:.purple,width:5)
        mark.control=CGPoint(x:140,y:20);mark.style.arrow = .double;mark.text="曲线"
        document.add(mark);try CaptureImage.png(document.image).write(to:url)
        try CaptureEditableArchive.save(document,for:url)
        let reopened=CaptureDocument(image:try CaptureImage.load(url))
        try CaptureEditableArchive.restore(reopened,for:url)
        #expect(reopened.marks.count == 1)
        #expect(reopened.marks[0].id == mark.id && reopened.marks[0].control == mark.control)
        #expect(reopened.marks[0].style.arrow == .double && reopened.marks[0].text == "曲线")
        reopened.clearMarks()
        #expect(NSBitmapImageRep(cgImage:reopened.image).colorAt(x:40,y:180)!.brightnessComponent>0.95)
        #expect(document.marks.count == 1)
    }
    @Test @MainActor func canvasCreatesNumbersAndEditsCurveOnTheFirstDrag() async throws {
        let suite="AnnotationCanvas-"+UUID().uuidString,defaults=try #require(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at:folder) }
        let controller=ScreenshotController(directory:folder)
        let editor=CaptureFloatingEditor(document:CaptureDocument(image:try blank()),controller:controller,annotationDefaults:defaults)
        defer { editor.close() }
        editor.show()
        func drawView(_ view:NSView)->CaptureDrawingView? {
            if let drawing=view as? CaptureDrawingView { return drawing }
            return view.subviews.lazy.compactMap { drawView($0) }.first
        }
        let root=try #require(editor.canvasPanel.contentView)
        func settle() async { for _ in 0..<5 { await Task.yield() };root.layoutSubtreeIfNeeded() }
        await settle()
        let canvas=try #require(drawView(root))
        func send(_ type:NSEvent.EventType,_ point:CGPoint) throws {
            let factor=CGFloat(editor.document.image.width)/canvas.bounds.width
            let location=canvas.convert(CGPoint(x:point.x/factor,y:point.y/factor),to:nil)
            let event=try #require(NSEvent.mouseEvent(with:type,location:location,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                windowNumber:editor.canvasPanel.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
            editor.canvasPanel.sendEvent(event)
        }
        editor.perform(.number);await settle()
        for i in 1...5 {
            let p=CGPoint(x:CGFloat(i)*55,y:50)
            try send(.leftMouseDown,p);try send(.leftMouseUp,p);await settle()
        }
        #expect(editor.document.marks.map { $0.numberValue } == [1,2,3,4,5])
        editor.document.clearMarks();editor.perform(.arrow);await settle()
        try send(.leftMouseDown,CGPoint(x:20,y:70));try send(.leftMouseDragged,CGPoint(x:150,y:70));try send(.leftMouseUp,CGPoint(x:150,y:70));await settle()
        #expect(editor.document.marks.count == 1)
        let arrow=try #require(editor.document.marks.first)
        editor.toolsPanel.makeKeyAndOrderFront(nil)
        try send(.leftMouseDown,CGPoint(x:85,y:70));try send(.leftMouseDragged,CGPoint(x:85,y:35));try send(.leftMouseUp,CGPoint(x:85,y:35));await settle()
        #expect(editor.document.marks[0].id == arrow.id)
        #expect(editor.document.marks[0].control != nil)
        #expect(abs(editor.document.marks[0].curveMidpoint.y-35)<1)
    }
    @Test @MainActor func styleScrubbingIsOneUndo() throws {
        let document=CaptureDocument(image:try blank())
        var mark=CaptureMark(tool:.rectangle,points:[CGPoint(x:40,y:40),CGPoint(x:250,y:180)],color:.red,width:3)
        document.add(mark);document.beginMarkEdit(mark.id)
        for radius in stride(from:0,through:40,by:4) { mark.style.cornerRadius=CGFloat(radius);document.previewMark(mark) }
        document.finishMarkEdit()
        #expect(document.undoCount == 2)
        document.undo();#expect(document.marks[0].style.cornerRadius == 0)
        document.redo();#expect(document.marks[0].style.cornerRadius == 40)
    }
    @Test @MainActor func ringsWatermarksMagnifiersAndLayersRenderTheirActualPixels() throws {
        let base=try blank()
        var ring=CaptureMark(tool:.ellipse,points:[CGPoint(x:40,y:40),CGPoint(x:180,y:160)],color:.green,width:3)
        ring.style.ellipseKind = .ring;ring.style.fill = .solid
        let pixels=NSBitmapImageRep(cgImage:try CaptureImage.render(base,marks:[ring]))
        #expect(pixels.colorAt(x:110,y:100)!.brightnessComponent>0.95)
        #expect(pixels.colorAt(x:45,y:100)!.greenComponent>0.7 && pixels.colorAt(x:45,y:100)!.redComponent<0.3)
        var watermark=CaptureMark(tool:.watermark,points:[.zero,CGPoint(x:360,y:240)],color:.black,width:3,text:"TEST {date}")
        watermark.style.opacity=0.3;watermark.style.rotation = -.pi/6;watermark.createdAt=Date(timeIntervalSince1970:0)
        let first=try CaptureImage.png(CaptureImage.render(base,marks:[watermark]))
        #expect(first != (try CaptureImage.png(base)))
        #expect(first == (try CaptureImage.png(CaptureImage.render(base,marks:[watermark]))))
        let document=CaptureDocument(image:base)
        let red=CaptureMark(tool:.cover,points:[CGPoint(x:40,y:40),CGPoint(x:140,y:140)],color:.red,width:3)
        let blue=CaptureMark(tool:.cover,points:red.points,color:.blue,width:3)
        document.add(red);document.add(blue);document.selectedMarkID=red.id
        document.selectionAction(.front)
        #expect(NSBitmapImageRep(cgImage:document.image).colorAt(x:80,y:80)!.redComponent>0.9)
        document.undo();#expect(document.marks.last?.id == blue.id)
        document.selectedMarkID=red.id;document.selectionAction(.duplicate)
        #expect(document.marks.count == 3 && document.marks.last?.id != red.id)
        var magnifier=CaptureMark(tool:.magnify,points:[CGPoint(x:45,y:45),CGPoint(x:100,y:100)],color:.orange,width:3)
        magnifier.style.magnification=2;magnifier.style.ellipse=false
        let result=try CaptureImage.render(document.image,marks:[magnifier])
        let frame=magnifier.calloutRect(in:CGRect(x:0,y:0,width:360,height:240))
        #expect(frame.minX>100 && frame.width==110)
        #expect(NSBitmapImageRep(cgImage:result).colorAt(x:Int(frame.midX),y:Int(frame.midY))!.redComponent>0.9)
    }
    @Test @MainActor func galleryShowsTheNewStyles() throws {
        guard let output=ProcessInfo.processInfo.environment["TIETIEZHI_ANNOTATION_PREVIEW"] else { return }
        let context=try CaptureImage.context(width:900,height:600)
        context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:900,height:600))
        let base=try #require(context.makeImage());var marks:[CaptureMark]=[]
        for (i,style) in CaptureArrowStyle.allCases.enumerated() {
            let y=CGFloat(55+i*75)
            var mark=CaptureMark(tool:.arrow,points:[CGPoint(x:50,y:y+20),CGPoint(x:300,y:y+20)],color:.systemRed,width:5)
            mark.style.arrow=style;marks.append(mark)
            var label=CaptureMark(tool:.text,points:[CGPoint(x:50,y:y+34)],color:.darkGray,width:3,text:style.title);label.style.fontSize=15;marks.append(label)
        }
        var curve=CaptureMark(tool:.arrow,points:[CGPoint(x:400,y:170),CGPoint(x:800,y:170)],color:.systemBlue,width:6)
        curve.control=CGPoint(x:600,y:-30);curve.style.arrow = .tapered;marks.append(curve)
        var rectangle=CaptureMark(tool:.rectangle,points:[CGPoint(x:400,y:220),CGPoint(x:640,y:340)],color:.systemBlue,width:5)
        rectangle.style.cornerRadius=32;marks.append(rectangle)
        var ring=CaptureMark(tool:.ellipse,points:[CGPoint(x:700,y:220),CGPoint(x:830,y:350)],color:.systemGreen,width:5)
        ring.style.ellipseKind = .ring;ring.style.fill = .solid;marks.append(ring)
        for i in 1...5 {
            var mark=CaptureMark(tool:.number,points:[CGPoint(x:CGFloat(350+i*85),y:440)],color:.systemOrange,width:3)
            mark.numberValue=i;mark.style.fontSize=28;mark.style.number = i%2==0 ? .outlineCircle:.circle;marks.append(mark)
        }
        var title=CaptureMark(tool:.text,points:[CGPoint(x:400,y:515)],color:.darkGray,width:3,text:"圆角 · 曲线箭头 · 自动序号 · 二次编辑")
        title.style.fontSize=22;marks.append(title)
        try CaptureImage.png(CaptureImage.render(base,marks:marks)).write(to:URL(fileURLWithPath:output))
    }
    @Test @MainActor func closingAndReopeningHistoryKeepsEditableAnnotations() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("SavedAnnotations-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let controller=ScreenshotController(directory:folder)
        defer { controller.deactivate() }
        let record=try controller.storeImage(blank())
        controller.open(record)
        let first=try #require(controller.editors.first)
        var mark=CaptureMark(tool:.rectangle,points:[CGPoint(x:30,y:30),CGPoint(x:240,y:160)],color:.red,width:4)
        mark.style.cornerRadius=24;first.document.add(mark);first.close()
        #expect(FileManager.default.fileExists(atPath:CaptureEditableArchive.url(for:controller.url(record)).path))
        controller.open(record)
        let reopened=try #require(controller.editors.first)
        #expect(reopened.document.marks.first?.id == mark.id)
        #expect(reopened.document.marks.first?.style.cornerRadius == 24)
    }
    @MainActor private func blank() throws -> CGImage {
        let context=try CaptureImage.context(width:360,height:240)
        context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:360,height:240))
        return try #require(context.makeImage())
    }
}
