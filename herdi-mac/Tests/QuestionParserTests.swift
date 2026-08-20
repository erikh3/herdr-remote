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

// Multi-question preview with per-option "↳" descriptions.
let DESC_PREVIEW = """
╭─── Ask 2 questions ───╮
├─── [db] · options:2 ───┤
│  Pick DB │
│   \u{25cb} Postgres │
│    \u{21b3} relational store │
│   \u{25cb} SQLite │
│    \u{21b3} embedded file │
├─── [caps] · multi · options:2 ───┤
│  Capabilities? │
│   \u{2610} Cache │
│    \u{21b3} in-memory layer │
│   \u{2610} Tracing │
│    \u{21b3} request spans │
╰───╯
"""

// Tabbed multi-select whose question text ends with the word "Submit" — the
// tab-bar "Submit" tab must be skipped without dropping the real question line.
let SUBMIT_WORD_SCREEN = """
╭─ Ask ─╮
│  langs    Submit │
│ Check these, then press Submit: │
├───────────┤
│ \u{f054} \u{f096} Kotlin │
│   \u{f096} Swift │
│   \u{f096} Other (type your own) │
├───────────┤
│ Space toggle · Enter submit · Esc cancel │
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

// --- review/submit screen detection ---
let REVIEW_SCREEN = """
╭─ Ask ─╮
│ env    feat    notify    Submit │
│ Review answers │
├───────────────┤
│ 1. env: Staging │
│ 2. feat: Cache, Metrics │
│ 3. notify: Yes │
│  Submit │
├───────────────┤
│ Enter submit · ↑/↓ scroll · Esc cancel │
╰───────╯
"""
expect(QuestionParser.isReviewScreen(REVIEW_SCREEN) == true,
       "isReviewScreen detects review/submit screen")
expect(QuestionParser.isReviewScreen(ASK_SCREEN) == false,
       "isReviewScreen false for a normal question")
expect(QuestionParser.detectQuestion(REVIEW_SCREEN) == nil,
       "review screen is not parsed as a question")

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

// --- question text ending in "Submit" (tab-bar skip regression) ---
let sw = QuestionParser.detectQuestion(SUBMIT_WORD_SCREEN)
expect(sw != nil, "SUBMIT_WORD_SCREEN detected as question")
expect(sw?.text == "Check these, then press Submit:",
       "SUBMIT_WORD_SCREEN keeps question ending in Submit, skips tab bar")
expect(sw?.isMultiSelect == true, "SUBMIT_WORD_SCREEN is multi-select")
expect(QuestionParser.detectOptions(SUBMIT_WORD_SCREEN) == ["Kotlin", "Swift"],
       "SUBMIT_WORD_SCREEN detectOptions drops Other")

// --- options with descriptions (synthetic) ---
let dq = QuestionParser.detectQuestion(DESC_SCREEN)
expect(dq != nil, "DESC_SCREEN detected as question")
expect(dq?.text == "Pick one.", "DESC_SCREEN question text")
expect(dq?.options.map { $0.label } == ["Alpha", "Beta", "Other (type your own)"],
       "DESC_SCREEN option labels ignore description lines")
expect(dq?.isMultiSelect == false, "DESC_SCREEN is single-select")
expect(dq?.selectedIndex == 0, "DESC_SCREEN cursor on first option")
expect(dq?.options.first { $0.label == "Alpha" }?.description == "first choice",
       "DESC_SCREEN Alpha description captured")
expect(dq?.options.first { $0.label == "Beta" }?.description == "second choice",
       "DESC_SCREEN Beta description captured")
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

// --- widget option descriptions (real captured single-question widget) ---
if let desc = loadFixture("live_desc.txt") {
    let lq = QuestionParser.detectQuestion(desc)
    expect(lq != nil, "live_desc parsed as question")
    expect(lq?.text == "Pick DB", "live_desc question text")
    expect(lq?.options.map { $0.label } == ["Postgres (Recommended)", "SQLite", "Dynamo", "Other (type your own)"],
           "live_desc option labels keep (Recommended) suffix")
    expect(lq?.options.first { $0.label == "Postgres (Recommended)" }?.description == "relational",
           "live_desc Postgres description captured")
    expect(lq?.options.first { $0.label == "SQLite" }?.description == "embedded",
           "live_desc SQLite description captured")
    expect(lq?.options.first { $0.label == "Dynamo" }?.description == "serverless",
           "live_desc Dynamo description captured")
} else {
    print("skip: live_desc.txt not captured")
}

// --- multi-question preview parsing ---
if let preview = loadFixture("live_multipreview.txt") {
    let subs = QuestionParser.parseMultiQuestionPreview(preview)
    expect(subs.count == 2, "preview parses 2 sub-questions")
    expect(subs.first?.key == "env", "preview first key is env")
    expect(subs.first?.text == "Environment?", "preview first question text")
    expect(subs.first?.isMultiSelect == false, "preview env is single-select")
    expect(subs.first?.options.map { $0.label } == ["Staging", "Production"],
           "preview env option labels")
    expect(subs.last?.key == "caps", "preview second key is caps")
    expect(subs.last?.isMultiSelect == true, "preview caps is multi-select")
    expect(subs.last?.options.map { $0.label } == ["Cache", "Metrics", "Tracing"],
           "preview caps option labels")
    expect(subs.last?.options.allSatisfy { $0.multi && !$0.checked } == true,
           "preview caps options are unchecked checkboxes")
} else {
    print("skip: live_multipreview.txt not captured")
}
expect(QuestionParser.parseMultiQuestionPreview(ASK_SCREEN).isEmpty,
       "parseMultiQuestionPreview empty for single-question ask")

// --- multi-question preview descriptions (synthetic) ---
let descSubs = QuestionParser.parseMultiQuestionPreview(DESC_PREVIEW)
expect(descSubs.count == 2, "DESC_PREVIEW parses 2 sub-questions")
expect(descSubs.first?.options.map { $0.label } == ["Postgres", "SQLite"],
       "DESC_PREVIEW db labels exclude description lines")
expect(descSubs.first?.options.first { $0.label == "Postgres" }?.description == "relational store",
       "DESC_PREVIEW Postgres description captured")
expect(descSubs.first?.options.first { $0.label == "SQLite" }?.description == "embedded file",
       "DESC_PREVIEW SQLite description captured")
expect(descSubs.last?.text == "Capabilities?",
       "DESC_PREVIEW caps question text excludes descriptions")
expect(descSubs.last?.options.first { $0.label == "Cache" }?.description == "in-memory layer",
       "DESC_PREVIEW Cache description captured")

// --- permission-guard approval prompt (real captured widget) ---
if let guardian = loadFixture("live_guardian.txt") {
    let g = QuestionParser.detectGuardianPrompt(guardian)
    expect(g != nil, "live_guardian detected as guardian prompt")
    expect(g?.tool == "bash", "live_guardian tool is bash")
    expect(g?.command == "cat /etc/passwd", "live_guardian command captured")
    expect(g?.options == ["Allow once", "Allow this exact call this session",
                          "Deny (recommended)", "Deny (type your own)"],
           "live_guardian option labels verbatim")
    expect(g?.selectedIndex == 2, "live_guardian cursor on Deny (recommended)")
    expect(QuestionParser.detectQuestion(guardian) == nil,
           "guardian prompt is not parsed as an ask question")
} else {
    print("skip: live_guardian.txt not captured")
}
// The pending call for a non-bash tool is a "<tool>: <args>" line below header.
if let guardianRead = loadFixture("live_guardian_read.txt") {
    let g = QuestionParser.detectGuardianPrompt(guardianRead)
    expect(g != nil, "live_guardian_read detected as guardian prompt")
    expect(g?.tool == "read", "live_guardian_read tool is read")
    expect(g?.command.contains("configure-artifactory/action.yaml") == true,
           "live_guardian_read command captured from tool-call line")
    expect(g?.options.count == 4, "live_guardian_read has 4 options")
    expect(g?.selectedIndex == 2, "live_guardian_read cursor on Deny (recommended)")
} else {
    print("skip: live_guardian_read.txt not captured")
}
// A normal ask question must not be misdetected as a guardian prompt.
expect(QuestionParser.detectGuardianPrompt(ASK_SCREEN) == nil,
       "detectGuardianPrompt nil for a normal ask question")

if failures > 0 { FileHandle.standardError.write(Data("\(failures) failure(s)\n".utf8)); exit(1) }
print("ALL PASS")
