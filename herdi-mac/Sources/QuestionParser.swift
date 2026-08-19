import Foundation
import CryptoKit

struct QuestionOption: Equatable {
    let label: String
    let selected: Bool   // live cursor is on this row
    let multi: Bool      // checkbox-style marker
    let checked: Bool    // checkbox currently ticked
}

struct ParsedQuestion {
    let text: String
    let options: [QuestionOption]
    let selectedIndex: Int
    let isMultiSelect: Bool
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
                // non-blank, unmarked line inside a block is a description
                // continuation (omp renders each option's description on its
                // own indented line) — keep the block open and skip it.
                if line.isEmpty, !current.isEmpty {
                    blocks.append((currentStart!, current))
                    current = []
                    currentStart = nil
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
                let isSubmit = line.lowercased().contains("submit")
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
        for raw in text.components(separatedBy: "\n") {
            // Match "... Ask <N> questions ..." anywhere on the line.
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
