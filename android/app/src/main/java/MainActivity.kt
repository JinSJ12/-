package app.caption

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.ActivityInfo
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast

private const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
private const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT
private const val LIMIT = 100
private val GRAY = Color.rgb(160, 160, 165)

private val SAMPLES = listOf(
    "右边有敌人", "等一下，我马上过去", "快来帮我",
    "잠깐만, 바로 갈게", "오른쪽 조심해", "撤退！撤退！", "打得不错",
)

class MainActivity : Activity() {
    private val captions = mutableListOf<Caption>()
    private val translator = DeviceTranslator()
    private lateinit var client: CaptionClient
    private lateinit var paraphraser: Paraphraser
    private lateinit var aiStatusView: TextView
    private val settings by lazy { getSharedPreferences("settings", Context.MODE_PRIVATE) }

    private var modelStatus = ""
    private var isFocusMode = false
    private var isHistoryOpen = false

    // 기본 화면
    private lateinit var mainScreen: LinearLayout
    private lateinit var modelStatusView: TextView
    private lateinit var serverStatusView: TextView
    private lateinit var list: LinearLayout
    private lateinit var listScroll: ScrollView
    private lateinit var samples: View

    // 자막 보기 화면
    private lateinit var focusScreen: FrameLayout
    private lateinit var currentCaption: LinearLayout
    private lateinit var historyButton: Button
    private lateinit var historyPanel: LinearLayout
    private lateinit var historyList: LinearLayout
    private lateinit var historyScroll: ScrollView
    private lateinit var controls: LinearLayout
    private lateinit var focusStatus: TextView
    private lateinit var originalButton: Button

    private var fontSize: Float
        get() = settings.getFloat("focusFontSize", 56f)
        set(value) = settings.edit().putFloat("focusFontSize", value).apply()
    private var showsOriginal: Boolean
        get() = settings.getBoolean("focusShowsOriginal", false)
        set(value) = settings.edit().putBoolean("focusShowsOriginal", value).apply()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 앱을 보고 있는 동안 화면이 꺼지지 않게 합니다.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        Caption.prefersBasic = settings.getBoolean("preferBasic", false)
        client = CaptionClient(onCaption = ::receive, onStatus = { if (::list.isInitialized) render() })
        paraphraser = Paraphraser(
            applicationContext,
            onStatus = { if (!isDestroyed) render() },
            onResult = { caption ->
                if (!isDestroyed) {
                    client.send(caption, forward = !isFocusMode)
                    render()
                }
            },
        )
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        mainScreen = buildMainScreen()
        focusScreen = buildFocusScreen().apply { visibility = View.GONE }
        root.addView(mainScreen, FrameLayout.LayoutParams(MATCH, MATCH))
        root.addView(focusScreen, FrameLayout.LayoutParams(MATCH, MATCH))
        setContentView(root)

