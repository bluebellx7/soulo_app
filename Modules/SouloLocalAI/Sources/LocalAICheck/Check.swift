import Foundation
import SouloLocalAI
import Darwin

final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var content = ""
    func set(_ value: String) { lock.lock(); content = value; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return content }
}

@main struct LocalAICheck {
    static func main() async {
        do { try await run() }
        catch {
            let data = try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription], options: [.sortedKeys])
            print(data.map { String(decoding: $0, as: UTF8.self) } ?? "Inference failed")
            await LocalAIEngine.shared.unload()
            exit(1)
        }
    }
    static func run() async throws {
        let arguments = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard let path = value("--model") else {
            print("local-ai-check --model file.gguf [--prompt text] [--image file.jpg --projector file.gguf] [--cpu]")
            return
        }
        let output = Output()
        let image = try value("--image").map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        var system = value("--system") ?? "You are a helpful assistant. Answer in Chinese. Give the answer directly without reasoning."
        var prompt = value("--prompt") ?? "请只回答：本地推理正常。"
        var grammar = try value("--grammar-file").map { try String(contentsOfFile: $0, encoding: .utf8) }
        if let toolsPath = value("--tools-file") {
            let data = try Data(contentsOf: URL(fileURLWithPath: toolsPath))
            let tools = try JSONDecoder().decode([LocalAITool].self, from: data)
            grammar = await LocalAITools.grammar(for: tools)
            system = await LocalAITools.plannerSystem
            prompt = "Available tools:\n" + String(decoding: data, as: UTF8.self) + "\nUSER request:\n" + prompt
        }
        let metrics = try await LocalAIEngine.shared.generate(model: URL(fileURLWithPath: path),
            projector: value("--projector").map { URL(fileURLWithPath: $0) },
            request: LocalAIRequest(system: system,
                prompt: prompt, image: image,
                maximumTokens: UInt32(value("--tokens") ?? "128") ?? 128,
                grammar: grammar),
            useGPU: !arguments.contains("--cpu"), onText: { output.set($0) })
        struct Answer: Encodable { let output: String; let metrics: LocalAIMetrics }
        var followUp: Answer?
        if let question = value("--follow-up") {
            let next = Output()
            let nextMetrics = try await LocalAIEngine.shared.generate(model: URL(fileURLWithPath: path),
                request: .init(system: system, prompt: question, maximumTokens: 128,
                    history: [.init(isUser: true, content: prompt), .init(isUser: false, content: output.text)]),
                useGPU: !arguments.contains("--cpu"), onText: { next.set($0) })
            followUp = .init(output: next.text, metrics: nextMetrics)
        }
        struct Report: Encodable { let output: String; let metrics: LocalAIMetrics; let followUp: Answer? }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(Report(output: output.text, metrics: metrics, followUp: followUp)), as: UTF8.self))
        await LocalAIEngine.shared.unload()
    }
}
