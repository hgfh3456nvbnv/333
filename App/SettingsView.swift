import SwiftUI
import TermCore
import TermSSH

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let palette = model.palette
        NavigationStack {
            Form {
                connections(palette)
                sshHosts(palette)
                agent(palette)
                appearance(palette)
            }
            .themedList(palette)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func connections(_ palette: Palette) -> some View {
        Section {
            ForEach(model.profiles) { profile in
                NavigationLink {
                    ConnectionEditor(model: model, profileID: profile.id)
                } label: {
                    SettingsRow(title: profile.name, detail: profile.baseURL,
                                isActive: profile.id == model.activeProfile?.id, palette: palette)
                }
            }
            NavigationLink {
                ConnectionEditor(model: model, profileID: nil)
            } label: {
                Label("Add connection", systemImage: "plus")
            }
        } header: {
            Text("Connections")
        } footer: {
            Text("OpenAI-compatible gateways. API keys and custom headers are stored in the Keychain on this device.")
        }
        .listRowBackground(palette.surface)
    }

    private func sshHosts(_ palette: Palette) -> some View {
        Section {
            ForEach(model.hosts) { host in
                NavigationLink {
                    HostEditor(host: host, secret: model.hostSecret(for: host),
                               passphrase: model.hostPassphrase(for: host), isNew: false)
                } label: {
                    SettingsRow(title: host.name, detail: host.address,
                                isActive: host.id == model.activeHost?.id, palette: palette)
                }
            }
            NavigationLink {
                HostEditor(host: SSHHost(name: "", host: "", username: ""), secret: "", passphrase: "", isNew: true)
            } label: {
                Label("Add host", systemImage: "plus")
            }
        } header: {
            Text("SSH hosts")
        } footer: {
            Text("The agent runs commands on the selected host. Switch hosts below the message box.")
        }
        .listRowBackground(palette.surface)
    }

    private func agent(_ palette: Palette) -> some View {
        Section {
            Picker("Permissions", selection: Binding(get: { model.settings.approvalMode }, set: { model.setApprovalMode($0) })) {
                ForEach(ApprovalMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            NavigationLink("System prompt") {
                TextEditor(text: binding(\.systemPrompt))
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(palette.background.ignoresSafeArea())
                    .navigationTitle("System prompt")
                    .navigationBarTitleDisplayMode(.inline)
            }
        } header: {
            Text("Agent")
        } footer: {
            Text(model.settings.approvalMode.summary + ".")
        }
        .listRowBackground(palette.surface)
    }

    private func appearance(_ palette: Palette) -> some View {
        Section {
            Picker("Theme", selection: binding(\.themeID)) {
                ForEach(Theme.all) { theme in
                    Text(theme.name).tag(theme.id)
                }
            }
            Stepper("Text size: \(Int(model.settings.fontSize))", value: binding(\.fontSize), in: 10...20, step: 1)
        } header: {
            Text("Appearance")
        } footer: {
            Text("Files the agent writes are in Files › On My iPhone › TermAI.")
        }
        .listRowBackground(palette.surface)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in model.update { $0[keyPath: keyPath] = value } })
    }
}

private struct SettingsRow: View {
    let title: String
    let detail: String
    let isActive: Bool
    let palette: Palette

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if isActive {
                Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(palette.accent)
            }
        }
    }
}

private extension View {
    /// The bordered box that text inputs sit in.
    func inputBox(_ palette: Palette) -> some View {
        font(palette.label)
            .foregroundStyle(palette.text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 10)
            .frame(minHeight: 38)
            .card(palette, fill: palette.background, radius: 8)
    }

    /// A small button face, as on "Test connection".
    func pill(_ palette: Palette) -> some View {
        font(palette.label)
            .foregroundStyle(palette.text)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A labelled setting: title, a line of help, then the control.
private struct Field<Content: View>: View {
    let title: String
    let help: String
    let boxed: Bool
    let palette: Palette
    let content: Content

    init(_ title: String, help: String, boxed: Bool = true, palette: Palette, @ViewBuilder content: () -> Content) {
        self.title = title
        self.help = help
        self.boxed = boxed
        self.palette = palette
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(palette.labelBold).foregroundStyle(palette.text)
            Text(help)
                .font(palette.caption)
                .foregroundStyle(palette.dim)
                .fixedSize(horizontal: false, vertical: true)
            if boxed {
                content.inputBox(palette)
            } else {
                content
            }
        }
    }
}

// MARK: Connection

/// One gateway: where requests go, how they are authorised and which models it offers.
struct ConnectionEditor: View {
    private enum Check: Equatable {
        case idle
        case running
        case passed(String)
        case failed(String)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var profile: Profile
    @State private var apiKey: String
    @State private var headers: [RequestHeader]
    @State private var modelsText: String
    @State private var showKey = false
    @State private var check = Check.idle
    @State private var isFetching = false
    @State private var fetchMessage: String?
    private let isNew: Bool
    /// Presented as its own sheet rather than pushed from Settings.
    private let isModal: Bool

