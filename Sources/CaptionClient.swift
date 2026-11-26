import Foundation
import Observation

/// 서브컴의 자막 서버에 접속해 문장을 받아옵니다. 끊기면 다시 연결합니다.
@MainActor
@Observable
final class CaptionClient {
    private(set) var status = "서브컴에 연결 안 됨"
    private(set) var isConnected = false

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    /// 번역 결과를 서브컴으로 보낼지 여부. 자막 보기 모드에서는 끕니다.
    @ObservationIgnored var isForwardingEnabled = true

    /// 본 PC의 수신 앱에 전달할 번역 결과. 형식은 서버의 OVERLAY.md에 있습니다.
    private struct OverlayMessage: Encodable {
        let type: String
        let id: String
        let speaker: String?
        let original: String
        let text: String
        let direction: String
    }

    private struct Message: Decodable {
        let type: String
        let speaker: String?
        let text: String?
        let message: String?
    }

    typealias CaptionHandler = @MainActor (_ text: String, _ speaker: String?) -> Void

    func connect(address: String, password: String, onCaption: @escaping CaptionHandler) {
        disconnect()

        var host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.contains(":") { host += ":8765" }
        guard let url = URL(string: "ws://\(host)"), url.host != nil else {
            status = "주소 형식이 잘못되었습니다"
            return
        }

        var request = URLRequest(url: url)
        request.setValue(password, forHTTPHeaderField: "X-App-Password")
        request.timeoutInterval = 40

        loop = Task { await run(request, onCaption) }
    }

    func disconnect() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        isConnected = false
        status = "서브컴에 연결 안 됨"
    }

    /// 번역이 끝난 자막을 서브컴으로 보냅니다. 연결되지 않았으면 보내지 않습니다.
    func send(_ caption: Caption) {
        guard isConnected, isForwardingEnabled, let socket, let text = caption.translated else { return }
        let message = OverlayMessage(
            type: "translation",
            id: caption.id.uuidString,
            speaker: caption.speaker,
            original: caption.original,
            text: text,
            direction: caption.direction == .koreanToChinese ? "ko-zh" : "zh-ko"
        )
        guard let data = try? JSONEncoder().encode(message),
              let json = String(data: data, encoding: .utf8)
        else { return }
        // 전송에 실패하면 수신 쪽 재연결에 맡기고 넘어갑니다.
        socket.send(.string(json)) { _ in }
    }

    private func run(_ request: URLRequest, _ onCaption: CaptionHandler) async {
        while !Task.isCancelled {
            status = "서브컴에 연결 중"
            let current = URLSession.shared.webSocketTask(with: request)
            socket = current
            current.resume()

            do {
                while true {
                    let received = try await current.receive()
                    if Task.isCancelled { return }
                    guard case .string(let json) = received,
                          let message = try? JSONDecoder().decode(Message.self, from: Data(json.utf8))
                    else { continue }

                    switch message.type {
                    case "hello":
                        isConnected = true
                        status = "서브컴에 연결됨"
                    case "caption":
                        if let text = message.text { onCaption(text, message.speaker) }
                    case "error":
                        // 비밀번호 오류 등은 다시 시도하지 않습니다.
                        isConnected = false
                        status = message.message ?? "서브컴이 연결을 거부했습니다"
                        current.cancel(with: .normalClosure, reason: nil)
                        return
                    default:
                        break
                    }
                }
            } catch {
                current.cancel(with: .goingAway, reason: nil)
            }

            if Task.isCancelled { return }
            isConnected = false
            status = "연결 끊김, 3초 후 다시 연결"
            try? await Task.sleep(for: .seconds(3))
        }
    }
}
