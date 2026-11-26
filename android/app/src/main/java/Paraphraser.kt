package app.caption

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.SamplerConfig
import com.google.ai.edge.litertlm.ThinkingConfig
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** 태블릿 안에서 실행할 수 있는 의역 모델 후보 (Hugging Face의 litert-community). */
enum class AiModel(val title: String, val repo: String, val file: String) {
    GEMMA(
        "Gemma 4 E2B (약 2.6GB, 품질 우선)",
        "litert-community/gemma-4-E2B-it-litert-lm",
        "gemma-4-E2B-it.litertlm",
    ),
    QWEN(
        "Qwen2.5 1.5B (약 1.6GB)",
        "litert-community/Qwen2.5-1.5B-Instruct",
        "Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.litertlm",
    ),
    QWEN_SMALL(
        "Qwen3.5 0.8B (약 0.5GB, 가벼움)",
        "litert-community/Qwen3.5-0.8B",
        "Qwen3.5-0.8B_mixed48_h1024.litertlm",
    );

    val url get() = "https://huggingface.co/$repo/resolve/main/$file"
}

private const val MAX_WAITING = 3 // 밀리면 오래된 문장은 기본 번역만 둡니다.
private const val KEY_LOADING = "aiLoading"
private const val KEY_GPU_TRYING = "aiGpuTrying"

/**
 * 모델 내려받기, 불러오기, 의역을 맡습니다. 무거운 작업은 작업 스레드 하나에서 차례로 실행하고,
 * 알림은 화면 스레드로 보냅니다. 실패하면 기본 번역이 그대로 남습니다.
 */
