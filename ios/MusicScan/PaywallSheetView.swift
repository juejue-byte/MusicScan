import StoreKit
import SwiftUI

/// Clean, unclipped Sky-themed StoreKit 2 paywall sheet presented when Superwall is not configured
/// or when unlocking a server-enforced half-page preview scan.
struct PaywallSheetView: View {
    let request: PaywallPresentationRequest
    let onDismiss: (Bool) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var billing = BillingManager.shared
    @State private var selectedProductID = AppConfig.ProductID.yearly

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    private var yearlyPriceText: String {
        billing.yearlyProduct?.displayPrice ?? "$99.99"
    }

    private var monthlyPriceText: String {
        billing.monthlyProduct?.displayPrice ?? "$15.99"
    }

    private var renewalCopy: String {
        if selectedProductID == AppConfig.ProductID.yearly {
            return "\(yearlyPriceText) a year, renews automatically until you cancel. Cancel anytime in Settings at least 24 hours before renewal. Up to \(AppConfig.proPagesPerMonth) pages a month."
        } else {
            return "\(monthlyPriceText) a month, renews automatically until you cancel. Cancel anytime in Settings at least 24 hours before renewal. Up to \(AppConfig.proPagesPerMonth) pages a month."
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    featuresCard
                    planSelector
                    statusMessageBanner
                    continueButton
                    legalFooter
                }
                .padding(.horizontal, isCompact ? 20 : 32)
                .padding(.vertical, 20)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(SkyTheme.canvasGradient.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") {
                        onDismiss(false)
                    }
                    .fontWeight(.semibold)
                    .disabled(billing.isPurchasing || billing.isRestoring)
                }
            }
        }
        .task {
            if billing.products.isEmpty {
                await billing.loadProducts()
            }
        }
        .interactiveDismissDisabled(billing.isPurchasing || billing.isRestoring)
        .tint(SkyTheme.blue600)
    }

    // MARK: - Header & Features

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProPillBadge()
                Text("MusicScan Pro")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(SkyTheme.slate600)
            }

            Text("Unlock every page you scan")
                .font(.system(size: isCompact ? 28 : 34, weight: .black, design: .rounded))
                .foregroundStyle(SkyTheme.navy900)
                .fixedSize(horizontal: false, vertical: true)

            Text(request.reason)
                .font(.system(size: 15))
                .foregroundStyle(SkyTheme.slate600)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var featuresCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            featureRow(icon: "doc.viewfinder", text: "Full pages, every time (up to \(AppConfig.proPagesPerMonth) pages/month)")
            featureRow(icon: "pencil", text: "Edit notes on the staff, Fix It review, and bar rescans")
            featureRow(icon: "play.fill", text: "Sampled playback, slow down, loop, and hands separate")
            featureRow(icon: "square.and.arrow.up", text: "Export clean MusicXML & MIDI to MuseScore or any DAW")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(SkyTheme.line.opacity(0.85), lineWidth: 1)
        )
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            IconTileBadge(
                systemName: icon,
                foreground: SkyTheme.blue600,
                background: SkyTheme.sky50,
                size: 32,
                cornerRadius: 9
            )
            Text(text)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(SkyTheme.navy900)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Plan Selector

    private var planSelector: some View {
        VStack(spacing: 12) {
            radioPlanRow(
                id: AppConfig.ProductID.yearly,
                title: "Yearly · \(yearlyPriceText)",
                subtitle: "$8.33 a month, billed yearly",
                badge: "Best value · save 48%"
            )
            radioPlanRow(
                id: AppConfig.ProductID.monthly,
                title: "Monthly · \(monthlyPriceText)",
                subtitle: "Billed every month",
                badge: nil
            )
        }
        .padding(.top, 4)
    }

    private func radioPlanRow(id: String, title: String, subtitle: String, badge: String?) -> some View {
        let isSelected = selectedProductID == id
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                selectedProductID = id
            }
        } label: {
            HStack(spacing: 14) {
                Circle()
                    .stroke(isSelected ? SkyTheme.blue600 : SkyTheme.line, lineWidth: isSelected ? 7 : 1.8)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(SkyTheme.navy900)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(SkyTheme.slate600)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? SkyTheme.sky50.opacity(0.9) : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? SkyTheme.blue600 : SkyTheme.line, lineWidth: isSelected ? 2 : 1.2)
            )
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(SkyTheme.blue600, in: Capsule())
                        .offset(x: -14, y: -11)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Status, CTA & Legal

    @ViewBuilder
    private var statusMessageBanner: some View {
        if let error = billing.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(SkyTheme.wrongInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(SkyTheme.wrongFill, in: RoundedRectangle(cornerRadius: 10))
        } else if let status = billing.statusMessage {
            Label(status, systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(SkyTheme.sureInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(SkyTheme.sureFill, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var continueButton: some View {
        Button {
            Task {
                let unlocked = await billing.purchaseProduct(id: selectedProductID)
                if unlocked {
                    onDismiss(true)
                }
            }
        } label: {
            HStack(spacing: 10) {
                if billing.isPurchasing {
                    ProgressView().tint(.white)
                }
                Text(billing.isPurchasing ? "Verifying subscription…" : "Continue")
                    .font(.system(size: 16.5, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(SkyTheme.blue600, in: Capsule())
            .shadow(color: SkyTheme.blue600.opacity(0.28), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(billing.isPurchasing || billing.isRestoring)
    }

    private var legalFooter: some View {
        VStack(spacing: 10) {
            Text(renewalCopy)
                .font(.system(size: 11.5))
                .foregroundStyle(SkyTheme.slate600)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            HStack(spacing: 18) {
                Button {
                    Task {
                        _ = await billing.restorePurchases()
                        if billing.isPro {
                            onDismiss(true)
                        }
                    }
                } label: {
                    Text(billing.isRestoring ? "Restoring…" : "Restore purchases")
                        .underline()
                }
                .buttonStyle(.plain)
                .disabled(billing.isPurchasing || billing.isRestoring)

                Link("Terms", destination: AppConfig.termsURL)
                    .underline()
                Link("Privacy", destination: AppConfig.privacyURL)
                    .underline()
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(SkyTheme.blue700)
            .frame(maxWidth: .infinity)
        }
    }
}

#Preview("Paywall") {
    PaywallSheetView(
        request: PaywallPresentationRequest(
            placement: "unlock_page",
            reason: "Unlock full pages, edit and fix flagged bars, play back with sampled instruments, and export MusicXML & MIDI.",
            jobID: nil
        ),
        onDismiss: { _ in }
    )
}
