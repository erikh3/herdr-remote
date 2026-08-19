import Foundation
import CryptoKit

struct QuestionOption: Equatable {
    let label: String
    let selected: Bool   // live cursor is on this row
    let multi: Bool      // checkbox-style marker
    let checked: Bool    // checkbox currently ticked
    var description: String? = nil  // omp option description (subtext)
}

struct ParsedQuestion {
    let text: String
    let options: [QuestionOption]
    let selectedIndex: Int
    let isMultiSelect: Bool
}

/// One option inside a multi-question preview sub-question.
struct MultiQuestionOption: Equatable {
    let label: String
    let multi: Bool      // checkbox-style (vs radio single-select)
    let checked: Bool    // preview shows a pre-checked box
    var description: String? = nil  // omp option description (subtext)
}

/// One sub-question parsed from omp's multi-question preview box. omp renders
/// a multi-question ask as a tabbed form; the preview box lists every tab
/// ([key] section) with its question text and options, which is everything the
/// notch needs to render all questions in a single card.
struct MultiSubQuestion: Equatable {
    let key: String              // omp's [key] identifier for the tab
    let text: String             // question prompt
    let isMultiSelect: Bool
    let options: [MultiQuestionOption]
}

enum QuestionParser {
    static let questionOther = "Other (type your own)"
    static let toolOptions = ["yes, single permission", "trust, always allow", "no (tab to edit)"]
    static let subagentOptions = ["approve all pending", "configure individually", "exit (cancel subagents)"]

    // Ports QUESTION_OPTION_RE (relay/herdr_relay.py:92-96).
    // cursor markers, then a checkbox/radio marker, then label.
    private static let cursorMarkers = Set("\u{f054}>\u{203a}\u{276f}\u{25b8}\u{2192}")
    private static let radioMarkers = Set("\u{f046}\u{f10c}\u{f192}\u{f096}\u{f14a}\u{25cb}\u{25c9}\u{2610}\u{2611}")
    private static let multiMarkers: Set<String> =
        ["\u{f046}", "\u{f096}", "\u{f14a}", "\u{2610}", "\u{2611}", "[ ]", "[x]", "[X]"]
    private static let checkedMarkers: Set<String> =
        ["\u{f046}", "\u{f14a}", "\u{2611}", "[x]", "[X]"]

    /// Strip box gutters and whitespace, matching Python's
    /// `line.strip().strip("\u2502|").strip()`.
    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
           .trimmingCharacters(in: CharacterSet(charactersIn: "\u{2502}|"))
           .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when a normalized line is an omp option-description line. In the
    /// preview box these are prefixed with "↳" (also tolerate ⤷/→ variants).
    private static func isDescriptionLine(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        return "\u{21b3}\u{2937}\u{2192}".contains(first)
    }

