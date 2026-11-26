import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "app.caption"
    compileSdk = 35

    defaultConfig {
        applicationId = "local.captiontranslator.app"
        minSdk = 26
        targetSdk = 34
        versionCode = (System.getenv("GITHUB_RUN_NUMBER") ?: "1").toInt()
        versionName = "1.0"
        // 갤럭시 탭 S7+를 비롯한 최근 기기용. 설치 파일 크기를 줄입니다.
        ndk { abiFilters += "arm64-v8a" }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    implementation("com.google.mlkit:translate:17.0.3") // 기기 내 번역
    implementation("com.squareup.okhttp3:okhttp:4.12.0") // 서브컴 연결(WebSocket)과 모델 내려받기
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.20.0") // 기기 내 AI 의역
}
