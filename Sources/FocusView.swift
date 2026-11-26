import SwiftUI

/// 번역문을 가운데에 크게 보여주는 자막 보기 화면입니다. 화면을 누르면 메뉴가 나옵니다.
struct FocusCaptionView: View {
    let captions: [Caption]
    let status: String
    let isConnected: Bool
    let close: @MainActor () -> Void

    @State var showsControls = false
    @AppStorage("focusFontSize") var fontSize = 48.0
    @AppStorage("focusShowsOriginal") var showsOriginal = false

    /// 번역이 끝난 최근 자막 두 개. 번역 중인 문장은 끝난 뒤에 올라옵니다.
    private var recent: [Caption] {
        Array(captions.filter { $0.translated != nil || $0.failure != nil }.suffix(2))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 20) {
                if let latest = recent.last {
                    if recent.count > 1 {
                        line(recent[0], size: fontSize * 0.55, maxLines: 2)
                            .opacity(0.45)
                    }
                    line(latest, size: fontSize, maxLines: showsOriginal ? 3 : 4)
                        .layoutPriority(1)
                } else {
                    Text("자막을 기다리는 중\n화면을 누르면 메뉴가 나옵니다")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(Rectangle())
        .onTapGesture { showsControls.toggle() }
        .overlay(alignment: .top) {
            if showsControls {
                controls
            } else if !isConnected {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    private func line(_ caption: Caption, size: Double, maxLines: Int) -> some View {
        VStack(spacing: 6) {
            if let speaker = caption.speaker {
                Text(speaker)
                    .font(.system(size: max(size * 0.4, 15), weight: .semibold))
                    .foregroundStyle(speakerColor(speaker))
            }
            if showsOriginal {
                Text(caption.original)
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
            }
            Text(caption.translated ?? caption.failure ?? "")
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(caption.translated == nil ? Color.red : Color.white)
                .lineLimit(maxLines)
                .minimumScaleFactor(0.4)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button("닫기") { close() }
            Spacer()
            Button("글자 −") { fontSize = max(fontSize - 8, 24) }
            Button("글자 +") { fontSize = min(fontSize + 8, 80) }
            Button(showsOriginal ? "원문 숨기기" : "원문 보기") { showsOriginal.toggle() }
        }
        .buttonStyle(.bordered)
        .padding(10)
        .background(.black.opacity(0.85))
    }
}
