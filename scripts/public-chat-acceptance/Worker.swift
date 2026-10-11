import CryptoKit
import Foundation

enum WorkerFailure: Error { case refused }

// Synthetic test identities only. This callback never uses the platform Keychain.
// The lock covers callbacks from the native SDK's worker threads.
// swiftlint:disable:next no_unchecked_sendable
final class TestCredentials: SecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private let file: URL
  private let key: SymmetricKey
  private var values: [String: String]

  init(root: URL) throws {
    file = root.appendingPathComponent("credentials.sealed")
    let keyFile = root.appendingPathComponent("credentials.key")
    if FileManager.default.fileExists(atPath: keyFile.path) {
      let bytes = try Data(contentsOf: keyFile)
      guard bytes.count == 32 else { throw WorkerFailure.refused }
      key = SymmetricKey(data: bytes)
    } else {
      guard !FileManager.default.fileExists(atPath: file.path) else { throw WorkerFailure.refused }
      key = SymmetricKey(size: .bits256)
      try key.withUnsafeBytes { try Data($0).write(to: keyFile, options: .atomic) }
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    }
    if FileManager.default.fileExists(atPath: file.path) {
      values = try JSONDecoder().decode(
        [String: String].self,
        from: AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: file)), using: key))
    } else {
      values = [:]
    }
  }

  private func save(_ next: [String: String]) throws {
    guard let sealed = try AES.GCM.seal(JSONEncoder().encode(next), using: key).combined else {
      throw WorkerFailure.refused
    }
    try sealed.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    values = next
  }
  func hasSecretForLabel(label: String) throws -> Bool { lock.withLock { values[label] != nil } }
  func hasSecretForAccountId(accountIdHex: String) throws -> Bool {
    lock.withLock { values[accountIdHex] != nil }
  }
  func writeSecret(label: String, accountIdHex: String, secretKeyHex: String) throws {
    try lock.withLock {
      var next = values
      next[label] = secretKeyHex
      next[accountIdHex] = secretKeyHex
      try save(next)
    }
  }
  func loadSecret(label: String, accountIdHex: String) throws -> String {
    try lock.withLock {
      guard let value = values[accountIdHex], values[label] == value else {
        throw WorkerFailure.refused
      }
      return value
    }
  }
  func removeSecret(label: String, accountIdHex: String) throws {
    try lock.withLock {
      var next = values
      next.removeValue(forKey: label)
      next.removeValue(forKey: accountIdHex)
      try save(next)
    }
  }
}

struct Request: Decodable {
  let command: String
  let member: String?
  let group: String?
  let text: String?
  let message: String?
  let sender: String?
  let secret: String?
}

