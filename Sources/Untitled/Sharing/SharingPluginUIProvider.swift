import Combine
import SwiftUI

struct SharingPluginUIProvider: PluginUIProvider {
    @MainActor func register(in registry: PluginUIRegistry) {
        registry.component("sharing.dashboard", requiredActions: [.sharePeripherals]) { context in
            AnyView(SharingPluginView(controller: context.store.peripheralSharing(for: context.pluginID)))
        }
        registry.component("sharing.status", requiredActions: [.sharePeripherals]) { context in
            AnyView(SharingStatusView(controller: context.store.peripheralSharing(for: context.pluginID)))
        }
        registry.command("sharing.toggle", requiredActions: [.sharePeripherals], presentation: { context in
            .init(title: context.store.peripheralSharing(for: context.pluginID).isRunning ? "停止共享" : "启动共享", symbol: "network")
        }, updates: { $0.store.peripheralSharing(for: $0.pluginID).objectWillChange.eraseToAnyPublisher() }) { context in
            try context.store.performPeripheralAction(.sharePeripherals, pluginID: context.pluginID)
        }
        registry.command("sharing.switch", requiredActions: [.sharePeripherals, .switchPeripheralControl], presentation: { context in
            let controller = context.store.peripheralSharing(for: context.pluginID)
            return .init(title: controller.control == .local ? "控制另一台 Mac" : "返回本机", symbol: "keyboard",
                         isEnabled: controller.keyboardMouseEnabled && controller.peerName != nil)
        }, updates: { $0.store.peripheralSharing(for: $0.pluginID).objectWillChange.eraseToAnyPublisher() }) { context in
            try context.store.performPeripheralAction(.switchPeripheralControl, pluginID: context.pluginID)
        }
        registry.command("sharing.stop", requiredActions: [.sharePeripherals, .stopPeripheralSharing], presentation: { context in
            .init(title: "停止全部共享", symbol: "stop.circle", isEnabled: context.store.peripheralSharing(for: context.pluginID).isRunning)
        }, updates: { $0.store.peripheralSharing(for: $0.pluginID).objectWillChange.eraseToAnyPublisher() }) { context in
            try context.store.performPeripheralAction(.stopPeripheralSharing, pluginID: context.pluginID)
        }
    }
}

private struct SharingStatusView: View {
    @ObservedObject var controller: PeripheralSharingController
    var body: some View {
        Label(controller.isRunning ? "\(controller.peerName ?? "等待连接") · \(controller.control.rawValue)" : "共享已关闭",
              systemImage: controller.isRunning ? "circle.fill" : "circle")
            .font(.caption).foregroundStyle(.secondary)
    }
}
