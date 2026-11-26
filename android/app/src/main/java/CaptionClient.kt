package app.caption

import android.os.Handler
import android.os.Looper
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/** 서브컴의 자막 서버에 접속해 문장을 받아옵니다. 끊기면 다시 연결합니다. */
class CaptionClient(
    private val onCaption: (text: String, speaker: String?, requestId: String?) -> Unit,
    private val onStatus: () -> Unit,
) {
    var status = "서브컴에 연결 안 됨"
        private set
    var isConnected = false
        private set

    private val main = Handler(Looper.getMainLooper())
    private val http = OkHttpClient.Builder().pingInterval(20, TimeUnit.SECONDS).build()
    private var socket: WebSocket? = null
    private var attempt = 0 // 이전 접속의 늦은 알림을 무시하기 위한 번호

    fun connect(address: String, password: String) {
        disconnect()
        var host = address.trim()
        if (!host.contains(":")) host += ":8765"
        val request = try {
            Request.Builder()
                .url("ws://$host")
                .header("X-App-Password", password)
                .build()
        } catch (e: IllegalArgumentException) {
            update("주소 또는 비밀번호 형식이 잘못되었습니다", false)
            return
        }
        open(request, attempt)
    }

    fun disconnect() {
        attempt++
        main.removeCallbacksAndMessages(null)
        socket?.cancel()
        socket = null
        update("서브컴에 연결 안 됨", false)
    }

    /**
     * 번역이 끝난 자막을 서브컴으로 보냅니다. forward는 본 PC 수신 앱에도 전달할지 여부입니다.
     * 봇이 보낸 문장은 자막 보기 중에도 번역을 돌려줍니다.
     */
    fun send(caption: Caption, forward: Boolean) {
        // 의역이 늦게 끝나면 같은 id로 한 번 더 보냅니다.
        val text = caption.best ?: return
        if (!isConnected || (!forward && caption.requestId == null)) return
        val message = JSONObject()
            .put("type", "translation")
            .putOpt("ref", caption.requestId) // 없으면 항목을 넣지 않습니다.
            .put("forward", forward)
            .put("id", caption.id)
            .put("speaker", caption.speaker ?: JSONObject.NULL)
            .put("original", caption.original)
            .put("text", text)
            .put("direction", caption.direction.code)
        socket?.send(message.toString())
    }

    private fun update(newStatus: String, connected: Boolean) {
        status = newStatus
        isConnected = connected
        onStatus()
    }

    private fun open(request: Request, current: Int) {
        update("서브컴에 연결 중", false)
        socket = http.newWebSocket(request, object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                main.post { handle(text, current) }
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(1000, null)
                main.post { retry(request, current) }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                main.post { retry(request, current) }
            }
        })
    }

    private fun handle(text: String, current: Int) {
        if (current != attempt) return
        val message = try {
            JSONObject(text)
        } catch (e: org.json.JSONException) {
            return
        }
        when (message.optString("type")) {
            "hello" -> update("서브컴에 연결됨", true)
            "caption" -> {
                val body = message.optString("text")
                val speaker = if (message.isNull("speaker")) null else message.optString("speaker")
                val requestId = if (message.isNull("id")) null else message.optString("id")
                if (body.isNotEmpty()) onCaption(body, speaker, requestId)
            }
            "error" -> {
                // 비밀번호 오류 등은 다시 시도하지 않습니다.
                val reason = message.optString("message", "서브컴이 연결을 거부했습니다")
                attempt++
                socket?.cancel()
                socket = null
                update(reason, false)
            }
        }
    }

    private fun retry(request: Request, current: Int) {
        if (current != attempt) return
        // 같은 접속에서 알림이 두 번 와도 한 번만 다시 연결합니다.
        attempt++
        val next = attempt
        socket?.cancel()
        socket = null
        update("연결 끊김, 3초 후 다시 연결", false)
        main.postDelayed({ if (next == attempt) open(request, next) }, 3_000)
    }
}
