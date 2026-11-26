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
/** 모델마다 번역을 시키는 방법이 다릅니다. */
enum class AiStyle {
    TRANSLATE, // 지시문을 주고 원문을 직접 번역
    POLISH, // 작은 범용 모델: 직접 번역하면 내용을 지어내므로 기본 번역의 말투만 다듬기
    TRANSLATION_ONLY, // 번역 전용 모델: 지시문 없이 한 메시지로 요청
}

/** 목록 순서와 방식은 아이폰 앱에 맞춥니다. Gemma는 안드로이드에만 있습니다. */
enum class AiModel(
    val title: String,
    val repo: String,
    val file: String,
    val style: AiStyle,
    val cpuOnly: Boolean = false,
) {
    QWEN35(
        "Qwen3.5 2B (약 2.1GB, 말투 다듬기)",
        "litert-community/Qwen3.5-2B",
        "Qwen3.5-2B_int8.litertlm",
        AiStyle.POLISH,
    ),
    HYMT(
        "Hy-MT2 1.8B (약 1.8GB, 번역 전용, CPU)",
        "litert-community/Hy-MT2-1.8B",
        "Hy-MT2-1.8B_int8.litertlm",
        AiStyle.TRANSLATION_ONLY,
        cpuOnly = true, // 모델 설명의 휴대폰 시험에서 GPU 결과에 오류가 있었습니다.
    ),
    QWEN3(
        "Qwen3 1.7B (약 1GB, 말투 다듬기)",
        "litert-community/Qwen3-1.7B",
        "Qwen3-1.7B_dynamic_wi4b32_afp32.litertlm",
        AiStyle.POLISH,
    ),
    GEMMA(
        "Gemma 4 E2B (약 2.6GB, 직접 번역)",
        "litert-community/gemma-4-E2B-it-litert-lm",
        "gemma-4-E2B-it.litertlm",
        AiStyle.TRANSLATE,
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
    @Volatile var isReady = false
        private set

    @Volatile private var isActive = true
    @Volatile private var download: Call? = null
    private var engine: Engine? = null // 작업 스레드에서만 사용합니다.
    private var engineModel: AiModel? = null // 작업 스레드에서만 사용합니다.

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
                val (loaded, backend) = load(file, model.cpuOnly)
                prefs.edit().putBoolean(KEY_LOADING, false).commit()
                if (current != ticket) {
                    loaded.close()
                    return@execute
                }
                engine = loaded
                engineModel = model
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
    private fun load(file: File, cpuOnly: Boolean): Pair<Engine, String> {
        // GPU를 시도하다 앱이 종료된 적이 있으면 다시 시도하지 않습니다.
        if (!cpuOnly && !prefs.getBoolean(KEY_GPU_TRYING, false)) {
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
        val model = engineModel ?: return
        val caption = synchronized(waiting) { waiting.removeFirstOrNull() } ?: return
        val draft = caption.translated // 기본 번역(초벌)
        val instructions: String?
        val prompt: String
        when (model.style) {
            AiStyle.TRANSLATE -> {
                instructions = translateInstructions(caption.direction)
                prompt = caption.original
            }
            AiStyle.POLISH -> {
                // 말투만 다듬는 모델은 기본 번역(초벌)이 있어야 합니다.
                if (draft == null) return
                instructions = polishInstructions(caption.direction)
                prompt = when (caption.direction) {
                    Direction.ZH_KO -> "원문: ${caption.original}\n초벌: $draft"
                    Direction.KO_ZH -> "原文：${caption.original}\n初稿：$draft"
                }
            }
            AiStyle.TRANSLATION_ONLY -> {
                val language = if (caption.direction == Direction.ZH_KO) "韩语" else "中文"
                instructions = null
                prompt = "将以下文本翻译成$language，使用朋友之间聊天的口语语气，" +
                    "注意只需要输出翻译后的结果，不要额外解释：\n\n${caption.original}"
            }
        }
        val started = System.currentTimeMillis()
        val raw = try {
            val config = ConversationConfig(
                systemInstruction = instructions?.let { Contents.of(it) },
                // 뜻이 달라지지 않도록 매번 가장 확률이 높은 말만 고릅니다.
                samplerConfig = SamplerConfig(topK = 1, topP = 0.95, temperature = 0.0),
                maxOutputToken = 120,
                // "생각하기" 기능은 느려서 끕니다. 번역 전용 모델에는 해당 기능이 없습니다.
                thinkingConfig =
                    if (model.style == AiStyle.TRANSLATION_ONLY) null
                    else ThinkingConfig(enableThinking = false),
            )
            // 문장마다 새 대화를 만들어 이전 문장이 쌓이지 않게 합니다.
            active.createConversation(config).use { it.sendMessage(prompt).toString() }
        } catch (e: Throwable) {
            report(current, "의역 실패: ${e.message}")
            return
        }
        val result = clean(raw, caption.original, draft, caption.direction) ?: return
        val seconds = (System.currentTimeMillis() - started) / 1000f
        main.post {
            if (current != ticket) return@post
            caption.refined = result
            caption.refinedSeconds = seconds
            onResult(caption)
        }
    }

    /** 초벌 번역의 말투만 고치게 하는 지시 (아이폰 앱과 같은 방식) */
    private fun polishInstructions(direction: Direction) = when (direction) {
        Direction.ZH_KO ->
            "너는 번역문의 말투를 고치는 교정기야. 초벌 번역을 친구끼리 쓰는 반말로만 고쳐.\n" +
                "뜻은 절대 더하거나 빼지 마. 고칠 것이 없으면 초벌을 그대로 출력해.\n" +
                "질문은 질문으로, 부탁은 부탁으로 유지해. 위치를 나타내는 말(在, 앞, 뒤 등)을 빠뜨리지 마.\n" +
                "고친 문장 한 줄만 출력해.\n" +
                "예)\n원문: 你在做什么？\n초벌: 당신은 무엇을 하고 있습니까?\n답: 너 뭐 하고 있어?\n" +
                "예)\n원문: 敌人在后面\n초벌: 적은 뒤에 있습니다.\n답: 적 뒤에 있어.\n" +
                "예)\n원문: 你能帮我一下吗？\n초벌: 저를 좀 도와주시겠습니까?\n답: 나 좀 도와줄래?"
        Direction.KO_ZH ->
            "你是译文润色器。只把初稿改成朋友之间聊天的口语简体中文。\n" +
                "绝对不要增加或删减意思。如果初稿已经自然，就原样输出。\n" +
                "问句保持问句，请求保持请求。不要漏掉“在”等表示位置的词。只输出一行。\n" +
                "例）\n原文：지금 어디에 계세요?\n初稿：您现在在哪里？\n答：你现在在哪儿呢？\n" +
                "例）\n原文：적이 뒤에 있어요.\n初稿：敌人在后面。\n答：敌人在后面呢。\n" +
                "例）\n原文：저를 좀 도와주실 수 있어요?\n初稿：您能帮我一下吗？\n答：能帮我一下不？"
    }

    private fun translateInstructions(direction: Direction) = when (direction) {
        Direction.ZH_KO ->
            "너는 게임 음성 채팅 통역사야. 중국어 문장을 자연스러운 반말 한국어로 번역해.\n" +
                "뜻은 원문과 똑같아야 해. 내용을 더하거나 빼거나 바꾸지 마. 질문은 질문으로, 명령은 명령으로 옮겨.\n" +
                "뜻이 확실하지 않으면 직역에 가깝게 옮겨. 번역문 한 줄만 출력해.\n" +
                "예) 快来帮我 → 빨리 와서 도와줘\n" +
                "예) 你听得到我说话吗？ → 내 말 들려?\n" +
                "예) 我没看到他 → 나 걔 못 봤어"
        Direction.KO_ZH ->
            "你是游戏语音聊天的翻译。把韩语句子翻译成自然、口语化的简体中文。\n" +
                "意思必须和原文完全一致，不要增加、删减或改变内容。疑问句仍译成疑问句，命令仍译成命令。\n" +
                "原文含义不清楚时尽量直译。中文语法要完整，不要漏掉“在”这样的词。只输出一行译文。\n" +
                "例）나 뒤에 있어 → 我在后面呢\n" +
                "例）내 목소리 들려? → 听得到我说话吗？\n" +
                "例）걔 못 봤어 → 我没看到他"
    }

    /** 모델 출력에서 번역문만 남깁니다. 결과가 이상하면 null. */
    private fun clean(raw: String, source: String, draft: String?, direction: Direction): String? {
        var line = raw.substringAfter("</think>")
            .lineSequence()
            .map { it.trim() }
            .firstOrNull { it.isNotEmpty() }
            ?: return null
        // 예시를 따라 붙인 머리말을 지웁니다.
        listOf("답:", "답：", "答：", "答:").forEach { line = line.removePrefix(it) }
        val result = line.trim('"', '\'', '“', '”', '「', '」', ' ')
        if (result.isEmpty() || result.length > maxOf(60, source.length * 5)) return null
        // 초벌보다 훨씬 길면 내용을 덧붙인 것으로 보고 버립니다.
        if (draft != null && result.length > maxOf(draft.length * 2, draft.length + 10)) return null
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
