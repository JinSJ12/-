import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Observation
import Tokenizers

/// 아이폰 안에서 실행할 수 있는 의역 모델 후보. 용량은 처음 내려받는 크기입니다.
enum AIModel: String, CaseIterable, Identifiable {
    case qwen35
    case hymt8
    case hymt4
    case translategemma
    case qwen3

    var id: String { rawValue }

    var title: String {
        switch self {
        case .qwen35: "Qwen3.5 2B (약 1.7GB, 범용)"
        case .hymt8: "Hy-MT2 1.8B 8비트 (약 1.9GB, 번역 전용)"
        case .hymt4: "Hy-MT2 1.8B 4비트 (약 1GB, 번역 전용)"
        case .translategemma: "TranslateGemma 4B (약 2.2GB, 번역 전용, 무거움)"
        case .qwen3: "Qwen3 1.7B (약 1GB, 범용)"
        }
    }

    var configuration: ModelConfiguration {
        switch self {
        case .qwen35: LLMRegistry.qwen3_5_2b_4bit
        case .hymt8: ModelConfiguration(id: "mlx-community/Hy-MT2-1.8B-8bit")
        case .hymt4: ModelConfiguration(id: "mlx-community/Hy-MT2-1.8B-4bit")
        case .translategemma: LLMRegistry.translategemma_4b_it_4bit
        case .qwen3: LLMRegistry.qwen3_1_7b_4bit
        }
    }

    /// 모델마다 번역을 시키는 방법이 다릅니다. draft는 애플 번역입니다.
    /// 요청할 수 없으면 nil.
    func request(for text: String, draft: String?, direction: TranslationDirection) -> AIRequest? {
        // 뜻이 바뀌지 않도록 모든 모델에서 매번 같은 답이 나오게(temperature 0) 합니다.
        var parameters = GenerateParameters(maxTokens: 120, temperature: 0)

        switch self {
        case .qwen35, .qwen3:
            // 작은 범용 모델은 직접 번역하면 내용을 지어내므로, 애플 번역의 말투만 다듬게 합니다.
            guard let draft else { return nil }
            return AIRequest(
                instructions: Self.polishInstructions(for: direction),
                prompt: direction == .chineseToKorean
                    ? "원문: \(text)\n초벌: \(draft)"
                    : "原文：\(text)\n初稿：\(draft)",
                parameters: parameters,
                // Qwen의 "생각하기" 기능은 느려서 끕니다.
                context: ["enable_thinking": false]
            )
        case .hymt8, .hymt4:
            // 번역 전용 모델은 별도의 지시 없이 한 메시지로 요청합니다.
            parameters.repetitionPenalty = 1.05
            let language = direction == .chineseToKorean ? "韩语" : "中文"
            return AIRequest(
                instructions: nil,
                prompt: "将以下文本翻译成\(language)，使用朋友之间聊天的口语语气，"
                    + "注意只需要输出翻译后的结果，不要额外解释：\n\n\(text)",
                parameters: parameters,
                context: nil
            )
        case .translategemma:
            // 언어 코드만 받는 모델이라 말투는 지정할 수 없습니다.
            let codes = direction == .chineseToKorean ? ("zh", "ko") : ("ko", "zh")
            return AIRequest(
                instructions: nil,
                prompt: text,
                parameters: parameters,
                context: ["source_lang_code": codes.0, "target_lang_code": codes.1]
            )
        }
    }

    private static func polishInstructions(for direction: TranslationDirection) -> String {
        switch direction {
        case .chineseToKorean:
            """
            너는 번역문의 말투를 고치는 교정기야. 초벌 번역을 친구끼리 쓰는 반말로만 고쳐.
            뜻은 절대 더하거나 빼지 마. 고칠 것이 없으면 초벌을 그대로 출력해.
            고친 문장 한 줄만 출력해.
            예)
            원문: 你在做什么？
            초벌: 당신은 무엇을 하고 있습니까?
            답: 너 뭐 하고 있어?
            """
        case .koreanToChinese:
            """
            你是译文润色器。只把初稿改成朋友之间聊天的口语简体中文。
            绝对不要增加或删减意思。如果初稿已经自然，就原样输出。只输出一行。
            例）
            原文：지금 어디에 계세요?
            初稿：您现在在哪里？
            答：你现在在哪儿呢？
            """
        }
    }
}

/// 모델에 보낼 한 번의 번역 요청
struct AIRequest {
    let instructions: String?
    let prompt: String
    let parameters: GenerateParameters
    let context: [String: any Sendable]?
}

/// 모델을 불러오고 문장을 생성합니다. 화면이 멈추지 않도록 별도 actor에서 실행합니다.
private actor ModelRunner {
    private var container: ModelContainer?
    private var model: AIModel?
    private var latest = 0 // 늦게 끝난 이전 요청이 새 요청을 덮어쓰지 않게 하는 번호

    func load(
        _ model: AIModel,
        ticket: Int,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Bool {
        guard ticket > latest else { return false }
        latest = ticket
        container = nil

        let loaded = try await #huggingFaceLoadModelContainer(
            configuration: model.configuration,
            progress: .download { progress in onProgress(progress.fractionCompleted) }
        )
        guard ticket == latest else { return false }
        container = loaded
        self.model = model
        return true
    }

    func unload(ticket: Int) {
        guard ticket > latest else { return }
        latest = ticket
        container = nil
        model = nil
    }

    func generate(
        _ text: String,
        draft: String?,
        direction: TranslationDirection
    ) async throws -> String? {
        guard let container, let model,
              let request = model.request(for: text, draft: draft, direction: direction)
        else { return nil }
        // 문장마다 새 대화를 만들어 이전 문장이 쌓이지 않게 합니다.
        let session = ChatSession(
            container,
            instructions: request.instructions,
            generateParameters: request.parameters,
            additionalContext: request.context
        )
        return try await session.respond(to: request.prompt)
    }
}

