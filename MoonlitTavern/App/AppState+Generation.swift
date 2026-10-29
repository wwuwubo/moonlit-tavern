import Foundation
import MoonlitCore

extension AppState {
    /// 当前模式对应的引擎。本地模式永远只返回本地引擎，聊天内容不会发往网络。
    func activeEngine() -> InferenceEngine {
        switch settings.providerMode {
        case .local: return llama
        case .cloud: return OpenAICompatibleEngine(settings: settings.cloud)
        }
    }

    var isGenerating: Bool { generation != nil }

    // MARK: - 消息操作

    func sendUserMessage(_ text: String, in chatID: UUID) {
        let trimmed = text.trimmed
        // 用户已经开口：还没生成完的剧情选项不要了
        cancelSuggestions()
        guard !trimmed.isEmpty, generation == nil, var chat = chat(chatID) else { return }
        let persona = persona(for: chat)
        chat.append(ChatMessage(role: .user, speakerName: persona.name, content: trimmed))
        saveChat(chat)
        guard chat.turnOrder != .manual || !chat.isGroup else { return }
        generateReply(chatID: chatID)
    }

    /// 让某个角色发言。speakerID 为空时按群聊顺序策略选择。
    func generateReply(chatID: UUID, speakerID: UUID? = nil) {
        startReply(chatID: chatID, speakerID: speakerID, regenerating: nil)
    }

    /// 重新生成：新回复作为该消息的兄弟版本，可左右切换。
    func regenerate(messageID: UUID, in chatID: UUID) {
        guard let chat = chat(chatID), let message = chat.message(messageID), message.role == .assistant else { return }
        startReply(chatID: chatID, speakerID: message.speakerID, regenerating: messageID)
    }

    /// 继续：回复写到一半停下（多半是到了回复长度上限）时，从断开的地方接着写，并进同一条回复。
    func continueReply(messageID: UUID, in chatID: UUID) {
        cancelSuggestions()
        guard generation == nil, let chat = chat(chatID), let message = chat.message(messageID), message.role == .assistant else { return }
        guard let speaker = character(message.speakerID) ?? participants(of: chat).first(where: { $0.name == message.speakerName }) else {
            show(.warning, "找不到这条回复的角色，无法继续")
            return
        }
        var state = GenerationState(
            chatID: chatID, speakerID: speaker.id, speakerName: speaker.name,
            purpose: .reply, phase: .processingPrompt, progress: nil
        )
        state.continuingMessageID = messageID
        state.baseText = message.content
        generation = state
        generationTask = Task { [weak self] in
            guard let self else { return }
            let saved = await self.runContinuation(chatID: chatID, messageID: messageID, speaker: speaker)
            if saved, self.settings.suggestions.enabled {
                self.requestSuggestions(chatID: chatID, messageID: messageID)
            }
        }
    }

    func editMessage(_ messageID: UUID, in chatID: UUID, content: String) {
        updateChat(chatID) { $0.editMessage(messageID, content: content) }
    }

    func deleteMessage(_ messageID: UUID, in chatID: UUID) {
        updateChat(chatID) { $0.deleteMessage(messageID) }
    }

    func toggleHidden(_ messageID: UUID, in chatID: UUID) {
        guard let message = chat(chatID)?.message(messageID) else { return }
        updateChat(chatID) { $0.setHidden(messageID, hidden: !message.isHidden) }
    }

    func switchSibling(_ messageID: UUID, in chatID: UUID, offset: Int) {
        updateChat(chatID) { $0.switchSibling(of: messageID, offset: offset) }
    }

    func stopGeneration() {
        llama.cancel()
        generationTask?.cancel()
        cancelSuggestions()
    }

    // MARK: - 回复生成

