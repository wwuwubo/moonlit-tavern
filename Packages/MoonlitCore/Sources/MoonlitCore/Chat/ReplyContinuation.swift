import Foundation

/// 「继续」：回复写到长度上限停下时，让模型从断开的地方接着写，续写的内容并进同一条回复。
public enum ReplyContinuation {
    /// 不支持助手预填的服务（云端）用这条说明代替预填。
    public static let instruction = "（接着上一条回复往下写，从断开的地方直接续上，不要重复已经写过的内容，也不要另起开头。）"

    /// 续写请求。plan 是按「这条回复还没写」组装的提示词（活动叶子设为回复的父消息）。
    /// - supportsPrefill: 本地模型把已写部分作为助手回复的开头预填进去，模型自然接着写，
    ///   提示词前缀和上一次生成一致，KV 缓存可以复用；云端服务把它作为一条助手消息，再追加说明。
    public static func request(
        plan: PromptPlan,
        base: String,
        supportsPrefill: Bool,
        sampling: SamplingParams,
        maxNewTokens: Int
    ) -> GenerationRequest {
        if supportsPrefill {
            return GenerationRequest(
                messages: plan.messages,
                prefill: plan.prefill + base,
                sampling: sampling,
                maxNewTokens: maxNewTokens,
                stopSequences: plan.stopSequences
            )
        }
        var messages = plan.messages
        messages.append(PromptMessage(role: .assistant, content: base))
        messages.append(PromptMessage(role: .system, content: instruction))
        return GenerationRequest(
            messages: messages,
            prefill: plan.prefill,
            sampling: sampling,
            maxNewTokens: maxNewTokens,
            stopSequences: plan.stopSequences
        )
    }

    /// 把续写的部分接到原回复后面并定稿。续写什么都没写出来时原样返回原回复。
    public static func finalize(base: String, addition: String, speakerName: String) -> ReplyOutcome {
        let added = StreamingTextFilter.removingThinkTags(addition)
        guard !added.trimmed.isEmpty else {
            return ReplyOutcome(content: base, visibleCount: base.count, cleanedCount: base.count, usedFallback: false)
        }
        var outcome = ReplyFinalizer.finalize(visible: base + added, speakerName: speakerName)
        if outcome.content.isEmpty { outcome.content = base }
        return outcome
    }
}
