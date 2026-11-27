import SuperwallKit
import SwiftUI

#if os(iOS)
import AVFoundation
#endif

@main
struct MyApp: App {
    init() {
        #if os(iOS)
        // Configure audio playback off the main thread so cold launch never stalls UI responsiveness.
        Task.detached(priority: .utility) {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
        }
        #endif

        // Configure Superwall + StoreKit 2 at cold launch before any views or deep links run.
        let storedServer = UserDefaults.standard.string(forKey: AppConfig.serverURLStorageKey)
            ?? AppConfig.defaultServerAddress
        BillingManager.shared.configure(serverURL: AppConfig.normalizedServerURL(from: storedServer))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    // Quietly create or restore the user's Supabase guest session on first launch,
                    // then verify any active StoreKit 2 subscriptions with the server.
                    await AuthManager.shared.start()
                    await BillingManager.shared.syncExistingEntitlements(notifyServer: true, surfaceErrors: false)
                }
                .onOpenURL { url in
                    // Route Superwall preview / campaign deep links first; auth callbacks go to Supabase Auth.
                    let handledBySuperwall = BillingManager.shared.isSuperwallReady
                        && Superwall.handleDeepLink(url)
                    if !handledBySuperwall || url.host?.lowercased() == AppConfig.authCallbackHost {
                        AuthManager.shared.handleCallback(url)
                    }
                }
        }
    }
}