    init(profile: Profile, apiKey: String, headers: [RequestHeader], isNew: Bool, isModal: Bool) {
        _profile = State(initialValue: profile)
        _apiKey = State(initialValue: apiKey)
        _headers = State(initialValue: headers)
        _modelsText = State(initialValue: profile.models.joined(separator: "\n"))
        self.isNew = isNew
        self.isModal = isModal
    }

    /// Editor for a saved profile, or for a blank one when `profileID` is nil or unknown.
    @MainActor
    init(model: AppModel, profileID: UUID?, isModal: Bool = false) {
        if let saved = model.profiles.first(where: { $0.id == profileID }) {
            self.init(profile: saved, apiKey: model.apiKey(for: saved), headers: model.headers(for: saved),
                      isNew: false, isModal: isModal)
        } else {
            self.init(profile: Profile(name: "", baseURL: "https://"), apiKey: "", headers: [], isNew: true, isModal: isModal)
        }
    }

    private var modelIDs: [String] {
        var seen = Set<String>()
        return modelsText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private var hasEndpoint: Bool {
        guard let url = URL(string: profile.baseURL.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    var body: some View {
        let palette = model.palette
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connection").font(.system(size: 24, weight: .bold)).foregroundStyle(palette.text)
                    Text("Choose where TermAI sends inference requests.").font(palette.label).foregroundStyle(palette.dim)
                }
                credentials(palette)
                modelList(palette)
                if !isNew {
                    Button {
                        model.deleteProfile(profile)
                        dismiss()
                    } label: {
                        Text("Delete connection")
                            .font(palette.label)
                            .foregroundStyle(palette.error)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .card(palette, fill: palette.sidebar)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(palette.background.ignoresSafeArea())
        .navigationTitle(isNew ? "New connection" : profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isModal {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).disabled(!hasEndpoint)
            }
        }
    }

    private func credentials(_ palette: Palette) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("GATEWAY CREDENTIALS").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.text)
                Spacer(minLength: 8)
                Button(action: testConnection) {
                    HStack(spacing: 6) {
                        if check == .running {
                            ProgressView().controlSize(.mini)
                        } else {
                            Circle().fill(checkColor(palette)).frame(width: 7, height: 7)
                        }
                        Text("Test connection")
                    }
                    .pill(palette)
                }
                .buttonStyle(.plain)
                .disabled(check == .running || !hasEndpoint)
            }
            checkMessage(palette)

            Field("Name", help: "Shown in the sidebar and the model picker.", palette: palette) {
                TextField("", text: $profile.name, prompt: Text("e.g. openrouter").foregroundStyle(palette.dim))
            }
            Field("Gateway base URL", help: "Full URL of the OpenAI-compatible endpoint, usually ending in /v1.", palette: palette) {
                TextField("", text: $profile.baseURL, prompt: Text("https://api.openai.com/v1").foregroundStyle(palette.dim))
                    .keyboardType(.URL)
            }
            Field("Gateway API key", help: "Stored in the Keychain on this device. Leave empty if the server needs none.", palette: palette) {
                HStack(spacing: 8) {
                    if showKey {
                        TextField("", text: $apiKey, prompt: Text("sk-…").foregroundStyle(palette.dim))
                    } else {
                        SecureField("", text: $apiKey, prompt: Text("sk-…").foregroundStyle(palette.dim))
                    }
                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye").foregroundStyle(palette.dim)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showKey ? "Hide key" : "Show key")
                }
            }
            Field("Gateway auth scheme", help: "How the key is sent: Authorization: Bearer, or an x-api-key header.",
                  boxed: false, palette: palette) {
                Picker("Auth scheme", selection: $profile.authScheme) {
                    Text("bearer").tag(Profile.AuthScheme.bearer)
                    Text("x-api-key").tag(Profile.AuthScheme.apiKeyHeader)
                }
                .pickerStyle(.segmented)
            }
            customHeaders(palette)
        }
        .padding(16)
        .card(palette, fill: palette.sidebar)
    }

