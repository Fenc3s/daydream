import Foundation
import Observation

@MainActor
@Observable
final class ResultPopupState {
    var result: CommandExecutionResult
    var isStreaming: Bool
    var statusMessage = "Processing…"

    var canApply: Bool { !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init(result: CommandExecutionResult, isStreaming: Bool = false) {
        self.result = result
        self.isStreaming = isStreaming
    }
}
