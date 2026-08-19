import Foundation

enum AgentStatus: String, Codable {
    case working, blocked, idle, unknown
}

@Observable
final class Agent: Identifiable {
    let id: String
    var name: String
    var status: AgentStatus
    var project: String
    var cwd: String
    var host: String
    var prompt: String?
    var options: [String]?
    var promptId: String?
    var multiOptions: [String] = []
    var selectedOptions: [String] = []
    var interaction: String?
    var isMultiSelect = false
    /// True when the blocked prompt is an omp `ask` question (options are
    /// verbatim answers, not permission keywords). Drives raw-label rendering.
    var isQuestion = false
    /// Total questions in a multi-question ask (nil for single/none). Shown as
    /// a queue indicator in the notch.
    var questionTotal: Int? = nil
    /// The full multi-question form when this ask has more than one question.
    /// Non-nil replaces the single-question UI with an all-questions card that
    /// collects every answer and submits omp's tabbed form once.
    var form: MultiQuestionForm? = nil

    init(id: String, name: String, status: AgentStatus, project: String, cwd: String, host: String = "local") {
        self.id = id
        self.name = name
        self.status = status
        self.project = project
        self.cwd = cwd
        self.host = host
    }
}

/// One question inside a multi-question form, holding both the parsed options
/// and the user's in-progress selection.
@Observable
final class FormQuestion: Identifiable {
    let id: String            // omp's [key]
    let text: String
    let isMultiSelect: Bool
    let options: [String]     // answer labels (excludes "Other")
    /// Single-select: at most one label. Multi-select: any number.
    var selected: Set<String> = []
    /// Free-text answer typed via "Other"; overrides `selected` when non-empty.
    var customText: String = ""

    init(id: String, text: String, isMultiSelect: Bool, options: [String]) {
        self.id = id
        self.text = text
        self.isMultiSelect = isMultiSelect
        self.options = options
    }

    /// The answer for this question: custom text if provided, else the selected
    /// labels. Empty when unanswered.
    var answerLabels: [String] {
        let trimmed = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return [trimmed] }
        // Preserve option order for determinism when driving the form.
        return options.filter { selected.contains($0) }
    }

    var isAnswered: Bool { !answerLabels.isEmpty }
}

/// A multi-question omp ask rendered as one notch card. Collects every answer,
/// then drives omp's tabbed form to submit them together.
@Observable
final class MultiQuestionForm {
    let questions: [FormQuestion]

    init(questions: [FormQuestion]) {
        self.questions = questions
    }

    /// True once every question has an answer (selection or custom text).
    var isComplete: Bool { questions.allSatisfy { $0.isAnswered } }
}

struct AgentMessage: Decodable {
    let type: String
    let agents: [AgentData]?
    let pane_id: String?
    let agent: String?
    let agentData: AgentData?
    let project: String?
    let prompt: String?
    let options: [String]?
    let prompt_id: String?
    let multi_options: [String]?
    let selected_options: [String]?
    let interaction: String?
    let multi: Bool?
    let update: Bool?

    struct AgentData: Decodable {
        let pane_id: String
        let agent: String
        let status: String
        let cwd: String
        let project: String
        let host: String?
    }

    private enum CodingKeys: String, CodingKey {
        case type, agents, pane_id, agent, project, prompt, options, prompt_id
        case multi_options, selected_options, interaction, multi, update
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        agents = try? values.decode([AgentData].self, forKey: .agents)
        pane_id = try? values.decode(String.self, forKey: .pane_id)
        project = try? values.decode(String.self, forKey: .project)
        prompt = try? values.decode(String.self, forKey: .prompt)
        options = try? values.decode([String].self, forKey: .options)
        prompt_id = try? values.decode(String.self, forKey: .prompt_id)
        multi_options = try? values.decode([String].self, forKey: .multi_options)
        selected_options = try? values.decode([String].self, forKey: .selected_options)
        interaction = try? values.decode(String.self, forKey: .interaction)
        multi = try? values.decode(Bool.self, forKey: .multi)
        update = try? values.decode(Bool.self, forKey: .update)
        if type == "agent_update" {
            agentData = try? values.decode(AgentData.self, forKey: .agent)
            agent = nil
        } else {
            agent = try? values.decode(String.self, forKey: .agent)
            agentData = nil
        }
    }
}

struct ResponseMessage: Codable {
    let type = "respond"
    let pane_id: String
    let prompt_id: String?
    let text: String
}

struct QuestionToggleMessage: Codable {
    let type = "question_toggle"
    let pane_id: String
    let prompt_id: String
    let option: String
}

struct QuestionSubmitMessage: Codable {
    let type = "question_submit"
    let pane_id: String
    let prompt_id: String
}