@main
struct PublicChatWorker {
  static func line() throws -> Data? {
    var bytes = Data()
    while true {
      let byte = FileHandle.standardInput.readData(ofLength: 1)
      if byte.isEmpty { return bytes.isEmpty ? nil : bytes }
      if byte == Data([10]) { return bytes }
      guard bytes.count < 32768 else { throw WorkerFailure.refused }
      bytes.append(byte)
    }
  }
  static func reply(_ value: [String: Any]) throws {
    var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    bytes.append(10)
    FileHandle.standardOutput.write(bytes)
  }
  static func required(_ value: String?) throws -> String {
    guard let value, !value.isEmpty, value.utf8.count < 4096 else { throw WorkerFailure.refused }
    return value
  }
  static func main() async {
    var runtime: Marmot?
    do {
      guard CommandLine.arguments.count == 3 else { throw WorkerFailure.refused }
      let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
      let relay = CommandLine.arguments[2]
      guard let endpoint = URL(string: relay), endpoint.scheme == "ws",
        endpoint.host == "127.0.0.1", endpoint.port != nil
      else { throw WorkerFailure.refused }
      let marker = root.appendingPathComponent(".public-chat-test")
      let markerBytes = Data("isolated-public-chat-v1\n".utf8)
      if FileManager.default.fileExists(atPath: root.path) {
        guard try Data(contentsOf: marker) == markerBytes else { throw WorkerFailure.refused }
      } else {
        try FileManager.default.createDirectory(
          at: root, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        try markerBytes.write(to: marker)
      }
      let credentials = try TestCredentials(root: root)
      let client = try Marmot.newWithConfiguration(
        rootPath: root.appendingPathComponent("runtime").path, relayUrls: [relay],
        options: MarmotOptions(
          relayPolicy: .allowLoopback,
          clientName: "isolated-public-chat-test", secretStore: credentials))
      runtime = client
      try await client.start()
      var account: String?
      while let bytes = try line() {
        let request = try JSONDecoder().decode(Request.self, from: bytes)
        do {
          var value: [String: Any] = [:]
          switch request.command {
          case "create":
            guard account == nil else { throw WorkerFailure.refused }
            let identity = try await client.createIdentity(
              defaultRelays: [relay],
              bootstrapRelays: [relay], inboxRelays: [relay])
            account = identity.accountIdHex
            value = ["account": identity.accountIdHex]
          case "secret":
            value = ["secret": try client.revealNsec(accountRef: required(account))]
          case "import":
            guard account == nil else { throw WorkerFailure.refused }
            var state = try await client.beginOnboarding(
              nsec: required(request.secret),
              options: OnboardingOptionsFfi(
                defaultRelays: [relay], discoveryRelays: [relay], inboxRelays: [relay]))
            for _ in 0..<32 where !state.ready {
              state = try await client.runOnboarding(accountRef: state.accountIdHex)
              if state.ready { break }
              guard
                let step = state.steps.first(where: {
                  $0.status == .needsInput || $0.status == .retryableFailure
                })
              else { continue }
              if step.step == .singleDevice, step.actions.contains(.continueAnyway) {
                state = try await client.acknowledgeOnboardingSingleDevice(
                  accountRef: state.accountIdHex, revision: state.revision)
              } else if step.actions.contains(.continueWithout) {
                state = try await client.continueOnboardingWithout(
                  accountRef: state.accountIdHex, step: step.step)
              } else {
                throw WorkerFailure.refused
              }
            }
            guard state.ready else { throw WorkerFailure.refused }
            account = state.accountIdHex
            value = ["account": state.accountIdHex]
          case "reopen":
            let identities = try client.listAccounts()
            guard account == nil, identities.count == 1 else { throw WorkerFailure.refused }
            account = identities[0].accountIdHex
            value = ["account": try required(account)]
          case "publish":
            value = [
              "published": try await client.publishNewKeyPackage(accountRef: required(account))
            ]
          case "packages":
            value = [
              "count": try await client.accountKeyPackages(
                accountRef: required(account), bootstrapRelays: [relay]
              ).count
            ]
          case "create-chat":
            let group = try await client.createGroup(
              accountRef: required(account), name: "",
              memberRefs: [required(request.member)], description: nil)
            value = ["group": group]
          case "invitations":
            value = [
              "groups": try client.chatList(accountRef: required(account), includeArchived: true)
                .filter { $0.pendingConfirmation }.map(\.groupIdHex)
            ]
          case "accept":
            _ = try await client.acceptGroupInvite(
              accountRef: required(account), groupIdHex: required(request.group))
          case "state":
            let state = try await client.groupMlsState(
              accountRef: required(account), groupIdHex: required(request.group))
            value = [
              "members": state.memberCount, "current": state.protocolProfile == .current,
              "components": state.requiredAppComponents,
            ]
          case "send":
            let sent = try await client.sendText(
              accountRef: required(account), groupIdHex: required(request.group),
              text: required(request.text))
            value = ["messages": sent.messageIds, "published": sent.published]
          case "has-message":
            let matches = try client.messages(
              accountRef: required(account), groupIdHex: required(request.group), limit: 100,
              kinds: [9]
            )
            .filter {
              $0.messageIdHex == request.message && $0.plaintext == request.text
                && $0.sender == request.sender
            }
            value = ["matches": matches.count]
          case "catch-up": try await client.catchUpAccounts()
          case "close": try await client.shutdownAndClose()
          default: throw WorkerFailure.refused
          }
          try reply(["ok": true, "value": value])
          if request.command == "close" { return }
        } catch {
          let category: String
          switch error {
          case MarmotKitError.MissingKeyPackage: category = "missing-key-package"
          case MarmotKitError.Publish: category = "publish"
          default: category = "refused"
          }
          try reply(["ok": false, "stage": request.command, "category": category])
        }
      }
      try await client.shutdownAndClose()
    } catch {
      if let runtime { try? await runtime.shutdownAndClose() }
      // Never emit SDK error details, identities, secrets, packets or chat text.
      fputs("public-chat-worker-refused\n", stderr)
      exit(1)
    }
  }
}