    private func startReply(chatID: UUID, speakerID: UUID?, regenerating messageID: UUID?) {
        cancelSuggestions()
        guard generation == nil, let chat = chat(chatID) else { return }
        let speaker: TavernCharacter
        if let speakerID, let c = character(speakerID) {
            speaker = c
        } else if let c = GroupDirector.nextSpeaker(in: chat, characters: characters, strategy: chat.turnOrder == .manual ? .natural : nil) {
            speaker = c
        } else {
            show(.warning, "这个存档没有可发言的角色")
            return
        }
        generation = GenerationState(
            chatID: chatID, speakerID: speaker.id, speakerName: speaker.name,
            purpose: .reply, phase: .processingPrompt, progress: nil, regeneratingMessageID: messageID
        )
        generationTask = Task { [weak self] in
            guard let self else { return }
            let saved = await self.runReply(chatID: chatID, speaker: speaker, regenerating: messageID)
            // 回复完整保存后，接着替用户想几个下一步的选项（不占用生成状态，用户随时可以直接输入）
            if let saved, self.settings.suggestions.enabled {
                self.requestSuggestions(chatID: chatID, messageID: saved)
            }
        }
    }

    /// 生成一条回复。返回成功保存（且没有被中断）的回复 id，用于接着生成剧情选项。
    @discardableResult
    private func runReply(chatID: UUID, speaker: TavernCharacter, regenerating messageID: UUID?) async -> UUID? {
        defer {
            generation = nil
            generationTask = nil
        }
        do {
            if settings.providerMode == .local {
                generation?.phase = .loadingModel
                try await ensureModelLoaded()
            }
            guard var promptChat = chat(chatID) else { return nil }
            if let messageID, let original = promptChat.message(messageID) {
                promptChat.activeLeafID = original.parentID
            }
            let engine = activeEngine()
            let plan = await buildPlan(for: promptChat, speaker: speaker, engine: engine)
            if plan.report.overflow {
                show(.warning, "固定设定已经占满上下文，聊天记录几乎放不下。请精简角色设定或调大上下文。")
            }
            lastPlans[chatID] = snapshot(plan, engine: engine.engineName)

            let request = GenerationRequest(
                messages: plan.messages,
                prefill: plan.prefill,
                sampling: settings.sampling,
                maxNewTokens: settings.effectiveMaxNewTokens,
                stopSequences: plan.stopSequences,
                minNewTokens: settings.minNewTokens,
                // 末尾的回复前提醒只用这一次，下一轮会挪位置；在它前面存检查点
                stableMessageCount: plan.tailCount > 0 ? plan.messages.count - plan.tailCount : nil
            )
            var finalStats: GenerationStats?
            var cancelled = false
            var streamError: Error?
            do {
                for try await event in engine.generate(request) {
                    switch event {
                    case .progress(let phase, let value):
                        generation?.phase = phase
                        generation?.progress = value
                    case .text(let delta):
                        generation?.text += delta
                    case .finished(let stats):
                        finalStats = stats
                    }
                }
            } catch InferenceError.cancelled {
                cancelled = true
            } catch is CancellationError {
                cancelled = true
            } catch {
                // 生成中途出错：已经显示出来的部分照样保存，不能跟着错误一起丢掉
                streamError = error
            }
            if Task.isCancelled || finalStats?.stopReason == "用户停止" { cancelled = true }

            let visible = generation?.text ?? ""
            let outcome = ReplyFinalizer.finalize(visible: visible, speakerName: speaker.name)
            let stopReason = streamError.map { "出错" + ($0.localizedDescription.isEmpty ? "" : "：\($0.localizedDescription)") }
                ?? (cancelled ? "用户停止" : (finalStats?.stopReason ?? "未知"))
            EngineLog.shared.append(outcome.logLine(stopReason: stopReason, saved: !outcome.content.isEmpty,
                                                    error: streamError?.localizedDescription))
            guard !outcome.content.isEmpty else {
                if let streamError { throw streamError }
                if !cancelled {
                    let reason = finalStats?.stopReason ?? "未知"
                    show(.warning, "模型这次没有写出正文（停止原因：\(reason)）。可以点重新生成；反复出现时请到「设置 › 诊断日志」查看记录。")
                }
                return nil
            }
            var stats = finalStats ?? GenerationStats(engine: engine.engineName, modelName: "", stopReason: stopReason)
            if cancelled || streamError != nil { stats.stopReason = stopReason }
            if let streamError {
                show(.warning, "生成中途出错（\(streamError.localizedDescription)），已保存已经生成的部分。")
            }
            let reply = ChatMessage(role: .assistant, speakerID: speaker.id, speakerName: speaker.name, content: outcome.content, stats: stats)
            guard var chat = chat(chatID) else { return nil }
            if let messageID {
                chat.addSibling(reply, siblingOf: messageID)
            } else {
                chat.append(reply)
            }
            chat.historyAnchor = plan.historyAnchor
            chat.loreState = plan.lore.nextState
            saveChat(chat)
            lastStats = stats

            if !cancelled, streamError == nil, settings.memory.autoSummarize,
               plan.truncatedMessages.count >= settings.memory.summarizeBatch {
                await summarize(chatID: chatID, messages: plan.truncatedMessages)
            }
            return (cancelled || streamError != nil) ? nil : reply.id
        } catch {
            show(.error, error.localizedDescription)
            EngineLog.shared.append("生成失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 续写一条回复。返回是否完整写完（没有被停止或出错），用于接着生成剧情选项。
    private func runContinuation(chatID: UUID, messageID: UUID, speaker: TavernCharacter) async -> Bool {
        defer {
            generation = nil
            generationTask = nil
        }
        do {
            if settings.providerMode == .local {
                generation?.phase = .loadingModel
                try await ensureModelLoaded()
            }
            guard var promptChat = chat(chatID), let original = promptChat.message(messageID) else { return false }
            promptChat.activeLeafID = original.parentID
            let engine = activeEngine()
            let plan = await buildPlan(for: promptChat, speaker: speaker, engine: engine)
            lastPlans[chatID] = snapshot(plan, engine: engine.engineName)
            let request = ReplyContinuation.request(
                plan: plan, base: original.content, supportsPrefill: engine.isLocal,
                sampling: settings.sampling, maxNewTokens: settings.effectiveMaxNewTokens
            )
            var finalStats: GenerationStats?
            var cancelled = false
            var streamError: Error?
            do {
                for try await event in engine.generate(request) {
                    switch event {
                    case .progress(let phase, let value):
                        generation?.phase = phase
                        generation?.progress = value
                    case .text(let delta):
                        generation?.text += delta
                    case .finished(let stats):
                        finalStats = stats
                    }
                }
            } catch InferenceError.cancelled {
                cancelled = true
            } catch is CancellationError {
                cancelled = true
            } catch {
                streamError = error
            }
            if Task.isCancelled || finalStats?.stopReason == "用户停止" { cancelled = true }

            let addition = generation?.text ?? ""
            let outcome = ReplyContinuation.finalize(base: original.content, addition: addition, speakerName: speaker.name)
            let stopReason = streamError.map { "出错：\($0.localizedDescription)" }
                ?? (cancelled ? "用户停止" : (finalStats?.stopReason ?? "未知"))
            EngineLog.shared.append("继续回复：原有 \(original.content.count) 字，续写 \(addition.count) 字，停止原因 \(stopReason)，保存后 \(outcome.content.count) 字")
            if outcome.content.count > original.content.count {
                var stats = finalStats
                if cancelled || streamError != nil { stats?.stopReason = stopReason }
                updateChat(chatID) { $0.continueMessage(messageID, content: outcome.content, stats: stats) }
                if let stats { lastStats = stats }
            } else if !cancelled, streamError == nil {
                show(.info, "模型认为这条回复已经写完了，没有续写内容。")
            }
            if let streamError {
                show(.warning, "续写中途出错（\(streamError.localizedDescription)），已保存已经写出的部分。")
            }
            return !cancelled && streamError == nil
        } catch {
            show(.error, error.localizedDescription)
            EngineLog.shared.append("继续回复失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 组装提示词。使用模型自己的分词器计数时会在后台线程进行，避免卡界面。
    func buildPlan(for chat: ChatSession, speaker: TavernCharacter, engine: InferenceEngine) async -> PromptPlan {
        let contextLength: Int
        if engine.isLocal, case .loaded(let info) = modelState {
            contextLength = info.contextLength
        } else {
            contextLength = settings.local.contextLength
        }
        let context = PromptContext(
            characters: participants(of: chat),
            speaker: speaker,
            persona: persona(for: chat),
            settings: settings,
            session: chat,
            lorebooks: activeLorebooks(for: chat),
            memory: memory(for: chat.id),
            contextLength: contextLength,
            maxNewTokens: settings.effectiveMaxNewTokens,
            tokenCounter: engine.tokenCounter() ?? HeuristicTokenCounter()
        )
        return await Task.detached(priority: .userInitiated) {
            PromptBuilder().build(context)
        }.value
    }

    func snapshot(_ plan: PromptPlan, engine: String) -> PlanSnapshot {
        PlanSnapshot(
            report: plan.report,
            loreIncluded: plan.lore.included.map { (title: $0.entry.title, book: $0.bookName, reason: $0.reason.label, tokens: $0.tokens) },
            loreDropped: plan.lore.dropped.map { (title: $0.activation.entry.title, reason: $0.reason.rawValue) },
            memoryIDs: plan.report.includedMemoryIDs,
            promptPreview: plan.messages,
            prefill: plan.prefill,
            engine: engine
        )
    }

    /// 不发送请求，只预览当前会组装出的提示词（右侧面板「上下文」用）。
    func previewPlan(chatID: UUID) async {
        guard let chat = chat(chatID),
              let speaker = GroupDirector.nextSpeaker(in: chat, characters: characters, strategy: .natural) ?? participants(of: chat).first
        else { return }
        let engine = activeEngine()
        let plan = await buildPlan(for: chat, speaker: speaker, engine: engine)
        lastPlans[chatID] = snapshot(plan, engine: engine.engineName)
    }

    // MARK: - 记忆摘要

    /// 立即整理：把除最近 6 条外、尚未摘要的消息做一次摘要。
    func summarizeNow(chatID: UUID) async {
        cancelSuggestions()
        guard generation == nil, let chat = chat(chatID) else { return }
        let memory = memory(for: chatID)
        let path = chat.activePath().filter { !$0.isHidden }
        let candidates = path.dropLast(6).filter { !memory.summarizedMessageIDs.contains($0.id) }
        guard candidates.count >= 2 else {
            show(.info, "需要整理的旧消息太少（最近 6 条保留原文）。")
            return
        }
        // 单次最多 40 条，避免摘要提示词过长
        await summarize(chatID: chatID, messages: Array(candidates.prefix(40)))
    }

    func summarize(chatID: UUID, messages: [ChatMessage]) async {
        guard let chat = chat(chatID), !messages.isEmpty else { return }
        let ownsGeneration = generation == nil
        if ownsGeneration {
            generation = GenerationState(chatID: chatID, speakerID: nil, speakerName: "记忆整理", purpose: .summary, phase: .processingPrompt, progress: nil)
        } else {
            generation?.purpose = .summary
            generation?.speakerName = "记忆整理"
            generation?.text = ""
        }
        defer { if ownsGeneration { generation = nil } }

        do {
            if settings.providerMode == .local { try await ensureModelLoaded() }
            let engine = activeEngine()
            let previous = memory(for: chatID).summaries.sorted { $0.messageIndex < $1.messageIndex }.last?.content
            let prompt = Summarizer.prompt(
                messages: messages,
                previousSummary: previous,
                characterNames: participants(of: chat).map(\.name),
                userName: persona(for: chat).name
            )
            let request = GenerationRequest(messages: prompt, sampling: .summarization, maxNewTokens: 420, purpose: .summary)
            var output = ""
            for try await event in engine.generate(request) {
                if case .text(let delta) = event {
                    output += delta
                    generation?.text = output
                }
            }
            let parsed = Summarizer.parse(output)
            guard !parsed.isEmpty else {
                show(.warning, "模型没有按格式输出摘要，本次未写入记忆。")
                return
            }
            let path = chat.activePath()
            let lastIndex = messages.last.flatMap { last in path.firstIndex { $0.id == last.id } } ?? path.count
            updateMemory(chatID) { memory in
                Summarizer.merge(Summarizer.memoryItems(from: parsed, messageIndex: lastIndex), into: &memory)
                memory.summarizedMessageIDs.formUnion(messages.map(\.id))
            }
            if !parsed.stateUpdates.isEmpty {
                updateChat(chatID) { $0.plotState.merge(parsed.stateUpdates) { _, new in new } }
            }
            show(.success, "已整理 \(messages.count) 条旧消息到长期记忆")
        } catch InferenceError.cancelled {
            // 用户停止，不提示
        } catch {
            show(.error, "记忆整理失败：\(error.localizedDescription)")
        }
    }
}
