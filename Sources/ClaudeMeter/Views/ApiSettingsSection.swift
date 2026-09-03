import ClaudeMeterCore
import SwiftUI

/// Settings → General block for the Claude API cost-tracking credential.
///
/// The key is written straight to the Keychain and never rendered back — once saved, the
/// field is replaced by the verified organization name.
struct ApiSettingsSection: View {
    @ObservedObject var spend: ApiSpendStore
    @Environment(\.textScale) private var scale

    @State private var entry = ""
    @State private var status: Status = .idle

    /// Read from the store rather than a local `@State` seeded once: the Settings window is
    /// cached for the app's lifetime, so a copy here would never see the key change.
    private var hasKey: Bool { spend.hasKey }

    private enum Status: Equatable {
        case idle
        case verifying
        case verified(String)
        case failed(String)
    }

    private let keys = AdminKeyStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasKey {
                HStack {
                    Label(organizationLabel, systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    if status == .verifying { ProgressView().controlSize(.small) }
                    Button("Verify") { verify() }
                    Button("Remove", role: .destructive) { remove() }
                }
            } else {
                SecureField("sk-ant-admin01-…", text: $entry)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save") { save() }
                        .disabled(AdminKey(entry) == nil)
                    if status == .verifying { ProgressView().controlSize(.small) }
                }
            }

            if case let .failed(message) = status {
                Text(message).font(scale.font(10)).foregroundStyle(.red)
            }

            instructions
        }
    }

    private var organizationLabel: String {
        if case let .verified(name) = status { return name }
        return "Admin key saved"
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("How to get a key").font(scale.font(10, weight: .semibold))
            Text("""
            1. Open platform.claude.com → Settings → Admin keys
            2. Click Create key, name it, and copy the secret — it's shown only once
            3. Paste it above

            Requires an organization (individual accounts can't use the Admin API) \
            and the admin role in it.
            """)
            .font(scale.font(10))
            .foregroundStyle(.secondary)
            Text("""
            A Console admin key carries full access to your organization, including member \
            management — Console keys have no read-only option. It is stored in your Keychain \
            and sent only to api.anthropic.com.
            """)
            .font(scale.font(10))
            .foregroundStyle(.secondary)
            Text("Removing the key here does not revoke it — revoke it in the Console.")
                .font(scale.font(10))
                .foregroundStyle(.secondary)
            Link(
                "Open Admin keys settings",
                destination: URL(string: "https://platform.claude.com/settings/admin-keys")!,
            )
            .font(scale.font(10))
        }
        .padding(.top, 4)
    }

    private func save() {
        guard let key = AdminKey(entry) else { return }
        do {
            try keys.save(key)
            entry = ""
            spend.refreshKeyState()
            verify()
        } catch {
            status = .failed("Couldn't save to the Keychain: \(error.localizedDescription)")
        }
    }

    private func verify() {
        // Without this, repeated clicks race and the last response to land wins — which can
        // show a red error for a key that is fine, or green for one that just failed.
        guard status != .verifying else { return }
        status = .verifying
        Task { @MainActor in
            do {
                let name = try await CostClient().verifyOrganization()
                status = .verified(name)
                await spend.refresh(force: true)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                status = .failed(message)
            }
        }
    }

    private func remove() {
        do {
            try keys.clear()
        } catch {
            status = .failed(
                "Couldn't remove the key from the Keychain — it is still stored. "
                    + "Revoke it in the Console to be safe.",
            )
            return
        }
        status = .idle
        spend.reset()
    }
}
