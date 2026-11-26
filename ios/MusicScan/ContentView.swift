import SwiftUI

struct ContentView: View {
    @AppStorage(ServerConfig.storageKey) private var serverURL: String = ServerConfig.defaultURL
    @State private var loadError: String?
    @State private var showSettings = false
    @State private var reloadToken = 0

    var body: some View {
        ZStack {
            Color(red: 0.965, green: 0.969, blue: 0.976).ignoresSafeArea()  // matches the page (--bg)
            if let url = ServerConfig.normalize(serverURL) {
                EditorWebView(
                    url: url,
                    reloadToken: reloadToken,
                    onLoaded: { loadError = nil },
                    onLoadError: { loadError = $0 },
                    onOpenSettings: { showSettings = true }
                )
                // The page lays itself out around the notch and home indicator (viewport-fit=cover + env()).
                .ignoresSafeArea()
            }
            if let err = loadError ?? (ServerConfig.normalize(serverURL) == nil ? "The server address is not valid." : nil) {
                ConnectionErrorView(
                    message: err,
                    address: serverURL,
                    retry: { loadError = nil; reloadToken += 1 },
                    change: { showSettings = true }
                )
            }
        }
        .sheet(isPresented: $showSettings) {
            ServerSettingsView(serverURL: $serverURL) {
                loadError = nil
                reloadToken += 1
            }
        }
    }
}

struct ConnectionErrorView: View {
    let message: String
    let address: String
    let retry: () -> Void
    let change: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "music.note.house")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(.tint)
            Text("Can't reach the MusicScan server")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("\(message)\n\nServer: \(address)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Start it on your computer with  HOST=0.0.0.0 scripts/run.sh  and keep the phone on the same Wi-Fi.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Change server", action: change).buttonStyle(.bordered)
                Button("Try again", action: retry).buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(20)
    }
}
