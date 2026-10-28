import Foundation
import MoonlitCore

// 用法：EngineHarness <model.gguf> [--ctx 8192] [--out result.json] [--cpu]
// 依次执行：加载 → 单人角色扮演 → 第二轮（KV 缓存续用）→ 重新生成 → 停止生成 → 群聊身份 → 记忆摘要 → 长上下文。
// 所有数字都来自本次运行的真实计时。

struct Check: Codable {
    var name: String
    var passed: Bool
    var critical: Bool
    var detail: String
}

struct RunRecord: Codable {
    var name: String
    var promptTokens: Int
    var evaluated: Int
    var generated: Int
    var ttft: Double
    var promptTPS: Double
    var genTPS: Double
    var stopReason: String
    var footprintMB: Double?
    var text: String
}

struct Report: Codable {
    var model: String
    var host: String
    var os: String
    var physicalMemoryGB: Double
    var gpuOffload: Bool
    var contextLength: Int
    var loadSeconds: Double
    var footprintAfterLoadMB: Double?
    var architecture: String
    var format: String
    var checks: [Check] = []
    var runs: [RunRecord] = []
}

var args = CommandLine.arguments.dropFirst()
guard let modelPath = args.first else {
    print("用法：EngineHarness <model.gguf> [--ctx 8192] [--out result.json] [--cpu]")
    exit(2)
}
args = args.dropFirst()
var contextLength = 8192
var outPath: String?
var cpuOnly = false
while let a = args.first {
    args = args.dropFirst()
    switch a {
    case "--ctx": contextLength = Int(args.first ?? "") ?? 8192; args = args.dropFirst()
    case "--out": outPath = args.first; args = args.dropFirst()
    case "--cpu": cpuOnly = true
    default: break
    }
}

@MainActor func log(_ s: String) {
    print(s)
    fflush(stdout)
}

func hostDescription() -> String {
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
    return String(cString: buffer)
}

let engine = LlamaEngine()
let modelURL = URL(fileURLWithPath: modelPath)
let config = LlamaLoadConfig(
    modelURL: modelURL,
    contextLength: contextLength,
    kvCacheType: .q8_0,
    gpuLayers: cpuOnly ? 0 : -1,
    threads: 0,
    batchSize: 512,
    flashAttention: true,
    promptFormat: .auto,
    disableThinking: true
)

log("== 加载模型 \(modelURL.lastPathComponent) ==")
let info: LoadedModelInfo
do {
    info = try await engine.load(config) { _ in }
} catch {
    log("❌ 加载失败：\(error.localizedDescription)")
    for line in EngineLog.shared.snapshot() { log(line) }
    exit(1)
}
log("模型：\(info.description)，架构 \(info.architecture)，参数 \(String(format: "%.2f", Double(info.parameterCount) / 1e9))B")
log("上下文 \(info.contextLength)（训练 \(info.trainContext)），模板 \(info.resolvedFormat.rawValue)，思考模式 \(info.supportsThinking ? "支持" : "不支持")")
log(String(format: "GPU：%@，加载耗时 %.2f 秒，进程内存 %.0f MB", info.gpuOffload ? "Metal" : "CPU", info.loadSeconds, info.footprintAfterLoadMB ?? -1))

let v = ProcessInfo.processInfo.operatingSystemVersion
var report = Report(
    model: info.fileName,
    host: hostDescription(),
    os: "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
    physicalMemoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
    gpuOffload: info.gpuOffload,
    contextLength: info.contextLength,
    loadSeconds: info.loadSeconds,
    footprintAfterLoadMB: info.footprintAfterLoadMB,
    architecture: info.architecture,
    format: info.resolvedFormat.rawValue
)

@MainActor func check(_ name: String, _ passed: Bool, critical: Bool = true, _ detail: String) {
    report.checks.append(Check(name: name, passed: passed, critical: critical, detail: detail))
    log("\(passed ? "✅" : (critical ? "❌" : "⚠️")) \(name)：\(detail)")
}

