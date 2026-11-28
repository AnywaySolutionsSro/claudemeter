import ClaudeMeterCore
import SwiftUI

/// Claude signed out: only a compact "Connect Claude account" button (plus the manual
/// paste fallback and a failed login's error), or the login in progress.
struct ClaudeConnectSection: View {
    @EnvironmentObject private var auth: AuthModel
    @Environment(\.textScale) private var scale

    var body: some View {
        switch auth.state {
        case .signedOut:
            VStack(alignment: .leading, spacing: scale.pt(4)) {
                HStack(spacing: scale.pt(8)) {
                    Button("Connect Claude account") { auth.beginLogin() }
                        .keyboardShortcut(.defaultAction)
                    Button("Paste code manually") { auth.beginManualLogin() }
                        .buttonStyle(.link).font(scale.font(10))
                }
                errorLine
            }
        case .waitingForBrowser:
            HStack(spacing: scale.pt(8)) {
                ProgressView().controlSize(.small)
                Text("Approve Claude access in your browser…")
                    .font(scale.font(11)).foregroundColor(.secondary)
                Spacer()
                Button("Cancel") { auth.cancel() }.font(scale.font(11))
            }
        case .awaitingCode, .connecting:
            pasteCode
        case .signedIn:
            EmptyView()
        }
    }

    @ViewBuilder private var errorLine: some View {
        if let error = auth.errorMessage {
            Text(error).font(scale.font(10)).foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pasteCode: some View {
        VStack(alignment: .leading, spacing: scale.pt(8)) {
            Text("Approve access in the browser, copy the code shown, and paste it here:")
                .font(scale.font(11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Paste authorization code", text: $auth.pastedCode)
                .textFieldStyle(.roundedBorder).font(scale.font(11))
                .disabled(auth.state == .connecting)
                .onSubmit { auth.submitCode() }
            errorLine
            HStack {
                Button("Cancel") { auth.cancel() }.font(scale.font(11))
                Spacer()
                if auth.state == .connecting {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Sign in") { auth.submitCode() }
                        .font(scale.font(11)).keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

/// Codex not signed in to ChatGPT: only a "Connect Codex account" button (the ChatGPT
/// login), or that login in progress. Transcripts still drive sessions, auto-resume and
/// the widget's session rows; the dropdown shows Codex limits only once connected.
struct CodexConnectSection: View {
    @EnvironmentObject private var chatGPT: ChatGPTAuthModel
    @Environment(\.textScale) private var scale

    var body: some View {
        switch chatGPT.state {
        case .signedOut:
            VStack(alignment: .leading, spacing: scale.pt(4)) {
                Button("Connect Codex account") { chatGPT.beginLogin() }
                    .help("Sign in to ChatGPT for live Codex limits")
                if let error = chatGPT.errorMessage {
                    Text(error).font(scale.font(10)).foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .waitingForBrowser:
            HStack(spacing: scale.pt(8)) {
                ProgressView().controlSize(.small)
                Text("Approve Codex access in your browser…")
                    .font(scale.font(11)).foregroundColor(.secondary)
                Spacer()
                Button("Cancel") { chatGPT.cancel() }.font(scale.font(11))
            }
        case .signedIn:
            EmptyView()
        }
    }
}