    private func customHeaders(_ palette: Palette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Custom headers").font(palette.labelBold).foregroundStyle(palette.text)
                    Text("Sent with every request, e.g. HTTP-Referer. Stored in the Keychain.")
                        .font(palette.caption)
                        .foregroundStyle(palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    headers.append(RequestHeader())
                } label: {
                    Label("Add header", systemImage: "plus").pill(palette)
                }
                .buttonStyle(.plain)
            }
            ForEach($headers) { $header in
                HStack(spacing: 8) {
                    TextField("", text: $header.name, prompt: Text("Name").foregroundStyle(palette.dim))
                        .inputBox(palette)
                    TextField("", text: $header.value, prompt: Text("Value").foregroundStyle(palette.dim))
                        .inputBox(palette)
                    Button {
                        headers.removeAll { $0.id == header.id }
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(palette.dim)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove header")
                }
            }
        }
    }

    private func modelList(_ palette: Palette) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("MODELS").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.text)
                Spacer(minLength: 8)
                Button(action: fetchModels) {
                    HStack(spacing: 6) {
                        if isFetching { ProgressView().controlSize(.mini) }
                        Text("Fetch from endpoint")
                    }
                    .pill(palette)
                }
                .buttonStyle(.plain)
                .disabled(isFetching || !hasEndpoint)
            }
            if let fetchMessage {
                Text(fetchMessage).font(palette.caption).foregroundStyle(palette.dim)
            }
            Field("Model IDs", help: "One per line. They appear in the model picker.", palette: palette) {
                TextEditor(text: $modelsText)
                    .font(palette.mono)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
            }
            if !modelIDs.isEmpty {
                Field("Default model", help: "Selected when you switch to this connection.", boxed: false, palette: palette) {
                    Picker("Default model", selection: Binding(
                        get: { profile.defaultModel.flatMap { modelIDs.contains($0) ? $0 : nil } ?? modelIDs[0] },
                        set: { profile.defaultModel = $0 })) {
                        ForEach(modelIDs, id: \.self) { id in
                            Text(id).tag(id)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
        .padding(16)
        .card(palette, fill: palette.sidebar)
    }

    @ViewBuilder
    private func checkMessage(_ palette: Palette) -> some View {
        switch check {
        case .passed(let message): Text(message).font(palette.caption).foregroundStyle(palette.success)
        case .failed(let message): Text(message).font(palette.caption).foregroundStyle(palette.error)
        case .idle, .running: EmptyView()
        }
    }

    private func checkColor(_ palette: Palette) -> Color {
        switch check {
        case .passed: return palette.success
        case .failed: return palette.error
        case .idle, .running: return palette.dim
        }
    }

    private func save() {
        var saved = profile
        saved.baseURL = saved.baseURL.trimmingCharacters(in: .whitespaces)
        saved.name = saved.name.trimmingCharacters(in: .whitespaces)
        // A connection can be saved with nothing but its URL; it is then named after the host.
        if saved.name.isEmpty { saved.name = URL(string: saved.baseURL)?.host ?? "gateway" }
        saved.models = modelIDs
        if let chosen = saved.defaultModel, !modelIDs.contains(chosen) { saved.defaultModel = nil }
        model.saveProfile(saved, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines), headers: headers)
        if isNew { model.select(profile: saved) }
        dismiss()
    }

    private func testConnection() {
        check = .running
        let baseURL = profile.baseURL
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = profile.authScheme
        let extra = headers
        Task {
            do {
                let found = try await OpenAIClient().listModels(baseURL: baseURL, apiKey: key, authScheme: scheme, headers: extra)
                check = .passed("Connected. The endpoint lists \(found.count) models.")
            } catch {
                check = .failed(error.localizedDescription)
            }
        }
    }

    private func fetchModels() {
        isFetching = true
        fetchMessage = nil
        let baseURL = profile.baseURL
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = profile.authScheme
        let extra = headers
        Task {
            do {
                let fetched = try await OpenAIClient().listModels(baseURL: baseURL, apiKey: key, authScheme: scheme, headers: extra)
                let existing = Set(modelIDs)
                let added = fetched.filter { !existing.contains($0) }
                modelsText = (modelIDs + added).joined(separator: "\n")
                fetchMessage = "\(fetched.count) models found, \(added.count) added."
            } catch {
                fetchMessage = "Failed: \(error.localizedDescription)"
            }
            isFetching = false
        }
    }
}

// MARK: Model picker

/// Every model of every connection, searchable. Typing an unknown ID offers to add it.
struct ModelPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        let palette = model.palette
        let needle = query.trimmingCharacters(in: .whitespaces)
        NavigationStack {
            List {
                if let profile = model.activeProfile, !needle.isEmpty, !profile.models.contains(needle) {
                    Section {
                        Button {
                            choose(needle, in: profile)
                        } label: {
                            Label("Use “\(needle)”", systemImage: "plus")
                        }
                    } footer: {
                        Text("Adds this model ID to \(profile.name).")
                    }
                    .listRowBackground(palette.surface)
                }
                ForEach(model.profiles) { profile in
                    ModelSection(profile: profile, needle: needle, palette: palette, choose: choose)
                }
                Section {
                    Button {
                        model.panel = model.profiles.isEmpty ? .connection(nil) : .settings
                    } label: {
                        Label(model.profiles.isEmpty ? "Add connection" : "Manage connections", systemImage: "gearshape")
                    }
                }
                .listRowBackground(palette.surface)
            }
            .themedList(palette)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search or enter a model ID")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func choose(_ id: String, in profile: Profile) {
        model.select(model: id, in: profile.id)
        dismiss()
    }
}

