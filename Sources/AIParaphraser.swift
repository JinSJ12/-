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
    case qwen3
    case gemma3n

    var id: String { rawValue }

    var title: String {
        switch self {
        case .qwen35: "Qwen3.5 2B (약 1.8GB)"
        case .qwen3: "Qwen3 1.7B (약 1GB, 가벼움)"
        case .gemma3n: "Gemma 3n E2B (약 2.6GB, 무거움)"
        }
    }

    var configuration: ModelConfiguration {
        switch self {
        case .qwen35: LLMRegistry.qwen3_5_2b_4bit
        case .qwen3: LLMRegistry.qwen3_1_7b_4bit
        case .gemma3n: LLMRegistry.gemma3n_E2B_it_lm_4bit
        }
    }

    /// Qwen의 "생각하기" 기능은 느려서 끕니다.
    var disablesThinking: Bool { self != .gemma3n }
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

    func generate(_ text: String, instructions: String) async throws -> String? {
        guard let container, let model else { return nil }
        // 문장마다 새 대화를 만들어 이전 문장이 쌓이지 않게 합니다.
        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(maxTokens: 120, temperature: 0.3),
            additionalContext: model.disablesThinking ? ["enable_thinking": false] : nil
        )
        return try await session.respond(to: text)
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
        jobs.append(Job(id: caption.id, text: caption.original, direction: caption.direction))
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
                    job.text, instructions: Self.instructions(for: job.direction))
                if Task.isCancelled { return }
                if let raw, let result = Self.clean(raw, source: job.text, direction: job.direction) {
                    onResult?(job.id, result, Date().timeIntervalSince(start))
                }
            }
            if !Task.isCancelled { worker = nil }
        }
    }

    private static func instructions(for direction: TranslationDirection) -> String {
        switch direction {
        case .chineseToKorean:
            """
            너는 게임 음성 채팅 통역사야. 중국어 문장을 한국 친구끼리 말하는 자연스러운 반말 한국어로 의역해.
            원래의 뜻과 말투를 살려. 번역문 한 줄만 출력하고 설명은 하지 마.
            예) 快来帮我 → 빨리 와서 도와줘
            예) 你干嘛呢 → 너 뭐 해?
            """
        case .koreanToChinese:
            """
            你是游戏语音聊天的翻译。把韩语句子意译成中国朋友之间说话那样自然、口语化的简体中文。
            保留原来的意思和语气。只输出一行译文，不要解释。
            例）나 먼저 갈게 → 我先走啦
            例）그거 완전 웃겼어 → 那个太好笑了
            """
        }
    }

    /// 모델 출력에서 번역문만 남깁니다. 결과가 이상하면 nil.
    static func clean(_ raw: String, source: String, direction: TranslationDirection) -> String? {
        var text = raw
        if let end = text.range(of: "</think>") {
            text = String(text[end.upperBound...])
        }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first(where: { !$0.isEmpty }) else { return nil }
        let result = first.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”「」 "))

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
