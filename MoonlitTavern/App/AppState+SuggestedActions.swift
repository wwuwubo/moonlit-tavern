import Foundation
import MoonlitCore

extension AppState {
    /// 取消待生成的选项；用户发送消息应始终优先。
    func cancelSuggestedActions() {
        if actionsLoadingChatID != nil {
            actionsTask?.cancel()
            activeEngine().cancel()
        }
        actionsTask = nil
        actionsLoadingChatID = nil
    }

    /// 刷新选项只改变选项列表，不改动角色回复或任何已保存的历史消息。
    func refreshSuggestedActions(in chatID: UUID) {
        guard generation == nil, let chat = chat(chatID),
              let last = chat.activePath().last, last.role == .assistant else { return }
        cancelSuggestedActions()
        suggestedActions[chatID] = []
        suggestedActionSourceIDs[chatID] = last.id
        actionsLoadingChatID = chatID
        let replyID = last.id
        actionsTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.actionsLoadingChatID == chatID {
                    self.actionsLoadingChatID = nil
                    self.actionsTask = nil
                }
            }
            do {
                if self.settings.providerMode == .local {
                    try await self.ensureModelLoaded()
                }
                try Task.checkCancellation()
                guard let current = self.chat(chatID),
                      current.activePath().last?.id == replyID else { return }
                let recent = current.activePath().suffix(6).map {
                    "\($0.role == .user ? "用户" : $0.speakerName)：\(String($0.content.prefix(380)))"
                }.joined(separator: "\n")
                let speaker = self.character(last.speakerID)
                let request = GenerationRequest(
                    messages: [
                        PromptMessage(role: .system, content: """
                        你是互动剧情的行动选项策划。根据角色的最后回复及当前剧情，提出4个让用户选择的下一步行动。
                        每项必须是用户自己能够采取的具体行动，互有差异，符合当前情境。
                        只输出4行，以1.、2.、3.、4.开头，每行不超过30个汉字。不写旁白、解释或角色回复。
                        """),
                        PromptMessage(role: .user, content: """
                        当前角色：\(last.speakerName)
                        角色性格：\(String((speaker?.personality ?? "").prefix(250)))
                        场景：\(String((speaker?.scenario ?? "").prefix(250)))
                        最近剧情：
                        \(recent)
                        """)
                    ],
                    sampling: .summarization,
                    maxNewTokens: 180,
                    purpose: .summary
                )
                var text = ""
                for try await event in self.activeEngine().generate(request) {
                    try Task.checkCancellation()
                    if case .text(let delta) = event { text += delta }
                }
                let choices = ActionSuggestionParser.parse(text)
                guard !Task.isCancelled,
                      self.chat(chatID)?.activePath().last?.id == replyID,
                      self.generation == nil else { return }
                self.suggestedActions[chatID] = choices
                self.suggestedActionSourceIDs[chatID] = replyID
                if choices.isEmpty {
                    EngineLog.shared.append("剧情选项解析为空：原始字符数 \(text.count)")
                }
            } catch is CancellationError {
                // 用户主动回复后，中止选项生成，不影响已保存的角色消息。
            } catch {
                EngineLog.shared.append("剧情选项生成失败：\(error.localizedDescription)")
            }
        }
    }
}
