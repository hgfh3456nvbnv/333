import XCTest
@testable import TermCore

/// Replays scripted streams, one per model call, and records the requests it received.
final class ScriptedClient: ChatStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[StreamEvent]]
    private(set) var requests: [ChatRequest] = []

    init(_ scripts: [[StreamEvent]]) {
        self.scripts = scripts
    }

    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.lock()
        requests.append(request)
        let events = scripts.isEmpty ? [] : scripts.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

struct FakeShell: RemoteShell {
    var label = "box"
    func run(command: String, timeout: TimeInterval, onOutput: @escaping @Sendable (String) -> Void) async throws -> Int {
        onOutput("ran: \(command)\n")
        return command.contains("fail") ? 3 : 0
    }
}

actor Recorder {
    var messages: [ChatMessage] = []
    var finished: [(id: String, result: ToolResult, denied: Bool)] = []
    var text = ""

    func record(_ event: AgentEvent) {
        switch event {
        case .message(let message): messages.append(message)
        case .toolFinished(let id, let result, let denied): finished.append((id, result, denied))
        case .assistantDelta(let delta): text += delta
        default: break
        }
    }
}

final class TermCoreTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("termcore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
    }

    // MARK: Streaming

    func testSSEParserHandlesSplitChunksAndCRLF() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed(Data("data: {\"a\"".utf8)), [])
        XCTAssertEqual(parser.feed(Data(":1}\r\n\r\ndata:[DONE]\n: comment\nevent: x\n".utf8)), ["{\"a\":1}", "[DONE]"])
    }

    func testSSEParserKeepsMultibyteCharactersSplitAcrossChunks() {
        var parser = SSEParser()
        let bytes = Array("data: héllo ✓\n".utf8)
        XCTAssertEqual(parser.feed(Data(bytes[..<8])), [])
        XCTAssertEqual(parser.feed(Data(bytes[8...])), ["héllo ✓"])
    }

    func testDecodeTextToolCallsAndUsage() {
        XCTAssertEqual(OpenAIClient.decode(#"{"choices":[{"delta":{"content":"hi"}}]}"#), [.text("hi")])
        XCTAssertEqual(
            OpenAIClient.decode(#"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"c1","function":{"name":"ssh_exec","arguments":"{\"co"}}]}}]}"#),
            [.toolCallDelta(index: 1, id: "c1", name: "ssh_exec", arguments: "{\"co")])
        XCTAssertEqual(OpenAIClient.decode(#"{"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3}}"#),
                       [.usage(input: 12, output: 3)])
        XCTAssertEqual(OpenAIClient.decode("not json"), [])
    }

    func testRequestBodyAndEndpoint() throws {
        let request = ChatRequest(
            baseURL: "https://example.com/v1/", apiKey: "k", model: "m",
            messages: [
                ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "c1", name: "ssh_exec", arguments: "")]),
                ChatMessage(role: .tool, content: "out", toolCallID: "c1"),
            ],
            tools: ToolBox(workspace: workspace, shell: FakeShell()).specs)
        let urlRequest = try OpenAIClient.urlRequest(for: request)
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer k")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "m")
        XCTAssertEqual(body["stream"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let call = try XCTUnwrap((messages[0]["tool_calls"] as? [[String: Any]])?.first)
        XCTAssertEqual((call["function"] as? [String: Any])?["arguments"] as? String, "{}")
        XCTAssertEqual(messages[1]["tool_call_id"] as? String, "c1")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 5)
        let schema = (tools[0]["function"] as? [String: Any])?["parameters"] as? [String: Any]
        XCTAssertEqual(schema?["type"] as? String, "object")

        XCTAssertThrowsError(try OpenAIClient.endpoint("ftp://x", "/models"))
        XCTAssertThrowsError(try OpenAIClient.endpoint("not a url", "/models"))
    }

    func testAPIErrorExtractsMessage() {
        let error = APIError.from(status: 401, body: Data(#"{"error":{"message":"bad key"}}"#.utf8))
        XCTAssertEqual(error, APIError(status: 401, message: "bad key"))
        XCTAssertEqual(APIError.from(status: 502, body: Data("Bad Gateway".utf8)).message, "Bad Gateway")
    }

    // MARK: Agent

    func testAgentRunsToolThenAnswers() async throws {
        let client = ScriptedClient([
            [.text("checking"),
             .toolCallDelta(index: 0, id: "c1", name: "ssh_exec", arguments: "{\"command\":"),
             .toolCallDelta(index: 0, id: nil, name: nil, arguments: "\"uptime\"}")],
            [.text("all good")],
        ])
        let recorder = Recorder()
        let agent = Agent(client: client, tools: ToolBox(workspace: workspace, shell: FakeShell()))
        try await agent.run(
            request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: [ChatMessage(role: .user, content: "status?")]),
            approve: { _, summary in
                XCTAssertEqual(summary, "ssh box $ uptime")
                return .allow
            },
            emit: { await recorder.record($0) })

        let messages = await recorder.messages
        XCTAssertEqual(messages.map(\.role), [.assistant, .tool, .assistant])
        XCTAssertEqual(messages[0].toolCalls?.first?.arguments, "{\"command\":\"uptime\"}")
        XCTAssertEqual(messages[1].toolCallID, "c1")
        XCTAssertEqual(messages[1].content, "ran: uptime\n\n[exit 0]")
        XCTAssertEqual(messages[2].content, "all good")

        // The second model call must see the tool result.
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertEqual(client.requests[1].messages.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(client.requests[0].tools.first?.name, "ssh_exec")
    }

    func testDeniedToolIsReportedToTheModelAndNotRun() async throws {
        let client = ScriptedClient([
            [.toolCallDelta(index: 0, id: "c1", name: "write_file", arguments: "{\"path\":\"a.txt\",\"content\":\"x\"}")],
            [.text("ok, skipped")],
        ])
        let recorder = Recorder()
        let agent = Agent(client: client, tools: ToolBox(workspace: workspace, shell: nil))
        try await agent.run(
            request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: [ChatMessage(role: .user, content: "write")]),
            approve: { _, _ in .deny },
            emit: { await recorder.record($0) })

        let finished = await recorder.finished
        XCTAssertEqual(finished.count, 1)
        XCTAssertTrue(finished[0].denied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("a.txt").path))
        let messages = await recorder.messages
        XCTAssertEqual(messages[1].role, .tool)
        XCTAssertTrue(messages[1].content.contains("declined"))
    }

    func testReadOnlyToolsSkipApprovalAndFailedCommandsAreErrors() async throws {
        try Data("hello".utf8).write(to: workspace.appendingPathComponent("note.txt"))
        let client = ScriptedClient([
            [.toolCallDelta(index: 0, id: "", name: "read_file", arguments: "{\"path\":\"note.txt\"}"),
             .toolCallDelta(index: 1, id: "c2", name: "ssh_exec", arguments: "{\"command\":\"fail\"}")],
            [.text("done")],
        ])
        let recorder = Recorder()
        let asked = Recorder()
        let agent = Agent(client: client, tools: ToolBox(workspace: workspace, shell: FakeShell()))
        try await agent.run(
            request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: [ChatMessage(role: .user, content: "go")]),
            approve: { call, _ in
                await asked.record(.assistantDelta(call.name))
                return .allow
            },
            emit: { await recorder.record($0) })

        let askedFor = await asked.text
        XCTAssertEqual(askedFor, "ssh_exec")
        let finished = await recorder.finished
        XCTAssertEqual(finished[0].result, ToolResult(text: "hello"))
        XCTAssertTrue(finished[1].result.isError)
        XCTAssertTrue(finished[1].result.text.hasSuffix("[exit 3]"))
        // A call that arrived without an id still gets one, so its result can be matched.
        let messages = await recorder.messages
        XCTAssertFalse(try XCTUnwrap(messages[0].toolCalls?[0].id).isEmpty)
        XCTAssertEqual(messages[1].toolCallID, messages[0].toolCalls?[0].id)
    }

    func testAgentStopsAfterMaxSteps() async {
        let loop: [StreamEvent] = [.toolCallDelta(index: 0, id: "c", name: "list_files", arguments: "{}")]
        let agent = Agent(client: ScriptedClient([loop, loop, loop]), tools: ToolBox(workspace: workspace, shell: nil), maxSteps: 2)
        do {
            try await agent.run(
                request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: []),
                approve: { _, _ in .allow }, emit: { _ in })
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AgentError, .tooManySteps(2))
        }
    }

    // MARK: Tools

    func testWorkspaceToolsStayInsideWorkspace() async throws {
        let tools = ToolBox(workspace: workspace, shell: nil)
        let write = await tools.run(ToolCall(id: "1", name: "write_file", arguments: #"{"path":"dir/a.txt","content":"abc"}"#)) { _ in }
        XCTAssertEqual(write, ToolResult(text: "wrote 3 bytes"))
        let list = await tools.run(ToolCall(id: "2", name: "list_files", arguments: #"{"path":"dir"}"#)) { _ in }
        XCTAssertEqual(list.text, "a.txt  3")
        let root = await tools.run(ToolCall(id: "3", name: "list_files", arguments: "{}")) { _ in }
        XCTAssertEqual(root.text, "dir/")

        for path in ["../outside.txt", "dir/../../outside.txt", "/../../etc/passwd"] {
            let escaped = await tools.run(ToolCall(id: "4", name: "read_file", arguments: "{\"path\":\"\(path)\"}")) { _ in }
            XCTAssertTrue(escaped.isError, path)
            XCTAssertTrue(escaped.text.contains("outside the workspace"), escaped.text)
        }
        // An absolute-looking path is treated as relative to the workspace root.
        let absolute = await tools.run(ToolCall(id: "5", name: "read_file", arguments: #"{"path":"/dir/a.txt"}"#)) { _ in }
        XCTAssertEqual(absolute.text, "abc")

        let noShell = await tools.run(ToolCall(id: "6", name: "ssh_exec", arguments: #"{"command":"ls"}"#)) { _ in }
        XCTAssertTrue(noShell.isError)
        XCTAssertFalse(tools.specs.contains { $0.name == "ssh_exec" })
    }

    func testSymlinkCannotEscapeWorkspace() async throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("secret".utf8).write(to: outside.appendingPathComponent("s.txt"))
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("link"), withDestinationURL: outside)

        let result = await ToolBox(workspace: workspace, shell: nil)
            .run(ToolCall(id: "1", name: "read_file", arguments: #"{"path":"link/s.txt"}"#)) { _ in }
        XCTAssertTrue(result.isError, result.text)
    }

    func testTruncateAndStripHTML() {
        let long = String(repeating: "a", count: 50) + String(repeating: "b", count: 50)
        let cut = Truncate.middle(long, limit: 20)
        XCTAssertTrue(cut.hasPrefix("aaaaaaaaaa\n"))
        XCTAssertTrue(cut.hasSuffix("\nbbbbbbbbbb"))
        XCTAssertTrue(cut.contains("80 characters omitted"))
        XCTAssertEqual(ToolBox.stripHTML("<html><style>p{}</style><p>Tom &amp; Jerry</p><script>x()</script></html>"), "Tom & Jerry")
    }

    func testMarkdownSegmentsAndExport() {
        XCTAssertEqual(Markdown.segments("intro\n\n```sh\nls -la\n\necho hi\n```\nafter"), [
            .init(isCode: false, text: "intro"),
            .init(isCode: true, text: "ls -la\n\necho hi", language: "sh"),
            .init(isCode: false, text: "after"),
        ])
        // A fence still open while streaming renders as code.
        XCTAssertEqual(Markdown.segments("a\n```\nx = 1"), [.init(isCode: false, text: "a"), .init(isCode: true, text: "x = 1")])
        XCTAssertEqual(Markdown.segments(""), [])

        let session = Session(title: "t", transcript: [
            TranscriptItem(kind: .user, text: "hi"), TranscriptItem(kind: .info, text: "noise"),
            TranscriptItem(kind: .tool, text: "up 3 days", title: "ssh box $ uptime"), TranscriptItem(kind: .assistant, text: "fine"),
        ])
        XCTAssertEqual(Markdown.export(session), "# t\n\n**❯ hi**\n\n```\nssh box $ uptime\nup 3 days\n```\n\nfine\n")
    }

    func testToolOutputArrivesInOrderBeforeTheResult() async throws {
        struct Chatty: RemoteShell {
            var label = "box"
            func run(command: String, timeout: TimeInterval, onOutput: @escaping @Sendable (String) -> Void) async throws -> Int {
                for n in 0..<200 { onOutput("\(n),") }
                return 0
            }
        }
        actor Log {
            var entries: [String] = []
            func add(_ entry: String) { entries.append(entry) }
        }
        let log = Log()
        let client = ScriptedClient([[.toolCallDelta(index: 0, id: "c1", name: "ssh_exec", arguments: "{\"command\":\"x\"}")], [.text("ok")]])
        try await Agent(client: client, tools: ToolBox(workspace: workspace, shell: Chatty())).run(
            request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: []),
            approve: { _, _ in .allow },
            emit: { event in
                switch event {
                case .toolOutput(_, let chunk): await log.add(chunk)
                case .toolFinished: await log.add("END")
                default: break
                }
            })
        let entries = await log.entries
        XCTAssertEqual(entries, (0..<200).map { "\($0)," } + ["END"])
    }

    // MARK: Commands, storage

    func testCommandParsing() {
        XCTAssertEqual(Commands.parse("  "), .empty)
        XCTAssertEqual(Commands.parse("hello"), .prompt("hello"))
        XCTAssertEqual(Commands.parse("/model  gpt-x "), .command(name: "model", args: "gpt-x"))
        XCTAssertEqual(Commands.parse("/NEW"), .command(name: "new", args: ""))
        XCTAssertEqual(Commands.parse("/etc/hosts looks odd"), .prompt("/etc/hosts looks odd"))
        XCTAssertEqual(Commands.parse("! ls -la"), .shell("ls -la"))
        XCTAssertEqual(Commands.parse("!"), .empty)
        XCTAssertEqual(Commands.suggestions(for: "/se").map(\.name), ["setup", "sessions"])
        XCTAssertEqual(Commands.suggestions(for: "/model x"), [])
        XCTAssertEqual(Commands.suggestions(for: "hi"), [])
    }

    func testStorageRoundTrip() {
        let storage = Storage(directory: workspace)
        let profile = Profile(name: "p", baseURL: "https://x/v1", models: ["a", "b"])
        storage.saveProfiles([profile])
        storage.saveHosts([SSHHost(name: "h", host: "example.com", port: 2222, username: "u", auth: .privateKey)])
        var settings = AppSettings()
        settings.themeID = "crt-amber"
        settings.approvalMode = .auto
        storage.saveSettings(settings)

        // Whole-second dates: the store keeps ISO 8601 timestamps without fractions.
        let older = Session(title: "older", createdAt: Date(timeIntervalSince1970: 50), updatedAt: Date(timeIntervalSince1970: 100),
                            messages: [ChatMessage(role: .user, content: "1")])
        let newer = Session(title: "newer", createdAt: Date(timeIntervalSince1970: 60), updatedAt: Date(timeIntervalSince1970: 200), messages: [ChatMessage(role: .user, content: "2")],
                            transcript: [TranscriptItem(kind: .tool, text: "out", title: "ssh $ ls", status: .ok)])
        storage.saveSession(older)
        storage.saveSession(newer)
        storage.saveSession(Session())  // empty sessions are not persisted

        let reloaded = Storage(directory: workspace)
        XCTAssertEqual(reloaded.loadProfiles(), [profile])
        XCTAssertEqual(reloaded.loadHosts().first?.address, "u@example.com:2222")
        XCTAssertEqual(reloaded.loadSettings(), settings)
        XCTAssertEqual(reloaded.sessionSummaries().map(\.title), ["newer", "older"])
        XCTAssertEqual(reloaded.loadSession(id: newer.id), newer)
        reloaded.deleteSession(id: newer.id)
        XCTAssertEqual(reloaded.sessionSummaries().map(\.title), ["older"])
        XCTAssertEqual(Theme.named("nope"), .minimalDark)
    }

    // MARK: Connections, permissions, rendering and the file browser

    func testAuthSchemesAndCustomHeaders() throws {
        var request = ChatRequest(
            baseURL: "https://example.com/v1", apiKey: "k", model: "m", messages: [], authScheme: .apiKeyHeader,
            headers: [RequestHeader(name: " HTTP-Referer ", value: "https://app.example"), RequestHeader(name: "", value: "ignored")])
        var urlRequest = try OpenAIClient.urlRequest(for: request)
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "HTTP-Referer"), "https://app.example")

        // A custom header can replace the default credential header.
        request.authScheme = .bearer
        request.headers = [RequestHeader(name: "Authorization", value: "Basic abc")]
        urlRequest = try OpenAIClient.urlRequest(for: request)
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Basic abc")
    }

    func testProfileCompatibilityAndHeaderStorage() throws {
        // Profiles written before auth schemes existed still load.
        let legacy = #"[{"id":"\#(UUID().uuidString)","name":"old","baseURL":"https://x/v1","models":["a"]}]"#
        let profiles = try JSONDecoder().decode([Profile].self, from: Data(legacy.utf8))
        XCTAssertEqual(profiles.first?.authScheme, .bearer)
        XCTAssertEqual(profiles.first?.preferredModel, "a")

        let headers = [RequestHeader(name: "X-Org", value: "acme"), RequestHeader(name: "  ", value: "dropped")]
        let stored = try XCTUnwrap(RequestHeader.encode(headers))
        XCTAssertEqual(RequestHeader.decode(stored), [headers[0]])
        XCTAssertNil(RequestHeader.encode([RequestHeader()]))
        XCTAssertEqual(RequestHeader.decode(nil), [])
        XCTAssertEqual(RequestHeader.decode("not json"), [])
    }

    func testApprovalModes() {
        XCTAssertNil(ApprovalMode.ask.automaticDecision(forTool: "write_file"))
        XCTAssertEqual(ApprovalMode.acceptEdits.automaticDecision(forTool: "write_file"), .allow)
        XCTAssertNil(ApprovalMode.acceptEdits.automaticDecision(forTool: "ssh_exec"))
        XCTAssertEqual(ApprovalMode.plan.automaticDecision(forTool: "write_file"), .deny)
        XCTAssertNil(ApprovalMode.plan.automaticDecision(forTool: "fetch_url"))
        XCTAssertEqual(ApprovalMode.auto.automaticDecision(forTool: "ssh_exec"), .allow)

        XCTAssertEqual(ApprovalMode.named("Manual"), .ask)
        XCTAssertEqual(ApprovalMode.named("accept-edits"), .acceptEdits)
        XCTAssertEqual(ApprovalMode.named("edits"), .acceptEdits)
        XCTAssertEqual(ApprovalMode.named("bypass"), .auto)
        XCTAssertNil(ApprovalMode.named("sometimes"))
        // Raw values stored by earlier versions keep their meaning.
        XCTAssertEqual(ApprovalMode(rawValue: "ask"), .ask)
        XCTAssertEqual(ApprovalMode(rawValue: "auto"), .auto)

        XCTAssertTrue(SystemPrompt.build(custom: "", hostLabel: nil, planning: true).contains("Plan mode is on"))
        XCTAssertFalse(SystemPrompt.build(custom: "", hostLabel: nil).contains("Plan mode"))
    }

    func testMarkdownBlocks() {
        let text = """
        # Title

        Some **bold** text
        second line

        - one
          - nested
          continued
        2. two

        > quoted
        > more

        ---
        | a | b |
        |---|:-:|
        | 1 | 2 |
        ```swift
        let x = 1
        ```
        """
        XCTAssertEqual(Markdown.blocks(text), [
            .heading(level: 1, text: "Title"),
            .paragraph("Some **bold** text\nsecond line"),
            .listItem(marker: "•", indent: 0, text: "one"),
            .listItem(marker: "•", indent: 1, text: "nested\ncontinued"),
            .listItem(marker: "2.", indent: 0, text: "two"),
            .quote("quoted\nmore"),
            .rule,
            .table([["a", "b"], ["1", "2"]]),
            .code(language: "swift", text: "let x = 1"),
        ])
        // Not markup: a hashtag, a lone dash and a number without a list delimiter.
        XCTAssertEqual(Markdown.blocks("#tag\n-\n3 apples"), [.paragraph("#tag\n-\n3 apples")])
    }

    func testWorkspaceFileBrowsing() throws {
        let files = FileManager.default
        try files.createDirectory(at: workspace.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: workspace.appendingPathComponent("b.txt"))
        try Data("x".utf8).write(to: workspace.appendingPathComponent("A.md"))
        try Data("let a = 1".utf8).write(to: workspace.appendingPathComponent("src/main.swift"))
        try Data("deep".utf8).write(to: workspace.appendingPathComponent("src/deep/Notes.TXT"))
        try Data([0xFF, 0xFE, 0x00]).write(to: workspace.appendingPathComponent("blob.bin"))
        try Data("secret".utf8).write(to: workspace.appendingPathComponent(".hidden"))

        // Folders first, then files by name ignoring case; dotfiles are left out.
        XCTAssertEqual(WorkspaceFiles.list(root: workspace).map(\.path), ["src", "A.md", "b.txt", "blob.bin"])
        XCTAssertEqual(WorkspaceFiles.list(root: workspace).first { $0.path == "b.txt" }?.size, 5)
        XCTAssertEqual(WorkspaceFiles.list(root: workspace, directory: "../..").map(\.path), [])

        XCTAssertEqual(WorkspaceFiles.tree(root: workspace, expanded: []).map(\.path), ["src", "A.md", "b.txt", "blob.bin"])
        let tree = WorkspaceFiles.tree(root: workspace, expanded: ["src"])
        XCTAssertEqual(tree.map(\.path), ["src", "src/deep", "src/main.swift", "A.md", "b.txt", "blob.bin"])
        XCTAssertEqual(tree.map(\.depth), [0, 1, 1, 0, 0, 0])
        XCTAssertEqual(tree[2].name, "main.swift")

        XCTAssertEqual(WorkspaceFiles.search(root: workspace, query: "TXT").map(\.path), ["b.txt", "src/deep/Notes.TXT"])
        XCTAssertEqual(WorkspaceFiles.search(root: workspace, query: "nothing"), [])

        XCTAssertEqual(WorkspaceFiles.text(root: workspace, path: "src/main.swift"), "let a = 1")
        XCTAssertNil(WorkspaceFiles.text(root: workspace, path: "blob.bin"))
        XCTAssertNil(WorkspaceFiles.text(root: workspace, path: "../outside.txt"))
        XCTAssertEqual(WorkspaceFiles.text(root: workspace, path: "b.txt", limit: 2), "he\n… [truncated]")
    }

    // MARK: Live HTTP (needs a mock server; see Tests/mock_server.py)

    func testLiveStreamingAgainstMockServer() async throws {
        guard let base = ProcessInfo.processInfo.environment["TERMAI_TEST_BASEURL"] else {
            throw XCTSkip("set TERMAI_TEST_BASEURL to run")
        }
        let client = OpenAIClient()
        let models = try await client.listModels(baseURL: base, apiKey: "test-key")
        XCTAssertEqual(models, ["mock-a", "mock-b"])

        let recorder = Recorder()
        let agent = Agent(client: client, tools: ToolBox(workspace: workspace, shell: FakeShell()))
        try await agent.run(
            request: ChatRequest(baseURL: base, apiKey: "test-key", model: "mock-a", messages: [ChatMessage(role: .user, content: "go")]),
            approve: { _, _ in .allow }, emit: { await recorder.record($0) })
        let messages = await recorder.messages
        XCTAssertEqual(messages.map(\.role), [.assistant, .tool, .assistant])
        XCTAssertEqual(messages[1].content, "ran: echo hi\n\n[exit 0]")
        XCTAssertEqual(messages[2].content, "héllo ✓ done")

        do {
            for try await _ in client.streamChat(ChatRequest(baseURL: base, apiKey: "wrong", model: "m", messages: [])) {}
            XCTFail("expected 401")
        } catch {
            XCTAssertEqual(error as? APIError, APIError(status: 401, message: "bad key"))
        }
    }
}
