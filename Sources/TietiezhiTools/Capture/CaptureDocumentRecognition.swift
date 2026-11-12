import AppKit
import Vision
import CoreText

struct CaptureDocumentParagraph:Identifiable,Sendable {
    var id=UUID()
    var text:String
    var rect:CGRect
}
struct CaptureTableCell:Identifiable,Codable,Sendable,Equatable {
    var id=UUID()
    var row:Int
    var column:Int
    var rowSpan=1
    var columnSpan=1
    var text:String
    var rect:CGRect
}
struct CaptureDetectedTable:Identifiable,Codable,Sendable,Equatable {
    var id=UUID()
    var name:String
    var rowCount:Int
    var columnCount:Int
    var cells:[CaptureTableCell]
    var rect:CGRect
    var rows:[[String]] {
        guard rowCount>0,columnCount>0,rowCount<=10000,columnCount<=1024 else { return [] }
        var values=Array(repeating:Array(repeating:"",count:columnCount),count:rowCount)
        for cell in cells where (0..<rowCount).contains(cell.row) && (0..<columnCount).contains(cell.column) { values[cell.row][cell.column]=cell.text }
        return values
    }
    mutating func merge(_ id:UUID,rows:Int,columns:Int) throws {
        guard let target=cells.first(where:{ $0.id==id }),rows>0,columns>0,target.row+rows<=rowCount,target.column+columns<=columnCount else { throw PluginError.invalid("合并范围超出表格。") }
        let region=CGRect(x:target.column,y:target.row,width:columns,height:rows)
        let affected=cells.filter { region.intersects(CGRect(x:$0.column,y:$0.row,width:$0.columnSpan,height:$0.rowSpan)) }
        guard affected.allSatisfy({ region.contains(CGRect(x:$0.column,y:$0.row,width:$0.columnSpan,height:$0.rowSpan)) }) else { throw PluginError.invalid("范围跨过已有合并单元格，请先拆分。") }
        var merged=target;merged.rowSpan=rows;merged.columnSpan=columns
        merged.text=affected.sorted { ($0.row,$0.column)<($1.row,$1.column) }.map(\.text).filter { !$0.isEmpty }.joined(separator:"\n")
        merged.rect=affected.reduce(CGRect.null) { $0.union($1.rect) }
        let ids=Set(affected.map(\.id));cells.removeAll { ids.contains($0.id) };cells.append(merged)
    }
    mutating func split(_ id:UUID) {
        guard let target=cells.first(where:{ $0.id==id }),target.rowSpan>1 || target.columnSpan>1 else { return }
        cells.removeAll { $0.id==id }
        for row in target.row..<(target.row+target.rowSpan) { for column in target.column..<(target.column+target.columnSpan) {
            let rect=CGRect(x:target.rect.minX+CGFloat(column-target.column)/CGFloat(target.columnSpan)*target.rect.width,y:target.rect.maxY-CGFloat(row-target.row+1)/CGFloat(target.rowSpan)*target.rect.height,width:target.rect.width/CGFloat(target.columnSpan),height:target.rect.height/CGFloat(target.rowSpan))
            cells.append(CaptureTableCell(id:row==target.row && column==target.column ? target.id:UUID(),row:row,column:column,text:row==target.row && column==target.column ? target.text:"",rect:rect))
        } }
    }
    func validate() throws {
        guard rowCount>0,rowCount<=10000,columnCount>0,columnCount<=1024,cells.count<=100000 else { throw PluginError.invalid("表格尺寸超出支持范围。") }
        var occupied=Set<Int>()
        for cell in cells {
            guard cell.row>=0,cell.column>=0,cell.rowSpan>0,cell.columnSpan>0,cell.row+cell.rowSpan<=rowCount,cell.column+cell.columnSpan<=columnCount else { throw PluginError.invalid("合并单元格范围无效。") }
            for row in cell.row..<(cell.row+cell.rowSpan) { for column in cell.column..<(cell.column+cell.columnSpan) {
                guard occupied.insert(row*columnCount+column).inserted else { throw PluginError.invalid("合并单元格范围重叠。") }
            } }
        }
    }
}
struct CaptureDocumentStructure:Sendable {
    var title=""
    var paragraphs:[CaptureDocumentParagraph]=[]
    var tables:[CaptureDetectedTable]=[]
    var usesSystemStructure=false
    var markdown:String {
        var parts:[String]=[]
        if !title.isEmpty { parts.append("# "+title) }
        parts += paragraphs.map(\.text)
        for table in tables {
            let rows=table.rows
            guard let first=rows.first else { continue }
            let escape:(String)->String = { $0.replacingOccurrences(of:"|",with:"\\|").replacingOccurrences(of:"\n",with:"<br>") }
            parts.append("## "+table.name+"\n\n| "+first.map(escape).joined(separator:" | ")+" |\n| "+Array(repeating:"---",count:first.count).joined(separator:" | ")+" |\n"+rows.dropFirst().map { "| "+$0.map(escape).joined(separator:" | ")+" |" }.joined(separator:"\n"))
        }
        return parts.joined(separator:"\n\n")
    }
}

