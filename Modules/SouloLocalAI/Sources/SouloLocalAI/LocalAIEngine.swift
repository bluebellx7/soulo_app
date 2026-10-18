import Foundation
import CLocalAIBridge
#if os(iOS)
import os
#endif

public enum LocalAIError: Error, LocalizedError, Equatable {
    case cancelled, modelMissing, modelInvalid, contextTooLong, inferenceFailed, unsupportedTemplate, visionMissing, insufficientMemory, busy, disabled, pageChanged, invalidToolCall, operationNotApplied, imageContextMissing, pageEmpty
    public var errorDescription: String? {
        switch self {
        case .cancelled: return AIL10n.text("stopped")
        case .modelMissing: return AIL10n.text("model_missing")
        case .modelInvalid: return AIL10n.text("model_invalid")
        case .contextTooLong: return AIL10n.text("context_long")
        case .inferenceFailed: return AIL10n.text("inference_error")
        case .unsupportedTemplate: return AIL10n.text("template_error")
        case .visionMissing: return AIL10n.text("vision_missing")
        case .insufficientMemory: return AIL10n.text("memory_low")
        case .busy: return AIL10n.text("busy")
        case .disabled: return AIL10n.text("enable_help")
        case .pageChanged: return AIL10n.text("page_changed")
        case .invalidToolCall: return AIL10n.text("tool_invalid")
        case .operationNotApplied: return AIL10n.text("tool_not_applied")
        case .imageContextMissing: return AIL10n.text("image_context_missing")
        case .pageEmpty: return AIL10n.text("empty_page")
        }
    }
}

/// This object is the only native state touched across threads: an atomic flag.
public final class LocalAICancellation: @unchecked Sendable {
    let pointer: OpaquePointer
    public init() { pointer = lai_cancellation_create()! }
    public func cancel() { lai_cancellation_cancel(pointer) }
    deinit { lai_cancellation_free(pointer) }
}

public struct LocalAIRequest: Sendable {
    public struct Turn: Sendable {
        public let isUser: Bool
        public let content: String
        public init(isUser: Bool, content: String) { self.isUser = isUser; self.content = content }
    }
    public let system: String
    public let prompt: String
    public var history: [Turn]
    public var image: Data?
    public var maximumTokens: UInt32
    public var grammar: String?
    public init(system: String, prompt: String, image: Data? = nil, maximumTokens: UInt32 = 768, history: [Turn] = [], grammar: String? = nil) {
        self.system = system; self.prompt = prompt; self.image = image; self.maximumTokens = maximumTokens; self.history = history
        self.grammar = grammar
    }
}

public struct LocalAIMetrics: Codable, Sendable {
    public let promptTokens: Int
    public let generatedTokens: Int
    public let loadSeconds: Double
    public let firstTokenSeconds: Double
    public let generationSeconds: Double
    public var tokensPerSecond: Double { Double(generatedTokens) / max(0.001, generationSeconds) }
}

private final class TokenSink {
    let receive: @Sendable (String) -> Void
    init(_ receive: @escaping @Sendable (String) -> Void) { self.receive = receive }
}

