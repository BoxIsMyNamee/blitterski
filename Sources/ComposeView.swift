import SwiftUI

struct ComposeView: View {
    @EnvironmentObject var store: FeedStore
    @EnvironmentObject var theme: Theme
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var toX = true
    @State private var toBsky = true
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var sendToX: Bool { toX && store.xConnected }
    private var sendToBsky: Bool { toBsky && store.bskyHandle != nil }
    /// Twitter allows 280, Bluesky 300; use the tighter limit when posting to both.
    private var limit: Int { sendToX ? 280 : 300 }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canPost: Bool {
        !sending && !trimmed.isEmpty && text.count <= limit && (sendToX || sendToBsky)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $text)
                    .focused($focused)
                    .frame(minHeight: 160)
                HStack {
                    if store.xConnected {
                        Toggle("Twitter", isOn: $toX).toggleStyle(.button)
                    }
                    if store.bskyHandle != nil {
                        Toggle("Bluesky", isOn: $toBsky).toggleStyle(.button)
                    }
                    Spacer()
                    Text("\(text.count)/\(limit)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(text.count > limit ? Color.red : Color.secondary)
                }
                if !store.xConnected && store.bskyHandle == nil {
                    Text("Connect an account in Settings first.").font(.footnote).foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("New post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        post()
                    } label: {
                        if sending { ProgressView() } else { Text("Post").fontWeight(.semibold) }
                    }
                    .disabled(!canPost)
                }
            }
        }
        .onAppear { focused = true }
    }

    private func post() {
        Task {
            sending = true
            error = nil
            do {
                try await store.createPost(text: trimmed, toX: sendToX, toBluesky: sendToBsky)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}