class Paraphraser(
    private val context: Context,
    private val onStatus: () -> Unit,
    private val onResult: (Caption) -> Unit,
) {
    var status = "AI 의역 꺼짐"
        private set

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val http = OkHttpClient.Builder().readTimeout(60, TimeUnit.SECONDS).build()
    private val prefs = context.getSharedPreferences("ai", Context.MODE_PRIVATE)
    private val waiting = ArrayDeque<Caption>()

    @Volatile private var ticket = 0 // 켜거나 끌 때마다 올려, 이전 작업을 무효로 만듭니다.
    @Volatile private var isReady = false
    @Volatile private var isActive = true
    @Volatile private var download: Call? = null
    private var engine: Engine? = null // 작업 스레드에서만 사용합니다.

    /** 모델을 불러오다 앱이 종료된 적이 있으면 true. 확인한 뒤에는 기록을 지웁니다. */
    fun consumeInterruptedLoad(): Boolean {
        val interrupted = prefs.getBoolean(KEY_LOADING, false)
        prefs.edit().putBoolean(KEY_LOADING, false).apply()
        return interrupted
    }

    fun start(model: AiModel) {
        val current = ++ticket
        isReady = false
        download?.cancel()
        clearWaiting()
        report(current, "AI 모델 준비 중")
        worker.execute {
            try {
                closeEngine()
                val file = fetch(model, current)
                if (current != ticket) return@execute
                report(current, "AI 모델 불러오는 중")
                prefs.edit().putBoolean(KEY_LOADING, true).commit()
                val (loaded, backend) = load(file)
                prefs.edit().putBoolean(KEY_LOADING, false).commit()
                if (current != ticket) {
                    loaded.close()
                    return@execute
                }
                engine = loaded
                isReady = true
                report(current, "AI 의역 켜짐 ($backend)")
            } catch (e: Throwable) {
                prefs.edit().putBoolean(KEY_LOADING, false).commit()
                report(current, "AI 모델 준비 실패: ${e.message}")
            }
        }
    }

    fun stop(reason: String = "AI 의역 꺼짐") {
        val current = ++ticket
        isReady = false
        download?.cancel()
        clearWaiting()
        prefs.edit().putBoolean(KEY_LOADING, false).apply()
        worker.execute { closeEngine() }
        report(current, reason)
    }

    /** 앱이 화면에 없을 때는 의역하지 않습니다. */
    fun setActive(active: Boolean) {
        isActive = active
        if (!active) clearWaiting()
    }

    fun enqueue(caption: Caption) {
        if (!isReady || !isActive) return
        synchronized(waiting) {
            waiting.addLast(caption)
            while (waiting.size > MAX_WAITING) waiting.removeFirst()
        }
        val current = ticket
        worker.execute { paraphraseNext(current) }
    }

    fun shutdown() {
        ticket++
        isReady = false
        download?.cancel()
        clearWaiting()
        worker.execute { closeEngine() }
        worker.shutdown()
        main.removeCallbacksAndMessages(null)
    }

    private fun clearWaiting() = synchronized(waiting) { waiting.clear() }

    private fun report(current: Int, text: String) {
        main.post {
            if (current != ticket) return@post
            status = text
            onStatus()
        }
    }

    /** 모델 파일이 없으면 내려받습니다. 끊긴 곳부터 이어받습니다. */
    private fun fetch(model: AiModel, current: Int): File {
        val folder = context.getExternalFilesDir("models") ?: File(context.filesDir, "models")
        folder.mkdirs()
        val file = File(folder, model.file)
        if (file.exists()) return file

        val part = File(folder, model.file + ".part")
        val have = if (part.exists()) part.length() else 0L
        val request = Request.Builder().url(model.url)
        if (have > 0) request.header("Range", "bytes=$have-")
        val call = http.newCall(request.build())
        download = call
        call.execute().use { response ->
            if (response.code == 416) {
                part.delete()
                throw IOException("이어받기에 실패했습니다. 다시 켜 주세요")
            }
            if (!response.isSuccessful) throw IOException("내려받기 오류 ${response.code}")
            val body = response.body ?: throw IOException("받은 내용이 없습니다")
            val resumed = response.code == 206
            var done = if (resumed) have else 0L
            val length = body.contentLength()
            val total = if (length >= 0) done + length else -1L
            if (total > 0 && folder.usableSpace < total - done) {
                throw IOException("저장 공간이 부족합니다")
            }

            var shown = -1
            body.byteStream().use { input ->
                FileOutputStream(part, resumed).use { output ->
                    val buffer = ByteArray(256 * 1024)
                    while (true) {
                        if (current != ticket) throw IOException("취소됨")
                        val count = input.read(buffer)
                        if (count < 0) break
                        output.write(buffer, 0, count)
                        done += count
                        val percent = if (total > 0) (done * 100 / total).toInt() else 0
                        if (percent != shown) {
                            shown = percent
                            report(current, "AI 모델 내려받는 중 $percent%")
                        }
                    }
                }
            }
            if (total > 0 && done != total) throw IOException("내려받기가 중간에 끊겼습니다. 다시 켜 주세요")
        }
        if (!part.renameTo(file)) throw IOException("모델 파일을 저장하지 못했습니다")
        return file
    }

    /** GPU를 먼저 쓰고, 안 되면 CPU로 불러옵니다. */
    private fun load(file: File): Pair<Engine, String> {
        // GPU를 시도하다 앱이 종료된 적이 있으면 다시 시도하지 않습니다.
        if (!prefs.getBoolean(KEY_GPU_TRYING, false)) {
            prefs.edit().putBoolean(KEY_GPU_TRYING, true).commit()
            val gpu = runCatching { create(file, Backend.GPU()) }
            prefs.edit().putBoolean(KEY_GPU_TRYING, false).commit()
            gpu.getOrNull()?.let { return it to "GPU" }
        }
        return create(file, Backend.CPU(threadCount = 4)) to "CPU"
    }

    private fun create(file: File, backend: Backend): Engine {
        val engine = Engine(
            EngineConfig(
                modelPath = file.absolutePath,
                backend = backend,
                cacheDir = context.cacheDir.absolutePath,
            )
        )
        try {
            engine.initialize()
        } catch (e: Throwable) {
            runCatching { engine.close() }
            throw e
        }
        return engine
    }

    private fun closeEngine() {
        runCatching { engine?.close() }
        engine = null
    }

    private fun paraphraseNext(current: Int) {
        if (current != ticket || !isActive) return
        val active = engine ?: return
        val caption = synchronized(waiting) { waiting.removeFirstOrNull() } ?: return
        val started = System.currentTimeMillis()
        val raw = try {
            val config = ConversationConfig(
                systemInstruction = Contents.of(instructions(caption.direction)),
                samplerConfig = SamplerConfig(topK = 20, topP = 0.9, temperature = 0.3),
                maxOutputToken = 120,
                thinkingConfig = ThinkingConfig(enableThinking = false),
            )
            // 문장마다 새 대화를 만들어 이전 문장이 쌓이지 않게 합니다.
            active.createConversation(config).use { it.sendMessage(caption.original).toString() }
        } catch (e: Throwable) {
            report(current, "의역 실패: ${e.message}")
            return
        }
        val result = clean(raw, caption.original, caption.direction) ?: return
        val seconds = (System.currentTimeMillis() - started) / 1000f
        main.post {
            if (current != ticket) return@post
            caption.refined = result
            caption.refinedSeconds = seconds
            onResult(caption)
        }
    }

    private fun instructions(direction: Direction) = when (direction) {
        Direction.ZH_KO ->
            "너는 게임 음성 채팅 통역사야. 중국어 문장을 한국 친구끼리 말하는 자연스러운 반말 한국어로 의역해.\n" +
                "원래의 뜻과 말투를 살려. 번역문 한 줄만 출력하고 설명은 하지 마.\n" +
                "예) 快来帮我 → 빨리 와서 도와줘\n" +
                "예) 你干嘛呢 → 너 뭐 해?"
        Direction.KO_ZH ->
            "你是游戏语音聊天的翻译。把韩语句子意译成中国朋友之间说话那样自然、口语化的简体中文。\n" +
                "保留原来的意思和语气。只输出一行译文，不要解释。\n" +
                "例）나 먼저 갈게 → 我先走啦\n" +
                "例）그거 완전 웃겼어 → 那个太好笑了"
    }

    /** 모델 출력에서 번역문만 남깁니다. 결과가 이상하면 null. */
    private fun clean(raw: String, source: String, direction: Direction): String? {
        val line = raw.substringAfter("</think>")
            .lineSequence()
            .map { it.trim() }
            .firstOrNull { it.isNotEmpty() }
            ?: return null
        val result = line.trim('"', '\'', '“', '”', '「', '」', ' ')
        if (result.isEmpty() || result.length > maxOf(60, source.length * 5)) return null
        if (result.contains("<think>") || result.contains("→")) return null

        val hasHangul = Direction.of(result) == Direction.KO_ZH
        val hasHan = result.any { it in '一'..'鿿' }
        val valid = when (direction) {
            Direction.ZH_KO -> hasHangul && !hasHan
            Direction.KO_ZH -> hasHan && !hasHangul
        }
        return if (valid) result else null
    }
}
