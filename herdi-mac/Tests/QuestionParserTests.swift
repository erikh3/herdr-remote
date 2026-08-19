import Foundation

var failures = 0
func expect(_ cond: Bool, _ msg: String) {
    if cond { print("ok: \(msg)") }
    else { FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8)); failures += 1 }
}

// Fixtures ported verbatim from tests/test_herdr_relay.py:290-319
let ASK_SCREEN = """
╰─ Ask ─╮
│ Which color? │
│ \u{276f} \u{25c9} Red │
│   \u{25cb} Blue │
│   \u{25cb} Green │
│   \u{25cb} Other (type your own) │
│ Enter select · ↑/↓ move · Esc cancel │
╰───────╯
"""

let MULTI_SCREEN = """
╰─ Ask ─╮
│ Which capabilities? │
│ \u{276f} \u{2610} Color output │
│   \u{2610} Nerd Font │
│   \u{2610} Mobile layout │
│   \u{25cb} Other (type your own) │
╰───────╯
"""

let MULTI_SELECTED_SCREEN = """
╰─ Ask ─╮
│ capabilities    Submit │
│ Which capabilities? │
│   \u{2611} Color output │
│ \u{276f} \u{2610} Nerd Font │
│   \u{2610} Mobile layout │
│   \u{25cb} Other (type your own) │
╰───────╯
"""

// --- single-select detection ---
let q = QuestionParser.detectQuestion(ASK_SCREEN)
expect(q != nil, "ASK_SCREEN detected as question")
expect(q?.options.map { $0.label } == ["Red", "Blue", "Green", "Other (type your own)"],
       "ASK_SCREEN option labels")
expect(q?.isMultiSelect == false, "ASK_SCREEN is single-select")
expect(q?.selectedIndex == 0, "ASK_SCREEN cursor on first option")
expect(QuestionParser.detectOptions(ASK_SCREEN) == ["Red", "Blue", "Green"],
       "ASK_SCREEN detectOptions drops Other")

// --- multi-select detection ---
let m = QuestionParser.detectQuestion(MULTI_SCREEN)
expect(m?.isMultiSelect == true, "MULTI_SCREEN is multi-select")
expect(m?.options.map { $0.label } == ["Color output", "Nerd Font", "Mobile layout", "Other (type your own)"],
       "MULTI_SCREEN option labels")
expect(QuestionParser.detectOptions(MULTI_SCREEN) == ["Color output", "Nerd Font", "Mobile layout"],
       "MULTI_SCREEN detectOptions drops Other")

let sel = QuestionParser.detectQuestion(MULTI_SELECTED_SCREEN)
expect(sel?.options.first { $0.label == "Color output" }?.checked == true,
       "MULTI_SELECTED shows Color output checked")
expect(sel?.selectedIndex == 1, "MULTI_SELECTED cursor on Nerd Font")

// --- prompt identity ---
expect(QuestionParser.promptId(paneId: "p1", content: MULTI_SCREEN)
     == QuestionParser.promptId(paneId: "p1", content: MULTI_SELECTED_SCREEN),
       "promptId ignores multi-selection state")
let colorQ = ASK_SCREEN
let deleteQ = ASK_SCREEN.replacingOccurrences(of: "Which color?", with: "Delete all data?")
expect(QuestionParser.promptId(paneId: "p1", content: colorQ)
     != QuestionParser.promptId(paneId: "p1", content: deleteQ),
       "promptId distinguishes question text")
expect(!QuestionParser.promptId(paneId: "p1", content: "random blocked prompt").isEmpty,
       "promptId non-question fallback non-empty")

if failures > 0 { FileHandle.standardError.write(Data("\(failures) failure(s)\n".utf8)); exit(1) }
print("ALL PASS")