var sampling = SamplingParams(temperature: 0.7, topP: 0.9, topK: 40, minP: 0.05, repeatPenalty: 1.05, repeatLastN: 256, seed: 42)

/// 执行一次生成。cancelAfter 不为空时，收到这么多段文本后调用 cancel()。
@MainActor func generate(_ name: String, _ request: GenerationRequest, cancelAfter: Int? = nil) async -> (String, GenerationStats?, Error?) {
    log("\n== \(name) ==")
    var text = ""
    var chunks = 0
    var stats: GenerationStats?
    do {
        for try await event in engine.generate(request) {
            switch event {
            case .text(let delta):
                text += delta
                chunks += 1
                print(delta, terminator: "")
                fflush(stdout)
                if let n = cancelAfter, chunks == n { engine.cancel() }
            case .finished(let s):
                stats = s
            case .progress:
                break
            }
        }
    } catch {
        log("\n生成出错：\(error.localizedDescription)")
        return (text, nil, error)
    }
    print("")
    if let s = stats {
        log(String(format: "提示词 %ld tok（实际计算 %ld），生成 %ld tok，首 token %.2f 秒，读取 %.1f tok/s，生成 %.1f tok/s，停止原因：%@，进程内存 %.0f MB",
                   s.promptTokens, s.promptTokensEvaluated, s.generatedTokens, s.timeToFirstToken,
                   s.promptTokensPerSecond, s.generationTokensPerSecond, s.stopReason, s.peakMemoryMB ?? -1))
        report.runs.append(RunRecord(name: name, promptTokens: s.promptTokens, evaluated: s.promptTokensEvaluated,
                                     generated: s.generatedTokens, ttft: s.timeToFirstToken, promptTPS: s.promptTokensPerSecond,
                                     genTPS: s.generationTokensPerSecond, stopReason: s.stopReason, footprintMB: s.peakMemoryMB, text: text))
    }
    return (text, stats, nil)
}

@MainActor func cleanOutputChecks(_ name: String, _ text: String) {
    check("\(name)：无思考段泄漏", !text.contains("<think>") && !text.contains("</think>"), "输出中不含 <think>")
    check("\(name)：无模板符号泄漏", !text.contains("<|im_"), "输出中不含 <|im_start|>/<|im_end|>")
    check("\(name)：UTF-8 完整", !text.contains("\u{FFFD}"), "没有乱码替换字符")
}

let counter = engine.tokenCounter() ?? HeuristicTokenCounter()
var settings = AppSettings()
settings.replyLength = .custom
settings.sampling = sampling
settings.sampling.maxNewTokens = 160

// ---------- 单人角色扮演 ----------
let erin = SampleData.erin
var chat = ChatSession(title: "harness", characterIDs: [erin.id])
chat.append(ChatMessage(role: .assistant, speakerID: erin.id, speakerName: erin.name,
                        content: MacroContext(characterName: erin.name, userName: "旅人").expand(erin.firstMessage)))
chat.append(ChatMessage(role: .user, speakerName: "旅人", content: "我想要一间朝着钟楼的房间，住三晚，多少钱？"))

@MainActor func plan(for chat: ChatSession, characters: [TavernCharacter], speaker: TavernCharacter, books: [Lorebook] = [SampleData.lorebook]) -> PromptPlan {
    PromptBuilder().build(PromptContext(
        characters: characters, speaker: speaker, persona: UserPersona(name: "旅人"),
        settings: settings, session: chat, lorebooks: books, memory: nil,
        contextLength: info.contextLength, maxNewTokens: settings.effectiveMaxNewTokens,
        tokenCounter: counter, roll: { _ in 0 }
    ))
}

