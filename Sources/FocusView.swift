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
    @State var isHistoryExpanded = false

    /// 번역이 끝난 자막. 번역 중인 문장은 끝난 뒤에 올라옵니다.
    private var finished: [Caption] {
        captions.filter { $0.translated != nil || $0.failure != nil }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geometry in
                VStack(spacing: 0) {
                    currentCaption
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    historyPanel
                        .frame(height: isHistoryExpanded ? geometry.size.height * 0.65 : 88)
                }
            }
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

    /// 화면 아래에 항상 보이는 지난 자막. 누르면 크게 펼치거나 접습니다.
    private var historyPanel: some View {
        // 지금 크게 보이는 최신 자막은 내역에서 뺍니다.
        let history = Array(finished.dropLast())

        return VStack(spacing: 4) {
            Label(
                isHistoryExpanded ? "내역 접기" : "내역 펼치기",
                systemImage: isHistoryExpanded ? "chevron.down" : "chevron.up"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if history.isEmpty {
                            Text("지난 자막이 여기에 쌓입니다")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(history) { caption in
                            historyRow(caption).id(caption.id)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .onAppear { scrollToLatest(proxy, in: history) }
                .onChange(of: history.last?.id) {
                    // 펼쳐서 읽는 중에는 화면을 마음대로 옮기지 않습니다.
                    if !isHistoryExpanded { scrollToLatest(proxy, in: history) }
                }
                .onChange(of: isHistoryExpanded) {
                    scrollToLatest(proxy, in: Array(finished.dropLast()))
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.08))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation { isHistoryExpanded.toggle() }
        }
    }

    private func historyRow(_ caption: Caption) -> some View {
        VStack(spacing: 1) {
            if showsOriginal && isHistoryExpanded {
                Text(caption.original)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let speaker = caption.speaker {
                    Text(speaker)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(speakerColor(speaker))
                }
                Text(caption.translated ?? caption.failure ?? "")
                    .font(.subheadline)
                    .foregroundStyle(caption.translated == nil ? Color.red : Color.white.opacity(0.75))
            }
        }
        .multilineTextAlignment(.center)
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy, in history: [Caption]) {
        guard let id = history.last?.id else { return }
        proxy.scrollTo(id, anchor: .bottom)
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