private struct ModelSection: View {
    @Environment(AppModel.self) private var model
    let profile: Profile
    let needle: String
    let palette: Palette
    let choose: (String, Profile) -> Void

    private var matches: [String] {
        needle.isEmpty ? profile.models : profile.models.filter { $0.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        let isActiveProfile = profile.id == model.activeProfile?.id
        if needle.isEmpty || !matches.isEmpty {
            Section(profile.name) {
                ForEach(matches, id: \.self) { id in
                    Button {
                        choose(id, profile)
                    } label: {
                        HStack(spacing: 8) {
                            Text(id).foregroundStyle(palette.text)
                            Spacer(minLength: 0)
                            if isActiveProfile, id == model.activeModel {
                                Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(palette.accent)
                            }
                        }
                    }
                }
                if profile.models.isEmpty {
                    Text("No models saved yet. Type a model ID in the search field to add one.")
                        .font(.footnote)
                        .foregroundStyle(palette.dim)
                }
            }
            .listRowBackground(palette.surface)
        }
    }
}

// MARK: SSH host

private struct HostEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var host: SSHHost
    @State var secret: String
    @State var passphrase: String
    let isNew: Bool

    private var canSave: Bool {
        ![host.name, host.host, host.username].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            && (1...65_535).contains(host.port)
    }

    var body: some View {
        let palette = model.palette
        Form {
            Section("Server") {
                TextField("Name, e.g. web1", text: $host.name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Hostname or IP", text: $host.host)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Port", value: $host.port, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                TextField("Username", text: $host.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            .listRowBackground(palette.surface)

            Section {
                Picker("Method", selection: $host.auth) {
                    Text("Password").tag(SSHHost.Auth.password)
                    Text("Private key").tag(SSHHost.Auth.privateKey)
                }
                .pickerStyle(.segmented)
                .onChange(of: host.auth) {
                    secret = ""
                    passphrase = ""
                }
                if host.auth == .password {
                    SecureField("Password", text: $secret)
                } else {
                    TextEditor(text: $secret)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(minHeight: 120)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Passphrase (if the key has one)", text: $passphrase)
                }
            } header: {
                Text("Authentication")
            } footer: {
                Text(host.auth == .password
                     ? "Stored in the Keychain on this device."
                     : "Paste an Ed25519 or RSA private key in OpenSSH format (-----BEGIN OPENSSH PRIVATE KEY-----). Stored in the Keychain on this device.")
            }
            .listRowBackground(palette.surface)

            if let key = host.trustedHostKey {
                Section {
                    Text(SSHKeys.fingerprint(ofOpenSSHKey: key)).font(.system(.caption, design: .monospaced))
                    Button("Forget host key", role: .destructive) { host.trustedHostKey = nil }
                } header: {
                    Text("Trusted host key")
                } footer: {
                    Text("Recorded on first connection. Connections are refused if the server presents a different key.")
                }
                .listRowBackground(palette.surface)
            }

            if !isNew {
                Section {
                    Button("Delete host", role: .destructive) {
                        model.deleteHost(host)
                        dismiss()
                    }
                }
                .listRowBackground(palette.surface)
            }
        }
        .themedList(palette)
        .navigationTitle(isNew ? "New host" : host.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var saved = host
                    saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                    saved.host = saved.host.trimmingCharacters(in: .whitespaces)
                    saved.username = saved.username.trimmingCharacters(in: .whitespaces)
                    model.saveHost(saved, secret: secret, passphrase: passphrase)
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
    }
}
