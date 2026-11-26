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
                    Text("On your computer run HOST=0.0.0.0 scripts/run.sh, then enter its address on your Wi-Fi network (System Settings > Wi-Fi > Details > IP address) with port 8000. The simulator can use http://localhost:8000.")
                }
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

    private func test() async {
        guard let base = ServerConfig.normalize(draft) else { return }
        checking = true
        defer { checking = false }
        var request = URLRequest(url: base.appendingPathComponent("api/samples"))
        request.timeoutInterval = 6
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            reachable = code == 200
            status = code == 200 ? "Connected to MusicScan." : "Something answered, but not MusicScan (HTTP \(code))."
        } catch {
            reachable = false
            status = "Could not reach it: \(error.localizedDescription)"
        }
    }
}