    /// Strip a leading description marker (preview uses "↳ ", widget uses plain
    /// indentation) and surrounding whitespace, returning the description text.
    private static func stripDescriptionMarker(_ line: String) -> String {
        var s = line
        if let first = s.first, "\u{21b3}\u{2937}\u{2192}".contains(first) {
            s.removeFirst()
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private struct OptionMatch { let cursor: Bool; let marker: String; let label: String }

    /// Port of QUESTION_OPTION_RE as an explicit scanner (Swift lacks named
    /// groups on the same regex engine; scanning is clearer and testable).
    private static func matchOption(_ line: String) -> OptionMatch? {
        let chars = Array(line)
        var i = 0
        var cursor = false
        if i < chars.count, cursorMarkers.contains(chars[i]) {
            cursor = true
            i += 1
        }
        while i < chars.count, chars[i] == " " { i += 1 }
        guard i < chars.count else { return nil }

        // bracket markers: ( ), (o), [ ], [x], [X]
        var marker = ""
        if chars[i] == "(" || chars[i] == "[" {
            let close: Character = chars[i] == "(" ? ")" : "]"
            guard i + 2 < chars.count, chars[i + 2] == close else { return nil }
            let inner = chars[i + 1]
            let allowed: Set<Character> = chars[i] == "(" ? [" ", "o"] : [" ", "x", "X"]
            guard allowed.contains(inner) else { return nil }
            marker = String(chars[i ... i + 2])
            i += 3
        } else if radioMarkers.contains(chars[i]) {
            marker = String(chars[i])
            i += 1
        } else {
            return nil
        }

        guard i < chars.count, chars[i] == " " else { return nil }
        while i < chars.count, chars[i] == " " { i += 1 }
        let label = String(chars[i...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        return OptionMatch(cursor: cursor, marker: marker, label: label)
    }

    // Port of detect_question (relay/herdr_relay.py:378-434).
    static func detectQuestion(_ text: String) -> ParsedQuestion? {
        let lines = text.components(separatedBy: "\n")
        var blocks: [(start: Int, options: [(match: OptionMatch, opt: QuestionOption)])] = []
        var current: [(match: OptionMatch, opt: QuestionOption)] = []
        var currentStart: Int? = nil

        for (index, raw) in lines.enumerated() {
            let line = normalize(raw)
            guard let m = matchOption(line) else {
                // A blank/separator line ends the current option block. A
                // non-blank, unmarked line inside a block is the preceding
                // option's description (omp renders each option's description on
                // its own indented line) — attach it to the last option.
                if line.isEmpty, !current.isEmpty {
                    blocks.append((currentStart!, current))
                    current = []
                    currentStart = nil
                } else if !line.isEmpty, !current.isEmpty,
                          current[current.count - 1].opt.description == nil {
                    let last = current[current.count - 1]
                    let desc = stripDescriptionMarker(line)
                    current[current.count - 1] = (
                        last.match,
                        QuestionOption(
                            label: last.opt.label, selected: last.opt.selected,
                            multi: last.opt.multi, checked: last.opt.checked,
                            description: desc))
                }
                continue
            }
            if currentStart == nil { currentStart = index }
            let opt = QuestionOption(
                label: m.label,
                selected: m.cursor,
                multi: multiMarkers.contains(m.marker),
                checked: checkedMarkers.contains(m.marker)
            )
            current.append((m, opt))
        }
        if !current.isEmpty { blocks.append((currentStart!, current)) }

        for block in blocks.reversed() {
            let opts = block.options.map { $0.opt }
            let hasOther = opts.contains { $0.label == questionOther }
            let hasDone = opts.contains { $0.label.contains("Done selecting") }
            guard hasOther || hasDone else { continue }

            var questionLines: [String] = []
            for raw in lines[..<block.start].reversed() {
                let line = normalize(raw)
                if line.isEmpty {
                    if !questionLines.isEmpty { break }
                    continue
                }
                // The tabbed-form tab bar ends with the "Submit" tab (e.g.
                // "langs    Submit"). Only treat a line as that chrome when
                // "Submit" is its final whitespace-delimited token, so a prose
                // question that merely mentions submit (e.g. "…press Submit:")
                // is still captured as the question text.
                let isSubmit = line.split(whereSeparator: { $0 == " " })
                    .last?.caseInsensitiveCompare("Submit") == .orderedSame
                let isAskChrome = line.range(
                    of: #"^[\W_]*ask[\W_]*$"#, options: [.regularExpression, .caseInsensitive]) != nil
                let hasAlnum = line.contains { $0.isLetter || $0.isNumber }
                if isSubmit || isAskChrome || !hasAlnum {
                    if !questionLines.isEmpty { break }
                    continue
                }
                questionLines.append(line)
            }
            let questionText = questionLines.reversed().joined(separator: " ")
            let selectedIndex = opts.firstIndex { $0.selected } ?? 0
            let isMulti = opts.contains { $0.multi } || hasDone
            return ParsedQuestion(
                text: questionText, options: opts,
                selectedIndex: selectedIndex, isMultiSelect: isMulti)
        }
        return nil
    }

    // Port of detect_approval_options (relay/herdr_relay.py:437-443).
    static func detectApprovalOptions(_ text: String) -> [String] {
        let lower = text.lowercased()
        if lower.contains("yes, single permission") { return toolOptions }
        if lower.contains("approve all pending") { return subagentOptions }
        return []
    }

    // Port of detect_options (relay/herdr_relay.py:446-457).
    static func detectOptions(_ text: String) -> [String] {
        let approval = detectApprovalOptions(text)
        if !approval.isEmpty { return approval }
        guard let q = detectQuestion(text) else { return [] }
        return q.options
            .map { $0.label }
            .filter { $0 != questionOther && !$0.contains("Done selecting") }
    }

    /// Total questions in a multi-question omp ask, parsed from the preview
    /// header line "Ask N questions". Returns nil for single-question asks
    /// (whose header is just "Ask") or when no such header is present.
    static func questionCount(_ text: String) -> Int? {
        // Scan bottom-up so the most recent widget's header wins over any stale
        // "Ask N questions" lines left in scrollback.
        for raw in text.components(separatedBy: "\n").reversed() {
            guard let askRange = raw.range(of: "Ask ") else { continue }
            let after = raw[askRange.upperBound...]
            let digits = after.prefix { $0.isNumber }
            guard !digits.isEmpty, let n = Int(digits) else { continue }
            let rest = after[after.index(after.startIndex, offsetBy: digits.count)...]
            if rest.trimmingCharacters(in: .whitespaces).hasPrefix("question") {
                return n
            }
        }
        return nil
    }

    /// Parse omp's multi-question preview box into its sub-questions. omp
    /// renders a multi-question ask as a tabbed form and mirrors every tab in a
    /// preview box:
    ///
    ///     ╭───  Ask 2 questions ───╮
    ///     ├─── [env] · options:2 ───┤
    ///     │  Environment?          │
    ///     │   ◉ Staging            │
    ///     │   ○ Production         │
    ///     ├─── [caps] · multi · options:3 ───┤
    ///     │  Capabilities?         │
    ///     │   ☐ Cache              │
    ///     ╰───╯
    ///
    /// Returns the sub-questions of the most recent preview box, or an empty
    /// array when the buffer has no multi-question preview.
    static func parseMultiQuestionPreview(_ text: String) -> [MultiSubQuestion] {
        let lines = text.components(separatedBy: "\n")
        // Find the most recent "Ask N questions" preview header.
        var headerIndex: Int? = nil
        for index in lines.indices.reversed() {
            guard let askRange = lines[index].range(of: "Ask ") else { continue }
            let after = lines[index][askRange.upperBound...]
            let digits = after.prefix { $0.isNumber }
            guard !digits.isEmpty else { continue }
            let rest = after[after.index(after.startIndex, offsetBy: digits.count)...]
            if rest.trimmingCharacters(in: .whitespaces).hasPrefix("question") {
                headerIndex = index
                break
            }
        }
        guard let start = headerIndex else { return [] }

        // Walk downward, collecting [key] sections until the box closes (a
        // bottom border with no bracketed key) or a new box opens.
        var result: [MultiSubQuestion] = []
        var key: String? = nil
        var multiHeader = false
        var questionLines: [String] = []
        var options: [MultiQuestionOption] = []

        func flush() {
            guard let k = key else { return }
            let isMulti = multiHeader || options.contains { $0.multi }
            result.append(MultiSubQuestion(
                key: k,
                text: questionLines.joined(separator: " "),
                isMultiSelect: isMulti,
                options: options))
        }

        for raw in lines[(start + 1)...] {
            let line = normalize(raw)
            if let sectionKey = sectionHeaderKey(line) {
                flush()
                key = sectionKey
                multiHeader = line.contains("multi")
                questionLines = []
                options = []
                continue
            }
            // The box-closing bottom border ends the preview; stop before the
            // interactive Ask widget (or any following box) leaks in.
            if isBoxCloseBorder(line) { break }
            if key == nil { continue }
            if line.isEmpty { continue }
            if let m = matchOption(line) {
                options.append(MultiQuestionOption(
                    label: m.label,
                    multi: multiMarkers.contains(m.marker),
                    checked: checkedMarkers.contains(m.marker)))
            } else if isDescriptionLine(line), !options.isEmpty,
                      options[options.count - 1].description == nil {
                // "↳ text" under an option is that option's description.
                let last = options[options.count - 1]
                options[options.count - 1] = MultiQuestionOption(
                    label: last.label, multi: last.multi, checked: last.checked,
                    description: stripDescriptionMarker(line))
            } else if line.contains(where: { $0.isLetter || $0.isNumber }) {
                questionLines.append(line)
            }
        }
        flush()
        return result
    }

    /// Extract the `[key]` identifier from a preview section-header line such as
    /// `─── [env] · options:2 ───`. Returns nil for non-header lines.
    private static func sectionHeaderKey(_ line: String) -> String? {
        guard let open = line.firstIndex(of: "["),
              let close = line.firstIndex(of: "]"),
              open < close else { return nil }
        // A header is mostly box-drawing dashes around a bracketed key; require
        // the line to start with box-drawing/dash chrome to avoid matching a
        // question that merely contains brackets.
        let prefix = line[line.startIndex..<open]
        let chromeOnly = prefix.allSatisfy { "─-┄┈├┤┏┓┗┛╭╮╰╯│ ".contains($0) }
        guard chromeOnly else { return nil }
        let key = line[line.index(after: open)..<close]
            .trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    /// True for a normalized bottom-border line (begins with a bottom box
    /// corner and carries no bracketed key or alphanumerics).
    private static func isBoxCloseBorder(_ line: String) -> Bool {
        guard let first = line.first, "╰╯└┘".contains(first) else { return false }
        return !line.contains("[") && !line.contains(where: { $0.isLetter || $0.isNumber })
    }

    /// True when the pane shows omp's multi-question Review/Submit confirmation
    /// screen (the final step after all questions are answered). It has no
    /// selectable option markers, so detectQuestion returns nil for it; callers
    /// use this to auto-submit instead of surfacing it as a prompt.
    static func isReviewScreen(_ text: String) -> Bool {
        let hasReview = text.contains("Review answers")
        // Footer distinguishes the review screen ("Enter submit · ↑/↓ scroll")
        // from a question ("Enter select"/"Space toggle").
        let hasSubmitFooter = text.contains("Enter submit") && text.contains("scroll")
        return hasReview && hasSubmitFooter
    }

    // Manual hex: String(format:"%02x") emits zeros under this toolchain's optimizer.
    private static let hexDigits = Array("0123456789abcdef")
    private static func hex(_ bytes: [UInt8]) -> String {
        var s = ""
        s.reserveCapacity(bytes.count * 2)
        for b in bytes {
            s.append(hexDigits[Int(b >> 4)])
            s.append(hexDigits[Int(b & 0x0f)])
        }
        return s
    }

    private static func sha256Prefix20(_ input: String) -> String {
        let digest = Array(SHA256.hash(data: Data(input.utf8)))
        return String(hex(digest).prefix(20))
    }

    // Port of question_prompt_id (relay/herdr_relay.py:465-483).
    // Signature JSON must be byte-identical to Python's json.dumps(sort_keys=True):
    // keys sorted, ", "/": " separators, non-ASCII escaped as \uXXXX.
    static func promptId(paneId: String, content: String) -> String {
        guard let q = detectQuestion(content) else {
            let normalized = content.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
                .joined(separator: " ")
            return sha256Prefix20("\(paneId)\n\(normalized)")
        }
        let labels = q.options
            .map { $0.label }
            .filter { $0 != questionOther && !$0.contains("Done selecting") }
        // Build the signature with sorted keys: labels, multi, pane_id, question.
        let signature = "{"
            + "\"labels\": [" + labels.map { jsonString($0) }.joined(separator: ", ") + "], "
            + "\"multi\": \(q.isMultiSelect ? "true" : "false"), "
            + "\"pane_id\": \(jsonString(paneId)), "
            + "\"question\": \(jsonString(q.text))"
            + "}"
        return sha256Prefix20(signature)
    }

    // Matches Python json.dumps default string encoding (ensure_ascii=True).
    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value > 0x7e {
                    out += format0x4(scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    // \uXXXX escape (handles BMP; astral chars escaped as surrogate pair to match Python).
    private static func format0x4(_ value: UInt32) -> String {
        func u16(_ v: UInt32) -> String {
            let d = hexDigits
            return "\\u"
                + String(d[Int((v >> 12) & 0xf)])
                + String(d[Int((v >> 8) & 0xf)])
                + String(d[Int((v >> 4) & 0xf)])
                + String(d[Int(v & 0xf)])
        }
        if value > 0xffff {
            let v = value - 0x10000
            let high = 0xd800 + (v >> 10)
            let low = 0xdc00 + (v & 0x3ff)
            return u16(high) + u16(low)
        }
        return u16(value)
    }
}
