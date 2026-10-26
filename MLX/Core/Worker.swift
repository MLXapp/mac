import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Runs models with Apple's MLX on this Mac's GPU. One job at a time; a job stops within a token
/// or two of being cancelled, and the model is dropped so the owner gets their memory back.
actor Worker {
    struct Output: Sendable {
        let tokens: [Int]
        let text: String
        let promptTokens: Int
        let tokPerSec: Double
        let ttftMs: Int
        let ms: Int
        let stop: String  // stop, length, cancelled
        var outHash: String { sha256Hex(tokens.map(String.init).joined(separator: ",")) }
    }

    /// Can this Mac join a Thunderbolt 5 pod: MLX's JACCL backend over the RDMA driver of macOS 26.2+.
    static var podReady: (jaccl: Bool, rdma: Bool) {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let rdma = v.majorVersion > 26 || (v.majorVersion == 26 && v.minorVersion >= 2)
        return (MLXDistributed.isAvailable(.jaccl), rdma)
    }

    /// Live token count and speed for the menu (sampled from the main actor).
    nonisolated let live = LiveCounter()

    private var context: ModelContext?
    private var loaded: String?

    var loadedModel: String? { loaded }

    /// Cap MLX's memory at a share of this Mac's memory.
    func setMemoryShare(_ pct: Int) {
        let bytes = Double(ProcessInfo.processInfo.physicalMemory) * Double(pct) / 100
        Memory.memoryLimit = Int(bytes)
        Memory.cacheLimit = 256 * 1024 * 1024
    }

    /// Download (first time only) and load a model from Hugging Face.
    func load(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        if loaded == id, context != nil { return }
        unload()
        let ctx = try await LLMModelFactory.shared.load(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: ModelConfiguration(id: id),
            progressHandler: { p in progress(p.fractionCompleted) }
        )
        context = ctx
        loaded = id
    }

    func unload() {
        context = nil
        loaded = nil
        Memory.clearCache()
    }

    /// Greedy decoding (temperature 0), so every Mac should produce the same tokens.
    func run(prompt: String, maxTokens: Int) async throws -> Output {
        guard let ctx = context else { throw API.Failure(message: "No model loaded") }
        let started = Date()
        let input = try await ctx.processor.prepare(input: UserInput(prompt: prompt))
        let params = GenerateParameters(maxTokens: maxTokens, temperature: 0)
        let (stream, task) = try generateTokensTask(input: input, parameters: params, context: ctx)
        var ids: [Int] = []
        var info: GenerateCompletionInfo?
        let live = self.live
        live.begin()
        defer { live.end() }
        await withTaskCancellationHandler {
            for await event in stream {
                switch event {
                case .token(let t):
                    ids.append(t)
                    live.token()
                case .info(let i): info = i
                }
            }
        } onCancel: {
            task.cancel()
        }
        await task.value
        Memory.clearCache()
        let stop: String
        switch info?.stopReason {
        case .some(.stop): stop = "stop"
        case .some(.length): stop = "length"
        default: stop = "cancelled"
        }
        let text = ctx.tokenizer.decode(tokenIds: ids)
        return Output(
            tokens: ids, text: String(text.prefix(600)), promptTokens: info?.promptTokenCount ?? 0,
            tokPerSec: info?.tokensPerSecond ?? 0, ttftMs: Int((info?.promptTime ?? 0) * 1000), ms: Int(Date().timeIntervalSince(started) * 1000),
            stop: Task.isCancelled ? "cancelled" : stop)
    }
}