/// 번역할 문장을 받아 아이폰 AI로 의역합니다. 실패하면 아무것도 바꾸지 않아 애플 번역이 남습니다.
@MainActor
@Observable
final class AIParaphraser {
    enum State: Equatable {
        case off
        case loading(Double)
        case ready
        case failed(String)
    }

    private(set) var state: State = .off

    /// 의역이 끝나면 (자막 ID, 의역문, 걸린 초)를 알립니다.
    @ObservationIgnored var onResult: (@MainActor (UUID, String, Double) -> Void)?

    private struct Job {
        let id: UUID
        let text: String
        let draft: String? // 애플 번역
        let direction: TranslationDirection
    }

    private static let loadingKey = "aiModelIsLoading"
    private static let maxWaiting = 3 // 밀리면 오래된 문장은 애플 번역만 둡니다.

    @ObservationIgnored private let runner = ModelRunner()
    @ObservationIgnored private var ticket = 0
    @ObservationIgnored private var jobs: [Job] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var isActive = true

    var statusText: String {
        switch state {
        case .off: "AI 의역 꺼짐"
        case .loading(let fraction):
            fraction < 1 ? "AI 모델 내려받는 중 \(Int(fraction * 100))%" : "AI 모델 불러오는 중"
        case .ready: "AI 의역 켜짐"
        case .failed(let reason): reason
        }
    }

    /// 앱이 모델을 불러오다 종료된 적이 있으면 true. 확인한 뒤에는 기록을 지웁니다.
    func consumeInterruptedLoad() -> Bool {
        let interrupted = UserDefaults.standard.bool(forKey: Self.loadingKey)
        UserDefaults.standard.set(false, forKey: Self.loadingKey)
        return interrupted
    }

    func start(_ model: AIModel) {
        cancelWork()
        ticket += 1
        let current = ticket
        state = .loading(0)
        UserDefaults.standard.set(true, forKey: Self.loadingKey)

        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor [weak self] in self?.updateProgress(fraction, ticket: current) }
        }
        Task {
            do {
                let loaded = try await runner.load(model, ticket: current, onProgress: report)
                guard loaded, current == ticket else { return }
                state = .ready
            } catch {
                guard current == ticket else { return }
                state = .failed("AI 모델 준비 실패: \(error.localizedDescription)")
            }
            UserDefaults.standard.set(false, forKey: Self.loadingKey)
        }
    }

    /// 모델을 내리고 끕니다. reason이 있으면 상태에 이유를 보여줍니다.
    func stop(reason: String? = nil) {
        cancelWork()
        ticket += 1
        let current = ticket
        state = reason.map { State.failed($0) } ?? .off
        UserDefaults.standard.set(false, forKey: Self.loadingKey)
        Task { await runner.unload(ticket: current) }
    }

    /// 앱이 화면에 없을 때 GPU를 쓰면 종료될 수 있어 작업을 멈춥니다.
    func setActive(_ active: Bool) {
        isActive = active
        if !active { cancelWork() }
    }

    func enqueue(_ caption: Caption) {
        guard state == .ready, isActive else { return }
        jobs.append(Job(
            id: caption.id,
            text: caption.original,
            draft: caption.translated,
            direction: caption.direction
        ))
        if jobs.count > Self.maxWaiting {
            jobs.removeFirst(jobs.count - Self.maxWaiting)
        }
        process()
    }

    private func updateProgress(_ fraction: Double, ticket: Int) {
        guard ticket == self.ticket, case .loading = state else { return }
        state = .loading(fraction)
    }

    private func cancelWork() {
        worker?.cancel()
        worker = nil
        jobs.removeAll()
    }

    private func process() {
        guard worker == nil else { return }
        worker = Task {
            while !Task.isCancelled, !jobs.isEmpty {
                let job = jobs.removeFirst()
                let start = Date()
                let raw = try? await runner.generate(
                    job.text, draft: job.draft, direction: job.direction)
                if Task.isCancelled { return }
                if let raw, let result = Self.clean(
                    raw, source: job.text, draft: job.draft, direction: job.direction) {
                    onResult?(job.id, result, Date().timeIntervalSince(start))
                }
            }
            if !Task.isCancelled { worker = nil }
        }
    }

    /// 모델 출력에서 번역문만 남깁니다. 결과가 이상하면 nil.
    static func clean(
        _ raw: String,
        source: String,
        draft: String?,
        direction: TranslationDirection
    ) -> String? {
        var text = raw
        if let end = text.range(of: "</think>") {
            text = String(text[end.upperBound...])
        }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard var first = lines.first(where: { !$0.isEmpty }) else { return nil }
        // 예시를 따라 붙인 머리말을 지웁니다.
        for label in ["답:", "답：", "答：", "答:"] where first.hasPrefix(label) {
            first = String(first.dropFirst(label.count))
        }
        let result = first.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”「」 "))

        // 애플 번역보다 훨씬 길면 내용을 덧붙인 것으로 보고 버립니다.
        if let draft, result.count > max(draft.count * 2, draft.count + 10) { return nil }

        guard !result.isEmpty,
              result.count <= max(60, source.count * 5),
              !result.contains("<think>"),
              !result.contains("→")
        else { return nil }

        let hasHangul = TranslationDirection(of: result) == .koreanToChinese
        let hasHan = result.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        switch direction {
        case .chineseToKorean: return hasHangul && !hasHan ? result : nil
        case .koreanToChinese: return hasHan && !hasHangul ? result : nil
        }
    }
}
