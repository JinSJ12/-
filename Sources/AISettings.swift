import SwiftUI

/// 아이폰 AI 의역을 켜고 끄고, 모델을 고르는 화면입니다.
struct AISettings: View {
    let paraphraser: AIParaphraser
    @Binding var isEnabled: Bool
    @Binding var model: AIModel
    @Binding var prefersApple: Bool
    // private으로 두면 다른 파일에서 이 화면을 만들 수 없습니다.
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("모델") {
                    Picker("모델", selection: $model) {
                        ForEach(AIModel.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .disabled(isEnabled)
                }

                Section {
                    Toggle("애플 번역을 크게 보기", isOn: $prefersApple)
                } footer: {
                    Text("AI가 뜻을 바꾸는 경우를 대비해, AI 의역은 작게 두고 애플 번역을 크게 볼 수 있습니다.")
                }

                Section {
                    Text(paraphraser.statusText)
                    if case .loading(let fraction) = paraphraser.state {
                        ProgressView(value: fraction)
                    }
                    if isEnabled {
                        Button("AI 의역 끄기", role: .destructive) {
                            isEnabled = false
                            paraphraser.stop()
                        }
                    } else {
                        Button("내려받고 켜기") {
                            isEnabled = true
                            paraphraser.start(model)
                        }
                    }
                } footer: {
                    Text("""
                    처음 켤 때 모델을 내려받으므로 Wi-Fi를 권합니다. 끝날 때까지 앱을 열어 두세요.
                    모델을 바꾸려면 먼저 끄세요. 발열과 배터리 소모가 늘어날 수 있습니다.
                    """)
                }
            }
            .navigationTitle("AI 의역")
            .toolbar {
                Button("닫기") { dismiss() }
            }
        }
    }
}
