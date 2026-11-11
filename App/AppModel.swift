import Foundation
import Observation
import SwiftUI
import TermCore
import TermSSH
import UIKit

struct PendingApproval: Identifiable, Equatable {
    let id = UUID()
    /// Name of the tool waiting to run.
    let tool: String
    let summary: String
}

struct ShareItem: Identifiable {
    let id = UUID()
    let text: String
}

/// The sheets that slide over the chat.
enum Panel: Identifiable, Equatable {
    case settings
    /// The connection editor for a saved profile, or for a new one when nil.
    case connection(UUID?)
    case models
    case files
    case terminal

    var id: String {
        switch self {
        case .settings: return "settings"
        case .connection(let profileID): return "connection-\(profileID?.uuidString ?? "new")"
        case .models: return "models"
        case .files: return "files"
        case .terminal: return "terminal"
        }
    }
}

private struct Failure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

@MainActor
@Observable
final class AppModel {
    var profiles: [Profile] = []
    var hosts: [SSHHost] = []
    var settings = AppSettings()
    var session = Session()
    /// Saved sessions for the sidebar, most recent first.
    var sessions: [SessionSummary] = []
    var input = ""
    var isRunning = false
    var pendingApproval: PendingApproval?
    var panel: Panel?
    var showSidebar = false
    var shareItem: ShareItem?
    var usageLine: String?
    /// Bumped when the transcript should jump to the bottom.
    var scrollTick = 0
    /// Commands run by hand in the terminal panel. They are not part of the chat or the model's context.
    var terminalItems: [TranscriptItem] = []
    var terminalInput = ""

    @ObservationIgnored let storage: Storage
    @ObservationIgnored let secrets: SecretStore
    @ObservationIgnored let workspace: URL
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var approvalContinuation: CheckedContinuation<ApprovalDecision, Never>?
    @ObservationIgnored private var alwaysAllow = false
    @ObservationIgnored private var connection: SSHConnection?
    @ObservationIgnored private var connectionHostID: UUID?
    @ObservationIgnored private var assistantItemID: UUID?
    @ObservationIgnored private var toolItems: [String: UUID] = [:]
    @ObservationIgnored private var runStart = Date()
    @ObservationIgnored private var listedSessions: [SessionSummary] = []

    private static let busy = "Busy. Stop the current run first."

    init() {
        let files = FileManager.default
        let isDemo = ProcessInfo.processInfo.arguments.contains("-demo")
        let support: URL
        if isDemo {
            // Screenshot mode: sample content, nothing read from or written to real storage.
            let scratch = files.temporaryDirectory.appendingPathComponent("termai-demo-\(UUID().uuidString)")
            support = scratch.appendingPathComponent("support")
            workspace = scratch.appendingPathComponent("workspace")
            secrets = InMemorySecretStore()
        } else {
            support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TermAI")
            workspace = files.urls(for: .documentDirectory, in: .userDomainMask)[0]
            secrets = KeychainStore()
        }
        try? files.createDirectory(at: support, withIntermediateDirectories: true)
        try? files.createDirectory(at: workspace, withIntermediateDirectories: true)
        storage = Storage(directory: support)
        profiles = storage.loadProfiles()
        hosts = storage.loadHosts()
        settings = storage.loadSettings()

        if isDemo {
            // `-screen <name>` picks what the screenshot shows; `-theme <id>` picks the theme.
            loadDemo(screen: UserDefaults.standard.string(forKey: "screen") ?? "chat")
        } else {
            sessions = storage.sessionSummaries()
        }
    }

    // MARK: Derived state

    var theme: Theme { Theme.named(settings.themeID) }
    var palette: Palette { Palette(theme: theme, fontSize: settings.fontSize) }

    var activeProfile: Profile? {
        profiles.first { $0.id == settings.activeProfileID } ?? profiles.first
    }

    var activeModel: String? {
        if let model = settings.activeModel, !model.isEmpty { return model }
        return activeProfile?.preferredModel
    }

