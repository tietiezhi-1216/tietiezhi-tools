import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import TietiezhiTools

@Suite(.serialized)
struct CapturePinMediaTests {
    @Test @MainActor func oldPinRecordsRemainReadableWithoutNewFields() throws {
        let item=CapturePinRecord(filename:"example.png",groupID:CapturePinGroup.defaultID,text:"legacy")
        var object=try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(item)) as? [String:Any])
        object.removeValue(forKey:"payload");object.removeValue(forKey:"adjustments");object.removeValue(forKey:"viewport")
        let decoded=try JSONDecoder().decode(CapturePinRecord.self,from:JSONSerialization.data(withJSONObject:object))
        #expect(decoded.text=="legacy" && decoded.payload==nil && decoded.viewport==nil)
    }
    @Test @MainActor func selectedPinsMoveAndCloseTogetherAndLockedPinsStayOpen() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let manager=CapturePinManager(directory:folder,displaysWindows:false)
        let image=try #require(CaptureImage.context(width:20,height:10).makeImage())
        let first=try manager.create(image),second=try manager.create(image),third=try manager.create(image)
        manager.selectedIDs=[first,second]
        manager.toggle(first,\.locked)
        manager.closeSelection(first)
        #expect(manager.record(first)?.isOpen==true)
        #expect(manager.record(second)?.isOpen==false)
        #expect(manager.record(third)?.isOpen==true)
        let group=manager.createGroup(name:"测试")
        manager.selectedIDs=[first,second];manager.moveSelection(first,to:group)
        #expect(manager.record(first)?.groupID==group && manager.record(second)?.groupID==group)
        #expect(manager.record(third)?.groupID==CapturePinGroup.defaultID)
    }
    @Test @MainActor func viewportAndTransformsPersistWithoutDestroyingOriginalPixels() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let manager=CapturePinManager(directory:folder,displaysWindows:false)
        let ctx=try CaptureImage.context(width:100,height:60)
        ctx.setFillColor(NSColor.red.cgColor);ctx.fill(CGRect(x:0,y:0,width:100,height:60))
        let id=try manager.create(#require(ctx.makeImage()))
        let original=try Data(contentsOf:manager.url(#require(manager.record(id))))
        manager.adjust(id) { $0.quarterTurns=1;$0.grayscale=true }
        #expect(manager.image(id)?.width==60 && manager.image(id)?.height==100)
        manager.setViewport(id,CGRect(x:0.25,y:0.2,width:0.5,height:0.5))
        #expect(manager.visibleImage(id)?.width==30 && manager.visibleImage(id)?.height==50)
        manager.saveNow()
        let restored=CapturePinManager(directory:folder,displaysWindows:false)
        #expect(restored.record(id)?.adjustments?.quarterTurns==1)
        let viewport=try #require(restored.record(id)?.viewport)
        #expect(abs(viewport.minX-0.25)<0.000001 && abs(viewport.minY-0.2)<0.000001 && abs(viewport.width-0.5)<0.000001 && abs(viewport.height-0.5)<0.000001)
        #expect(try Data(contentsOf:manager.url(#require(manager.record(id))))==original)
    }
    @Test @MainActor func animationCopiesAllFramesAndDoesNotDependOnSourceFile() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let file=folder.appendingPathComponent("source.gif")
        let destination=try #require(CGImageDestinationCreateWithURL(file as CFURL,UTType.gif.identifier as CFString,2,nil))
        for color in [NSColor.red,NSColor.blue] {
            let ctx=try CaptureImage.context(width:20,height:10);ctx.setFillColor(color.cgColor);ctx.fill(CGRect(x:0,y:0,width:20,height:10))
            CGImageDestinationAddImage(destination,try #require(ctx.makeImage()),[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.1]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        let manager=CapturePinManager(directory:folder.appendingPathComponent("pins"),displaysWindows:false)
        let id=try manager.createFile(file)
        try FileManager.default.removeItem(at:file)
        let asset=try #require(manager.assetURL(id))
        #expect(manager.record(id)?.payload?.kind == .animation)
        let animation=try #require(CapturePinAnimation(url:asset));#expect(animation.count==2)
        var displayed:CGImage?;animation.changed={ displayed=$0 };animation.step(1)
        #expect(animation.paused && animation.index==1 && displayed != nil)
    }
    @Test func colorAndFormulaAreDistinguishedFromOrdinaryText() {
        #expect(CapturePinMedia.color("#f80") != nil)
        #expect(CapturePinMedia.color("rgb(20, 120, 255)") != nil)
        #expect(CapturePinMedia.color("rgb(999, 1, 1)")==nil)
        #expect(CapturePinMedia.formula("$$\\frac{a}{b}$$")=="\\frac{a}{b}")
        #expect(CapturePinMedia.formula("cost $10 only")==nil)
    }
    @Test func importedHTMLCannotLoadRemoteContentOrExecuteScripts() throws {
        let input="<script src='https://evil.test/a.js'></script><iframe src='https://evil.test'></iframe><img src='https://evil.test/pixel'><link href='https://evil.test/style.css'><span style='color:red;background-image:url(https://evil.test)'>hello</span>"
        let result=String(data:try #require(CapturePinMedia.sanitizedHTML(Data(input.utf8))),encoding:.utf8) ?? ""
        #expect(!result.contains("https://") && !result.contains("<script") && !result.contains("<img") && !result.contains("<iframe"))
        #expect(result.contains("color:red") && result.contains("hello"))
    }
    @Test @MainActor func mouseDefaultsPersistOverridesAndRejectConflicts() throws {
        let name=UUID().uuidString,defaults=try #require(UserDefaults(suiteName:name))
        defer { defaults.removePersistentDomain(forName:name) }
        let settings=CapturePinMouseSettings(defaults:defaults)
        #expect(settings.gesture(.close)=="0:0:double")
        #expect(throws:PluginError.self) { try settings.set("0:0:double",for:.reset) }
        try settings.set("",for:.close);try settings.set("0:0:double",for:.reset)
        #expect(CapturePinMouseSettings(defaults:defaults).gesture(.reset)=="0:0:double")
    }
}
