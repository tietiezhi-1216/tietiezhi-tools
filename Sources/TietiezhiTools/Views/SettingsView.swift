import SwiftUI

struct SettingsView: View {
    @AppStorage("appearance") private var appearance: AppAppearance = .system

    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
            }

            Section("关于") {
                LabeledContent("应用", value: "Tietiezhi Tools")
                LabeledContent("版本", value: appVersion)
                Link("GitHub 项目与插件仓库", destination: HostInfo.repository)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 300)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? HostInfo.version
    }
}

private struct SettingsViewPreview: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
