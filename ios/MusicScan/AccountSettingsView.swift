import AuthenticationServices
import StoreKit
import SwiftUI

/// Sky-themed Account, Subscription, and Server settings sheet.
///
/// Supports:
/// - Silent guest status with optional Email, Sign in with Apple, and Google account linking (preserving guest scans/purchases)
/// - Signing into an existing account on a new device
/// - MusicScan Pro status, Upgrade (Superwall / StoreKit 2), Restore Purchases, and Manage Subscription
/// - Collapsible server diagnostics ("Test connection") for verifying Supabase sign-in + GPU availability
struct AccountSettingsView: View {
    @Binding var serverAddress: String
    var onServerChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var auth = AuthManager.shared
    @State private var billing = BillingManager.shared

    @State private var email = ""
    @State private var verificationCode = ""
    @State private var linkSent = false
    @State private var isExistingAccountMode = false

    @State private var showServerAdvanced = false
    @State private var serverDraft = ""
    @State private var connectionStatus: String?
    @State private var connectionOK = false
    @State private var isTestingConnection = false

    var body: some View {
        NavigationStack {
            Form {
                subscriptionSection
                accountSection
                #if DEBUG
                serverSection
                #endif
            }
            .navigationTitle("Account & Plan")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                serverDraft = serverAddress
            }
            .task {
                if auth.session == nil {
                    await auth.start()
                }
                if billing.products.isEmpty {
                    await billing.loadProducts()
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        #endif
        .tint(SkyTheme.blue600)
    }

    // MARK: - Subscription Section

    private var subscriptionSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: billing.isPro ? "crown.fill" : "music.note.list")
                    .font(.title3)
                    .foregroundStyle(billing.isPro ? SkyTheme.marigold : SkyTheme.blue600)
                    .frame(width: 32, height: 32)
                    .background(
                        billing.isPro ? SkyTheme.marigold.opacity(0.18) : SkyTheme.sky50,
                        in: RoundedRectangle(cornerRadius: 8)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(billing.isPro ? "MusicScan Pro" : "Free Plan")
                        .font(.headline)
                        .foregroundStyle(SkyTheme.navy900)
                    Text(billing.isPro
                         ? "Active · Up to \(AppConfig.proPagesPerMonth) pages a month"
                         : "1 full free page included · Upgrade for 30 pages/month")
                        .font(.caption)
                        .foregroundStyle(SkyTheme.slate600)
                }
            }
            .padding(.vertical, 4)

            if !billing.isPro {
                Button {
                    Task {
                        _ = await billing.presentPaywall(
                            placement: AppConfig.superwallUnlockPlacement,
                            reason: "Unlock full pages, fix flagged bars, play back, mark up, and export to MuseScore."
                        )
                    }
                } label: {
                    HStack {
                        Text("Upgrade to MusicScan Pro")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(billing.yearlyProduct.map { "\($0.displayPrice)/yr" } ?? "$99.99/yr")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(SkyTheme.navy900)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(SkyTheme.marigold, in: Capsule())
                    }
                }
            }

            Button {
                Task { _ = await billing.restorePurchases() }
            } label: {
                HStack {
                    Text(billing.isRestoring ? "Restoring Purchases…" : "Restore Purchases")
                    Spacer()
                    if billing.isRestoring {
                        ProgressView()
                    }
                }
            }
            .disabled(billing.isRestoring || billing.isPurchasing)

            if billing.isPro {
                Button("Manage Subscription") {
                    Task { await billing.openManageSubscriptions() }
                }
            }

