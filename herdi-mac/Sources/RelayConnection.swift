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
    /// Panes with a response being delivered to the omp TUI. While a pane is
    /// in-flight the poller must not re-read/re-populate it and the notch must
    /// not re-pop its card — otherwise the ~1.5s scripted key sequence races
    /// with the 1-2s pollers, piling repeated input into omp's answer editor.
    /// Maps pane id → guard expiry (safety net if delivery never lands).
    private var respondingPanes: [String: Date] = [:]

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
                            } else if existing.status == .blocked && a.status != .blocked {
                                // Left blocked (answered): drop stale prompt and
                                // clear the in-flight guard.
                                respondingPanes[existing.id] = nil
                                existing.prompt = nil
                                existing.promptId = nil
                                existing.options = nil
                                existing.multiOptions = []
                                existing.selectedOptions = []
                                existing.isMultiSelect = false
                                existing.isQuestion = false
                                existing.questionTotal = nil
                                existing.form = nil
                            }
                            existing.status = a.status
                        } else if a.status == .blocked, !isResponding(existing.id) {
                            // Still blocked and not mid-response: the prompt may
                            // have advanced (e.g. next question in a multi-question
                            // ask). Re-read; readPaneForBlocked updates promptId and
                            // only the observer re-pops when the card is collapsed.
                            readPaneForBlocked(existing, remote: a.host == "local" ? nil : a.host)
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

            // Multi-question Review/Submit screen: the cursor is already on
            // "Submit"; press Enter to submit all collected answers rather than
            // surfacing the review as another prompt. Keep the card hidden.
            if QuestionParser.isReviewScreen(raw) {
                _ = runHerdrKeys(paneId: paneId, remote: remote, ["Enter"])
                DispatchQueue.main.async {
                    self.beginResponding(agent.id, seconds: 3)
                    agent.prompt = nil
                    agent.promptId = nil
                    agent.options = nil
                    agent.isQuestion = false
                    agent.questionTotal = nil
                    agent.form = nil
                }
                return
            }

            let question = QuestionParser.detectQuestion(raw)
            let promptId = QuestionParser.promptId(paneId: agent.id, content: raw)

            // Multi-question ask: omp renders every question as a tab and mirrors
            // them in a preview box. Parse all of them and present one card that
            // collects every answer, then drives the tabbed form on submit.
            let subs = QuestionParser.parseMultiQuestionPreview(raw)
            // Only treat as a live form when the interactive widget currently
            // shows one of the parsed sub-questions; otherwise the preview is
            // stale scrollback from an earlier multi-question ask.
            let previewIsLive = subs.count > 1
                && (question.map { q in subs.contains { $0.text == q.text } } ?? false)
            if previewIsLive {
                let total = QuestionParser.questionCount(raw)
                // Stable id for the whole form so tab auto-advance (which changes
                // the active question) doesn't re-pop the card or drop selections.
                let formId = subs.map { "\($0.key)|\($0.text)|\($0.options.map { $0.label }.joined(separator: ","))" }
                    .joined(separator: "\u{1e}")
                DispatchQueue.main.async {
                    let changed = agent.promptId != formId
                    agent.isQuestion = true
                    agent.promptId = formId
                    agent.questionTotal = total
                    agent.prompt = nil
                    agent.options = nil
                    agent.multiOptions = []
                    agent.selectedOptions = []
                    if changed {
                        agent.form = MultiQuestionForm(questions: subs.map { sub in
                            let descs = Dictionary(
                                sub.options.compactMap { opt in
                                    opt.description.map { (opt.label, $0) }
                                },
                                uniquingKeysWith: { first, _ in first })
                            return FormQuestion(
                                id: sub.key,
                                text: sub.text,
                                isMultiSelect: sub.isMultiSelect,
                                options: sub.options
                                    .map { $0.label }
                                    .filter { $0 != QuestionParser.questionOther
                                              && !$0.contains("Done selecting") },
                                descriptions: descs)
                        })
                        self.sendNotification(agent: agent.name, project: agent.project)
                    }
                }
                return
            }

            if let question {
                let visible = question.options
                    .map { $0.label }
                    .filter { $0 != QuestionParser.questionOther && !$0.contains("Done selecting") }
                let checked = question.options
                    .filter { $0.multi && $0.checked && $0.label != QuestionParser.questionOther
                              && !$0.label.contains("Done selecting") }
                    .map { $0.label }
                let descriptions = Dictionary(
                    question.options.compactMap { opt in
                        opt.description.map { (opt.label, $0) }
                    },
                    uniquingKeysWith: { first, _ in first })
                let displayPrompt = question.text.isEmpty ? "(question)" : question.text
                let total = QuestionParser.questionCount(raw)

                DispatchQueue.main.async {
                    let changed = agent.promptId != promptId
                    agent.prompt = displayPrompt
                    agent.promptId = promptId
                    agent.isQuestion = true
                    agent.questionTotal = total
                    agent.optionDescriptions = descriptions
                    agent.form = nil
                    if question.isMultiSelect {
                        agent.options = nil
                        agent.multiOptions = visible
                        agent.selectedOptions = checked
                    } else {
                        agent.options = visible
                        agent.multiOptions = []
                        agent.selectedOptions = []
                    }
                    if changed {
                        agent.customDraft = ""
                        self.sendNotification(agent: agent.name, project: agent.project)
                    }
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
                let changed = agent.promptId != promptId
                agent.prompt = String(tail.prefix(500))
                agent.promptId = promptId
                agent.isMultiSelect = false
                agent.isQuestion = false
                agent.questionTotal = nil
                agent.form = nil
                agent.optionDescriptions = [:]
                agent.multiOptions = []
                agent.selectedOptions = []
                agent.options = approval.isEmpty
                    ? QuestionParser.toolOptions
                    : approval
                if changed {
                    agent.customDraft = ""
                    self.sendNotification(agent: agent.name, project: agent.project)
                }
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

    /// True while a response is being delivered to this pane (guard unexpired).
    func isResponding(_ paneId: String) -> Bool {
        guard let expiry = respondingPanes[paneId] else { return false }
        if Date() > expiry {
            respondingPanes[paneId] = nil
            return false
        }
        return true
    }

    /// Mark a pane in-flight for the given window (main-thread only).
    private func beginResponding(_ paneId: String, seconds: TimeInterval) {
        respondingPanes[paneId] = Date().addingTimeInterval(seconds)
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
            // A detected omp question (single or multi-select) navigates by
            // cursor: single-select selects the matching option, multi-select
            // delivers custom text via the "Other" option which submits the
            // already-toggled checkboxes together.
            if agent.isQuestion, agent.promptId != nil {
                beginResponding(paneId, seconds: 5)
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
        // Direct mode: navigate cursor to the option, press Space to toggle it
        // (omp multi-select: "Space toggle · Enter submit").
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
            let keys = Array(repeating: dir, count: abs(steps)) + ["Space"]
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
        // Direct mode: omp multi-select submits on Enter
        // ("Space toggle · Enter submit"). Toggles were already applied by
        // toggleQuestionOption; Enter confirms the current selection set.
        guard let agent = agents.first(where: { $0.id == paneId }) else { return }
        beginResponding(paneId, seconds: 3)
        let remote = agent.host == "local" ? nil : agent.host
        let realId = realPaneId(paneId, remote: remote)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let raw = readPaneRecent(realId, remote: remote)
            guard let question = QuestionParser.detectQuestion(raw), question.isMultiSelect else { return }
            _ = runHerdrKeys(paneId: realId, remote: remote, ["Enter"])
        }
    }

    /// Fill and submit omp's multi-question tabbed form in one pass. Direct mode
    /// only (the notch drives omp locally). Re-reads the pane before each tab so
    /// it syncs with omp's real cursor/tab state instead of counting keys blind.
    func submitForm(paneId: String, form: MultiQuestionForm) {
        guard mode == .direct,
              let agent = agents.first(where: { $0.id == paneId }) else { return }
        // Long window: driving every tab (with editor waits) takes a few seconds;
        // keep the poll's still-blocked re-read from racing us until we finish.
        beginResponding(paneId, seconds: 20)
        let remote = agent.host == "local" ? nil : agent.host
        let realId = realPaneId(paneId, remote: remote)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            driveForm(realId: realId, remote: remote, form: form)
        }
    }

    private func driveForm(realId: String, remote: String?, form: MultiQuestionForm) {
        // Bound iterations: one per question, plus slack for transitional frames
        // and the final review screen.
        let maxSteps = form.questions.count * 2 + 4
        // Guard against re-filling a tab that failed to advance (which caused a
        // retype loop); once a question's answer is applied, only Tab past it.
        var answered: Set<String> = []
        for _ in 0..<maxSteps {
            let raw = readPaneRecent(realId, remote: remote)
            if QuestionParser.isReviewScreen(raw) {
                _ = runHerdrKeys(paneId: realId, remote: remote, ["Enter"])
                return
            }
            guard let live = QuestionParser.detectQuestion(raw) else {
                Thread.sleep(forTimeInterval: 0.3)
                continue
            }
            guard let fq = form.questions.first(where: { $0.text == live.text }) else {
                // Unknown tab (shouldn't happen): advance to avoid stalling.
                _ = runHerdrKeys(paneId: realId, remote: remote, ["Tab"])
                continue
            }
            if answered.contains(fq.id) {
                // Already filled but still showing: advance past it with Tab.
                _ = runHerdrKeys(paneId: realId, remote: remote, ["Tab"])
                continue
            }
            applyAnswer(realId: realId, remote: remote, live: live, fq: fq)
            answered.insert(fq.id)
        }
    }

    /// Answer the currently-shown tab, then advance to the next tab. Navigation
    /// clamps the cursor to the top first, so option indices are absolute
    /// Down-steps. Advance keys differ by kind (Enter for single-select, Tab for
    /// multi-select) to avoid re-opening omp's custom-text editor.
    private func applyAnswer(realId: String, remote: String?, live: ParsedQuestion, fq: FormQuestion) {
        let optCount = live.options.count
        let custom = fq.customText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Clamp cursor to the first option (omp clamps at the top row).
        _ = runHerdrKeys(paneId: realId, remote: remote, Array(repeating: "Up", count: max(optCount, 1)))

        if live.isMultiSelect {
            // Multi-select records checkboxes AND custom "Other" text together,
            // so apply both. First walk the options and toggle the checkboxes.
            for i in 0..<optCount {
                let opt = live.options[i]
                let isOther = opt.label == QuestionParser.questionOther
                    || opt.label.contains("Done selecting")
                if !isOther, fq.selected.contains(opt.label) != opt.checked {
                    _ = runHerdrKeys(paneId: realId, remote: remote, ["Space"])
                }
                if i < optCount - 1 {
                    _ = runHerdrKeys(paneId: realId, remote: remote, ["Down"])
                }
            }
            // After the walk the cursor sits on the last option ("Other").
            if !custom.isEmpty {
                typeCustomText(realId: realId, remote: remote, custom)
            }
            // Advance with Tab, not Enter: the cursor is on "Other", where Enter
            // would (re-)open the editor. Tab advances from any cursor position
            // and preserves both the toggles and the committed custom text.
            _ = runHerdrKeys(paneId: realId, remote: remote, ["Tab"])
            return
        }

        // Single-select: custom text and options are mutually exclusive.
        if !custom.isEmpty {
            let otherIndex = optCount - 1
            if otherIndex > 0 {
                _ = runHerdrKeys(paneId: realId, remote: remote, Array(repeating: "Down", count: otherIndex))
            }
            // Committing the text on a single-select tab also advances.
            _ = typeCustomText(realId: realId, remote: remote, custom)
            return
        }

        // Land on the chosen option; Enter selects and advances.
        guard let target = fq.selected.first,
              let idx = live.options.firstIndex(where: { $0.label == target }) else {
            _ = runHerdrKeys(paneId: realId, remote: remote, ["Enter"])
            return
        }
        if idx > 0 {
            _ = runHerdrKeys(paneId: realId, remote: remote, Array(repeating: "Down", count: idx))
        }
        _ = runHerdrKeys(paneId: realId, remote: remote, ["Enter"])
    }

    /// Open omp's "Other" custom-text editor (cursor must already be on the
    /// "Other" row), type the text, and commit it with Enter. Returns true once
    /// the editor was found and the text submitted.
    @discardableResult
    private func typeCustomText(realId: String, remote: String?, _ text: String) -> Bool {
        _ = runHerdrKeys(paneId: realId, remote: remote, ["Enter"]) // open editor
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            let editor = readPaneRecent(realId, remote: remote, lines: 40)
            if editor.contains("Enter your response:")
                || (editor.contains("Custom answer:") && editor.lowercased().contains("submit")) {
                if remote == nil {
                    _ = runHerdrRaw(["pane", "send-text", realId, text])
                } else {
                    _ = runSSH(remote!, "herdr", "pane", "send-text", realId, text)
                }
                _ = runHerdrKeys(paneId: realId, remote: remote, ["Enter"]) // commit
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
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
            let matchIndex = labels.firstIndex { $0.caseInsensitiveCompare(text) == .orderedSame }
            // Single-select with an exact option match: navigate + Enter.
            // (Multi-select responses always arrive as custom text via the notch,
            // so they fall through to the "Other" flow below, which submits the
            // already-toggled boxes together with the typed answer.)
            if !question.isMultiSelect, let target = matchIndex {
                let steps = target - question.selectedIndex
                let dir = steps >= 0 ? "Down" : "Up"
                let navKeys = Array(repeating: dir, count: abs(steps)) + ["Enter"]
                _ = runHerdrKeys(paneId: paneId, remote: remote, navKeys)
                return
            }

            // Custom answer: "Other (type your own)" is always the LAST option.
            // Navigate down enough to land on it deterministically (omp clamps
            // the cursor at the last row), avoiding a miscount that would fire
            // Enter on a regular option and submit early.
            let downCount = max(labels.count, 1)
            guard runHerdrKeys(paneId: paneId, remote: remote,
                               Array(repeating: "Down", count: downCount)) else { return }
            // Enter opens the custom-answer editor.
            guard runHerdrKeys(paneId: paneId, remote: remote, ["Enter"]) else { return }
            // Wait up to 1.5s for the editor, then type text.
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline {
                let editor = readPaneRecent(paneId, remote: remote, lines: 40)
                if editor.contains("Enter your response:")
                    || (editor.contains("Custom answer:") && editor.lowercased().contains("submit")) {
                    // Type the custom text into the editor.
                    if remote == nil {
                        _ = runHerdrRaw(["pane", "send-text", paneId, text])
                    } else {
                        _ = runSSH(remote!, "herdr", "pane", "send-text", paneId, text)
                    }
                    // The editor commits the typed answer on Enter
                    // ("enter or ctrl+q submit"; Esc would CANCEL and discard it).
                    _ = runHerdrKeys(paneId: paneId, remote: remote, ["Enter"])
                    guard question.isMultiSelect else { return }
                    // Multi-select: the first Enter only confirms the custom text
                    // into "Other" and returns to the dialog with the cursor still
                    // on "Other" (where Enter would RE-OPEN the editor). Move Up
                    // onto a regular option, then Enter submits the whole dialog
                    // (checked boxes + the custom answer). Wait for the dialog
                    // (not the editor) before driving it.
                    let submitDeadline = Date().addingTimeInterval(1.5)
                    while Date() < submitDeadline {
                        let dialog = readPaneRecent(paneId, remote: remote, lines: 40)
                        let inEditor = dialog.contains("Enter your response:")
                            || (dialog.contains("Custom answer:") && dialog.lowercased().contains("submit"))
                        if !inEditor, dialog.contains("Space toggle") || dialog.contains("Enter submit") {
                            _ = runHerdrKeys(paneId: paneId, remote: remote, ["Up", "Enter"])
                            return
                        }
                        Thread.sleep(forTimeInterval: 0.05)
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
                    agent.isQuestion = msg.interaction == "omp_question"
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
