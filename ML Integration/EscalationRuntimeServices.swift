import Foundation
import AppKit
import Security

protocol EscalationConfigurable {
    func updateGitHubConfiguration(owner: String, repository: String, token: String)
    func updateEmailConfiguration(recipient: String)
}

protocol EscalationCredentialManageable {
    func loadStoredGitHubToken() -> String?
    func saveGitHubToken(_ token: String) throws
    func clearStoredGitHubToken() throws
}

protocol GitHubTokenSecureStoring {
    func readToken() -> String?
    func saveToken(_ token: String) throws
    func deleteToken() throws
}

struct KeychainGitHubTokenStore: GitHubTokenSecureStoring {
    private static let service = "com.tbdo.mlintegration"
    private static let account = "github-token"

    func readToken() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account
        ]

        let update: [CFString: Any] = [
            kSecValueData: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw RuntimeServiceError.commandFailed("Failed to update token in Keychain. Status: \(updateStatus)")
        }

        var add = query
        add[kSecValueData] = data
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw RuntimeServiceError.commandFailed("Failed to save token in Keychain. Status: \(addStatus)")
        }
    }

    func deleteToken() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RuntimeServiceError.commandFailed("Failed to delete token from Keychain. Status: \(status)")
        }
    }
}

final class DefaultEscalationService: EscalationService, EscalationConfigurable, EscalationCredentialManageable {
    private var githubOwner: String
    private var githubRepository: String
    private var githubToken: String
    private var supportEmailRecipient: String
    private let tokenStore: GitHubTokenSecureStoring

    init(
        githubOwner: String = "",
        githubRepository: String = "",
        githubToken: String = "",
        supportEmailRecipient: String = "",
        tokenStore: GitHubTokenSecureStoring = KeychainGitHubTokenStore()
    ) {
        self.githubOwner = githubOwner
        self.githubRepository = githubRepository
        self.tokenStore = tokenStore
        let trimmedToken = githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.githubToken = trimmedToken.isEmpty ? (tokenStore.readToken() ?? "") : trimmedToken
        self.supportEmailRecipient = supportEmailRecipient

        if !self.githubToken.isEmpty {
            try? tokenStore.saveToken(self.githubToken)
        }
    }

    func updateGitHubConfiguration(owner: String, repository: String, token: String) {
        githubOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        githubRepository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            githubToken = trimmedToken
            try? tokenStore.saveToken(trimmedToken)
        }
    }

    func updateEmailConfiguration(recipient: String) {
        supportEmailRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func loadStoredGitHubToken() -> String? {
        let stored = tokenStore.readToken()
        if let stored, !stored.isEmpty {
            githubToken = stored
        }
        return stored
    }

    func saveGitHubToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RuntimeServiceError.invalidVMRequest("GitHub token is empty.")
        }
        try tokenStore.saveToken(trimmed)
        githubToken = trimmed
    }

    func clearStoredGitHubToken() throws {
        try tokenStore.deleteToken()
        githubToken = ""
    }

    func openGitHubIssue(title: String, details: String, logs: URL?) async throws -> URL {
        guard !githubOwner.isEmpty, !githubRepository.isEmpty, !githubToken.isEmpty else {
            throw RuntimeServiceError.invalidVMRequest("GitHub owner, repository, and token are required.")
        }

        let endpoint = URL(string: "https://api.github.com/repos/\(githubOwner)/\(githubRepository)/issues")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(githubToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        var body = details
        if let logs {
            body += "\n\nDiagnostics bundle: \(logs.path)"
        }

        let payload: [String: Any] = [
            "title": title,
            "body": body
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RuntimeServiceError.commandFailed("Invalid GitHub response.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown GitHub API error."
            throw RuntimeServiceError.commandFailed("GitHub issue creation failed (\(http.statusCode)): \(message)")
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let htmlURLString = json["html_url"] as? String,
            let htmlURL = URL(string: htmlURLString)
        else {
            throw RuntimeServiceError.commandFailed("Unable to parse GitHub issue response.")
        }

        return htmlURL
    }

    func sendEmailEscalation(subject: String, body: String, attachments: [URL]) async throws {
        guard !supportEmailRecipient.isEmpty else {
            throw RuntimeServiceError.invalidVMRequest("Support email recipient is required.")
        }

        let draftURL = try writeEscalationDraft(subject: subject, body: body, attachments: attachments)

        let subjectQuery = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let bodyQuery = "\(body)\n\nDraft attachment: \(draftURL.path)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let mailto = URL(string: "mailto:\(supportEmailRecipient)?subject=\(subjectQuery)&body=\(bodyQuery)")

        if let mailto {
            NSWorkspace.shared.open(mailto)
        }
    }

    private func writeEscalationDraft(subject: String, body: String, attachments: [URL]) throws -> URL {
        let dir = RuntimeEnvironment.mlIntegrationRootURL()
            .appendingPathComponent("escalations", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fileURL = dir.appendingPathComponent("email-draft-\(UUID().uuidString).txt")
        var content = "Subject: \(subject)\n\n\(body)\n"

        if !attachments.isEmpty {
            content += "\nAttachments:\n"
            for attachment in attachments {
                content += "- \(attachment.path)\n"
            }
        }

        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}