let plan1 = plan(for: chat, characters: [erin], speaker: erin)
log("\n提示词组装：系统 \(plan1.report.systemTokens) tok，世界书 \(plan1.report.loreTokens) tok（激活 \(plan1.lore.included.map(\.entry.title).joined(separator: "、"))），历史 \(plan1.report.historyTokens) tok")
let req1 = GenerationRequest(messages: plan1.messages, prefill: plan1.prefill, sampling: sampling, maxNewTokens: 160, stopSequences: plan1.stopSequences)
let (reply1, stats1, err1) = await generate("单人角色扮演 · 第一轮", req1)
check("单人角色扮演：生成成功", err1 == nil && (stats1?.generatedTokens ?? 0) > 0 && !reply1.isBlank, "生成 \(stats1?.generatedTokens ?? 0) tok")
cleanOutputChecks("第一轮", reply1)
check("第一轮：首次计算完整提示词", (stats1?.promptTokensEvaluated ?? 0) == (stats1?.promptTokens ?? -1), "计算 \(stats1?.promptTokensEvaluated ?? 0)/\(stats1?.promptTokens ?? 0)")

// ---------- 第二轮：KV 缓存续用 ----------
let content1 = ResponseSanitizer.clean(reply1, speakerName: erin.name)
chat.append(ChatMessage(role: .assistant, speakerID: erin.id, speakerName: erin.name, content: content1))
chat.append(ChatMessage(role: .user, speakerName: "旅人", content: "钟楼那边晚上会有什么动静吗？"))
let plan2 = plan(for: chat, characters: [erin], speaker: erin)
let req2 = GenerationRequest(messages: plan2.messages, prefill: plan2.prefill, sampling: sampling, maxNewTokens: 160, stopSequences: plan2.stopSequences)
let (reply2, stats2, err2) = await generate("单人角色扮演 · 第二轮", req2)
check("第二轮：生成成功", err2 == nil && (stats2?.generatedTokens ?? 0) > 0, "生成 \(stats2?.generatedTokens ?? 0) tok")
cleanOutputChecks("第二轮", reply2)
if let s = stats2 {
    let reused = s.promptTokens - s.promptTokensEvaluated
    check("第二轮：复用 KV 缓存", reused > s.promptTokens / 2, critical: false,
          "复用 \(reused)/\(s.promptTokens) tok，只计算新增的 \(s.promptTokensEvaluated) tok")
}

// ---------- 重新生成：同一提示词，需要回退 ----------
let (reply3, stats3, err3) = await generate("重新生成（同一提示词）", req2)
check("重新生成：成功", err3 == nil && !reply3.isBlank, "生成 \(stats3?.generatedTokens ?? 0) tok")
if let s = stats3 {
    check("重新生成：KV 回退", s.promptTokensEvaluated < s.promptTokens, critical: false,
          s.promptTokensEvaluated <= 1 ? "部分回退成功，只重算 \(s.promptTokensEvaluated) tok"
                                       : "重算 \(s.promptTokensEvaluated)/\(s.promptTokens) tok（混合架构无法部分回退时会整段重算）")
}

// ---------- 停止生成 ----------
let reqStop = GenerationRequest(messages: plan2.messages, prefill: plan2.prefill, sampling: sampling, maxNewTokens: 300, stopSequences: plan2.stopSequences)
let (_, statsStop, errStop) = await generate("停止生成（收到 6 段后取消）", reqStop, cancelAfter: 6)
check("停止生成：及时停止", errStop == nil && statsStop?.stopReason == "用户停止" && (statsStop?.generatedTokens ?? 999) < 300,
      "停止原因 \(statsStop?.stopReason ?? "无")，已生成 \(statsStop?.generatedTokens ?? 0) tok")

