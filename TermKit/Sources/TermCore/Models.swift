import Foundation

/// An API endpoint: base URL plus the model IDs available on it. The API key and any custom headers live in the secret store.
public struct Profile: Codable, Identifiable, Equatable, Sendable {
    /// How the API key is put on the wire.
    public enum AuthScheme: String, Codable, Sendable, CaseIterable {
        /// `Authorization: Bearer <key>`
        case bearer
        /// `x-api-key: <key>`
        case apiKeyHeader = "x-api-key"
    }

    public var id: UUID
    public var name: String
    public var baseURL: String
    public var models: [String]
    public var defaultModel: String?
    public var authScheme: AuthScheme

    public init(id: UUID = UUID(), name: String, baseURL: String, models: [String] = [], defaultModel: String? = nil,
                authScheme: AuthScheme = .bearer) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.models = models
        self.defaultModel = defaultModel
        self.authScheme = authScheme
    }

    // Profiles saved before `authScheme` existed have no such key and use bearer.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        models = try container.decodeIfPresent([String].self, forKey: .models) ?? []
        defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel)
        authScheme = try container.decodeIfPresent(AuthScheme.self, forKey: .authScheme) ?? .bearer
    }

    public var secretKey: String { "profile.\(id.uuidString).apikey" }
    public var headersKey: String { "profile.\(id.uuidString).headers" }
    public var preferredModel: String? { defaultModel ?? models.first }
}

/// An extra HTTP header sent with every request to a profile's endpoint.
public struct RequestHeader: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var value: String

    public init(id: UUID = UUID(), name: String = "", value: String = "") {
        self.id = id
        self.name = name
        self.value = value
    }

    /// Header values are often credentials, so a profile's headers are kept in the secret store as one JSON string.
    /// Returns nil when there is nothing worth storing.
    public static func encode(_ headers: [RequestHeader]) -> String? {
        let named = headers.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !named.isEmpty, let data = try? JSONEncoder().encode(named) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ text: String?) -> [RequestHeader] {
        guard let text, let headers = try? JSONDecoder().decode([RequestHeader].self, from: Data(text.utf8)) else { return [] }
        return headers
    }
}

public struct SSHHost: Codable, Identifiable, Equatable, Sendable {
    public enum Auth: String, Codable, Sendable, CaseIterable {
        case password
        case privateKey
    }

    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var auth: Auth
    /// OpenSSH-format host key recorded on first connect; later connects must match it.
    public var trustedHostKey: String?

    public init(id: UUID = UUID(), name: String, host: String, port: Int = 22, username: String,
                auth: Auth = .password, trustedHostKey: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.trustedHostKey = trustedHostKey
    }

    public var secretKey: String { "host.\(id.uuidString).secret" }
    public var passphraseKey: String { "host.\(id.uuidString).passphrase" }
    public var address: String { "\(username)@\(host)" + (port == 22 ? "" : ":\(port)") }
}

public struct ToolCall: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Raw JSON object string as produced by the model.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    public var argumentValues: [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    public func string(_ key: String) -> String? { argumentValues[key] as? String }

    public func number(_ key: String) -> Double? {
        let value = argumentValues[key]
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

public struct ChatMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant, tool
    }

    public var role: Role
    public var content: String
    public var toolCalls: [ToolCall]?
    public var toolCallID: String?

    public init(role: Role, content: String, toolCalls: [ToolCall]? = nil, toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

/// One block in the on-screen transcript.
public struct TranscriptItem: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case user, assistant, tool, info, error
    }

    public enum Status: String, Codable, Sendable {
        case running, ok, failed, denied
    }

    public var id: UUID
    public var kind: Kind
    public var text: String
    /// Tool blocks only: the one-line description, e.g. `ssh web1 $ uptime`.
    public var title: String?
    public var status: Status?

    public init(id: UUID = UUID(), kind: Kind, text: String, title: String? = nil, status: Status? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.title = title
        self.status = status
    }
}

public struct Session: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [ChatMessage]
    public var transcript: [TranscriptItem]

    public init(id: UUID = UUID(), title: String = "new session", createdAt: Date = Date(), updatedAt: Date = Date(),
                messages: [ChatMessage] = [], transcript: [TranscriptItem] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.transcript = transcript
    }

    public var isEmpty: Bool { messages.isEmpty }
}

public struct SessionSummary: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var updatedAt: Date

    public init(id: UUID, title: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }
}

/// Who decides whether a tool call that changes state or leaves the device may run.
public enum ApprovalMode: String, Codable, Sendable, CaseIterable {
    /// Ask before anything that changes state or leaves the device.
    case ask
    /// Workspace file writes run without asking; commands and web requests still ask.
    case acceptEdits
    /// Planning only: file writes are refused; commands and web requests still ask.
    case plan
    /// Run every tool call without asking.
    case auto

    public var title: String {
        switch self {
        case .ask: return "Manual"
        case .acceptEdits: return "Accept edits"
        case .plan: return "Plan"
        case .auto: return "Bypass permissions"
        }
    }

    public var summary: String {
        switch self {
        case .ask: return "Always ask before commands, file edits and web requests"
        case .acceptEdits: return "File edits run without asking; commands and web requests still ask"
        case .plan: return "Explore and propose a plan; file edits are blocked"
        case .auto: return "Everything runs without asking"
        }
    }

    /// Parses the argument of `/approve`: the short names as well as the titles.
    public static func named(_ text: String) -> ApprovalMode? {
        switch text.lowercased().filter({ $0.isLetter }) {
        case "ask", "manual": return .ask
        case "edits", "acceptedits": return .acceptEdits
        case "plan": return .plan
        case "auto", "bypass", "bypasspermissions": return .auto
        default: return nil
        }
    }

    /// How a tool call that needs approval is settled without prompting; nil means ask the user.
    public func automaticDecision(forTool name: String) -> ApprovalDecision? {
        switch self {
        case .ask: return nil
        case .acceptEdits: return name == "write_file" ? .allow : nil
        case .plan: return name == "write_file" ? .deny : nil
        case .auto: return .allow
        }
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var activeProfileID: UUID?
    public var activeModel: String?
    public var activeHostID: UUID?
    public var themeID: String
    public var fontSize: Double
    public var approvalMode: ApprovalMode
    public var systemPrompt: String

    public init(activeProfileID: UUID? = nil, activeModel: String? = nil, activeHostID: UUID? = nil,
                themeID: String = Theme.minimalDark.id, fontSize: Double = 13,
                approvalMode: ApprovalMode = .ask, systemPrompt: String = "") {
        self.activeProfileID = activeProfileID
        self.activeModel = activeModel
        self.activeHostID = activeHostID
        self.themeID = themeID
        self.fontSize = fontSize
        self.approvalMode = approvalMode
        self.systemPrompt = systemPrompt
    }
}
