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

// Options carrying descriptions: omp renders each description on its own
// unmarked, indented line beneath the option label (mirrors real widget
// captured in fixtures/live_described.txt).
let DESC_SCREEN = """
╭─ Ask ─╮
│ Pick one. │
├───────────┤
│ \u{276f} \u{25c9} Alpha │
│      first choice │
│   \u{25cb} Beta │
│      second choice │
│   \u{25cb} Other (type your own) │
├───────────┤
│ Enter select · ↑/↓ move · Esc cancel │
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

// --- Finding 1: golden-hash parity with Python relay ---
expect(QuestionParser.promptId(paneId: "p1", content: ASK_SCREEN) == "8ea5fa454ba901c75027",
       "promptId matches Python golden hash for ASK_SCREEN")
expect(QuestionParser.promptId(paneId: "p1", content: "random blocked prompt") == "fbd2cd6c2ceef9f14daa",
       "promptId matches Python golden hash for non-question fallback")

// --- multi-question count ---
expect(QuestionParser.questionCount("╭─── Ask 3 questions ───────╮\n│ Env? │") == 3,
       "questionCount parses 'Ask 3 questions'")
expect(QuestionParser.questionCount("╭─ Ask ─╮\n│ Which color? │") == nil,
       "questionCount nil for single-question ask")
expect(QuestionParser.questionCount("no ask header here") == nil,
       "questionCount nil when absent")
expect(QuestionParser.questionCount("╭── Ask 12 questions ──╮") == 12,
       "questionCount parses multi-digit count")

// --- Finding 2: CRLF regression ---
let ASK_CRLF = ASK_SCREEN.replacingOccurrences(of: "\n", with: "\r\n")
expect(QuestionParser.detectQuestion(ASK_CRLF)?.options.map { $0.label } == ["Red", "Blue", "Green", "Other (type your own)"],
       "CRLF input yields clean labels (no trailing CR)")
expect(QuestionParser.promptId(paneId: "p1", content: ASK_CRLF) == "8ea5fa454ba901c75027",
       "CRLF input yields same promptId as LF")

// --- Finding 3: approval-option path ---
expect(QuestionParser.detectApprovalOptions("... yes, single permission ...") == ["yes, single permission", "trust, always allow", "no (tab to edit)"],
       "detectApprovalOptions recognizes tool permission")
expect(QuestionParser.detectApprovalOptions("... approve all pending ...") == ["approve all pending", "configure individually", "exit (cancel subagents)"],
       "detectApprovalOptions recognizes subagent approval")
expect(QuestionParser.detectApprovalOptions("nothing here") == [],
       "detectApprovalOptions returns empty when no trigger")
expect(QuestionParser.detectOptions("please respond: yes, single permission") == ["yes, single permission", "trust, always allow", "no (tab to edit)"],
       "detectOptions short-circuits to approval options")

// --- live fixtures captured from real omp panes (skip gracefully if absent) ---
func loadFixture(_ name: String) -> String? {
    try? String(contentsOfFile: "herdi-mac/Tests/fixtures/\(name)", encoding: .utf8)
}
if let single = loadFixture("live_single.txt") {
    let lq = QuestionParser.detectQuestion(single)
    expect(lq != nil, "live_single parsed as question")
    expect(lq?.text == "Which color?", "live_single question text")
    expect(lq?.options.map { $0.label } == ["Red", "Blue", "Green", "Other (type your own)"],
           "live_single option labels")
    expect(lq?.isMultiSelect == false, "live_single is single-select")
    expect(QuestionParser.detectOptions(single) == ["Red", "Blue", "Green"],
           "live_single detectOptions drops Other")
} else {
    print("skip: live_single.txt not captured")
}
if let multi = loadFixture("live_multi.txt") {
    let lq = QuestionParser.detectQuestion(multi)
    expect(lq != nil, "live_multi parsed as question")
    expect(lq?.text == "Which capabilities?", "live_multi question text")
    expect(lq?.isMultiSelect == true, "live_multi is multi-select")
    expect(QuestionParser.detectOptions(multi) == ["Color output", "Nerd Font", "Mobile layout"],
           "live_multi detectOptions drops Other")
} else {
    print("skip: live_multi.txt not captured")
}

// --- options with descriptions (synthetic) ---
let dq = QuestionParser.detectQuestion(DESC_SCREEN)
expect(dq != nil, "DESC_SCREEN detected as question")
expect(dq?.text == "Pick one.", "DESC_SCREEN question text")
expect(dq?.options.map { $0.label } == ["Alpha", "Beta", "Other (type your own)"],
       "DESC_SCREEN option labels ignore description lines")
expect(dq?.isMultiSelect == false, "DESC_SCREEN is single-select")
expect(dq?.selectedIndex == 0, "DESC_SCREEN cursor on first option")
expect(QuestionParser.detectOptions(DESC_SCREEN) == ["Alpha", "Beta"],
       "DESC_SCREEN detectOptions drops Other + descriptions")

// --- options with descriptions (real captured widget) ---
if let described = loadFixture("live_described.txt") {
    let lq = QuestionParser.detectQuestion(described)
    expect(lq != nil, "live_described parsed as question")
    expect(lq?.text == "Pick one.", "live_described question text")
    expect(lq?.options.map { $0.label } == ["Alpha", "Beta", "Other (type your own)"],
           "live_described option labels")
    expect(QuestionParser.detectOptions(described) == ["Alpha", "Beta"],
           "live_described detectOptions drops Other")
} else {
    print("skip: live_described.txt not captured")
}

if failures > 0 { FileHandle.standardError.write(Data("\(failures) failure(s)\n".utf8)); exit(1) }
print("ALL PASS")
