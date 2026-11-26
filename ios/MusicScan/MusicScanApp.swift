import AVFoundation
import SwiftUI

@main
struct MusicScanApp: App {
    init() {
        // Playback should be heard with the ring/silent switch on, like any music app.
        // Web Audio inside a WKWebView follows the app's audio session.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task { await AuthManager.shared.start() }  // anonymous account on first launch (Auth.swift)
        }
    }
}
