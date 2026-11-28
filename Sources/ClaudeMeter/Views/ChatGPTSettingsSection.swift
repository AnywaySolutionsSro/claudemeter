import ClaudeMeterCore
import SwiftUI

/// Settings → General → Codex: sign in to ChatGPT for live Codex limits. Reads only
/// the model's cached state — never the Keychain — so it can re-render freely.
struct ChatGPTSettingsSection: View {
    @ObservedObject var chatGPT: ChatGPTAuthModel
    @Environment(\.textScale) private var scale

    var body: some View {
        switch chatGPT.state {
        case .signedIn:
            HStack {
                Label(chatGPT.email.map { "Signed in as \($0)" } ?? "Signed in to ChatGPT",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Sign out", role: .destructive) { chatGPT.signOut() }
            }
            footnote("Codex limits come live from ChatGPT; transcripts fill in when they are newer.")
        case .waitingForBrowser:
            HStack {
                ProgressView().controlSize(.small)
                Text("Waiting for the browser…").font(scale.font(11))
                Spacer()
                Button("Cancel") { chatGPT.cancel() }
            }
        case .signedOut:
            Button {
                chatGPT.beginLogin()
            } label: {
                Label("Sign in to ChatGPT", systemImage: "person.crop.circle.badge.checkmark")
            }
            .buttonStyle(.borderedProminent)
            if let error = chatGPT.errorMessage {
                Text(error).font(scale.font(10)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footnote("Without it, Codex limits refresh only when a Codex turn runs.")
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(scale.font(10)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
