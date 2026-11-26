import SwiftUI

struct ServerSettingsView: View {
    @Binding var serverURL: String
    var onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var status: String?
    @State private var reachable = false
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.1.20:8000", text: $draft)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(save)
                } header: {
                    Text("MusicScan server")
                } footer: {
                    Text("Hosted: paste the address modal deploy printed, with your key, like https://you--musicscan.modal.run/?key=… (see deploy/README.md).\nOn your own computer: run HOST=0.0.0.0 scripts/run.sh and enter its Wi-Fi address with port 8000. The simulator can use http://localhost:8000.")
                }
                AccountSection()
                Section {
                    Button(checking ? "Checking…" : "Test connection") { Task { await test() } }
                        .disabled(checking || ServerConfig.normalize(draft) == nil)
                    if let status {
                        Label(status, systemImage: reachable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(reachable ? .green : .orange)
                    }
                }
            }
            .navigationTitle("Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(ServerConfig.normalize(draft) == nil)
                }
            }
            .onAppear { draft = serverURL }
            .onChange(of: draft) { _ in status = nil }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard let url = ServerConfig.normalize(draft) else { return }
        serverURL = url.absoluteString
        onSave()
        dismiss()
    }

    @MainActor private func test() async {
        guard let base = ServerConfig.normalize(draft) else { return }
        checking = true
        defer { checking = false }
        guard let health = ServerConfig.endpoint(base, "api/health") else { return }
        var request = URLRequest(url: health)
        request.timeoutInterval = 60  // a hosted server that scaled to zero takes up to a minute to wake
        if let bearer = await AuthManager.shared.bearer() { request.setValue(bearer, forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if code == 200, info?["app"] as? String == "musicscan" {
                let authorized = info?["authorized"] as? Bool ?? true
                reachable = authorized
                let signedIn = info?["user"] is String
                let signInOn = info?["sign_in"] as? Bool ?? false
                status = authorized ? (signedIn ? "Connected to MusicScan, signed in."
                                       : signInOn && AuthManager.shared.isConfigured
                                       ? "Connected to MusicScan, but the server did not accept the sign-in."
                                       : "Connected to MusicScan.")
                    : "Connected, but the access key is missing or wrong. Add ?key=… to the address."
            } else {
                reachable = false
                status = code == 404 ? "Something answered, but not an up-to-date MusicScan server (HTTP 404)."
                    : "Something answered, but not MusicScan (HTTP \(code))."
            }
        } catch {
            reachable = false
            status = "Could not reach it: \(error.localizedDescription)"
        }
    }
}