    /// The model ID without its vendor prefix, short enough for the message box.
    var modelLabel: String {
        guard let model = activeModel else { return profiles.isEmpty ? "No connection" : "No model" }
        return model.split(separator: "/").last.map(String.init) ?? model
    }

    var activeHost: SSHHost? {
        hosts.first { $0.id == settings.activeHostID }
    }

    var suggestions: [SlashCommand] {
        pendingApproval == nil ? Commands.suggestions(for: input) : []
    }

    var placeholder: String {
        if profiles.isEmpty { return "Add a connection to start" }
        if pendingApproval != nil { return "Waiting for your approval" }
        return isRunning ? "Working… tap stop to interrupt" : "Describe a task or type / for commands"
    }

    func update(_ change: (inout AppSettings) -> Void) {
        change(&settings)
        storage.saveSettings(settings)
    }

    // MARK: Transcript

    @discardableResult
    private func append(_ kind: TranscriptItem.Kind, _ text: String, title: String? = nil,
                        status: TranscriptItem.Status? = nil, inTerminal: Bool = false) -> UUID {
        let item = TranscriptItem(kind: kind, text: text, title: title, status: status)
        if inTerminal {
            terminalItems.append(item)
        } else {
            session.transcript.append(item)
        }
        return item.id
    }

    func info(_ text: String, inTerminal: Bool = false) { append(.info, text, inTerminal: inTerminal) }
    func fail(_ text: String, inTerminal: Bool = false) { append(.error, text, inTerminal: inTerminal) }

    private func mutateItem(_ id: UUID?, inTerminal: Bool = false, _ change: (inout TranscriptItem) -> Void) {
        guard let id else { return }
        if inTerminal {
            guard let index = terminalItems.lastIndex(where: { $0.id == id }) else { return }
            change(&terminalItems[index])
        } else {
            guard let index = session.transcript.lastIndex(where: { $0.id == id }) else { return }
            change(&session.transcript[index])
        }
    }

    private func appendOutput(_ id: UUID?, _ chunk: String, inTerminal: Bool = false) {
        mutateItem(id, inTerminal: inTerminal) { item in
            item.text += chunk
            // Only the tail is shown; keep the stored text bounded for long-running commands.
            if item.text.count > 24_000 { item.text = String(item.text.suffix(16_000)) }
        }
    }

    // MARK: Input

    func submit() {
        let raw = input
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Commands.parse(raw)
        // A message typed while the agent works stays in the box until the run is over.
        if isRunning, case .prompt = parsed { return }
        input = ""
        scrollTick += 1

        switch parsed {
        case .empty: break
        case .prompt(let text): send(text)
        case .shell(let command): runShell(command, inTerminal: false)
        case .command(let name, let args):
            // Commands that open a sheet or reset the screen leave no trace in the transcript.
            if !["setup", "config", "files", "terminal", "new", "clear", "retry"].contains(name) { append(.user, trimmed) }
            runCommand(name, args)
        }
    }

    /// Puts a workspace path into the message so the agent knows which file is meant.
    func attach(path: String) {
        let needsSpace = !input.isEmpty && !input.hasSuffix(" ") && !input.hasSuffix("\n")
        input += (needsSpace ? " " : "") + "`\(path)` "
        panel = nil
    }

    // MARK: Agent runs

    private func send(_ text: String) {
        guard !isRunning else { return info(Self.busy) }
        guard let profile = activeProfile else { return fail("No connection yet. Add one with /setup.") }
        guard let model = activeModel else { return fail("No model selected. Tap the model name to pick one.") }
        append(.user, text)
        if session.messages.isEmpty { session.title = String(text.prefix(48)) }
        session.messages.append(ChatMessage(role: .user, content: text))
        startRun(profile: profile, model: model)
    }

