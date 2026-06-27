import SwiftUI
import AppKit
import ClaudeMeterCore

/// The dropdown shown when the menu-bar item is clicked. Shows the sign-in flow when signed
/// out, and the live usage windows when signed in.
///
/// The 1-second `ticker` lives only as long as this view exists (created on popover-open,
/// destroyed on close), so the per-second timer never runs in the background.
struct MenuContentView: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var auth: AuthModel
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if auth.isSignedIn {
                usageContent
                Divider()
                signedInFooter
            } else {
                loginContent
            }
        }
        .padding(14)
        .frame(width: 290)
        .onReceive(ticker) { now = $0 }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.medium")
            Text("ClaudeMeter").font(.system(size: 13, weight: .bold))
            Spacer()
            if store.isLoading { ProgressView().controlSize(.small) }
        }
    }

    // MARK: - Signed in

    @ViewBuilder private var usageContent: some View {
        if let snapshot = store.snapshot {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(snapshot.allBuckets, id: \.title) { row in
                    UsageRow(title: row.title, bucket: row.bucket, now: now)
                }
            }
        } else if let error = store.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Loading usage…")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private var signedInFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let note = store.statusNote {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Start at login", isOn: launchAtLoginBinding)
                .font(.system(size: 12))
                .toggleStyle(.checkbox)

            HStack {
                if let updated = store.lastUpdated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Refresh") { Task { await store.refresh(force: true) } }
                    .font(.system(size: 11))
            }

            HStack {
                Button("Sign out") { auth.signOut() }
                    .font(.system(size: 11))
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .font(.system(size: 11))
            }
        }
    }

    // MARK: - Signed out / login

    @ViewBuilder private var loginContent: some View {
        switch auth.state {
        case .signedOut:
            VStack(alignment: .leading, spacing: 10) {
                Text("Connect your Claude account to see your usage and reset times.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = auth.errorMessage {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Connect Claude account") { auth.beginLogin() }
                    .keyboardShortcut(.defaultAction)
                Button("Paste code manually") { auth.beginManualLogin() }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
                quitRow
            }

        case .waitingForBrowser:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for approval in your browser…")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Text("Approve access in the browser tab that opened. This window will update on its own.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") { auth.cancel() }.font(.system(size: 11))
                    Spacer()
                }
            }

        case .awaitingCode, .connecting:
            VStack(alignment: .leading, spacing: 8) {
                Text("Approve access in the browser, copy the code shown, and paste it here:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("Paste authorization code", text: $auth.pastedCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .disabled(auth.state == .connecting)
                    .onSubmit { auth.submitCode() }

                if let error = auth.errorMessage {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button("Cancel") { auth.cancel() }
                        .font(.system(size: 11))
                    Spacer()
                    if auth.state == .connecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Sign in") { auth.submitCode() }
                            .font(.system(size: 11))
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }

        case .signedIn:
            EmptyView()
        }
    }

    private var quitRow: some View {
        HStack {
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .font(.system(size: 11))
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { LoginItem.isEnabled },
            set: { LoginItem.setEnabled($0) }
        )
    }
}
