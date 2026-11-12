import AppKit
import PDFKit
import Testing
@testable import TietiezhiTools

@Suite(.serialized)
struct CaptureDocumentRecognitionTests {
    @Test func basicLayoutRetainsSeparateTablesAndSurvivesSystemMiss() {
        var lines = [RecognizedLine(text: "标题", rect: CGRect(x: 0.1, y: 0.9, width: 0.4, height: 0.03))]
        for origin in [0.75, 0.3] {
            for row in 0..<3 { for column in 0..<2 {
                lines.append(RecognizedLine(text: "\(row)-\(column)", rect: CGRect(x: 0.1 + Double(column) * 0.4, y: origin - Double(row) * 0.05, width: 0.15, height: 0.03)))
            } }
        }
        let basic = CaptureDocumentRecognition.basic(lines: lines)
        #expect(basic.tables.count == 2)
        #expect(basic.tables.allSatisfy { $0.rowCount == 3 && $0.columnCount == 2 })
        #expect(basic.paragraphs.map(\.text) == ["标题"])
        #expect(basic.tables[0].cells.allSatisfy { !$0.rect.isEmpty })
        let system = CaptureDocumentStructure(title: "标题", usesSystemStructure: true)
        let combined = CaptureDocumentRecognition.keepingBasicTables(system, lines: lines)
        #expect(combined.tables.count == 2)
        #expect(combined.title == "标题" && combined.usesSystemStructure)
    }
    private func sampleTable(_ name:String="表格") -> CaptureDetectedTable {
        CaptureDetectedTable(name:name,rowCount:2,columnCount:2,cells:[
            CaptureTableCell(row:0,column:0,text:"项目",rect:CGRect(x:0,y:0.5,width:0.5,height:0.5)),
            CaptureTableCell(row:0,column:1,text:"数量",rect:CGRect(x:0.5,y:0.5,width:0.5,height:0.5)),
            CaptureTableCell(row:1,column:0,text:"Apple",rect:CGRect(x:0,y:0,width:0.5,height:0.5)),
            CaptureTableCell(row:1,column:1,text:"5",rect:CGRect(x:0.5,y:0,width:0.5,height:0.5))
        ],rect:CGRect(x:0,y:0,width:1,height:1))
    }
    private func unzip(_ file:URL,path:String) throws -> String {
        let process=Process(),pipe=Pipe();process.executableURL=URL(fileURLWithPath:"/usr/bin/unzip")
        process.arguments=["-p",file.path,path];process.standardOutput=pipe;process.standardError=FileHandle.nullDevice
        try process.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        #expect(process.terminationStatus==0);return String(data:data,encoding:.utf8) ?? ""
    }
    @Test func mergedCellsPreserveContentAndCannotPartiallyOverlap() throws {
        var table=sampleTable();let id=table.cells[0].id
        try table.merge(id,rows:2,columns:1);try table.validate()
        #expect(table.cells.count==3)
        #expect(table.cells.first { $0.id==id }?.text=="项目\nApple")
        #expect(throws:PluginError.self) { try table.merge(table.cells.first { $0.row==0 && $0.column==1 }!.id,rows:1,columns:2) }
        table.split(id);try table.validate();#expect(table.cells.count==4)
        #expect(table.cells.first { $0.id==id }?.rowSpan==1)
    }
    @Test func spreadsheetExportsEveryTableAndMergeRanges() throws {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".xlsx")
        defer { try? FileManager.default.removeItem(at:file) }
        var first=sampleTable();try first.merge(first.cells[0].id,rows:1,columns:2)
        try CaptureStructuredExport.spreadsheet([first,sampleTable("第二张")],to:file)
        let workbook=try unzip(file,path:"xl/workbook.xml")
        #expect(workbook.contains("sheetId=\"1\"") && workbook.contains("sheetId=\"2\""))
        let sheet=try unzip(file,path:"xl/worksheets/sheet1.xml")
        #expect(sheet.contains("mergeCell ref=\"A1:B1\"") && sheet.contains("t=\"inlineStr\""))
        #expect(try unzip(file,path:"xl/worksheets/sheet2.xml").contains("Apple"))
    }
    @Test func wordPreservesVerticalMergesAndEscapesXML() throws {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".docx")
        defer { try? FileManager.default.removeItem(at:file) }
        var table=sampleTable();try table.merge(table.cells[0].id,rows:2,columns:1)
        try CaptureStructuredExport.document(CaptureDocumentStructure(title:"A & B < C",tables:[table]),to:file)
        let xml=try unzip(file,path:"word/document.xml")
        #expect(xml.contains("w:vMerge w:val=\"restart\"") && xml.contains("w:vMerge w:val=\"continue\""))
        #expect(xml.contains("A &amp; B &lt; C"))
    }
    @Test @MainActor func searchablePDFRetainsOriginalImageAndPositionedText() throws {
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".pdf")
        defer { try? FileManager.default.removeItem(at:file) }
        let context=try CaptureImage.context(width:240,height:120)
        context.setFillColor(NSColor.green.cgColor);context.fill(CGRect(x:0,y:0,width:240,height:120))
        let image=try #require(context.makeImage())
        let line=RecognizedLine(text:"Invoice ID 123",rect:CGRect(x:0.1,y:0.6,width:0.6,height:0.2))
        let chinese=RecognizedLine(text:"中文编号 123",rect:CGRect(x:0.1,y:0.25,width:0.6,height:0.2))
        try CaptureStructuredExport.searchablePDF(image,lines:[line,chinese],to:file)
        let document=try #require(PDFDocument(url:file)),page=try #require(document.page(at:0))
        #expect(document.pageCount==1 && page.bounds(for:.mediaBox).size==CGSize(width:240,height:120))
        #expect(document.string?.contains("Invoice ID 123")==true)
        #expect(document.string?.contains("中文编号 123")==true)
        let selection=try #require(document.findString("Invoice",withOptions:[]).first)
        #expect(abs(selection.bounds(for:page).minX-24)<2)
        #expect(selection.bounds(for:page).midY>65)
        let preview=page.thumbnail(of:CGSize(width:240,height:120),for:.mediaBox)
        let bitmap=NSBitmapImageRep(cgImage:try #require(preview.cgImage(forProposedRect:nil,context:nil,hints:nil)))
        let color=try #require(bitmap.colorAt(x:bitmap.pixelsWide/2,y:bitmap.pixelsHigh/2)?.usingColorSpace(.deviceRGB))
        #expect(color.greenComponent>0.8 && color.redComponent<0.2)
    }
    @Test func textSelectionUsesUnequalCharacterBoxesAndUnicodeRanges() {
        let line=RecognizedLine(text:"W中i",rect:CGRect(x:0,y:0,width:1,height:0.1),fragments:[
            RecognizedTextFragment(range:NSRange(location:0,length:1),rect:CGRect(x:0,y:0,width:0.4,height:0.1)),
            RecognizedTextFragment(range:NSRange(location:1,length:1),rect:CGRect(x:0.4,y:0,width:0.5,height:0.1)),
            RecognizedTextFragment(range:NSRange(location:2,length:1),rect:CGRect(x:0.9,y:0,width:0.1,height:0.1))
        ])
        #expect(CapturePinTextGeometry.bounds(line,characters:1..<2)==CGRect(x:0.4,y:0,width:0.5,height:0.1))
        #expect(CapturePinTextGeometry.characterOffset(line,normalizedX:0.55)==1)
        #expect(CapturePinTextGeometry.characterOffset(line,normalizedX:0.88)==2)
        #expect(CaptureStructuredExport.columnName(26)=="AA")
    }
    @Test func animationAssetPathsCannotEscapePinDirectory() {
        let id=UUID().uuidString
        #expect(CapturePinMedia.safeAssetFilename(id+".gif"))
        #expect(CapturePinMedia.safeAssetFilename(id+".webp"))
        #expect(!CapturePinMedia.safeAssetFilename("../"+id+".gif"))
        #expect(!CapturePinMedia.safeAssetFilename(id+".gif/secret"))
        #expect(!CapturePinMedia.safeAssetFilename(id+".html"))
    }
}