enum CaptureDocumentRecognition {
    static func recognize(_ image:CGImage) async throws -> CaptureDocumentStructure {
        if #available(macOS 26,*) {
            let request=RecognizeDocumentsRequest()
            let observations=try await request.perform(on:image)
            try Task.checkCancellation()
            var result=CaptureDocumentStructure(usesSystemStructure:true)
            for observation in observations {
                let document=observation.document
                if result.title.isEmpty { result.title=document.title?.transcript ?? "" }
                for table in document.tables {
                    let unique=Set(table.rows.flatMap { $0 })
                    let minimumRow=unique.map { $0.rowRange.lowerBound }.min() ?? 0
                    let minimumColumn=unique.map { $0.columnRange.lowerBound }.min() ?? 0
                    let cells=unique.map { cell in
                        CaptureTableCell(row:cell.rowRange.lowerBound-minimumRow,column:cell.columnRange.lowerBound-minimumColumn,rowSpan:cell.rowRange.count,columnSpan:cell.columnRange.count,text:cell.content.text.transcript,rect:cell.content.boundingRegion.boundingBox.cgRect)
                    }.sorted { ($0.row,$0.column)<($1.row,$1.column) }
                    let rows=max(table.rows.count,cells.map { $0.row+$0.rowSpan }.max() ?? 0)
                    let columns=max(table.columns.count,cells.map { $0.column+$0.columnSpan }.max() ?? 0)
                    let extracted=CaptureDetectedTable(name:"表格 \(result.tables.count+1)",rowCount:rows,columnCount:columns,cells:cells,rect:table.boundingRegion.boundingBox.cgRect)
                    if !cells.isEmpty { try extracted.validate();result.tables.append(extracted) }
                }
                let paragraphs=document.paragraphs.isEmpty ? [document.text]:document.paragraphs
                for paragraph in paragraphs where paragraph.transcript != result.title {
                    let rect=paragraph.boundingRegion.boundingBox.cgRect
                    // A paragraph contained in a table is represented by that table's cells, not duplicated.
                    if result.tables.contains(where:{ $0.rect.contains(CGPoint(x:rect.midX,y:rect.midY)) }) { continue }
                    result.paragraphs.append(CaptureDocumentParagraph(text:paragraph.transcript,rect:rect))
                }
            }
            return result
        }
        return basic(lines: try await CaptureRecognition.recognize(image).lines)
    }

    static func basic(lines: [RecognizedLine]) -> CaptureDocumentStructure {
        var rows: [[RecognizedLine]] = []
        for line in lines.sorted(by: { $0.rect.midY > $1.rect.midY }) {
            if let i = rows.firstIndex(where: { abs(($0.first?.rect.midY ?? 0) - line.rect.midY) < max(0.012, line.rect.height * 0.55) }) { rows[i].append(line) }
            else { rows.append([line]) }
        }
        let candidates = rows.filter { $0.count >= 2 }
        var groups: [[[RecognizedLine]]] = []
        for row in candidates {
            if let last = groups.last?.last?.first, let next = row.first,
               last.rect.midY - next.rect.midY < max(0.05, max(last.rect.height, next.rect.height) * 3.5) {
                groups[groups.count - 1].append(row)
            } else { groups.append([row]) }
        }
        var result = CaptureDocumentStructure()
        var tableRegions: [CGRect] = []
        for group in groups where group.count > 1 {
            let reference = group.max(by: { $0.count < $1.count }) ?? []
            let anchors = reference.map(\.rect.midX).sorted()
            guard anchors.count > 1 else { continue }
            var cells: [CaptureTableCell] = []
            for (rowIndex, row) in group.enumerated() {
                for column in anchors.indices {
                    let items = row.filter { item in anchors.indices.min(by: { abs(anchors[$0] - item.rect.midX) < abs(anchors[$1] - item.rect.midX) }) == column }.sorted(by: { $0.rect.minX < $1.rect.minX })
                    let rect = items.reduce(CGRect.null) { $0.union($1.rect) }
                    cells.append(CaptureTableCell(row: rowIndex, column: column, text: items.map(\.text).joined(separator: " "), rect: rect.isNull ? .zero : rect))
                }
            }
            let region = group.flatMap { $0 }.reduce(CGRect.null) { $0.union($1.rect) }
            tableRegions.append(region)
            result.tables.append(CaptureDetectedTable(name: "表格 \(result.tables.count + 1)", rowCount: group.count, columnCount: anchors.count, cells: cells, rect: region))
        }
        result.paragraphs = lines.filter { line in !tableRegions.contains(where: { $0.contains(CGPoint(x: line.rect.midX, y: line.rect.midY)) }) }.map { CaptureDocumentParagraph(text: $0.text, rect: $0.rect) }
        return result
    }

    static func keepingBasicTables(_ result: CaptureDocumentStructure, lines: [RecognizedLine]) -> CaptureDocumentStructure {
        guard result.tables.isEmpty else { return result }
        let basic = basic(lines: lines)
        guard !basic.tables.isEmpty else { return result }
        var combined = result
        combined.tables = basic.tables
        combined.paragraphs.removeAll { paragraph in basic.tables.contains(where: { $0.rect.contains(CGPoint(x: paragraph.rect.midX, y: paragraph.rect.midY)) }) }
        return combined
    }
}