            if let error = billing.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else if let status = billing.statusMessage {
                Label(status, systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(SkyTheme.sureInk)
            }
        } header: {
            Text("MusicScan Pro")
        } footer: {
            HStack(spacing: 12) {
                Link("Terms of Use", destination: AppConfig.termsURL)
                Text("·")
                Link("Privacy Policy", destination: AppConfig.privacyURL)
            }
            .font(.caption)
        }
    }

    // MARK: - Account Section

    private var accountSection: some View {
        Section {
            if let session = auth.session {
                LabeledContent("Signed in as", value: session.displayLabel)
            } else {
                HStack {
                    Text("Setting up your guest account…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                }
            }

            if auth.isGuest {
                Picker("Mode", selection: $isExistingAccountMode) {
                    Text("Save guest account").tag(false)
                    Text("Sign into existing").tag(true)
                }
                .pickerStyle(.segmented)

                emailSignInControls
                appleAndGoogleButtons
            } else {
                Button("Sign Out", role: .destructive) {
                    Task { await auth.signOut() }
                }
                .disabled(auth.isBusy)
            }

            if let error = auth.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else if let message = auth.statusMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(SkyTheme.sureInk)
            }
        } header: {
            Text("Account")
        } footer: {
            if auth.isGuest {
                Text("Your free page and MusicScan Pro subscription are linked to this guest account automatically. Add your email, Apple, or Google account anytime to keep them on your iPhone and iPad.")
            } else {
                Text("Your account and subscription sync across your Apple devices. Use Restore Purchases after signing in on a new device.")
            }
        }
    }

    @ViewBuilder
    private var emailSignInControls: some View {
        TextField("you@example.com", text: $email)
            #if os(iOS)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            #endif
            .textContentType(.emailAddress)
            .autocorrectionDisabled()

        Button {
            Task {
                linkSent = await auth.sendEmailLink(email, linkToGuest: !isExistingAccountMode)
            }
        } label: {
            HStack {
                Text(auth.isBusy
                     ? "Sending…"
                     : linkSent ? "Send Sign-In Link Again" : "Continue with Email")
                Spacer()
                if auth.isBusy {
                    ProgressView()
                }
            }
        }
        .disabled(auth.isBusy || !email.contains("@"))

        if linkSent {
            TextField("Optional 6-digit code", text: $verificationCode)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .textContentType(.oneTimeCode)

            if !verificationCode.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Verify Code") {
                    Task {
                        let ok = await auth.verifyEmailCode(
                            email,
                            code: verificationCode,
                            linkToGuest: !isExistingAccountMode
                        )
                        if ok {
                            verificationCode = ""
                            linkSent = false
                        }
                    }
                }
                .disabled(auth.isBusy)
            }
        }
    }

    @ViewBuilder
    private var appleAndGoogleButtons: some View {
        Button {
            auth.signInWithApple()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "apple.logo")
                    .font(.body.weight(.semibold))
                Text("Continue with Apple")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(auth.isBusy)

        Button {
            auth.signInWithGoogle(linkToGuest: !isExistingAccountMode)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(SkyTheme.blue600)
                Text("Continue with Google")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SkyTheme.navy900)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(SkyTheme.sky50, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(SkyTheme.line, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(auth.isBusy)
    }

    // MARK: - Server Section (Collapsible)

    private var serverSection: some View {
        Section {
            DisclosureGroup("Connection & Server", isExpanded: $showServerAdvanced) {
                TextField("https://…", text: $serverDraft, axis: .vertical)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .lineLimit(2...4)
                    .onChange(of: serverDraft) { _, _ in
                        connectionStatus = nil
                    }

                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Text(isTestingConnection ? "Checking connection…" : "Test Connection")
                        Spacer()
                        if isTestingConnection {
                            ProgressView()
                        }
                    }
                }
                .disabled(isTestingConnection || AppConfig.normalizedServerURL(from: serverDraft) == nil)

                if let connectionStatus {
                    Label(
                        connectionStatus,
                        systemImage: connectionOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(connectionOK ? SkyTheme.sureInk : .orange)
                }

                if serverDraft.trimmingCharacters(in: .whitespacesAndNewlines) != serverAddress {
                    Button("Save Server Address") {
                        guard let normalized = AppConfig.normalizedServerURL(from: serverDraft) else { return }
                        serverAddress = normalized.absoluteString
                        onServerChanged()
                    }
                    .disabled(AppConfig.normalizedServerURL(from: serverDraft) == nil)
                }

                if serverAddress != AppConfig.defaultServerAddress {
                    Button("Reset to Default Server") {
                        serverAddress = AppConfig.defaultServerAddress
                        serverDraft = serverAddress
                        onServerChanged()
                    }
                }
            }
        } footer: {
            Text("Superwall SDK: \(billing.isSuperwallReady ? "Connected" : "Ready — add SuperwallAPIKey to Info.plist once App Store Connect is configured").")
        }
    }

    @MainActor
    private func testConnection() async {
        guard let base = AppConfig.normalizedServerURL(from: serverDraft),
              let healthURL = AppConfig.endpoint(base: base, path: "api/health") else {
            return
        }

        isTestingConnection = true
        defer { isTestingConnection = false }

        var request = URLRequest(url: healthURL, timeoutInterval: 60)
        if let bearer = await auth.bearerHeader() {
            request.setValue(bearer, forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

            if code == 200, info?["app"] as? String == "musicscan" {
                let authorized = info?["authorized"] as? Bool ?? false
                let signedIn = info?["user"] is String
                let device = info?["device"] as? String
                connectionOK = authorized
                if authorized && signedIn {
                    connectionStatus = device != nil
                        ? "Connected to MusicScan, signed in (\(device!))."
                        : "Connected to MusicScan, signed in."
                } else if authorized {
                    connectionStatus = "Connected to MusicScan."
                } else {
                    connectionStatus = "Server reachable, but sign-in token was not accepted."
                }
            } else {
                connectionOK = false
                connectionStatus = "Unexpected response from server (HTTP \(code))."
            }
        } catch {
            connectionOK = false
            connectionStatus = "Could not connect: \(error.localizedDescription)"
        }
    }
}