        prepareModels()
        connectSaved()
        resumeAi()
        render()
    }

    override fun onStart() {
        super.onStart()
        paraphraser.setActive(true)
    }

    override fun onStop() {
        paraphraser.setActive(false)
        super.onStop()
    }

    override fun onLowMemory() {
        super.onLowMemory()
        if (settings.getBoolean("aiEnabled", false)) {
            settings.edit().putBoolean("aiEnabled", false).apply()
            paraphraser.stop("메모리가 부족해 AI 의역을 껐습니다")
        }
    }

    override fun onDestroy() {
        client.disconnect()
        paraphraser.shutdown()
        translator.close()
        super.onDestroy()
    }

    // ---- AI 의역 ----

    private val aiModel: AiModel
        get() = AiModel.values().firstOrNull { it.name == settings.getString("aiModel", null) }
            ?: AiModel.GEMMA

    /** 켜 둔 상태였다면 다시 불러옵니다. 불러오다 종료된 적이 있으면 반복되지 않게 끕니다. */
    private fun resumeAi() {
        val interrupted = paraphraser.consumeInterruptedLoad()
        if (!settings.getBoolean("aiEnabled", false)) return
        if (interrupted) {
            settings.edit().putBoolean("aiEnabled", false).apply()
            paraphraser.stop("모델을 불러오다 앱이 종료되어 AI 의역을 껐습니다")
        } else {
            paraphraser.start(aiModel)
        }
    }

    private fun showAiDialog() {
        // AI가 뜻을 바꾸는 경우를 대비해, 어느 번역을 크게 볼지 고릅니다.
        val preferBasic = CheckBox(this).apply {
            text = "기본 번역을 크게 보기 (AI 의역은 작게)"
            isChecked = Caption.prefersBasic
            setPadding(dp(8), dp(8), dp(8), dp(8))
            setOnCheckedChangeListener { _, checked ->
                Caption.prefersBasic = checked
                settings.edit().putBoolean("preferBasic", checked).apply()
                render()
            }
        }
        val builder = AlertDialog.Builder(this)
            .setNegativeButton("닫기", null)
            .setView(preferBasic)
        if (settings.getBoolean("aiEnabled", false)) {
            builder.setTitle("AI 의역")
                .setMessage("${paraphraser.status}\n\n모델을 바꾸려면 먼저 끄세요.")
                .setPositiveButton("끄기") { _, _ ->
                    settings.edit().putBoolean("aiEnabled", false).apply()
                    paraphraser.stop()
                }
                .setNeutralButton("다시 불러오기") { _, _ -> paraphraser.start(aiModel) }
        } else {
            var selected = aiModel.ordinal
            // 목록과 설명을 함께 보여줄 수 없어, 안내는 제목에 짧게 적습니다.
            builder.setTitle("AI 모델 (Wi-Fi 권장, 받는 동안 앱을 열어 두세요)")
                .setSingleChoiceItems(
                    AiModel.values().map { it.title }.toTypedArray(),
                    selected,
                ) { _, which -> selected = which }
                .setPositiveButton("내려받고 켜기") { _, _ ->
                    val model = AiModel.values()[selected]
                    settings.edit()
                        .putString("aiModel", model.name)
                        .putBoolean("aiEnabled", true)
                        .apply()
                    paraphraser.start(model)
                }
        }
        builder.show()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) applySystemBars()
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        when {
            isHistoryOpen -> setHistory(false)
            isFocusMode -> setFocusMode(false)
            else -> {
                @Suppress("DEPRECATION")
                super.onBackPressed()
            }
        }
    }

    // ---- 자막 처리 ----

    /** 서버에서 온 문장. 방금 만든 번역문이 이름 없이 되돌아온 것이면 무시합니다. */
    private fun receive(text: String, speaker: String?, requestId: String?) {
        val trimmed = text.trim()
        val echoed = speaker.isNullOrBlank() &&
            captions.takeLast(10).any { it.translated?.trim() == trimmed || it.refined == trimmed }
        if (!echoed) add(trimmed, speaker, requestId)
    }

    private fun add(text: String, speaker: String? = null, requestId: String? = null) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        val caption = Caption(trimmed, speaker, requestId)
        captions.add(caption)
        while (captions.size > LIMIT) captions.removeAt(0)
        render()
        translate(caption)
    }

    private fun translate(caption: Caption) {
        translator.translate(caption) { done ->
            if (isDestroyed) return@translate
            // 본 PC로 전달하는 것은 기본 화면에서만 합니다.
            client.send(done, forward = !isFocusMode)
            render()
            // 의역은 기본 번역이 끝난 뒤(실패해도) 시작합니다.
            if (done.refined == null) paraphraser.enqueue(done)
        }
    }

    private fun prepareModels() {
        translator.prepare { status ->
            modelStatus = status
            if (!isDestroyed) render()
        }
    }

    private fun connectSaved() {
        val address = settings.getString("serverAddress", "").orEmpty()
        val password = settings.getString("serverPassword", "").orEmpty()
        if (address.isNotEmpty() && password.isNotEmpty()) client.connect(address, password)
    }

    // ---- 화면 만들기 ----

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    private fun label(text: String, size: Float, color: Int = Color.WHITE, bold: Boolean = false) =
        TextView(this).apply {
            this.text = text
            textSize = size
            setTextColor(color)
            if (bold) typeface = Typeface.DEFAULT_BOLD
        }

    private fun button(text: String, action: () -> Unit) = Button(this).apply {
        this.text = text
        isAllCaps = false
        setOnClickListener { action() }
    }

    private fun column() = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }

    private fun row() = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
    }

    private fun buildMainScreen(): LinearLayout {
        val screen = column().apply { setPadding(dp(16), dp(8), dp(16), dp(8)) }

        val header = row()
        val titles = column()
        titles.addView(label("중국어 ↔ 한국어", 20f, bold = true))
        modelStatusView = label("", 13f, GRAY)
        serverStatusView = label("", 13f, GRAY)
        aiStatusView = label("", 13f, GRAY)
        titles.addView(modelStatusView)
        titles.addView(serverStatusView)
        titles.addView(aiStatusView)
        header.addView(titles, LinearLayout.LayoutParams(0, WRAP, 1f))
        header.addView(button("연결") { showConnectionDialog() })
        header.addView(button("AI") { showAiDialog() })
        header.addView(button("다시 시도") {
            prepareModels()
            captions.filter { it.translated == null }.forEach { translate(it) }
        })
        header.addView(button("지우기") {
            captions.clear()
            render()
        })
        screen.addView(header)
        screen.addView(button("자막 보기 모드") { setFocusMode(true) }, MATCH, WRAP)

        list = column()
        listScroll = ScrollView(this).apply { addView(list) }
        screen.addView(listScroll, LinearLayout.LayoutParams(MATCH, 0, 1f))

        val sampleRow = row()
        SAMPLES.forEach { sample -> sampleRow.addView(button(sample) { add(sample) }) }
        samples = HorizontalScrollView(this).apply { addView(sampleRow) }
        screen.addView(samples)

        val input = EditText(this).apply {
            hint = "한국어 또는 중국어 입력"
            setTextColor(Color.WHITE)
            setHintTextColor(GRAY)
            inputType = InputType.TYPE_CLASS_TEXT
            imeOptions = EditorInfo.IME_ACTION_SEND
        }
        val submit = {
            add(input.text.toString())
            input.text.clear()
        }
        input.setOnEditorActionListener { _, action, _ ->
            if (action == EditorInfo.IME_ACTION_SEND) {
                submit()
                true
            } else {
                false
            }
        }
        val inputRow = row()
        inputRow.addView(input, LinearLayout.LayoutParams(0, WRAP, 1f))
        inputRow.addView(button("번역") { submit() })
        screen.addView(inputRow)
        return screen
    }

    private fun buildFocusScreen(): FrameLayout {
        val screen = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            setOnClickListener {
                controls.visibility =
                    if (controls.visibility == View.VISIBLE) View.GONE else View.VISIBLE
            }
        }

        currentCaption = column().apply {
            gravity = Gravity.CENTER
            setPadding(dp(32), dp(48), dp(32), dp(64))
        }
        screen.addView(currentCaption, FrameLayout.LayoutParams(MATCH, MATCH))

        // 내역은 평소에 숨어 있고, 열면 화면 전체를 덮습니다.
        historyButton = button("▲ 내역") { setHistory(true) }.apply { alpha = 0.6f }
        screen.addView(
            historyButton,
            FrameLayout.LayoutParams(WRAP, WRAP, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL),
        )

        focusStatus = label("", 13f, Color.rgb(255, 159, 10))
        screen.addView(
            focusStatus,
            FrameLayout.LayoutParams(WRAP, WRAP, Gravity.TOP or Gravity.CENTER_HORIZONTAL),
        )

        controls = row().apply {
            setBackgroundColor(Color.argb(220, 0, 0, 0))
            setPadding(dp(12), dp(8), dp(12), dp(8))
            visibility = View.GONE
        }
        controls.addView(button("닫기") { setFocusMode(false) })
        controls.addView(View(this), LinearLayout.LayoutParams(0, 1, 1f))
        controls.addView(button("글자 −") {
            fontSize = (fontSize - 8f).coerceAtLeast(24f)
            render()
        })
        controls.addView(button("글자 +") {
            fontSize = (fontSize + 8f).coerceAtMost(128f)
            render()
        })
        originalButton = button("원문 보기") {
            showsOriginal = !showsOriginal
            render()
        }
        controls.addView(originalButton)
        screen.addView(controls, FrameLayout.LayoutParams(MATCH, WRAP, Gravity.TOP))

        historyPanel = column().apply {
            setBackgroundColor(Color.rgb(30, 30, 32))
            isClickable = true // 내역을 눌러도 뒤의 메뉴가 열리지 않게 합니다.
            visibility = View.GONE
        }
        historyPanel.addView(button("▼ 내역 닫기") { setHistory(false) }, MATCH, WRAP)
        historyList = column().apply { setPadding(dp(24), dp(8), dp(24), dp(24)) }
        historyScroll = ScrollView(this).apply { addView(historyList) }
        historyPanel.addView(historyScroll, LinearLayout.LayoutParams(MATCH, 0, 1f))
        screen.addView(historyPanel, FrameLayout.LayoutParams(MATCH, MATCH))
        return screen
    }

    private fun showConnectionDialog() {
        val address = EditText(this).apply {
            hint = "서브컴 IP 주소 (예: 192.168.0.10)"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            setText(settings.getString("serverAddress", ""))
        }
        val password = EditText(this).apply {
            hint = "앱 비밀번호"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            setText(settings.getString("serverPassword", ""))
        }
        val form = column().apply {
            setPadding(dp(24), dp(8), dp(24), 0)
            addView(address)
            addView(password)
        }
        AlertDialog.Builder(this)
            .setTitle("서브컴 연결")
            .setView(form)
            .setPositiveButton("연결") { _, _ ->
                settings.edit()
                    .putString("serverAddress", address.text.toString().trim())
                    .putString("serverPassword", password.text.toString())
                    .apply()
                connectSaved()
            }
            .setNegativeButton("연결 끊기") { _, _ -> client.disconnect() }
            .setNeutralButton("취소", null)
            .show()
    }

    // ---- 화면 전환 ----

    private fun setFocusMode(enabled: Boolean) {
        isFocusMode = enabled
        isHistoryOpen = false
        controls.visibility = View.GONE
        mainScreen.visibility = if (enabled) View.GONE else View.VISIBLE
        focusScreen.visibility = if (enabled) View.VISIBLE else View.GONE
        requestedOrientation =
            if (enabled) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            else ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        applySystemBars()
        render()
    }

    private fun setHistory(open: Boolean) {
        isHistoryOpen = open
        controls.visibility = View.GONE
        render()
    }

    /** 자막 보기에서는 상태 표시줄과 탐색 버튼을 숨깁니다. */
    @Suppress("DEPRECATION")
    private fun applySystemBars() {
        window.decorView.systemUiVisibility = if (isFocusMode) {
            View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
        } else {
            View.SYSTEM_UI_FLAG_VISIBLE
        }
    }

    // ---- 그리기 ----

    private fun render() {
        modelStatusView.text = modelStatus
        serverStatusView.text = client.status
        serverStatusView.setTextColor(if (client.isConnected) Color.GREEN else Color.rgb(255, 159, 10))
        samples.visibility = if (client.isConnected) View.GONE else View.VISIBLE
        aiStatusView.text = paraphraser.status
        if (isFocusMode) renderFocus() else renderList()
    }

    private fun renderList() {
        list.removeAllViews()
        captions.forEach { caption ->
            val item = column().apply { setPadding(0, dp(10), 0, dp(10)) }
            caption.speaker?.let { item.addView(label(it, 15f, speakerColor(it), bold = true)) }
            item.addView(label(caption.original, 17f, GRAY))
            val best = caption.best
            if (best != null) {
                // 비교할 수 있도록, 번역이 둘 다 있으면 하나를 작게 함께 보여줍니다.
                caption.comparison?.let { item.addView(label(it, 15f, GRAY)) }
                item.addView(label(best, 28f, bold = true))
                if (caption.direction == Direction.KO_ZH) {
                    item.addView(button("중국어 복사") { copy(best) }, WRAP, WRAP)
                }
                caption.refinedSeconds?.let {
                    item.addView(label(String.format("AI 의역 %.1f초", it), 13f, GRAY))
                }
            } else {
                val failure = caption.failure
                item.addView(label(failure ?: "번역 중…", 17f, if (failure != null) Color.RED else GRAY))
            }
            list.addView(item)
        }
        // fullScroll은 입력창의 포커스를 빼앗을 수 있어 위치만 옮깁니다.
        listScroll.post { listScroll.scrollTo(0, list.height) }
    }

    private fun renderFocus() {
        val finished = captions.filter { it.best != null || it.failure != null }
        focusStatus.text = if (client.isConnected) "" else client.status
        originalButton.text = if (showsOriginal) "원문 숨기기" else "원문 보기"

        currentCaption.removeAllViews()
        val latest = finished.lastOrNull()
        if (latest == null) {
            currentCaption.addView(centered("자막을 기다리는 중\n화면을 누르면 메뉴가 나옵니다", 22f, GRAY))
        } else {
            latest.speaker?.let {
                currentCaption.addView(centered(it, fontSize * 0.4f, speakerColor(it), true))
            }
            if (showsOriginal) {
                currentCaption.addView(centered(latest.original, fontSize * 0.5f, GRAY).apply { maxLines = 2 })
            }
            val translated = latest.best
            currentCaption.addView(
                centered(
                    translated ?: latest.failure.orEmpty(),
                    fontSize,
                    if (translated != null) Color.WHITE else Color.RED,
                    true,
                ).apply { maxLines = if (showsOriginal) 3 else 4 }
            )
        }

        historyPanel.visibility = if (isHistoryOpen) View.VISIBLE else View.GONE
        historyButton.visibility = if (isHistoryOpen) View.GONE else View.VISIBLE
        if (!isHistoryOpen) return

        // 위로 올려 읽는 중이면 새 자막이 와도 위치를 옮기지 않습니다.
        val atBottom = !historyScroll.canScrollVertically(1)
        historyList.removeAllViews()
        finished.forEach { caption ->
            val item = column().apply { setPadding(0, dp(8), 0, dp(8)) }
            if (showsOriginal) item.addView(centered(caption.original, 15f, GRAY))
            caption.speaker?.let { item.addView(centered(it, 14f, speakerColor(it), true)) }
            val translated = caption.best
            item.addView(
                centered(
                    translated ?: caption.failure.orEmpty(),
                    20f,
                    if (translated != null) Color.WHITE else Color.RED,
                )
            )
            historyList.addView(item)
        }
        if (atBottom) historyScroll.post { historyScroll.scrollTo(0, historyList.height) }
    }

    private fun centered(text: String, size: Float, color: Int, bold: Boolean = false) =
        label(text, size, color, bold).apply {
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(MATCH, WRAP)
        }

    private fun copy(text: String) {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("번역", text))
        Toast.makeText(this, "복사했습니다", Toast.LENGTH_SHORT).show()
    }
}
