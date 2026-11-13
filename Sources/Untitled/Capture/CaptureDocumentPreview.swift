import AppKit
import SwiftUI

struct CaptureDocumentPreview:View {
    let image:CGImage
    var initialLines:[RecognizedLine]=[]
    @Environment(\.dismiss) private var dismiss
    @ViewState private var structure=CaptureDocumentStructure()
    @ViewState private var lines:[RecognizedLine]=[]
    @ViewState private var selectedTable=0
    @ViewState private var selectedCell:UUID?
    @ViewState private var mode=0
    @ViewState private var mergeRows=1
    @ViewState private var mergeColumns=1
    @ViewState private var busy=true
    @ViewState private var error:String?
    @ViewState private var recognitionTask: Task<Void, Never>?
    @ViewState private var recognitionGeneration = 0
    private var table:CaptureDetectedTable? { structure.tables.indices.contains(selectedTable) ? structure.tables[selectedTable]:nil }
    private var cell:CaptureTableCell? { table?.cells.first { $0.id==selectedCell } }
    var body:some View {
        VStack(spacing:14) {
            HStack {
                Text("文档与表格").font(.headline)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if recognitionTask != nil {
                    Button("取消识别") { cancelRecognition() }
                } else if #available(macOS 26, *) {
                    Button("重新识别结构") { enhanceStructure() }
                        .disabled(busy).help("使用系统文档模型重新识别并替换当前结构")
                }
                Menu("导出") {
                    Button("全部表格 Excel (.xlsx)") { export("xlsx") }.disabled(structure.tables.isEmpty)
                    Button("当前表格 CSV (.csv)") { export("csv") }.disabled(table==nil)
                    Button("可编辑 Word (.docx)") { export("docx") }
                    Button("Markdown (.md)") { export("md") }
                    Button("原图与可搜索文字 PDF") { export("pdf") }
                }.disabled(busy).fixedSize()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if !busy {
                HStack {
                    Picker("内容",selection:$mode) { Text("文档").tag(0);Text("表格（\(structure.tables.count)）").tag(1) }.pickerStyle(.segmented).frame(width:230)
                    if !structure.usesSystemStructure { Text("基础文字布局").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if mode==1,!structure.tables.isEmpty {
                        Picker("表格",selection:$selectedTable) { ForEach(structure.tables.indices,id:\.self) { Text(structure.tables[$0].name).tag($0) } }.frame(width:190)
                    }
                }
            }
            HStack(alignment:.top,spacing:14) {
                original.frame(width:300)
                VStack(alignment:.leading,spacing:10) {
                    if mode==0 {
                        TextField("标题",text:$structure.title).textFieldStyle(.roundedBorder)
                        ScrollView { VStack(alignment:.leading,spacing:10) {
                            ForEach($structure.paragraphs) { $paragraph in
                                TextField("段落",text:$paragraph.text,axis:.vertical).textFieldStyle(.roundedBorder).lineLimit(2...12)
                            }
                        } }
                    } else if let table {
                        TextField("表格名称",text:Binding(get:{table.name},set:{structure.tables[selectedTable].name=$0})).textFieldStyle(.roundedBorder)
                        if let cell {
                            HStack {
                                Text("\(CaptureStructuredExport.cellReference(row:cell.row,column:cell.column))").font(.caption.monospaced())
                                Stepper("跨 \(mergeRows) 行",value:$mergeRows,in:1...max(1,table.rowCount-cell.row)).fixedSize()
                                Stepper("跨 \(mergeColumns) 列",value:$mergeColumns,in:1...max(1,table.columnCount-cell.column)).fixedSize()
                                Button("合并范围") {
                                    do { try structure.tables[selectedTable].merge(cell.id,rows:mergeRows,columns:mergeColumns);error=nil } catch { self.error=error.localizedDescription }
                                }
                                Button("拆分") { structure.tables[selectedTable].split(cell.id);mergeRows=1;mergeColumns=1 }.disabled(cell.rowSpan==1 && cell.columnSpan==1)
                            }.controlSize(.small)
                        }
                        tableGrid(table)
                    } else {
                        ContentUnavailableView("未检测到表格",systemImage:"tablecells",description:Text("可返回文档查看文字，或裁剪到表格范围后重试。"))
                    }
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }.frame(maxHeight:.infinity).disabled(busy)
            if let error { Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth:.infinity,alignment:.leading) }
        }.padding(20).frame(width:1000,height:680)
            .task {
                defer { busy=false }
                do {
                    lines=initialLines.isEmpty ? try await CaptureRecognition.recognize(image).lines:initialLines
                    structure=CaptureDocumentRecognition.basic(lines: lines)
                    if !structure.tables.isEmpty { mode=1;selectedCell=structure.tables.first?.cells.first?.id }
                } catch {
                    self.error=error.localizedDescription
                    if structure.paragraphs.isEmpty && structure.tables.isEmpty { structure.paragraphs=lines.map { CaptureDocumentParagraph(text:$0.text,rect:$0.rect) } }
                }
            }
            .onDisappear { cancelRecognition() }
            .onChange(of:selectedCell) { _,_ in mergeRows=cell?.rowSpan ?? 1;mergeColumns=cell?.columnSpan ?? 1 }
            .onChange(of:selectedTable) { _,_ in selectedCell=table?.cells.first?.id }
    }
    private func cancelRecognition() {
        recognitionGeneration += 1
        recognitionTask?.cancel(); recognitionTask = nil; busy = false
    }
    private func enhanceStructure() {
        busy = true; error = nil
        recognitionGeneration += 1
        let generation = recognitionGeneration
        recognitionTask = Task { @MainActor in
            defer { if generation == recognitionGeneration { busy = false; recognitionTask = nil } }
            do {
                let result = try await CaptureDocumentRecognition.recognize(image)
                guard !Task.isCancelled, generation == recognitionGeneration else { return }
                structure = CaptureDocumentRecognition.keepingBasicTables(result, lines: lines)
                selectedTable = 0; selectedCell = structure.tables.first?.cells.first?.id
                if !structure.tables.isEmpty { mode = 1 }
            } catch {
                if !Task.isCancelled, generation == recognitionGeneration { self.error = error.localizedDescription }
            }
        }
    }
    private var original:some View {
        GeometryReader { proxy in
            let scale=min(proxy.size.width/CGFloat(image.width),proxy.size.height/CGFloat(image.height))
            let size=CGSize(width:CGFloat(image.width)*scale,height:CGFloat(image.height)*scale)
            ZStack(alignment:.topLeading) {
                Image(nsImage:NSImage(cgImage:image,size:.zero)).resizable().frame(width:size.width,height:size.height)
                if mode==1,let rect=cell?.rect,rect.width>0 {
                    Rectangle().fill(.blue.opacity(0.18)).overlay { Rectangle().strokeBorder(.blue,lineWidth:2) }
                        .frame(width:rect.width*size.width,height:rect.height*size.height)
                        .offset(x:rect.minX*size.width,y:(1-rect.maxY)*size.height)
                }
            }
        }
    }
    private func tableGrid(_ table:CaptureDetectedTable)->some View {
        ScrollView([.horizontal,.vertical]) {
            ZStack(alignment:.topLeading) {
                Color.clear
                ForEach(table.cells) { cell in
                    TextField("",text:Binding(get:{ self.table?.cells.first(where:{$0.id==cell.id})?.text ?? "" },set:{ value in
                        guard let index=structure.tables[selectedTable].cells.firstIndex(where:{$0.id==cell.id}) else { return };structure.tables[selectedTable].cells[index].text=value
                    }),axis:.vertical)
                        .textFieldStyle(.plain).padding(8)
                        .frame(width:CGFloat(cell.columnSpan)*150-1,height:CGFloat(cell.rowSpan)*58-1,alignment:.topLeading)
                        .background(selectedCell==cell.id ? Color.accentColor.opacity(0.1):Color(nsColor:.textBackgroundColor))
                        .overlay { Rectangle().strokeBorder(selectedCell==cell.id ? Color.accentColor:Color.secondary.opacity(0.3),lineWidth:1) }
                        .offset(x:CGFloat(cell.column)*150,y:CGFloat(cell.row)*58)
                        .simultaneousGesture(TapGesture().onEnded { selectedCell=cell.id })
                }
            }.frame(width:CGFloat(table.columnCount)*150,height:CGFloat(table.rowCount)*58)
        }
    }
    private func export(_ format:String) {
        let panel=NSSavePanel();panel.nameFieldStringValue="截图文档."+format
        panel.begin { response in
            guard response == .OK,let url=panel.url else { return }
            do {
                switch format {
                case "xlsx":try CaptureStructuredExport.spreadsheet(structure.tables,to:url)
                case "csv":if let table { try Data(CaptureDocumentExport.csv(table.rows).utf8).write(to:url,options:.atomic) }
                case "docx":try CaptureStructuredExport.document(structure,to:url)
                case "md":try Data(structure.markdown.utf8).write(to:url,options:.atomic)
                case "pdf":try CaptureStructuredExport.searchablePDF(image,lines:lines,to:url)
                default:break
                };error=nil
            } catch { self.error=error.localizedDescription }
        }
    }
}
