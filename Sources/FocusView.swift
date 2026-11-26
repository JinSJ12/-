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
    @State var isHistoryOpen = false

    /// 번역이 끝난 자막. 번역 중인 문장은 끝난 뒤에 올라옵니다.
    private var finished: [Caption] {
        captions.filter { $0.translated != nil || $0.failure != nil }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ZStack(alignment: .bottom) {
                currentCaption
                    .padding(.horizontal, 24)
                    .padding(.bottom, 36) // 내역 손잡이 자리
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 내역은 평소에 숨어 있고, 열면 화면 전체를 덮으며 올라옵니다.
                if isHistoryOpen {
                    historyPanel
                        .transition(.move(edge: .bottom))
                        .zIndex(1)
                } else {
                    historyHandle
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showsControls.toggle() }
        .overlay(alignment: .top) {
            if showsControls {
                controls
            } else if !isConnected && !isHistoryOpen {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        // 자막 보기에 들어올 때와 새 자막이 올 때 화면 꺼짐 방지를 다시 적용합니다.
        .onAppear { ScreenAwake.enable() }
        .onChange(of: captions.last?.id) { ScreenAwake.enable() }
    }

    @ViewBuilder
    private var currentCaption: some View {
        if let latest = finished.last {
            line(latest, size: fontSize, maxLines: showsOriginal ? 3 : 4)
        } else {
            Text("자막을 기다리는 중\n화면을 누르면 메뉴가 나옵니다")
                .font(.title2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var historyHandle: some View {
        Button {
            setHistory(open: true)
        } label: {
            Label("내역", systemImage: "chevron.up")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 4)
    }

    private var historyPanel: some View {
        VStack(spacing: 0) {
            Button {
                setHistory(open: false)
            } label: {
                Label("내역 닫기", systemImage: "chevron.down")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ScrollView {
                VStack(spacing: 12) {
                    if finished.isEmpty {
                        Text("아직 자막이 없습니다")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(finished) { caption in
                        historyRow(caption)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            // 열면 최신 자막부터 보여줍니다.
            .defaultScrollAnchor(.bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Color(white: 0.12).ignoresSafeArea() }
        .contentShape(Rectangle())
        .onTapGesture {} // 내역 창을 눌러도 메뉴가 열리지 않게 합니다.
    }

    private func setHistory(open: Bool) {
        showsControls = false
        withAnimation { isHistoryOpen = open }
    }

    private func historyRow(_ caption: Caption) -> some View {
        VStack(spacing: 2) {
            if showsOriginal {
                Text(caption.original)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let speaker = caption.speaker {
                    Text(speaker)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(speakerColor(speaker))
                }
                Text(caption.translated ?? caption.failure ?? "")
                    .font(.body)
                    .foregroundStyle(caption.translated == nil ? Color.red : Color.white)
            }
        }
        .multilineTextAlignment(.center)
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
