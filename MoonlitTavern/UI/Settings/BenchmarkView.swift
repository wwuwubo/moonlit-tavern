import SwiftUI
import MoonlitCore

/// 真机性能测试。结果全部来自本机实际运行，保存在本地，可复制为 Markdown 表格写进测试报告。
struct BenchmarkView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        List {
            Section {
                Button {
                    Task { await state.runBenchmark() }
                } label: { Label("测速（约 600 token 提示词 + 128 token 生成）", systemImage: "speedometer") }
                .disabled(state.isGenerating)
                Button {
                    Task { await state.runBenchmark(longContext: true) }
                } label: { Label("长上下文测试（填满当前上下文）", systemImage: "text.append") }
                .disabled(state.isGenerating)
                if let g = state.generation, g.purpose == .benchmark {
                    HStack {
                        ProgressView()
                        Text(g.progress.map { "\(g.phase.rawValue) \(Int($0 * 100))%" } ?? g.phase.rawValue)
                            .font(.caption)
                    }
                    Button("停止", role: .destructive) { state.stopGeneration() }
                }
            } footer: {
                Text("测试使用当前选择的模型和推理参数，温度设为 0，每次在开头加入随机标记，避免命中缓存。长上下文测试会把提示词填到上下文长度减 600 左右，用来验证 8K 上下文能否在本机跑通。测试时设备可能发热。")
            }

            Section {
                if state.benchmarks.isEmpty {
                    Text("还没有测试记录").foregroundStyle(Theme.textSecondary)
                }
                ForEach(state.benchmarks) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(r.kind) · \(r.modelFile)").font(.subheadline.weight(.medium))
                            Spacer()
                            Text(r.succeeded ? "成功" : "失败").font(.caption).foregroundStyle(r.succeeded ? Theme.success : Theme.danger)
                        }
                        Text("上下文 \(r.contextLength) · KV \(r.kvCache) · 提示词 \(r.promptTokens) tok · 生成 \(r.generatedTokens) tok")
                            .font(.caption)
                        if r.succeeded {
                            Text(String(format: "首 token %.2f 秒 · 读取 %.1f tok/s · 生成 %.1f tok/s", r.timeToFirstToken, r.promptTokensPerSecond, r.generationTokensPerSecond))
                                .font(.caption.monospacedDigit())
                        } else {
                            Text(r.note).font(.caption).foregroundStyle(Theme.danger)
                        }
                        Text("进程内存 \(r.footprintMB.map { String(format: "%.0f MB", $0) } ?? "-") · 温度 \(r.thermal) · \(r.deviceModel) · iPadOS \(r.systemVersion) · \(r.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("测试记录（真机实测）")
            }
        }
        .navigationTitle("真机性能测试")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    UIPasteboard.general.string = markdownTable()
                    state.show(.success, "已复制为 Markdown 表格")
                } label: { Image(systemName: "doc.on.doc") }
                .disabled(state.benchmarks.isEmpty)
                Button(role: .destructive) { state.clearBenchmarks() } label: { Image(systemName: "trash") }
                    .disabled(state.benchmarks.isEmpty)
            }
        }
    }

    private func markdownTable() -> String {
        var lines = [
            "| 时间 | 类型 | 模型 | 上下文 | KV | 提示词 tok | 生成 tok | 首 token(s) | 读取 tok/s | 生成 tok/s | 内存 MB | 温度 | 结果 |",
            "|---|---|---|---|---|---|---|---|---|---|---|---|---|"
        ]
        lines += state.benchmarks.map(\.markdownRow)
        if let first = state.benchmarks.first {
            lines.append("")
            lines.append("设备：\(first.deviceModel)，iPadOS \(first.systemVersion)")
        }
        return lines.joined(separator: "\n")
    }
}
