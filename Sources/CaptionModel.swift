import Foundation
import Observation
import Translation

enum TranslationDirection: Hashable {
    case chineseToKorean
    case koreanToChinese

    /// 한글이 있으면 한국어, 그 밖에는 중국어로 봅니다.
    init(of text: String) {
        let hasHangul = text.unicodeScalars.contains { scalar in
            (0xAC00...0xD7A3).contains(scalar.value) || (0x3130...0x318F).contains(scalar.value)
        }
        self = hasHangul ? .koreanToChinese : .chineseToKorean
    }

    var source: Locale.Language {
        Locale.Language(identifier: self == .koreanToChinese ? "ko" : "zh-Hans")
    }

    var target: Locale.Language {
        Locale.Language(identifier: self == .koreanToChinese ? "zh-Hans" : "ko")
    }
}

struct Caption: Identifiable {
    let id = UUID()
    let original: String
    var speaker: String?
    /// 봇이 번역을 돌려받으려고 붙인 번호
    var requestID: String?
    var translated: String?
    var failure: String?
    var seconds: Double?
    /// 아이폰 AI의 의역과 걸린 시간
    var refined: String?
    var refinedSeconds: Double?

    /// 의역이 있어도 애플 번역을 크게 볼지 여부
    var prefersApple = false

    var direction: TranslationDirection { TranslationDirection(of: original) }

    /// 화면에 크게 보여줄 번역문
    var best: String? { prefersApple ? translated ?? refined : refined ?? translated }

    /// 번역이 둘 다 있을 때, 비교용으로 작게 보여줄 문장
    var comparison: String? {
        guard let translated, let refined else { return nil }
        return prefersApple ? "AI: \(refined)" : "애플: \(translated)"
    }
}

/// 자막 목록을 관리하고, 들어온 순서대로 번역합니다.
/// 서브컴에서 받은 문장과 직접 입력한 문장이 모두 add(_:speaker:)로 들어옵니다.
@MainActor
@Observable
final class CaptionModel {
    private(set) var captions: [Caption] = []

    @ObservationIgnored
    private var queues: [TranslationDirection: AsyncStream<UUID>.Continuation] = [:]

    /// 번역이나 의역에 성공할 때마다 호출됩니다.
    @ObservationIgnored
    var onTranslated: (@MainActor (Caption) -> Void)?

    /// 애플 번역이 끝나면(실패해도) 한 번 호출됩니다. AI 의역을 시작할 때 씁니다.
    @ObservationIgnored
    var onDraft: (@MainActor (Caption) -> Void)?

    /// 바꾸면 이미 있는 자막에도 바로 적용합니다.
    var prefersApple = false {
        didSet {
            for index in captions.indices {
                captions[index].prefersApple = prefersApple
            }
        }
    }

    private let limit = 100

    func add(_ text: String, speaker: String? = nil, requestID: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var caption = Caption(original: trimmed, speaker: speaker, requestID: requestID)
        caption.prefersApple = prefersApple
        captions.append(caption)
        if captions.count > limit {
            captions.removeFirst(captions.count - limit)
        }
        queues[caption.direction]?.yield(caption.id)
    }

    /// 해당 자막 바로 앞에 나온 말(원문). AI가 뜻을 이해하는 데 씁니다.
    func context(before id: UUID, count: Int = 2) -> [String] {
        guard let index = captions.firstIndex(where: { $0.id == id }) else { return [] }
        return captions[..<index].suffix(count).map(\.original)
    }

    /// 방금 보여준 번역문과 같은 문장인지 확인합니다. 번역 결과가 되돌아오는 것을 거를 때 씁니다.
    func isRecentTranslation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return captions.suffix(10).contains { $0.translated == trimmed || $0.refined == trimmed }
    }

    func setRefined(_ id: UUID, text: String, seconds: Double) {
        update(id) {
            $0.refined = text
            $0.refinedSeconds = seconds
        }
        if let done = captions.first(where: { $0.id == id }) {
            onTranslated?(done)
        }
    }

    func clear() {
        captions.removeAll()
    }

    /// 번역 세션이 살아 있는 동안 계속 실행됩니다. 번역 방향마다 세션이 하나씩 있습니다.
    func translate(with session: TranslationSession, direction: TranslationDirection) async {
        for await id in makeQueue(for: direction) {
            guard let text = captions.first(where: { $0.id == id })?.original else { continue }
            let start = Date()
            do {
                let response = try await session.translate(text)
                update(id) {
                    $0.translated = response.targetText
                    $0.failure = nil
                    $0.seconds = Date().timeIntervalSince(start)
                }
                if let done = captions.first(where: { $0.id == id }) {
                    onTranslated?(done)
                    onDraft?(done)
                }
            } catch {
                if Task.isCancelled { return }
                update(id) { $0.failure = "번역 실패: \(error.localizedDescription)" }
                // 번역 전용 AI 모델은 애플 번역 없이도 번역할 수 있습니다.
                if let failed = captions.first(where: { $0.id == id }) {
                    onDraft?(failed)
                }
            }
        }
    }

    /// 새 대기열을 만들고, 아직 번역하지 못한 문장을 다시 넣습니다.
    private func makeQueue(for direction: TranslationDirection) -> AsyncStream<UUID> {
        let (stream, continuation) = AsyncStream.makeStream(of: UUID.self)
        queues[direction] = continuation
        for caption in captions where caption.translated == nil && caption.direction == direction {
            continuation.yield(caption.id)
        }
        return stream
    }

    private func update(_ id: UUID, _ change: (inout Caption) -> Void) {
        guard let index = captions.firstIndex(where: { $0.id == id }) else { return }
        change(&captions[index])
    }
}