enum CaptureStructuredExport {
    private static func xml(_ text:String)->String { CaptureDocumentExport.xml(text) }
    static func columnName(_ number:Int) -> String {
        var value=number+1,result=""
        while value>0 { value-=1;result=String(UnicodeScalar(65+value%26)!)+result;value/=26 }
        return result
    }
    static func cellReference(row:Int,column:Int)->String { columnName(column)+String(row+1) }
    static func spreadsheet(_ tables:[CaptureDetectedTable],to url:URL) throws {
        guard !tables.isEmpty,tables.count<=200 else { throw PluginError.invalid("没有可导出的表格，或表格数量过多。") }
        var files:[String:String]=[:],sheets="",relationships="",overrides=""
        for (index,table) in tables.enumerated() {
            try table.validate();let n=index+1
            // Prefix guarantees unique worksheet names even if the user repeats names.
            let name=String(("\(n) "+table.name.filter { !"[]:*?/\\'".contains($0) }).prefix(31))
            sheets += "<sheet name=\"\(xml(name))\" sheetId=\"\(n)\" r:id=\"rId\(n)\"/>"
            relationships += "<Relationship Id=\"rId\(n)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(n).xml\"/>"
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            var rows="",merges:[String]=[]
            let grouped=Dictionary(grouping:table.cells,by:\.row)
            for row in grouped.keys.sorted() {
                rows += "<row r=\"\(row+1)\">"
                for cell in grouped[row]!.sorted(by:{ $0.column<$1.column }) {
                    let start=cellReference(row:cell.row,column:cell.column)
                    rows += "<c r=\"\(start)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xml(cell.text))</t></is></c>"
                    if cell.rowSpan>1 || cell.columnSpan>1 { merges.append(start+":"+cellReference(row:cell.row+cell.rowSpan-1,column:cell.column+cell.columnSpan-1)) }
                }
                rows += "</row>"
            }
            let merged=merges.isEmpty ? "":"<mergeCells count=\"\(merges.count)\">"+merges.map { "<mergeCell ref=\"\($0)\"/>" }.joined()+"</mergeCells>"
            files["xl/worksheets/sheet\(n).xml"]="<?xml version=\"1.0\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(rows)</sheetData>\(merged)</worksheet>"
        }
        files["[Content_Types].xml"]=types("<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"+overrides)
        files["_rels/.rels"]=relations("<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>")
        files["xl/workbook.xml"]="<?xml version=\"1.0\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>\(sheets)</sheets></workbook>"
        files["xl/_rels/workbook.xml.rels"]=relations(relationships)
        try package(files,to:url)
    }
    static func document(_ structure:CaptureDocumentStructure,to url:URL) throws {
        func paragraph(_ text:String,bold:Bool=false)->String {
            "<w:p><w:r>\(bold ? "<w:rPr><w:b/></w:rPr>":"")<w:t xml:space=\"preserve\">\(xml(text))</w:t></w:r></w:p>"
        }
        var body=structure.title.isEmpty ? "":paragraph(structure.title,bold:true)
        body += structure.paragraphs.map { paragraph($0.text) }.joined()
        for table in structure.tables {
            try table.validate();body += paragraph(table.name,bold:true)
            body += "<w:tbl><w:tblPr><w:tblBorders>"+["top","left","bottom","right","insideH","insideV"].map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:color=\"BBBBBB\"/>" }.joined()+"</w:tblBorders></w:tblPr><w:tblGrid>"+Array(repeating:"<w:gridCol w:w=\"1800\"/>",count:table.columnCount).joined()+"</w:tblGrid>"
            for row in 0..<table.rowCount {
                body += "<w:tr>";var column=0
                while column<table.columnCount {
                    if let cell=table.cells.first(where:{ $0.column==column && $0.row<=row && $0.row+$0.rowSpan>row }) {
                        let continuation=row>cell.row
                        let span=cell.columnSpan>1 ? "<w:gridSpan w:val=\"\(cell.columnSpan)\"/>":""
                        let merge=cell.rowSpan>1 ? "<w:vMerge w:val=\"\(continuation ? "continue":"restart")\"/>":""
                        body += "<w:tc><w:tcPr>\(span)\(merge)</w:tcPr>\(paragraph(continuation ? "":cell.text))</w:tc>";column += cell.columnSpan
                    } else { body += "<w:tc><w:p/></w:tc>";column += 1 }
                }
                body += "</w:tr>"
            }
            body += "</w:tbl>"
        }
        try package([
            "[Content_Types].xml":types("<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"),
            "_rels/.rels":relations("<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>"),
            "word/document.xml":"<?xml version=\"1.0\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>\(body)<w:sectPr/></w:body></w:document>"
        ],to:url)
    }
    @MainActor static func searchablePDF(_ image:CGImage,lines:[RecognizedLine],to url:URL) throws {
        let scale=min(1,14000/CGFloat(max(image.width,image.height)))
        var page=CGRect(x:0,y:0,width:CGFloat(image.width)*scale,height:CGFloat(image.height)*scale)
        let staged=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".pdf")
        defer { try? FileManager.default.removeItem(at:staged) }
        guard let context=CGContext(staged as CFURL,mediaBox:&page,nil) else { throw PluginError.invalid("无法创建 PDF。") }
        context.beginPDFPage(nil);context.draw(image,in:page)
        for line in lines where !line.text.isEmpty {
            let r=line.rect,rect=CGRect(x:r.minX*page.width,y:r.minY*page.height,width:r.width*page.width,height:r.height*page.height).intersection(page)
            guard rect.width>0,rect.height>0 else { continue }
            let font=CTFontCreateWithName("Helvetica" as CFString,max(1,rect.height),nil)
            let attributed=NSAttributedString(string:line.text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String):true])
            let text=CTLineCreateWithAttributedString(attributed)
            var ascent:CGFloat=0,descent:CGFloat=0,leading:CGFloat=0
            let width=CTLineGetTypographicBounds(text,&ascent,&descent,&leading)
            guard width>0 else { continue }
            context.saveGState();context.translateBy(x:rect.minX,y:rect.minY)
            context.scaleBy(x:rect.width/width,y:rect.height/max(1,ascent+descent))
            context.textMatrix = .identity;context.textPosition=CGPoint(x:0,y:descent)
            context.setTextDrawingMode(.invisible);CTLineDraw(text,context);context.restoreGState()
        }
        context.endPDFPage();context.closePDF()
        try Data(contentsOf:staged).write(to:url,options:.atomic)
    }
    private static func types(_ body:String)->String { "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>\(body)</Types>" }
    private static func relations(_ body:String)->String { "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(body)</Relationships>" }
    private static func package(_ files:[String:String],to url:URL) throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        for (name,value) in files {
            let file=directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data(value.utf8).write(to:file)
        }
        let archive=directory.appendingPathComponent("export.zip"),process=Process()
        process.executableURL=URL(fileURLWithPath:"/usr/bin/zip");process.currentDirectoryURL=directory
        process.arguments=["-q","-r",archive.path]+files.keys.sorted();process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try process.run();process.waitUntilExit()
        guard process.terminationStatus==0 else { throw PluginError.invalid("文档打包失败。") }
        try Data(contentsOf:archive).write(to:url,options:.atomic)
    }
}
