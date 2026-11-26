import SwiftUI
import Translation
import UIKit

struct ContentView: View {
    @State private var model = CaptionModel()
    @State private var input = ""
    @State private var configuration: TranslationSession.Configuration?
    @State private var reverseConfiguration: TranslationSession.Configuration?
    @State private var languageStatus = "언어팩 확인 중"
    @State private var client = CaptionClient()
    @State private var showingSettings = false
    @State private var isFocusMode = false
    @AppStorage("serverAddress") private var serverAddress = ""
    @AppStorage("serverPassword") private var serverPassword = ""
    @Environment(\.scenePhase) private var scenePhase

    private let samples = [
        "右边有敌人",
        "等一下，我马上过去",
        "快来帮我",
        "잠깐만, 바로 갈게",
        "오른쪽 조심해",
        "撤退！撤退！",
        "打得不错",
    ]

    var body: some View {
        // 번역 작업은 바깥 ZStack에 붙여, 화면을 바꿔도 계속 실행되게 합니다.
        ZStack {
            if isFocusMode {
                FocusCaptionView(
                    captions: model.captions,
                    status: client.status,
                    isConnected: client.isConnected,
                    close: { setFocusMode(false) }
                )
            } else {
                mainScreen
            }
        }
        .sheet(isPresented: $showingSettings) {
            ConnectionSettings(
                address: $serverAddress,
                password: $serverPassword,
                connect: connect,
                disconnect: { client.disconnect() }
            )
        }
        .translationTask(configuration) { session in
            // 언어팩이 없으면 여기서 다운로드 안내가 나타납니다.
            try? await session.prepareTranslation()
            await refreshStatus()
            // 다운로드 안내가 겹치지 않게, 한국어 → 중국어는 준비가 끝난 뒤에 시작합니다.
            if reverseConfiguration == nil {
                let direction = TranslationDirection.koreanToChinese
                reverseConfiguration = .init(source: direction.source, target: direction.target)
            }
            await model.translate(with: session, direction: .chineseToKorean)
        }
        .background {
            Color.clear.translationTask(reverseConfiguration) { session in
                await model.translate(with: session, direction: .koreanToChinese)
            }
        }
        .onAppear {
            if configuration == nil {
                let direction = TranslationDirection.chineseToKorean
                configuration = .init(source: direction.source, target: direction.target)
                connect() // 저장된 주소가 있으면 바로 연결합니다.
            }
            // 번역이 끝나면 서브컴으로 보내, 본 PC의 수신 앱이 받을 수 있게 합니다.
            let sender = client
            model.onTranslated = { caption in sender.send(caption) }
            ScreenAwake.enable()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                ScreenAwake.enable()
            } else {
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    private var mainScreen: some View {
        VStack(spacing: 12) {
            header
            Button {
                setFocusMode(true)
            } label: {
                Label("자막 보기 모드", systemImage: "rectangle.landscape.rotate")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            captionList
            // 예문은 서브컴에 연결되지 않았을 때만 보여줍니다. 입력창은 항상 사용합니다.
            if !client.isConnected {
                sampleButtons
            }
            inputRow
        }
        .padding(.vertical, 8)
    }

    private func setFocusMode(_ enabled: Bool) {
        isFocusMode = enabled
        // 본 PC로 보내는 것은 기본 화면에서만 합니다.
        client.isForwardingEnabled = !enabled
        Orientation.set(enabled ? .landscape : .portrait)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("중국어 ↔ 한국어").font(.headline)
                Text(languageStatus).font(.caption).foregroundStyle(.secondary)
                Text(client.status)
                    .font(.caption)
                    .foregroundStyle(client.isConnected ? Color.green : Color.orange)
            }
            Spacer()
            Button("연결") { showingSettings = true }
                .buttonStyle(.bordered)
            Menu {
                Button("번역 다시 시도") {
                    configuration?.invalidate()
                    reverseConfiguration?.invalidate()
                }
                Button("자막 지우기", role: .destructive) { model.clear() }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title2)
            }
        }
        .padding(.horizontal)
    }

    private func connect() {
        guard !serverAddress.isEmpty, !serverPassword.isEmpty else { return }
        client.connect(address: serverAddress, password: serverPassword) { text, speaker in
            model.add(text, speaker: speaker)
        }
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
            // 자막 보기에서 돌아오면 최신 자막부터 보여줍니다.
            .onAppear { scrollToBottom(proxy) }
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
            TextField("한국어 또는 중국어 입력", text: $input)
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
        let direction = TranslationDirection.chineseToKorean
        switch await LanguageAvailability().status(from: direction.source, to: direction.target) {
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
            if let speaker = caption.speaker {
                Text(speaker)
                    .font(.headline)
                    .foregroundStyle(speakerColor(speaker))
            }

            Text(caption.original)
                .font(.title3)
                .foregroundStyle(.secondary)

            if let translated = caption.translated {
                Text(translated)
                    .font(.system(size: 28, weight: .bold))
                // 중국어 번역문은 디스코드 채팅에 붙여 넣을 수 있게 복사 버튼을 둡니다.
                if caption.direction == .koreanToChinese {
                    Button {
                        UIPasteboard.general.string = translated
                    } label: {
                        Label("중국어 복사", systemImage: "doc.on.doc")
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
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

/// 같은 사람은 항상 같은 색으로 표시합니다.
func speakerColor(_ speaker: String) -> Color {
    let palette: [Color] = [.cyan, .green, .orange, .pink, .yellow]
    let sum = speaker.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    return palette[sum % palette.count]
}

struct ConnectionSettings: View {
    @Binding var address: String
    @Binding var password: String
    let connect: @MainActor () -> Void
    let disconnect: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("서브컴") {
                    TextField("IP 주소 (예: 192.168.0.10)", text: $address)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("앱 비밀번호", text: $password)
                }
                Button("연결") {
                    connect()
                    dismiss()
                }
                .disabled(address.isEmpty || password.isEmpty)
                Button("연결 끊기", role: .destructive) {
                    disconnect()
                    dismiss()
                }
            }
            .navigationTitle("서브컴 연결")
        }
    }
}
