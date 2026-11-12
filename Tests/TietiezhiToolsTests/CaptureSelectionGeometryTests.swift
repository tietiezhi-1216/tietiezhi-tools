import AppKit
import Testing
@testable import TietiezhiTools

struct CaptureSelectionGeometryTests {
    @Test func centeredResizePreservesCenterAndAspectRatio() {
        let original=CGRect(x:100,y:100,width:160,height:90)
        let result=CaptureSelectionGeometry.resize(original,handle:.bottomRight,delta:CGSize(width:20,height:10),bounds:CGRect(x:0,y:0,width:800,height:600),ratio:16/9,centered:true)
        #expect(result.midX==original.midX)
        #expect(result.midY==original.midY)
        #expect(abs(result.width/result.height-16/9)<0.001)
    }
    @Test func selectionCannotEscapeDisplayOrBecomeNegative() {
        let bounds=CGRect(x:0,y:0,width:300,height:200)
        let oversized=CaptureSelectionGeometry.constrain(CGRect(x:-100,y:190,width:700,height:700),in:bounds)
        #expect(oversized==bounds)
        let reversed=CaptureSelectionGeometry.resize(CGRect(x:40,y:50,width:90,height:80),handle:.left,delta:CGSize(width:300,height:0),bounds:bounds)
        #expect(reversed.width>=8)
        #expect(bounds.contains(reversed))
    }
    @Test func shapeVerticesFollowResizedSelection() {
        let points=[CGPoint(x:10,y:20),CGPoint(x:110,y:20),CGPoint(x:60,y:70)]
        let result=CaptureSelectionGeometry.transform(points,from:CGRect(x:10,y:20,width:100,height:50),to:CGRect(x:30,y:40,width:200,height:100))
        #expect(result==[CGPoint(x:30,y:40),CGPoint(x:230,y:40),CGPoint(x:130,y:140)])
    }
    @Test func irregularCaptureActuallyHasTransparentPixels() throws {
        let context=try CaptureImage.context(width:20,height:20)
        context.setFillColor(NSColor.red.cgColor);context.fill(CGRect(x:0,y:0,width:20,height:20))
        let source=try #require(context.makeImage())
        let result=try CaptureSelectionGeometry.masked(source,points:[CGPoint(x:0,y:0),CGPoint(x:20,y:0),CGPoint(x:0,y:20)],rect:CGRect(x:0,y:0,width:20,height:20),scale:1)
        let bitmap=NSBitmapImageRep(cgImage:result)
        #expect((bitmap.colorAt(x:2,y:2)?.alphaComponent ?? 0)>0.9)
        #expect((bitmap.colorAt(x:18,y:18)?.alphaComponent ?? 1)<0.1)
    }
    @Test func additionPreservesOverlapAndSubtractionCreatesHole() throws {
        let context=try CaptureImage.context(width:40,height:40)
        context.setFillColor(NSColor.red.cgColor);context.fill(CGRect(x:0,y:0,width:40,height:40))
        let source=try #require(context.makeImage())
        let contours=[
            CaptureSelectionContour(points:CaptureSelectionGeometry.rectangle(CGRect(x:0,y:0,width:30,height:30))),
            CaptureSelectionContour(points:CaptureSelectionGeometry.rectangle(CGRect(x:10,y:10,width:30,height:30))),
            CaptureSelectionContour(points:CaptureSelectionGeometry.rectangle(CGRect(x:15,y:15,width:10,height:10)),subtract:true)
        ]
        let image=try CaptureSelectionGeometry.masked(source,contours:contours,rect:CGRect(x:0,y:0,width:40,height:40),scale:1)
        let bitmap=NSBitmapImageRep(cgImage:image)
        #expect((bitmap.colorAt(x:12,y:12)?.alphaComponent ?? 0)>0.9)
        #expect((bitmap.colorAt(x:20,y:20)?.alphaComponent ?? 1)<0.1)
        #expect((bitmap.colorAt(x:35,y:35)?.alphaComponent ?? 0)>0.9)
        #expect((bitmap.colorAt(x:35,y:2)?.alphaComponent ?? 1)<0.1)
    }
    @Test func screenshotShadowAddsPaddingWithoutResizingImage() throws {
        let context=try CaptureImage.context(width:40,height:30)
        context.setFillColor(NSColor.red.cgColor);context.fill(CGRect(x:0,y:0,width:40,height:30))
        let image=try CaptureSelectionGeometry.decorate(#require(context.makeImage()),cornerRadius:0,shadow:true,border:false)
        #expect(image.width==72)
        #expect(image.height==62)
        #expect((NSBitmapImageRep(cgImage:image).colorAt(x:20,y:20)?.redComponent ?? 0)>0.9)
    }
    @Test func screenshotDecorationParametersChangeOutputPixels() throws {
        let context=try CaptureImage.context(width:80,height:60)
        context.setFillColor(NSColor.red.cgColor);context.fill(CGRect(x:0,y:0,width:80,height:60))
        let source=try #require(context.makeImage())
        let border=try CaptureSelectionGeometry.decorate(source,cornerRadius:12,shadow:false,border:true,borderWidth:6,borderColor:.blue)
        let pixels=NSBitmapImageRep(cgImage:border)
        #expect(border.width==80 && border.height==60)
        #expect((pixels.colorAt(x:0,y:0)?.alphaComponent ?? 1)<0.1)
        #expect((pixels.colorAt(x:40,y:2)?.blueComponent ?? 0)>0.9)
        #expect((pixels.colorAt(x:40,y:10)?.redComponent ?? 0)>0.9)
        let shadow=try CaptureSelectionGeometry.decorate(source,cornerRadius:0,shadow:true,border:false,shadowBlur:20,shadowOpacity:0.4,shadowOffset:8)
        #expect(shadow.width==152 && shadow.height==132)
        #expect((NSBitmapImageRep(cgImage:shadow).colorAt(x:76,y:66)?.redComponent ?? 0)>0.9)
    }
    @Test func decoratedTransparentSelectionKeepsItsHoles() throws {
        let context=try CaptureImage.context(width:80,height:80)
        context.setFillColor(NSColor.red.cgColor);context.fill(CGRect(x:0,y:0,width:80,height:80))
        context.clear(CGRect(x:20,y:20,width:40,height:40))
        let image=try CaptureSelectionGeometry.decorate(#require(context.makeImage()),cornerRadius:8,shadow:true,border:false,shadowBlur:0,shadowOffset:0)
        let pixels=NSBitmapImageRep(cgImage:image)
        #expect((pixels.colorAt(x:40,y:40)?.alphaComponent ?? 1)<0.1)
        #expect((pixels.colorAt(x:10,y:10)?.redComponent ?? 0)>0.9)
        #expect(CaptureSelectionGeometry.decorationPadding(shadow:true,blur:.nan,offset:.infinity)==16)
    }
    @Test func globalMouseDefaultsAreOptInAndIgnoresSupportWildcards() {
        let name="capture-mouse-test-\(UUID())"
        let defaults=UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        #expect(!CaptureGlobalMousePreferences(defaults:defaults).enabled)
        defaults.set("com.apple.*, org.example.Editor",forKey:"capture.mouse.ignored")
        let preferences=CaptureGlobalMousePreferences(defaults:defaults)
        #expect(preferences.ignores("COM.APPLE.Terminal"))
        #expect(preferences.ignores("org.example.Editor"))
        #expect(!preferences.ignores("org.example.EditorOther"))
    }
}