// ---------- 群聊身份隔离 ----------
let lyon = SampleData.lyon
var group = ChatSession(title: "group", characterIDs: [erin.id, lyon.id], plotState: ["月相": "满月"])
group.append(ChatMessage(role: .assistant, speakerID: erin.id, speakerName: "艾琳", content: "*艾琳朝角落努了努嘴。* 那位是莱恩，每年满月都来。"))
group.append(ChatMessage(role: .user, speakerName: "旅人", content: "莱恩先生，你为什么每年都回来？"))
let speaker = GroupDirector.nextSpeaker(in: group, characters: [erin, lyon], strategy: .natural) ?? lyon
check("群聊：被点名的角色发言", speaker.id == lyon.id, "选中 \(speaker.name)")
let planG = plan(for: group, characters: [erin, lyon], speaker: speaker)
let reqG = GenerationRequest(messages: planG.messages, prefill: planG.prefill, sampling: sampling, maxNewTokens: 160, stopSequences: planG.stopSequences)
let (replyG, statsG, errG) = await generate("群聊 · 莱恩发言", reqG)
let cleanedG = ResponseSanitizer.clean(replyG, speakerName: speaker.name)
check("群聊：生成成功", errG == nil && !cleanedG.isBlank, "生成 \(statsG?.generatedTokens ?? 0) tok")
check("群聊：不替其他角色发言", !cleanedG.contains("\n艾琳：") && !cleanedG.contains("\n旅人："), "输出中没有「艾琳：」「旅人：」开头的行")
cleanOutputChecks("群聊", replyG)

// ---------- 记忆摘要 ----------
let summaryMessages = Summarizer.prompt(messages: chat.activePath(), previousSummary: nil, characterNames: ["艾琳"], userName: "旅人")
let reqS = GenerationRequest(messages: summaryMessages, sampling: .summarization, maxNewTokens: 360, purpose: .summary)
let (summaryText, _, errS) = await generate("记忆摘要", reqS)
let parsed = Summarizer.parse(summaryText)
check("摘要：生成并解析", errS == nil && !parsed.isEmpty, critical: false,
      "摘要 \(parsed.summary.count) 字，事件 \(parsed.events.count) 条，关系 \(parsed.relationships.count) 条，状态 \(parsed.stateUpdates.count) 项")

// ---------- 长上下文 ----------
let paragraph = """
月光从酒馆高窗斜照进来，落在吧台上一排擦得发亮的锡杯上。艾琳把账本合上，听见门外的风铃响了三声。\
来的是个披着斗篷的旅人，靴子上沾着钟楼广场的青灰色泥土。炉火噼啪作响，角落里的骑士握紧了剑柄。
"""
let target = info.contextLength - 400
var body = ""
var night = 1
while counter.count(body) < target - 200 {
    body += "第\(night)夜。" + paragraph + "\n"
    night += 1
}
let longMessages = [
    PromptMessage(role: .system, content: "你是小说作者。阅读下面的长篇记录，然后用一句话总结。"),
    PromptMessage(role: .user, content: body + "\n用一句话总结以上内容。")
]
var greedy = sampling
greedy.temperature = 0
let reqL = GenerationRequest(messages: longMessages, sampling: greedy, maxNewTokens: 48)
let (_, statsL, errL) = await generate("长上下文（接近 \(info.contextLength) tok）", reqL)
check("长上下文：\(info.contextLength) 上下文跑通", errL == nil && (statsL?.promptTokens ?? 0) > info.contextLength * 85 / 100 && (statsL?.generatedTokens ?? 0) > 0,
      "提示词 \(statsL?.promptTokens ?? 0) tok，生成 \(statsL?.generatedTokens ?? 0) tok，首 token \(String(format: "%.2f", statsL?.timeToFirstToken ?? 0)) 秒")

// ---------- 卸载 ----------
await engine.unload()
check("卸载模型", engine.info == nil, "卸载后引擎状态为空")

// ---------- 汇总 ----------
let failedCritical = report.checks.filter { $0.critical && !$0.passed }
log("\n== 汇总 ==")
log("检查 \(report.checks.count) 项，通过 \(report.checks.filter(\.passed).count) 项，关键项失败 \(failedCritical.count) 项")
log("引擎日志：")
for line in EngineLog.shared.snapshot() { log("  " + line) }

if let outPath {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(report) {
        try? data.write(to: URL(fileURLWithPath: outPath))
    }
}
exit(failedCritical.isEmpty ? 0 : 1)
