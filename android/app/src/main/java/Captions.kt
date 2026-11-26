package app.caption

import android.graphics.Color
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.Translator
import com.google.mlkit.nl.translate.TranslatorOptions
import java.util.UUID

enum class Direction(val code: String, val source: String, val target: String) {
    ZH_KO("zh-ko", TranslateLanguage.CHINESE, TranslateLanguage.KOREAN),
    KO_ZH("ko-zh", TranslateLanguage.KOREAN, TranslateLanguage.CHINESE);

    companion object {
        /** 한글이 있으면 한국어, 그 밖에는 중국어로 봅니다. */
        fun of(text: String): Direction =
            if (text.any { it in '가'..'힣' || it in '㄰'..'㆏' }) KO_ZH else ZH_KO
    }
}

/** requestId는 봇이 번역을 돌려받으려고 붙인 번호입니다. */
class Caption(val original: String, val speaker: String?, val requestId: String? = null) {
    val id: String = UUID.randomUUID().toString()
    val direction = Direction.of(original)
    var translated: String? = null
    var failure: String? = null
}

/** 같은 사람은 항상 같은 색으로 표시합니다. */
fun speakerColor(speaker: String): Int {
    val palette = intArrayOf(
        Color.CYAN,
        Color.GREEN,
        Color.rgb(255, 159, 10),
        Color.rgb(255, 55, 95),
        Color.YELLOW,
    )
    return palette[speaker.sumOf { it.code } % palette.size]
}

/** ML Kit 기기 내 번역. 언어 모델은 처음 한 번 내려받습니다. */
class DeviceTranslator {
    private val translators = mutableMapOf<Direction, Translator>()

    private fun translator(direction: Direction): Translator =
        translators.getOrPut(direction) {
            Translation.getClient(
                TranslatorOptions.Builder()
                    .setSourceLanguage(direction.source)
                    .setTargetLanguage(direction.target)
                    .build()
            )
        }

    /** 두 방향의 언어 모델을 준비합니다. */
    fun prepare(onStatus: (String) -> Unit) {
        onStatus("언어 모델 준비 중 (처음에는 내려받습니다)")
        val conditions = DownloadConditions.Builder().build()
        translator(Direction.ZH_KO).downloadModelIfNeeded(conditions)
            .onSuccessTask { _ -> translator(Direction.KO_ZH).downloadModelIfNeeded(conditions) }
            .addOnSuccessListener { onStatus("언어 모델 준비됨 (기기 내 번역 가능)") }
            .addOnFailureListener { onStatus("언어 모델 준비 실패. 인터넷 연결 후 다시 시도하세요") }
    }

    fun translate(caption: Caption, onDone: (Caption) -> Unit) {
        val translator = translator(caption.direction)
        translator.downloadModelIfNeeded(DownloadConditions.Builder().build())
            .onSuccessTask { _ -> translator.translate(caption.original) }
            .addOnSuccessListener { text ->
                caption.translated = text
                caption.failure = null
                onDone(caption)
            }
            .addOnFailureListener { error ->
                caption.failure = "번역 실패: ${error.localizedMessage}"
                onDone(caption)
            }
    }

    fun close() {
        translators.values.forEach { it.close() }
        translators.clear()
    }
}
