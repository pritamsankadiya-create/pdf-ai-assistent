package com.example.pdf_ai_assistant

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*

class MainActivity : FlutterActivity() {

    companion object {
        private const val METHOD_CHANNEL = "com.example.pdf_ai_assistant/local_ai"
        private const val STREAM_CHANNEL = "com.example.pdf_ai_assistant/local_ai_stream"
    }

    private var localAIService: LocalAIService? = null
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // MethodChannel for init, status, generate
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialize" -> {
                        scope.launch(Dispatchers.IO) {
                            val service = LocalAIService(applicationContext)
                            localAIService = service
                            val status = service.initialize()
                            withContext(Dispatchers.Main) { result.success(status) }
                        }
                    }

                    "checkStatus" -> {
                        val status = localAIService?.checkStatus()
                            ?: mapOf("status" to "unavailable", "message" to "Not initialized")
                        result.success(status)
                    }

                    "generateContent" -> {
                        val prompt = call.argument<String>("prompt")
                        if (prompt == null) {
                            result.error("INVALID_ARG", "prompt is required", null)
                            return@setMethodCallHandler
                        }
                        scope.launch {
                            val response = localAIService?.generateContent(prompt)
                                ?: mapOf("success" to false, "error" to "Not initialized")
                            result.success(response)
                        }
                    }

                    "close" -> {
                        localAIService?.close()
                        localAIService = null
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }

        // EventChannel for streaming responses
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, STREAM_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    val prompt = (arguments as? Map<*, *>)?.get("prompt") as? String
                    if (prompt == null || events == null) {
                        events?.error("INVALID_ARG", "prompt is required", null)
                        return
                    }

                    localAIService?.generateContentStream(
                        prompt = prompt,
                        onChunk = { text -> events.success(mapOf("type" to "chunk", "text" to text)) },
                        onDone = { events.endOfStream() },
                        onError = { error -> events.error("GENERATION_ERROR", error, null) }
                    ) ?: events.error("NOT_INIT", "LocalAIService not initialized", null)
                }

                override fun onCancel(arguments: Any?) {}
            })
    }

    override fun onDestroy() {
        localAIService?.close()
        scope.cancel()
        super.onDestroy()
    }
}
