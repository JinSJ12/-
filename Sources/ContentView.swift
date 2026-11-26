import SwiftUI
import Translation
import UIKit

struct ContentView: View {
    @State private var model = CaptionModel()
    @State private var input = ""
    @State private var configuration: TranslationSession.Configuration?
    @State private var languageStatus = "언어팩 확인 중"
    @Environment(\.scenePhase) private var scenePhase

    private let source = Locale.Language(identifier: "zh-Hans")
    private let target = Locale.Language(identifier: "ko")

    private let samples = [
        "右边有敌人",
        "等一下，我马上过去",
        "快来帮我",
        "撤退！撤退！",
        "打得不错",
    ]

    var body: some View {
        VStack(spacing: 12) {
            header
            captionList
            sampleButtons
            inputRow
        }
        .padding(.vertical, 8)
        .translationTask(configuration) { session in
            // 언어팩이 없으면 여기서 다운로드 안내가 나타납니다.
            try? await session.prepareTranslation()
            await refreshStatus()
            await model.translate(with: session)
        }
        .onAppear {
            if configuration == nil {
                configuration = .init(source: source, target: target)
            }
            // 앱을 보고 있는 동안 화면이 꺼지지 않게 합니다.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onChange(of: scenePhase) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = (phase == .active)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("중국어 → 한국어").font(.headline)
                Text(languageStatus).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("다시 시도") { configuration?.invalidate() }
            Button("지우기") { model.clear() }
        }
        .padding(.horizontal)
    }

    private var captionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(model.captions) { caption in
                        CaptionRow(caption: caption).id(caption.id)
                    }
                }
                .padding(.horizontal)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.captions.last?.id) { scrollToBottom(proxy) }
            .onChange(of: model.captions.last?.translated) { scrollToBottom(proxy) }
        }
    }

    private var sampleButtons: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(samples, id: \.self) { sample in
                    Button(sample) { model.add(sample) }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal)
        }
    }

    private var inputRow: some View {
        HStack {
            TextField("중국어 문장 입력", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
            Button("번역", action: send)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
    }

    private func send() {
        model.add(input)
        input = ""
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let id = model.captions.last?.id else { return }
        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
    }

    private func refreshStatus() async {
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed:
            languageStatus = "언어팩 설치됨 (기기 내 번역 가능)"
        case .supported:
            languageStatus = "언어팩 다운로드 필요"
        case .unsupported:
            languageStatus = "지원하지 않는 언어 조합"
        @unknown default:
            languageStatus = "언어팩 상태를 알 수 없음"
        }
    }
}

struct CaptionRow: View {
    let caption: Caption

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption.original)
                .font(.title3)
                .foregroundStyle(.secondary)

            if let translated = caption.translated {
                Text(translated)
                    .font(.system(size: 28, weight: .bold))
                if let seconds = caption.seconds {
                    Text(String(format: "%.2f초", seconds))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let failure = caption.failure {
                Text(failure).foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
