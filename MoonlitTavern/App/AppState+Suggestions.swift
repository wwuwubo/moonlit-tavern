import Foundation
import MoonlitCore

/// 一次剧情选项生成任务。
struct SuggestionJob: Equatable {
    let chatID: UUID
    let messageID: UUID
    /// 用户手动点的「换一组」：失败时要提示
    let manual: Bool
}

extension AppState {
    /// 为某条角色回复生成剧情选项。已有的选项在新选项出来之前保留；回复正文不会被改动。
    func requestSuggestions(chatID: UUID, messageID: UUID, manual: Bool = false) {
        guard generation == nil else { return }
        cancelSuggestions()
        let job = SuggestionJob(chatID: chatID, messageID: messageID, manual: manual)
        suggestionJob = job
        suggestionTask = Task { [weak self] in
            await self?.runSuggestions(job)
        }
    }

    /// 取消正在生成的选项。取消任务会结束推理流，本地引擎随即停下，给新的回复让路。
    func cancelSuggestions() {
        guard suggestionJob != nil || suggestionTask != nil else { return }
        suggestionTask?.cancel()
        suggestionTask = nil
        suggestionJob = nil
    }

    private func runSuggestions(_ job: SuggestionJob) async {
        defer {
            if suggestionJob == job {
                suggestionJob = nil
                suggestionTask = nil
            }
        }
        guard let chat = chat(job.chatID), let message = chat.message(job.messageID), message.role == .assistant,
              let speaker = character(message.speakerID) ?? participants(of: chat).first
        else { return }
        do {
            if settings.providerMode == .local { try await ensureModelLoaded() }
            try Task.checkCancellation()
            // 按「这条回复是最新一条」组装提示词，和下一轮回复共用同一段前缀
            var promptChat = chat
            promptChat.activeLeafID = job.messageID
            let engine = activeEngine()
            let plan = await buildPlan(for: promptChat, speaker: speaker, engine: engine)
            let names = participants(of: chat).map(\.name)
            let userName = persona(for: chat).name
            let count = settings.suggestions.count
            let request = ReplySuggestions.request(plan: plan, userName: userName, characterNames: names,
                                                   count: count, sampling: settings.sampling)
            // 小模型偶尔只写出一个能用的选项（其余跑题、重复或写成了角色的话），这时自动再要一次，合并去重
            var options: [String] = []
            let enough = min(2, count)
            for attempt in 1...2 {
                var output = ""
                for try await event in engine.generate(request) {
                    if case .text(let delta) = event { output += delta }
                }
                try Task.checkCancellation()
                let parsed = ReplySuggestions.parse(output, userName: userName, characterNames: names, limit: count)
                for option in parsed where options.count < count && !options.contains(option) {
                    options.append(option)
                }
                EngineLog.shared.append("剧情选项：第 \(attempt) 次，模型输出 \(output.count) 字，整理出 \(parsed.count) 个，累计 \(options.count) 个")
                if options.count >= enough { break }
            }
            guard !options.isEmpty else {
                if job.manual { show(.warning, "这次没能整理出剧情选项，可以再点一次「换一组」，或者直接输入。") }
                return
            }
            guard suggestionJob == job else { return }
            updateChat(job.chatID) { $0.setSuggestions(options, for: job.messageID) }
        } catch is CancellationError {
        } catch InferenceError.cancelled {
        } catch {
            EngineLog.shared.append("剧情选项生成失败：\(error.localizedDescription)")
            if job.manual { show(.error, "剧情选项生成失败：\(error.localizedDescription)") }
        }
    }
}
