plugins {
    // 8.7.3에서는 AI 라이브러리 변환이 실패해 더 새 버전을 씁니다.
    id("com.android.application") version "8.13.0" apply false
    // AI 실행 라이브러리(LiteRT-LM)를 읽으려면 Kotlin 2.3 이상이 필요합니다.
    id("org.jetbrains.kotlin.android") version "2.4.21" apply false
}
