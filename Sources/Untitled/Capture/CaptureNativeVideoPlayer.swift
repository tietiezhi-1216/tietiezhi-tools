import AVKit
import SwiftUI

/// Avoid the OS SwiftUI VideoPlayer overlay's runtime metadata dependency.
struct NativeCaptureVideoPlayer: NSViewRepresentable {
    let player: AVPlayer?
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.controlsStyle = .floating; view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause(); view.player = nil }
}
