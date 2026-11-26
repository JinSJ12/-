import Foundation
import Observation
import Translation

struct Caption: Identifiable {
    let id = UUID()
    let original: String
    var translated: String?
    var failure: String?
    var seconds: Double?
}

/// 자막 목록을 관리하고, 들어온 순서대로 번역합니다.
/// 나중에 서브컴에서 받은 문장도 add(_:)로 넣으면 됩니다.
@MainActor
@Observable
final class CaptionModel {
    private(set) var captions: [Caption] = []

    @ObservationIgnored
    private var queue: AsyncStream<UUID>.Continuation?

    private let limit = 100

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let caption = Caption(original: trimmed)
        captions.append(caption)
        if captions.count > limit {
            captions.removeFirst(captions.count - limit)
        }
        queue?.yield(caption.id)
    }

    func clear() {
        captions.removeAll()
    }

    /// 번역 세션이 살아 있는 동안 계속 실행됩니다.
    func translate(with session: TranslationSession) async {
        for await id in makeQueue() {
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
    private func makeQueue() -> AsyncStream<UUID> {
        let (stream, continuation) = AsyncStream.makeStream(of: UUID.self)
        queue = continuation
        for caption in captions where caption.translated == nil {
            continuation.yield(caption.id)
        }
        return stream
    }

    private func update(_ id: UUID, _ change: (inout Caption) -> Void) {
        guard let index = captions.firstIndex(where: { $0.id == id }) else { return }
        change(&captions[index])
    }
}
