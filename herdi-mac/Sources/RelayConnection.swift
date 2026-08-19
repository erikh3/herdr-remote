import Foundation
import Network
import Observation
import UserNotifications

@Observable
final class RelayConnection {
    var agents: [Agent] = []
    var isConnected = false
    var hostAddress = "ws://127.0.0.1:8375"
    var mode: ConnectionMode = .direct
    var herdrError: String? = nil  // Surfaces binary-not-found etc.

    enum ConnectionMode: String, CaseIterable {
        case direct = "Direct (herdr CLI)"
        case relay = "Relay (WebSocket)"
    }

    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var pollTimer: Timer?
    private var reconnectAttempt = 0
    private var reconnecting = false
    private var herdrPath: String = ""
    var remotes: [String] = [] // SSH targets, e.g. ["user@host"]

    init() {
        herdrPath = resolveHerdrPath()
        // Load saved remotes
        if let saved = UserDefaults.standard.stringArray(forKey: "herdi_remotes") {
            remotes = saved
        }
        startDirect()
    }

    /// Resolve herdr binary: UserDefaults override → HERDR_BIN env → PATH lookup → common locations
    private func resolveHerdrPath() -> String {
        // 1. UserDefaults override (set via Settings)
        if let custom = UserDefaults.standard.string(forKey: "herdi_herdr_path"),
           !custom.isEmpty, FileManager.default.isExecutableFile(atPath: custom) {
            return custom
        }
        // 2. HERDR_BIN environment variable
        if let envPath = ProcessInfo.processInfo.environment["HERDR_BIN"],
           FileManager.default.isExecutableFile(atPath: envPath) {
            return envPath
        }
        // 3. Resolve via PATH using /usr/bin/which
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["herdr"]
        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice
        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            if whichProcess.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        } catch {}
        // 4. Common install locations
        let commonPaths = [
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
            NSString(string: "~/.local/bin/herdr").expandingTildeInPath,
            NSString(string: "~/bin/herdr").expandingTildeInPath
        ]
        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Not found — return empty and set error in pollHerdr
        return ""
    }

    // MARK: - Direct Mode (polls herdr CLI)

    func startDirect() {
        mode = .direct
        task?.cancel(with: .normalClosure, reason: nil)
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollHerdr()
        }
        pollHerdr() // immediate first poll
    }

    private func pollHerdr() {
        DispatchQueue.global(qos: .utility).async { [self] in
            // Check if herdr binary is found
            if herdrPath.isEmpty {
                DispatchQueue.main.async { [self] in
                    isConnected = false
                    herdrError = "herdr not found. Install herdr or set path in Settings."
                    agents = []
                }
                return
            }
            
            // Local
            var allAgents = parseAgents(from: runHerdr("pane", "list"), host: "local")

            // Remotes via SSH
            for remote in remotes {
                let result = runSSH(remote, "herdr", "pane", "list")
                allAgents += parseAgents(from: result, host: remote)
            }

            DispatchQueue.main.async { [self] in
                isConnected = true
                herdrError = nil  // Clear any previous error
                var seen = Set<String>()
                for a in allAgents {
                    seen.insert(a.id)
                    if let existing = agents.first(where: { $0.id == a.id }) {
                        if existing.status != a.status {
                            if a.status == .blocked && existing.status != .blocked {
                                readPaneForBlocked(existing, remote: a.host == "local" ? nil : a.host)
                            }
                            existing.status = a.status
                        }
                        if existing.project != a.project { existing.project = a.project }
                        if existing.host != a.host { existing.host = a.host }
                    } else {
                        let agent = Agent(id: a.id, name: a.name, status: a.status, project: a.project, cwd: a.cwd, host: a.host)
                        agents.append(agent)
                        if a.status == .blocked { readPaneForBlocked(agent, remote: a.host == "local" ? nil : a.host) }
                    }
                }
                agents.removeAll { !seen.contains($0.id) }
            }
        }
    }

    private struct ParsedAgent {
        let id: String, name: String, status: AgentStatus, project: String, cwd: String, host: String
    }

    private struct PaneLocation {
        let workspaceId: String
        let tabId: String
    }

    private func parseAgents(from output: String, host: String) -> [ParsedAgent] {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultObj = json["result"] as? [String: Any],
              let panes = resultObj["panes"] as? [[String: Any]] else { return [] }

        return panes.compactMap { p in
            guard let agent = p["agent"] as? String, !agent.isEmpty else { return nil }
            let paneId = (host == "local" ? "" : "\(host):") + (p["pane_id"] as? String ?? "")
            let status = AgentStatus(rawValue: p["agent_status"] as? String ?? "unknown") ?? .unknown
            let cwd = p["cwd"] as? String ?? ""
            return ParsedAgent(id: paneId, name: agent, status: status, project: (cwd as NSString).lastPathComponent, cwd: cwd, host: host)
        }
    }

    private func parsePaneLocation(from output: String) -> PaneLocation? {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let pane = result["pane"] as? [String: Any],
              let workspaceId = pane["workspace_id"] as? String,
              let tabId = pane["tab_id"] as? String else { return nil }
        return PaneLocation(workspaceId: workspaceId, tabId: tabId)
    }

    private func runSSH(_ remote: String, _ args: String...) -> String {
        let process = Process()
        let password = KeychainHelper.getPassword(for: remote)

        if let password, FileManager.default.fileExists(atPath: "/opt/homebrew/bin/sshpass") {
            // Use sshpass for password auth
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/sshpass")
            process.arguments = ["-p", password, "ssh", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=no", remote] + args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-o", "ConnectTimeout=5", "-o", "BatchMode=yes", remote] + args
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "" }
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch { return "" }
    }

    func addRemote(_ remote: String, password: String? = nil) {
        guard !remote.isEmpty, !remotes.contains(remote) else { return }
        remotes.append(remote)
        UserDefaults.standard.set(remotes, forKey: "herdi_remotes")
        if let password, !password.isEmpty {
            KeychainHelper.setPassword(password, for: remote)
        }
    }

    func removeRemote(_ remote: String) {
        remotes.removeAll { $0 == remote }
        UserDefaults.standard.set(remotes, forKey: "herdi_remotes")
        KeychainHelper.deletePassword(for: remote)
    }

    /// Strip the "host:" prefix from a pane id for remote agents.
    private func realPaneId(_ id: String, remote: String?) -> String {
        remote == nil ? id : String(id.drop(while: { $0 != ":" }).dropFirst())
    }

    /// Read recent pane output (local or via ssh).
    private func readPaneRecent(_ paneId: String, remote: String?, lines: Int = 100) -> String {
        if let remote {
            return runSSH(remote, "herdr", "pane", "read", paneId, "--lines", String(lines), "--source", "recent")
        }
        return runHerdr("pane", "read", paneId, "--lines", String(lines), "--source", "recent")
    }

    private func readPaneForBlocked(_ agent: Agent, remote: String? = nil) {
        let paneId = realPaneId(agent.id, remote: remote)

        DispatchQueue.global(qos: .utility).async { [self] in
            let raw = readPaneRecent(paneId, remote: remote)

            let question = QuestionParser.detectQuestion(raw)
            let promptId = QuestionParser.promptId(paneId: agent.id, content: raw)

            if let question {
                let visible = question.options
                    .map { $0.label }
                    .filter { $0 != QuestionParser.questionOther && !$0.contains("Done selecting") }
                let checked = question.options
                    .filter { $0.multi && $0.checked && $0.label != QuestionParser.questionOther
                              && !$0.label.contains("Done selecting") }
                    .map { $0.label }
                let displayPrompt = question.text.isEmpty ? "(question)" : question.text

                DispatchQueue.main.async {
                    agent.prompt = displayPrompt
                    agent.promptId = promptId
                    agent.isMultiSelect = question.isMultiSelect
                    if question.isMultiSelect {
                        agent.options = nil
                        agent.multiOptions = visible
                        agent.selectedOptions = checked
                    } else {
                        agent.options = visible
                        agent.multiOptions = []
                        agent.selectedOptions = []
                    }
                    self.sendNotification(agent: agent.name, project: agent.project)
                }
                return
            }

            // Not an omp question: permission prompt or free-form. Fall back to
            // approval-option detection over the last lines of pane output.
            let approval = QuestionParser.detectApprovalOptions(raw)
            let tail = raw.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .suffix(6)
                .joined(separator: "\n")

            DispatchQueue.main.async {
                agent.prompt = String(tail.prefix(500))
                agent.promptId = promptId
                agent.isMultiSelect = false
                agent.multiOptions = []
                agent.selectedOptions = []
                agent.options = approval.isEmpty
                    ? QuestionParser.toolOptions
                    : approval
                self.sendNotification(agent: agent.name, project: agent.project)
            }
        }
    }

    /// Run herdr, returning stdout and whether the process exited 0.
    private func runHerdrChecked(_ args: [String]) -> (output: String, ok: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: herdrPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (out, process.terminationStatus == 0)
        } catch { return ("", false) }
    }

    private func runHerdr(_ args: String...) -> String { runHerdrChecked(Array(args)).output }

    // MARK: - Relay Mode (WebSocket)

    func connectRelay(to urlString: String) {
        guard let url = URL(string: urlString) else { return }
        mode = .relay
        hostAddress = urlString
        pollTimer?.invalidate()
        pollTimer = nil
        reconnecting = false
        task?.cancel(with: .normalClosure, reason: nil)
        task = session.webSocketTask(with: url)
        task?.resume()
        reconnectAttempt = 0
        listen()
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        pollTimer?.invalidate()
        isConnected = false
    }

    func send(response: ResponseMessage) {
        if mode == .direct {
            let paneId = response.pane_id
            guard let agent = agents.first(where: { $0.id == paneId }) else {
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    _ = runHerdrRaw(["pane", "send-text", paneId, response.text + "\n"])
                }
                return
            }
            // If this pane is currently a detected question, navigate by cursor;
            // otherwise send literal text (permission prompts, free-form).
            if agent.promptId != nil, (agent.options?.isEmpty == false) {
                directRespondToQuestion(agent: agent, text: response.text)
            } else {
                let remote = agent.host == "local" ? nil : agent.host
                let realId = realPaneId(paneId, remote: remote)
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    if let remote {
                        _ = runSSH(remote, "herdr", "pane", "send-text", realId, response.text + "\n")
                    } else {
                        _ = runHerdrRaw(["pane", "send-text", realId, response.text + "\n"])
                    }
                }
            }
        } else {
            guard let data = try? JSONEncoder().encode(response) else { return }
            task?.send(.string(String(data: data, encoding: .utf8)!)) { _ in }
        }
    }

    func toggleQuestionOption(paneId: String, promptId: String, option: String) {
        if mode == .relay {
            guard let data = try? JSONEncoder().encode(
                QuestionToggleMessage(pane_id: paneId, prompt_id: promptId, option: option)
            ) else { return }
            task?.send(.string(String(data: data, encoding: .utf8)!)) { _ in }
            return
        }
        // Direct mode: navigate cursor to the option and press Enter to toggle.
        guard let agent = agents.first(where: { $0.id == paneId }) else { return }
        let remote = agent.host == "local" ? nil : agent.host
        let realId = realPaneId(paneId, remote: remote)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let raw = readPaneRecent(realId, remote: remote)
            guard let question = QuestionParser.detectQuestion(raw), question.isMultiSelect else { return }
            guard let target = question.options.firstIndex(where: {
                $0.label.caseInsensitiveCompare(option) == .orderedSame
            }) else { return }
            let steps = target - question.selectedIndex
            let dir = steps >= 0 ? "Down" : "Up"
            let keys = Array(repeating: dir, count: abs(steps)) + ["Enter"]
            _ = runHerdrKeys(paneId: realId, remote: remote, keys)
        }
    }

    func submitQuestion(paneId: String, promptId: String) {
        if mode == .relay {
            guard let data = try? JSONEncoder().encode(
                QuestionSubmitMessage(pane_id: paneId, prompt_id: promptId)
            ) else { return }
            task?.send(.string(String(data: data, encoding: .utf8)!)) { _ in }
            return
        }
        // Direct mode: move to "Done selecting" and Enter, else Tab+Enter to Submit.
        guard let agent = agents.first(where: { $0.id == paneId }) else { return }
        let remote = agent.host == "local" ? nil : agent.host
        let realId = realPaneId(paneId, remote: remote)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let raw = readPaneRecent(realId, remote: remote)
            guard let question = QuestionParser.detectQuestion(raw), question.isMultiSelect else { return }
            if let done = question.options.firstIndex(where: { $0.label.contains("Done selecting") }) {
                let steps = done - question.selectedIndex
                let dir = steps >= 0 ? "Down" : "Up"
                let keys = Array(repeating: dir, count: abs(steps)) + ["Enter"]
                _ = runHerdrKeys(paneId: realId, remote: remote, keys)
            } else if raw.contains("Submit") {
                _ = runHerdrKeys(paneId: realId, remote: remote, ["Tab", "Enter"])
            }
        }
    }

    func focusPane(_ paneId: String) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            if let agent = agents.first(where: { $0.id == paneId }), agent.host != "local" {
                let prefix = agent.host + ":"
                let remotePaneId = paneId.hasPrefix(prefix) ? String(paneId.dropFirst(prefix.count)) : paneId
                let output = runSSH(agent.host, "herdr", "pane", "get", remotePaneId)
                guard let location = parsePaneLocation(from: output) else { return }
                _ = runSSH(agent.host, "herdr", "workspace", "focus", location.workspaceId)
                _ = runSSH(agent.host, "herdr", "tab", "focus", location.tabId)
                return
            }

            let output = runHerdr("pane", "get", paneId)
            guard let location = parsePaneLocation(from: output) else { return }
            _ = runHerdr("workspace", "focus", location.workspaceId)
            _ = runHerdr("tab", "focus", location.tabId)
        }
    }

    func interruptPane(_ paneId: String) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            _ = runHerdr("pane", "send-keys", paneId, "Ctrl+c")
        }
    }

    /// Send key names to a pane in direct mode (local or SSH).
    @discardableResult
    private func runHerdrKeys(paneId: String, remote: String?, _ keys: [String]) -> Bool {
        guard !keys.isEmpty else { return true }
        if let remote {
            let output = runSSH(remote, "herdr", "pane", "send-keys", paneId, keys.joined(separator: " "))
            return !output.contains("\"error\"")
        }
        let (output, ok) = runHerdrChecked(["pane", "send-keys", paneId] + keys)
        return ok && !output.contains("\"error\"")
    }

    private func runHerdrRaw(_ args: [String]) -> String { runHerdrChecked(args).output }

    /// Cursor-navigation response, ported from respond_to_question
    /// (relay/herdr_relay.py:569-603). Runs off the main thread.
    private func directRespondToQuestion(agent: Agent, text: String) {
        let remote = agent.host == "local" ? nil : agent.host
        let paneId = realPaneId(agent.id, remote: remote)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let raw = readPaneRecent(paneId, remote: remote)
            guard let question = QuestionParser.detectQuestion(raw) else {
                // Fallback: type the text + Enter (permission / free-form).
                if remote == nil {
                    _ = runHerdrRaw(["pane", "send-text", paneId, text + "\n"])
                } else {
                    _ = runSSH(remote!, "herdr", "pane", "send-text", paneId, text + "\n")
                }
                return
            }
            let labels = question.options.map { $0.label }
            var targetIndex = labels.firstIndex { $0.caseInsensitiveCompare(text) == .orderedSame }
            let custom = targetIndex == nil
            if custom {
                targetIndex = labels.firstIndex { $0 == QuestionParser.questionOther }
            }
            guard let target = targetIndex else { return }
            let steps = target - question.selectedIndex
            let dir = steps >= 0 ? "Down" : "Up"
            let navKeys = Array(repeating: dir, count: abs(steps)) + ["Enter"]
            guard runHerdrKeys(paneId: paneId, remote: remote, navKeys) else { return }
            guard custom else { return }
            // Wait up to 1.5s for the custom-answer editor, then type text.
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline {
                let editor = readPaneRecent(paneId, remote: remote, lines: 40)
                if editor.contains("Enter your response:")
                    || (editor.contains("Custom answer:") && editor.lowercased().contains("submit")) {
                    if remote == nil {
                        _ = runHerdrRaw(["pane", "send-text", paneId, text])
                        _ = runHerdrKeys(paneId: paneId, remote: remote, ["Enter"])
                    } else {
                        _ = runSSH(remote!, "herdr", "pane", "send-text", paneId, text)
                        _ = runSSH(remote!, "herdr", "pane", "send-keys", paneId, "Enter")
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                DispatchQueue.main.async { if !self.isConnected { self.isConnected = true } }
                switch message {
                case .string(let text): self.handleWS(text)
                case .data(let data): self.handleWS(String(data: data, encoding: .utf8) ?? "")
                @unknown default: break
                }
                self.listen()
            case .failure:
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard !reconnecting, mode == .relay else { return }
        reconnecting = true
        reconnectAttempt += 1
        let delay = min(Double(1 << min(reconnectAttempt, 5)), 30.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isConnected else { return }
            self.reconnecting = false
            self.connectRelay(to: self.hostAddress)
        }
    }

    private func handleWS(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONDecoder().decode(AgentMessage.self, from: data) else { return }
        DispatchQueue.main.async { [self] in
            switch msg.type {
            case "agents":
                guard let list = msg.agents else { return }
                var seen = Set<String>()
                for a in list {
                    seen.insert(a.pane_id)
                    upsertAgent(a)
                }
                agents.removeAll { !seen.contains($0.id) }
            case "agent_update":
                if let update = msg.agentData { upsertAgent(update) }
            case "blocked":
                if let pid = msg.pane_id, let agent = agents.first(where: { $0.id == pid }) {
                    agent.prompt = msg.prompt
                    agent.promptId = msg.prompt_id
                    agent.options = msg.options
                    agent.multiOptions = msg.multi_options ?? []
                    agent.selectedOptions = msg.selected_options ?? []
                    agent.interaction = msg.interaction
                    agent.isMultiSelect = msg.multi ?? false
                    agent.status = .blocked
                    if msg.update != true {
                        sendNotification(agent: agent.name, project: agent.project)
                    }
                }
            default: break
            }
        }
    }

    private func upsertAgent(_ data: AgentMessage.AgentData) {
        if let existing = agents.first(where: { $0.id == data.pane_id }) {
            existing.name = data.agent
            existing.status = AgentStatus(rawValue: data.status) ?? .unknown
            existing.project = data.project
            existing.cwd = data.cwd
            existing.host = data.host ?? "local"
            return
        }
        agents.append(Agent(
            id: data.pane_id, name: data.agent,
            status: AgentStatus(rawValue: data.status) ?? .unknown,
            project: data.project, cwd: data.cwd, host: data.host ?? "local"
        ))
    }

    private func sendNotification(agent: String, project: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Agent Blocked"
        content.body = "\(agent) needs input in \(project)"
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