    private func startRun(profile: Profile, model: String) {
        isRunning = true
        usageLine = nil
        runStart = Date()
        assistantItemID = nil
        let apiKey = secrets.secret(for: profile.secretKey) ?? ""
        let extraHeaders = self.headers(for: profile)
        if profile.baseURL.lowercased().hasPrefix("http://"), !apiKey.isEmpty {
            info("Note: \(profile.name) uses plain http, so the API key is sent unencrypted.")
        }
        let history = session.messages
        let host = activeHost

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                var shell: SSHConnection?
                if let host {
                    do {
                        shell = try await self.connect(to: host, inTerminal: false)
                    } catch {
                        self.fail("ssh \(host.name): \(error.localizedDescription)")
                        self.info("Continuing without SSH.")
                    }
                }
                try Task.checkCancellation()
                let system = SystemPrompt.build(
                    custom: self.settings.systemPrompt, hostLabel: shell == nil ? nil : host?.address,
                    planning: self.settings.approvalMode == .plan)
                let request = ChatRequest(
                    baseURL: profile.baseURL, apiKey: apiKey, model: model,
                    messages: [ChatMessage(role: .system, content: system)] + history,
                    authScheme: profile.authScheme, headers: extraHeaders)
                let agent = Agent(client: OpenAIClient(), tools: ToolBox(workspace: self.workspace, shell: shell))
                try await agent.run(
                    request: request,
                    approve: { [weak self] call, summary in await self?.requestApproval(call, summary) ?? .deny },
                    emit: { [weak self] event in await self?.handle(event) })
            } catch {
                if error is CancellationError || Task.isCancelled {
                    self.info("Stopped.")
                } else {
                    self.fail(error.localizedDescription)
                }
            }
            self.finishRun(touchesSession: true)
        }
    }

    private func finishRun(touchesSession: Bool) {
        for index in session.transcript.indices where session.transcript[index].status == .running {
            session.transcript[index].status = .failed
        }
        for index in terminalItems.indices where terminalItems[index].status == .running {
            terminalItems[index].status = .failed
        }
        isRunning = false
        runTask = nil
        assistantItemID = nil
        toolItems = [:]
        if touchesSession {
            session.updatedAt = Date()
            storage.saveSession(session)
            refreshSessions()
        }
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .assistantDelta(let delta):
            if assistantItemID == nil { assistantItemID = append(.assistant, "") }
            mutateItem(assistantItemID) { $0.text += delta }
        case .message(let message):
            session.messages.append(message)
            if message.role == .assistant { assistantItemID = nil }
        case .toolStarted(let call, let summary):
            toolItems[call.id] = append(.tool, "", title: summary, status: .running)
        case .toolOutput(let id, let chunk):
            appendOutput(toolItems[id], chunk)
        case .toolFinished(let id, let result, let denied):
            mutateItem(toolItems[id]) { item in
                item.status = denied ? .denied : (result.isError ? .failed : .ok)
                if denied {
                    item.text = "declined"
                } else if item.text.isEmpty {
                    item.text = String(result.text.prefix(2_000))
                } else if result.isError, let last = result.text.split(separator: "\n").last {
                    if !item.text.hasSuffix("\n") { item.text += "\n" }
                    item.text += last
                }
            }
        case .usage(let input, let output):
            let seconds = Int(Date().timeIntervalSince(runStart).rounded())
            usageLine = "\(Self.compact(input)) in · \(Self.compact(output)) out · \(seconds)s"
        }
    }

    static func compact(_ count: Int) -> String {
        count >= 1_000 ? String(format: "%.1fk", Double(count) / 1_000) : "\(count)"
    }

    func cancel() {
        guard isRunning else { return }
        runTask?.cancel()
        if pendingApproval != nil { resolveApproval(.deny) }
    }

    /// Sends the last prompt again, discarding what came after it.
    func retry() {
        guard !isRunning else { return info(Self.busy) }
        guard let index = session.messages.lastIndex(where: { $0.role == .user }) else { return fail("Nothing to retry.") }
        guard let profile = activeProfile, let model = activeModel else { return fail("No connection or model selected.") }
        session.messages.removeSubrange((index + 1)...)
        // The answer being replaced leaves the screen too.
        let prompt = session.messages[index].content
        if let shown = session.transcript.lastIndex(where: { $0.kind == .user && $0.text == prompt }) {
            session.transcript.removeSubrange((shown + 1)...)
        }
        scrollTick += 1
        startRun(profile: profile, model: model)
    }

    var lastAnswer: String? {
        session.transcript.last { $0.kind == .assistant }?.text
    }

    func copyLastAnswer() {
        guard let lastAnswer else { return fail("No answer to copy.") }
        UIPasteboard.general.string = lastAnswer
    }

    // MARK: Approval

    func setApprovalMode(_ mode: ApprovalMode) {
        update { $0.approvalMode = mode }
        alwaysAllow = false
        // A prompt that is already on screen is settled if the new mode no longer needs to ask.
        if let pending = pendingApproval, let decision = mode.automaticDecision(forTool: pending.tool) {
            resolveApproval(decision)
        }
    }

    private func requestApproval(_ call: ToolCall, _ summary: String) async -> ApprovalDecision {
        if let decision = settings.approvalMode.automaticDecision(forTool: call.name) { return decision }
        if alwaysAllow { return .allow }
        if Task.isCancelled { return .deny }
        pendingApproval = PendingApproval(tool: call.name, summary: summary)
        scrollTick += 1
        return await withCheckedContinuation { approvalContinuation = $0 }
    }

    func resolveApproval(_ decision: ApprovalDecision) {
        pendingApproval = nil
        approvalContinuation?.resume(returning: decision)
        approvalContinuation = nil
    }

    func allowAlways() {
        alwaysAllow = true
        info("Allowing tool calls for the rest of this session.")
        resolveApproval(.allow)
    }

    // MARK: SSH

    private func connect(to host: SSHHost, inTerminal: Bool) async throws -> SSHConnection {
        if let connection, connectionHostID == host.id, connection.isConnected { return connection }
        await dropConnection()
        guard let secret = secrets.secret(for: host.secretKey), !secret.isEmpty else {
            throw Failure(message: "no password or key stored for this host; open Settings")
        }
        let credentials = SSHCredentials(
            host: host.host, port: host.port, username: host.username,
            secret: host.auth == .password
                ? .password(secret)
                : .privateKey(pem: secret, passphrase: secrets.secret(for: host.passphraseKey)))
        info("connecting to \(host.address)…", inTerminal: inTerminal)
        let new = try await SSHConnection.connect(credentials, label: host.name, trustedHostKey: host.trustedHostKey)
        if host.trustedHostKey == nil, !new.hostKey.isEmpty, let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index].trustedHostKey = new.hostKey
            storage.saveHosts(hosts)
            info("first connection: trusting host key \(SSHKeys.fingerprint(ofOpenSSHKey: new.hostKey))", inTerminal: inTerminal)
        }
        connection = new
        connectionHostID = host.id
        return new
    }

    private func dropConnection() async {
        let old = connection
        connection = nil
        connectionHostID = nil
        await old?.close()
    }

    /// Runs a command on the active host. From the chat (`!command`) the output joins the transcript and the
    /// model's context; from the terminal panel it stays in the terminal log.
    private func runShell(_ command: String, inTerminal: Bool) {
        guard !isRunning else { return info(Self.busy, inTerminal: inTerminal) }
        guard let host = activeHost else {
            return fail("No SSH host selected. Add one in Settings, then pick it below the message box.", inTerminal: inTerminal)
        }
        isRunning = true
        runTask = Task { [weak self] in
            guard let self else { return }
            var itemID: UUID?
            do {
                let shell = try await self.connect(to: host, inTerminal: inTerminal)
                let title = inTerminal ? command : "ssh \(host.name) $ \(command)"
                let id = self.append(.tool, "", title: title, status: .running, inTerminal: inTerminal)
                itemID = id
                let (output, continuation) = AsyncStream<String>.makeStream()
                let forwarder = Task { [weak self] in
                    for await chunk in output { self?.appendOutput(id, chunk, inTerminal: inTerminal) }
                }
                let code: Int
                do {
                    code = try await shell.run(command: command, timeout: 300) { continuation.yield($0) }
                } catch {
                    continuation.finish()
                    await forwarder.value
                    throw error
                }
                continuation.finish()
                await forwarder.value
                self.mutateItem(id, inTerminal: inTerminal) { $0.status = code == 0 ? .ok : .failed }
                if code != 0 { self.appendOutput(id, "[exit \(code)]", inTerminal: inTerminal) }
                if !inTerminal {
                    let text = self.session.transcript.first { $0.id == id }?.text ?? ""
                    self.session.messages.append(ChatMessage(
                        role: .user,
                        content: "[I ran this on \(host.address) myself]\n$ \(command)\n\(Truncate.middle(text, limit: 4_000))\n[exit \(code)]"))
                }
            } catch {
                self.mutateItem(itemID, inTerminal: inTerminal) { $0.status = .failed }
                if error is CancellationError || Task.isCancelled {
                    self.info("Stopped.", inTerminal: inTerminal)
                } else {
                    self.fail("ssh \(host.name): \(error.localizedDescription)", inTerminal: inTerminal)
                }
            }
            self.finishRun(touchesSession: !inTerminal)
        }
    }

    func runTerminalCommand() {
        let command = terminalInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !isRunning else { return }
        terminalInput = ""
        runShell(command, inTerminal: true)
    }

    func clearTerminal() {
        terminalItems.removeAll { $0.status != .running }
    }

    // MARK: Commands

    private func runCommand(_ name: String, _ args: String) {
        let changesSession = ["new", "sessions", "retry", "clear"].contains(name)
        if isRunning, changesSession, !(name == "sessions" && args.isEmpty) {
            return info(Self.busy)
        }
        switch name {
        case "help":
            let width = Commands.all.map(\.usage.count).max() ?? 0
            let lines = Commands.all.map { $0.usage.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.help }
            info(lines.joined(separator: "\n") + "\n\n!<command>  run a command on the SSH host yourself")
        case "setup": panel = .connection(nil)
        case "config": panel = .settings
        case "files": panel = .files
        case "terminal": panel = .terminal
        case "model": modelCommand(args)
        case "profile": profileCommand(args)
        case "host": hostCommand(args)
        case "approve":
            if let mode = ApprovalMode.named(args) {
                setApprovalMode(mode)
            } else if !args.isEmpty {
                return fail("usage: /approve ask|edits|plan|auto")
            }
            info("permissions: \(settings.approvalMode.title). \(settings.approvalMode.summary)")
        case "theme":
            if args.isEmpty {
                info(Theme.all.map { ($0.id == theme.id ? "* " : "  ") + $0.id.padding(toLength: 11, withPad: " ", startingAt: 0) + $0.name }
                    .joined(separator: "\n"))
            } else if let match = Theme.all.first(where: { $0.id == args.lowercased() || $0.name.lowercased().hasPrefix(args.lowercased()) }) {
                update { $0.themeID = match.id }
                info("theme: \(match.name)")
            } else {
                fail("unknown theme. options: " + Theme.all.map(\.id).joined(separator: ", "))
            }
        case "system":
            if args.isEmpty {
                info(settings.systemPrompt.isEmpty ? "no custom system prompt. /system <text> sets one" : settings.systemPrompt)
            } else {
                update { $0.systemPrompt = args.lowercased() == "reset" ? "" : args }
                info(settings.systemPrompt.isEmpty ? "system prompt reset" : "system prompt set")
            }
        case "new": startNewSession()
        case "sessions": sessionsCommand(args)
        case "retry": retry()
        case "copy":
            copyLastAnswer()
            if let lastAnswer { info("copied \(lastAnswer.count) characters") }
        case "export":
            guard !session.isEmpty else { return fail("Nothing to export yet.") }
            shareItem = ShareItem(text: Markdown.export(session))
        case "clear":
            session.transcript.removeAll()
        default:
            fail("unknown command: /\(name)")
        }
    }

    private func modelCommand(_ args: String) {
        guard let profile = activeProfile else { return fail("No connection yet. Add one with /setup.") }
        if args.isEmpty {
            let current = activeModel
            let lines = profile.models.map { ($0 == current ? "* " : "  ") + $0 }
            info(lines.isEmpty ? "no models saved for \(profile.name). /model <id> adds one" : lines.joined(separator: "\n"))
            return
        }
        // Accept an exact ID, a unique substring of a saved ID, or a brand-new ID.
        let matches = profile.models.filter { $0.localizedCaseInsensitiveContains(args) }
        let chosen = profile.models.first { $0 == args } ?? (matches.count == 1 ? matches[0] : args)
        select(model: chosen, in: profile.id)
        info("model: \(chosen)")
    }

    func select(model: String, in profileID: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileID }), !profiles[index].models.contains(model) {
            profiles[index].models.append(model)
            storage.saveProfiles(profiles)
        }
        update {
            $0.activeProfileID = profileID
            $0.activeModel = model
        }
    }

    /// Switches to a connection and its default model.
    func select(profile: Profile) {
        update {
            $0.activeProfileID = profile.id
            $0.activeModel = profile.preferredModel
        }
    }

    private func profileCommand(_ args: String) {
        if args.isEmpty {
            let current = activeProfile?.id
            let lines = profiles.map { ($0.id == current ? "* " : "  ") + $0.name + "  " + $0.baseURL }
            return info(lines.isEmpty ? "no connections. run /setup" : lines.joined(separator: "\n"))
        }
        guard let match = profiles.first(where: { $0.name.lowercased().hasPrefix(args.lowercased()) }) else {
            return fail("no connection named \(args)")
        }
        select(profile: match)
        info("connection: \(match.name) · \(match.preferredModel ?? "no model")")
    }

    private func hostCommand(_ args: String) {
        if args.isEmpty {
            let current = activeHost?.id
            let lines = hosts.map { ($0.id == current ? "* " : "  ") + $0.name + "  " + $0.address }
            return info(lines.isEmpty ? "no SSH hosts. add one in Settings" : lines.joined(separator: "\n") + (current == nil ? "\n(none selected)" : ""))
        }
        if ["off", "none"].contains(args.lowercased()) {
            selectHost(nil)
            return info("ssh: off")
        }
        guard let match = hosts.first(where: { $0.name.lowercased().hasPrefix(args.lowercased()) }) else {
            return fail("no host named \(args)")
        }
        selectHost(match.id)
        info("ssh: \(match.name) (\(match.address)). connects on first use")
    }

    func selectHost(_ id: UUID?) {
        update { $0.activeHostID = id }
        // A run in progress keeps its connection; the next run reconnects to the new host.
        if connectionHostID != id, !isRunning { Task { await dropConnection() } }
    }

    // MARK: Sessions

    func refreshSessions() {
        sessions = storage.sessionSummaries()
    }

    func startNewSession() {
        guard !isRunning else { return info(Self.busy) }
        storage.saveSession(session)
        show(Session())
    }

    func openSession(_ id: UUID) {
        guard id != session.id else { return }
        guard !isRunning else { return info(Self.busy) }
        guard let loaded = storage.loadSession(id: id) else { return fail("That session could not be loaded.") }
        storage.saveSession(session)
        show(loaded)
    }

    func deleteSession(_ id: UUID) {
        if id == session.id {
            guard !isRunning else { return info(Self.busy) }
            show(Session())
        }
        storage.deleteSession(id: id)
        refreshSessions()
    }

    private func show(_ next: Session) {
        session = next
        alwaysAllow = false
        usageLine = nil
        refreshSessions()
        scrollTick += 1
    }

    private func sessionsCommand(_ args: String) {
        if args.isEmpty {
            listedSessions = Array(storage.sessionSummaries().prefix(20))
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d HH:mm"
            let lines = listedSessions.enumerated().map { index, summary in
                "\(index + 1)".padding(toLength: 4, withPad: " ", startingAt: 0) + formatter.string(from: summary.updatedAt) + "  " + summary.title
            }
            return info(lines.isEmpty ? "no saved sessions" : lines.joined(separator: "\n") + "\n\n/sessions <n> resumes one")
        }
        guard let number = Int(args), listedSessions.indices.contains(number - 1) else {
            return fail("run /sessions first, then /sessions <n>")
        }
        openSession(listedSessions[number - 1].id)
    }

    // MARK: Connections and hosts

    func apiKey(for profile: Profile) -> String { secrets.secret(for: profile.secretKey) ?? "" }
    func headers(for profile: Profile) -> [RequestHeader] { RequestHeader.decode(secrets.secret(for: profile.headersKey)) }

    func saveProfile(_ profile: Profile, apiKey: String, headers: [RequestHeader]) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        storage.saveProfiles(profiles)
        secrets.setSecret(apiKey, for: profile.secretKey)
        secrets.setSecret(RequestHeader.encode(headers), for: profile.headersKey)
        if settings.activeProfileID == nil || profiles.count == 1 {
            select(profile: profile)
        } else if settings.activeProfileID == profile.id, let model = settings.activeModel, !profile.models.contains(model) {
            update { $0.activeModel = profile.preferredModel }
        }
    }

    func deleteProfile(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        storage.saveProfiles(profiles)
        secrets.setSecret(nil, for: profile.secretKey)
        secrets.setSecret(nil, for: profile.headersKey)
        if settings.activeProfileID == profile.id {
            update {
                $0.activeProfileID = profiles.first?.id
                $0.activeModel = profiles.first?.preferredModel
            }
        }
    }

    func hostSecret(for host: SSHHost) -> String { secrets.secret(for: host.secretKey) ?? "" }
    func hostPassphrase(for host: SSHHost) -> String { secrets.secret(for: host.passphraseKey) ?? "" }

    func saveHost(_ host: SSHHost, secret: String, passphrase: String) {
        let isFirst = hosts.isEmpty
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        storage.saveHosts(hosts)
        secrets.setSecret(secret, for: host.secretKey)
        secrets.setSecret(passphrase, for: host.passphraseKey)
        if isFirst { update { $0.activeHostID = host.id } }
        // Reconnect with the new details on next use.
        if connectionHostID == host.id { Task { await dropConnection() } }
    }

    func deleteHost(_ host: SSHHost) {
        hosts.removeAll { $0.id == host.id }
        storage.saveHosts(hosts)
        secrets.setSecret(nil, for: host.secretKey)
        secrets.setSecret(nil, for: host.passphraseKey)
        if settings.activeHostID == host.id { selectHost(nil) }
    }

    // MARK: Workspace files

    /// Copies files picked in the system file browser into the workspace and returns their workspace paths.
    @discardableResult
    func importFiles(_ urls: [URL]) -> [String] {
        let files = FileManager.default
        var imported: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let base = url.deletingPathExtension().lastPathComponent
            let suffix = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
            var target = workspace.appendingPathComponent(url.lastPathComponent)
            var copy = 1
            while files.fileExists(atPath: target.path) {
                copy += 1
                target = workspace.appendingPathComponent("\(base) \(copy)\(suffix)")
            }
            do {
                try files.copyItem(at: url, to: target)
                imported.append(target.lastPathComponent)
            } catch {
                fail("Could not import \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return imported
    }

    func deleteFile(_ path: String) {
        try? FileManager.default.removeItem(at: workspace.appendingPathComponent(path))
    }

    // MARK: Demo content

    private func loadDemo(screen: String) {
        let profile = Profile(name: "openrouter", baseURL: "https://openrouter.ai/api/v1",
                              models: ["anthropic/claude-sonnet-5", "openai/gpt-6-luna"], defaultModel: "anthropic/claude-sonnet-5")
        let host = SSHHost(name: "web1", host: "10.0.0.12", username: "deploy")
        profiles = [profile]
        hosts = [host]
        secrets.setSecret("sk-demo-0000000000000000", for: profile.secretKey)
        secrets.setSecret(RequestHeader.encode([RequestHeader(name: "HTTP-Referer", value: "https://termai.example")]), for: profile.headersKey)
        settings = AppSettings(activeProfileID: profile.id, activeModel: profile.defaultModel, activeHostID: host.id,
                               themeID: UserDefaults.standard.string(forKey: "theme") ?? Theme.minimalDark.id)
        session = Session(title: "Why is nginx down on web1?", messages: [ChatMessage(role: .user, content: "demo")])
        let now = Date()
        sessions = [
            SessionSummary(id: session.id, title: session.title, updatedAt: now),
            SessionSummary(id: UUID(), title: "Rotate the deploy keys", updatedAt: now.addingTimeInterval(-3 * 3_600)),
            SessionSummary(id: UUID(), title: "Draft release notes for 0.2", updatedAt: now.addingTimeInterval(-26 * 3_600)),
            SessionSummary(id: UUID(), title: "Disk usage report for db1", updatedAt: now.addingTimeInterval(-4 * 86_400)),
        ]

        let fix = "ssh web1 $ sudo sed -i 's/servr_name/server_name/' /etc/nginx/sites-enabled/app && sudo nginx -t && sudo systemctl reload nginx"
        append(.user, "why is nginx down on web1?")
        append(.assistant, "Checking the service state first.")
        append(.tool, "× nginx.service - A high performance web server\n     Active: failed (Result: exit-code)\nnginx: [emerg] unknown directive \"servr_name\"\n  in /etc/nginx/sites-enabled/app:4\n[exit 3]",
               title: "ssh web1 $ systemctl status nginx --no-pager", status: .failed)
        append(.assistant, "There is a **typo** in the site config, line 4:\n\n```nginx\nservr_name example.com;\n```\n\nIt should be `server_name`. I can fix it and reload:")

        switch screen {
        case "empty":
            session = Session()
        case "approval":
            append(.tool, "", title: fix, status: .running)
            isRunning = true
            pendingApproval = PendingApproval(tool: "ssh_exec", summary: fix)
        default:
            append(.tool, "nginx: configuration file /etc/nginx/nginx.conf test is successful", title: fix, status: .ok)
            append(.assistant, "Fixed. nginx is serving again.\n\n- Config test passed\n- Service reloaded without dropping connections")
            usageLine = "2.4k in · 312 out · 9s"
        }

        switch screen {
        case "sidebar": showSidebar = true
        case "settings": panel = .settings
        case "connection": panel = .connection(profile.id)
        case "models": panel = .models
        case "files":
            let samples = ["notes/deploy-checklist.md": "# Deploy checklist\n", "notes/hosts.txt": "web1 10.0.0.12\n",
                           "scripts/backup.sh": "#!/bin/sh\ntar czf backup.tgz /srv/app\n", "nginx-app.conf": "server_name example.com;\n",
                           "report.md": "# Disk usage\n"]
            for (path, text) in samples {
                let url = workspace.appendingPathComponent(path)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(text.utf8).write(to: url)
            }
            panel = .files
        case "terminal":
            terminalItems = [
                TranscriptItem(kind: .info, text: "connecting to \(host.address)…"),
                TranscriptItem(kind: .tool, text: " 15:02:11 up 41 days,  3:17,  1 user,  load average: 0.08, 0.03, 0.01", title: "uptime", status: .ok),
                TranscriptItem(kind: .tool, text: "Filesystem      Size  Used Avail Use% Mounted on\n/dev/vda1        80G   31G   46G  41% /", title: "df -h /", status: .ok),
            ]
            panel = .terminal
        default: break
        }
    }
}
