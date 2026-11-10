/// Native capability modules are assembled here, outside the host's slot renderer.
@MainActor enum PluginComposition {
    static func makeUIRegistry() -> PluginUIRegistry {
        let registry = PluginUIRegistry()
        registry.register(HostPluginUIProvider())
        registry.register(CapturePluginUIProvider())
        return registry
    }
}
