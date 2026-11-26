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
    var translated: String?
    var failure: String?
    var seconds: Double?

    var direction: TranslationDirection { TranslationDirection(of: original) }
}

/// 자막 목록을 관리하고, 들어온 순서대로 번역합니다.
/// 서브컴에서 받은 문장과 직접 입력한 문장이 모두 add(_:speaker:)로 들어옵니다.
@MainActor
@Observable
final class CaptionModel {
    private(set) var captions: [Caption] = []

    @ObservationIgnored
    private var queues: [TranslationDirection: AsyncStream<UUID>.Continuation] = [:]

    private let limit = 100

    func add(_ text: String, speaker: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let caption = Caption(original: trimmed, speaker: speaker)
        captions.append(caption)
        if captions.count > limit {
            captions.removeFirst(captions.count - limit)
        }
        queues[caption.direction]?.yield(caption.id)
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
            } catch {
                if Task.isCancelled { return }
                update(id) { $0.failure = "번역 실패: \(error.localizedDescription)" }
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
