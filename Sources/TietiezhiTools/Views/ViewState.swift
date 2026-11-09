import SwiftUI

// 显式选择属性包装器，兼容不带 SwiftUI 宏插件的命令行 SDK。
typealias ViewState<Value> = SwiftUI.State<Value>
