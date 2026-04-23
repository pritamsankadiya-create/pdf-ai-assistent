package com.example.pdf_ai_assistant

import android.content.Context
import android.util.Log
import com.google.ai.edge.aicore.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collect

class LocalAIService(private val context: Context) {

    companion object {
        private const val TAG = "LocalAIService"
    }

    private var generativeModel: GenerativeModel? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private var modelReady = false
    private var downloadProgress: String = "idle"

    /**
     * Initialize the on-device Gemini Nano model.
     * Returns a status map: { "status": "ready"|"downloading"|"unavailable"|"error", "message": "..." }
     */
    fun initialize(): Map<String, Any> {
        return try {
            val downloadConfig = DownloadConfig(
                object : DownloadCallback {
                    override fun onDownloadStarted(bytesToDownload: Long) {
                        downloadProgress = "started"
                        Log.d(TAG, "Download started: $bytesToDownload bytes")
                    }

                    override fun onDownloadProgress(totalBytesDownloaded: Long) {
                        downloadProgress = "downloading"
                        Log.d(TAG, "Downloaded: $totalBytesDownloaded bytes")
                    }

                    override fun onDownloadCompleted() {
                        downloadProgress = "completed"
                        modelReady = true
                        Log.d(TAG, "Download completed")
                    }

                    override fun onDownloadFailed(failureStatus: String, e: GenerativeAIException) {
                        downloadProgress = "failed"
                        Log.e(TAG, "Download failed: $failureStatus", e)
                    }

                    override fun onDownloadDidNotStart(e: GenerativeAIException) {
                        downloadProgress = "failed"
                        Log.e(TAG, "Download did not start", e)
                    }
                }
            )

            val genConfig = generationConfig {
                this.context = this@LocalAIService.context
                temperature = 0.7f
                topK = 16
                maxOutputTokens = 1024
            }

            generativeModel = GenerativeModel(
                generationConfig = genConfig,
                downloadConfig = downloadConfig
            )

            // Try to prepare the engine — if model is already downloaded, this succeeds
            var initError: String? = null
            runBlocking {
                try {
                    generativeModel!!.prepareInferenceEngine()
                    modelReady = true
                    return@runBlocking
                } catch (e: Exception) {
                    initError = e.message ?: "Unknown error"
                    Log.w(TAG, "Model not ready yet, may need download: ${e.message}")
                }
            }

            when {
                modelReady -> mapOf("status" to "ready", "message" to "Gemini Nano is ready")
                initError?.contains("BINDING_FAILURE") == true ||
                initError?.contains("CONNECTION_ERROR") == true ->
                    mapOf("status" to "unavailable", "message" to "Google AI Core service is not available on this device. Please ensure Google Play Services and AI Core are installed and updated.")
                downloadProgress == "started" || downloadProgress == "downloading" ->
                    mapOf("status" to "downloading", "message" to "Model is downloading, please wait...")
                downloadProgress == "failed" ->
                    mapOf("status" to "error", "message" to "Model download failed: $initError")
                else ->
                    mapOf("status" to "downloading", "message" to "Model is being prepared, please wait...")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize AICore", e)
            mapOf("status" to "unavailable", "message" to "AICore not available: ${e.message}")
        }
    }

    /**
     * Check current status of the local model.
     */
    fun checkStatus(): Map<String, Any> {
        return when {
            modelReady -> mapOf("status" to "ready", "message" to "Gemini Nano is ready")
            generativeModel == null -> mapOf("status" to "unavailable", "message" to "Not initialized")
            downloadProgress == "downloading" || downloadProgress == "started" ->
                mapOf("status" to "downloading", "message" to "Model is downloading...")
            downloadProgress == "failed" ->
                mapOf("status" to "error", "message" to "Model download failed")
            else -> mapOf("status" to "unavailable", "message" to "Model not available")
        }
    }

    /**
     * Generate a summary/response using on-device Gemini Nano.
     * Returns the generated text or an error message.
     */
    suspend fun generateContent(prompt: String): Map<String, Any> {
        val model = generativeModel
            ?: return mapOf("success" to false, "error" to "Model not initialized")

        if (!modelReady) {
            return mapOf("success" to false, "error" to "Model not ready. Status: $downloadProgress")
        }

        return try {
            val response = model.generateContent(prompt)
            val text = response.text ?: ""
            mapOf("success" to true, "text" to text)
        } catch (e: Exception) {
            Log.e(TAG, "Generation failed", e)
            mapOf("success" to false, "error" to "Generation failed: ${e.message}")
        }
    }

    /**
     * Generate a streaming response using on-device Gemini Nano.
     * Calls onChunk for each piece of text, onDone when complete.
     */
    fun generateContentStream(
        prompt: String,
        onChunk: (String) -> Unit,
        onDone: () -> Unit,
        onError: (String) -> Unit
    ) {
        val model = generativeModel
        if (model == null || !modelReady) {
            onError("Model not ready")
            return
        }

        scope.launch {
            try {
                model.generateContentStream(prompt).collect { chunk ->
                    val text = chunk.text
                    if (!text.isNullOrEmpty()) {
                        withContext(Dispatchers.Main) { onChunk(text) }
                    }
                }
                withContext(Dispatchers.Main) { onDone() }
            } catch (e: Exception) {
                Log.e(TAG, "Streaming failed", e)
                withContext(Dispatchers.Main) { onError("Streaming failed: ${e.message}") }
            }
        }
    }

    fun close() {
        generativeModel?.close()
        generativeModel = null
        modelReady = false
        scope.cancel()
    }
}