/// All llama and Metal objects belong to this actor. There is no HTTP server,
/// child process, web script inference, or dependency on the host browser model.
public actor LocalAIEngine {
    public static let shared = LocalAIEngine()
    private var pointer: OpaquePointer?
    private var loadedModel: URL?
    public init() {}
    deinit { if let pointer { lai_engine_free(pointer) } }
    public func unload() { if let pointer { lai_engine_free(pointer); self.pointer = nil }; loadedModel = nil }

    public func generate(model: URL, projector: URL? = nil, request: LocalAIRequest,
                         contextSize: UInt32 = 4096, useGPU: Bool = true,
                         cancellation: LocalAICancellation = LocalAICancellation(),
                         onText: @escaping @Sendable (String) -> Void = { _ in }) async throws -> LocalAIMetrics {
        try await withTaskCancellationHandler {
            // Acquire and use the native pointer in one synchronous actor turn.
            // An unload queued during a model switch must not free it between
            // an async cancellation-handler entry and the C++ call.
            try generateNative(model: model, projector: projector, request: request, contextSize: contextSize,
                                     useGPU: useGPU, cancellation: cancellation, onText: onText)
        } onCancel: { cancellation.cancel() }
    }

    private func generateNative(model: URL, projector: URL?, request: LocalAIRequest,
                                contextSize: UInt32, useGPU: Bool, cancellation: LocalAICancellation,
                                onText: @escaping @Sendable (String) -> Void) throws -> LocalAIMetrics {
        guard FileManager.default.fileExists(atPath: model.path) else { throw LocalAIError.modelMissing }
        let expertFolder = model.deletingLastPathComponent().appendingPathComponent("experts", isDirectory: true)
        let enhanced = FileManager.default.fileExists(atPath: expertFolder.appendingPathComponent("manifest.json").path)
        let experts = enhanced ? expertFolder : nil
        if let experts {
            guard FileManager.default.fileExists(atPath: experts.appendingPathComponent("manifest.json").path) else { throw LocalAIError.modelInvalid }
            #if os(iOS) && !targetEnvironment(simulator)
            let reserve: UInt64 = loadedModel == model ? (request.image == nil ? 300_000_000 : 1_500_000_000)
                : (request.image == nil ? 2_800_000_000 : 4_100_000_000)
            guard ProcessInfo.processInfo.physicalMemory >= LocalAIModelProfile.enhanced.minimumDeviceMemory,
                  os_proc_available_memory() >= reserve else { throw LocalAIError.insufficientMemory }
            #endif
        }
        let expertCache: UInt32 = enhanced ? (ProcessInfo.processInfo.physicalMemory >= 12_000_000_000 ? 16 : 8) : 0
        let prefillBatch: UInt32 = ProcessInfo.processInfo.physicalMemory >= 12_000_000_000 ? 512 : 128
        if request.image != nil {
            guard let projector, FileManager.default.fileExists(atPath: projector.path) else { throw LocalAIError.visionMissing }
            #if os(iOS) && !targetEnvironment(simulator)
            // Native measurements peaked at 1.67 GB including language + vision.
            // Check the process's remaining allowance, rather than total device RAM.
            guard os_proc_available_memory() >= 1_800_000_000 else { throw LocalAIError.insufficientMemory }
            #endif
        }
        guard (1024...8192).contains(contextSize), request.maximumTokens > 0 else { throw LocalAIError.contextTooLong }
        if pointer == nil { pointer = lai_engine_create() }
        guard let pointer else { throw LocalAIError.inferenceFailed }
        #if targetEnvironment(simulator)
        let nativeGPU = false // Simulator Metal cannot map llama's model buffers reliably.
        #else
        let nativeGPU = useGPU
        #endif
        let turns = Array(request.history.suffix(12))
        let strings = turns.map { strdup($0.content) }
        defer { strings.forEach { free($0) } }
        let history = zip(turns, strings).map { lai_message(is_user: $0.0.isUser, content: UnsafePointer($0.1)) }
        let sink = TokenSink(onText)
        let opaque = Unmanaged.passUnretained(sink).toOpaque()
        var result = lai_metrics()
        let callback: lai_text_callback = { bytes, length, user in
            guard let bytes, let user else { return }
            let sink = Unmanaged<TokenSink>.fromOpaque(user).takeUnretainedValue()
            let data = UnsafeRawBufferPointer(start: bytes, count: length)
            sink.receive(String(decoding: data, as: UTF8.self))
        }
        let code = history.withUnsafeBufferPointer { previous in
              request.image.map { data in
                data.withUnsafeBytes { buffer in
                    lai_generate(pointer, model.path, projector?.path ?? "", experts?.path ?? "", expertCache, prefillBatch, request.system, request.prompt, request.grammar ?? "", previous.baseAddress, previous.count,
                                 buffer.bindMemory(to: UInt8.self).baseAddress, data.count,
                                 contextSize, request.maximumTokens, nativeGPU, cancellation.pointer, callback, opaque, &result)
                }
              } ?? lai_generate(pointer, model.path, "", experts?.path ?? "", expertCache, prefillBatch, request.system, request.prompt, request.grammar ?? "", previous.baseAddress, previous.count, nil, 0,
                              contextSize, request.maximumTokens, nativeGPU, cancellation.pointer, callback, opaque, &result)
        }
        withExtendedLifetime(sink) {}
        if code == 0 || code == 3 { loadedModel = model }
        switch code {
        case 0: break
        case 1: unload(); throw CancellationError()
        case 2: throw LocalAIError.modelInvalid
        case 3: throw LocalAIError.contextTooLong
        case 5: throw LocalAIError.unsupportedTemplate
        case 6: throw LocalAIError.inferenceFailed
        default: throw LocalAIError.inferenceFailed
        }
        return LocalAIMetrics(promptTokens: Int(result.prompt_tokens), generatedTokens: Int(result.generated_tokens),
                              loadSeconds: result.load_seconds, firstTokenSeconds: result.first_token_seconds,
                              generationSeconds: result.generation_seconds)
    }
}
