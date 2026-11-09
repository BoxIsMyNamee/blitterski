import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: FeedStore
    @State private var showXLogin = false
    @State private var showBskyLogin = false

    var body: some View {
        NavigationStack {
            List {
                Section("Accounts") {
                    HStack {
                        Label(store.xConnected ? "Twitter: connected" : "Twitter", systemImage: "person.crop.circle")
                        Spacer()
                        if store.xConnected {
                            Button("Disconnect", role: .destructive) { Task { await store.disconnectX() } }
                                .buttonStyle(.borderless)
                        } else {
                            Button("Connect") { showXLogin = true }.buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        Label(store.bskyHandle.map { "Bluesky: @\($0)" } ?? "Bluesky", systemImage: "cloud")
                        Spacer()
                        if store.bskyHandle != nil {
                            Button("Sign out", role: .destructive) { Task { await store.logoutBluesky() } }
                                .buttonStyle(.borderless)
                        } else {
                            Button("Sign in") { showBskyLogin = true }.buttonStyle(.borderless)
                        }
                    }
                }
                Section("Feeds") {
                    NavigationLink("Choose feeds") { FeedSettingsView() }
                }
                Section("About") {
                    Text("Personal client. Not affiliated with or endorsed by Twitter/X or Bluesky.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showXLogin) { XLoginSheet() }
            .sheet(isPresented: $showBskyLogin) { BskyLoginSheet() }
        }
    }
}

struct XLoginSheet: View {
    @EnvironmentObject var store: FeedStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            XLoginView { creds in
                store.connectX(creds)
                dismiss()
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Sign in to Twitter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

struct BskyLoginSheet: View {
    @EnvironmentObject var store: FeedStore
    @EnvironmentObject var config: FeedConfig
    @Environment(\.dismiss) private var dismiss
    @State private var handle = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Handle (you.bsky.social)", text: $handle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("App password", text: $password)
                } footer: {
                    Text("Use an app password, not your main password. Create one in the Bluesky app: Settings > Privacy and security > App passwords.")
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
                Button(busy ? "Signing in..." : "Sign in") {
                    Task {
                        busy = true
                        error = nil
                        do {
                            try await store.loginBluesky(handle: handle, password: password, config: config)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                        busy = false
                    }
                }
                .disabled(busy || handle.isEmpty || password.isEmpty)
            }
            .navigationTitle("Sign in to Bluesky")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

struct FeedSettingsView: View {
    @EnvironmentObject var store: FeedStore
    @EnvironmentObject var config: FeedConfig

    var body: some View {
        List {
            Section {
                ForEach(config.shown) { f in Text(f.title) }
                    .onMove { config.shown.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { config.shown.remove(atOffsets: $0) }
            } header: {
                Text("Shown (drag to reorder, swipe to remove)")
            }

            Section {
                if config.available.isEmpty {
                    Text("Nothing else available").foregroundStyle(.secondary)
                }
                ForEach(config.available) { f in
                    Button {
                        config.shown.append(f)
                    } label: {
                        Label(f.title, systemImage: "plus.circle")
                    }
                }
            } header: {
                Text("Available")
            }

            Section {
                Button("Load my Bluesky feeds") { Task { await store.fetchSavedFeeds(config) } }
                    .disabled(store.bskyHandle == nil)
            } footer: {
                Text("Adds the custom feeds you've saved on Bluesky to the Available list.")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Choose feeds")
        .navigationBarTitleDisplayMode(.inline)
    }
}
