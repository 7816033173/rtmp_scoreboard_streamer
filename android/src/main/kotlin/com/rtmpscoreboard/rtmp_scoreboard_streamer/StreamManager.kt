package com.rtmpscoreboard.rtmp_scoreboard_streamer

import android.content.Context
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.TextureView
import com.pedro.common.ConnectChecker
import com.pedro.encoder.input.gl.render.filters.`object`.ImageObjectFilterRender
import com.pedro.encoder.input.sources.audio.MicrophoneSource
import com.pedro.encoder.input.sources.video.Camera2Source
import com.pedro.encoder.input.video.CameraHelper
import com.pedro.encoder.utils.gl.AspectRatioMode
import com.pedro.library.generic.GenericStream
import io.flutter.plugin.common.EventChannel

/**
 * Camera -> GL overlay filter -> encoder -> RTMP. One scoreboard image is composited onto every
 * frame before encoding, so it is part of the video every viewer receives.
 *
 * Broadcast is landscape-only: filter coordinates then equal frame coordinates, no rotation math.
 */
class StreamManager(private val context: Context) : ConnectChecker {

    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private val pending = mutableListOf<Map<String, Any?>>()

    private val stream: GenericStream by lazy { GenericStream(context, this) }

    private var prepared = false
    private var previewView: TextureView? = null
    private var encW = 1280
    private var encH = 720

    /**
     * One named overlay. Holds bytes, not a Bitmap: RootEncoder recycles the bitmap it is given,
     * so each setImage needs a fresh decode. Insertion order is z-order (later = on top).
     */
    private class Layer(
        var png: ByteArray,
        var widthPct: Float,
        var anchor: String,
        var xPct: Float,
        var yPct: Float,
        var filter: ImageObjectFilterRender? = null,
    )

    private val layers = LinkedHashMap<String, Layer>()

    fun setSink(s: EventChannel.EventSink?) {
        sink = s
        if (s != null) {
            val drained = pending.toList()
            pending.clear()
            drained.forEach { e -> main.post { s.success(e) } }
        }
    }

    private fun emit(event: Map<String, Any?>) {
        val s = sink
        if (s == null) {
            if (pending.size < 32) pending.add(event)
            return
        }
        main.post { s.success(event) }
    }

    private fun emitError(code: String, message: String?) =
        emit(mapOf("type" to "error", "code" to code, "message" to (message ?: code)))

    /**
     * [fill] only changes the on-screen preview: true crops the camera image to fill the whole preview
     * view, false letterboxes it. The video that is sent is always the full frame.
     */
    fun prepare(width: Int, height: Int, fps: Int, bitrate: Int, front: Boolean, fill: Boolean = false) {
        encW = width
        encH = height
        stream.getGlInterface().setAspectRatioMode(if (fill) AspectRatioMode.Fill else AspectRatioMode.Adjust)
        if (prepared) {
            // prepareVideo throws while previewing; only re-select the camera.
            selectCamera(front)
            return
        }
        val videoOk = stream.prepareVideo(width, height, bitrate, fps, 2, 0)
        val audioOk = stream.prepareAudio(44100, true, 128 * 1000)
        if (!videoOk || !audioOk) {
            throw IllegalStateException("PREPARE_FAILED: video=$videoOk audio=$audioOk")
        }
        val gl = stream.getGlInterface()
        gl.autoHandleOrientation = false
        gl.setStreamIsPortrait(false)
        gl.setPreviewIsPortrait(false)
        gl.setStreamRotation(0)
        gl.setPreviewRotation(0)
        stream.setOrientation(270)
        prepared = true
        selectCamera(front)
    }

    private fun selectCamera(front: Boolean) {
        val src = stream.videoSource as? Camera2Source ?: return
        val isFront = src.getCameraFacing() == CameraHelper.Facing.FRONT
        if (isFront != front) src.switchCamera()
    }

    fun switchCamera() {
        (stream.videoSource as? Camera2Source)?.switchCamera()
    }

    fun setMuted(muted: Boolean) {
        val mic = stream.audioSource as? MicrophoneSource ?: return
        if (muted) mic.mute() else mic.unMute()
    }

    fun bindPreview(view: TextureView) {
        previewView = view
        if (prepared) attachPreview(view)
    }

    /**
     * The preview view changed size (for example the screen rotated after it was created).
     * RootEncoder keeps drawing into the size it was started with, which shows as a black preview,
     * so the new size has to be passed on.
     */
    fun previewResized(view: TextureView, width: Int, height: Int) {
        if (previewView !== view || width <= 0 || height <= 0) return
        stream.getGlInterface().setPreviewResolution(width, height)
    }

    private fun attachPreview(view: TextureView) {
        if (!prepared) return
        try {
            if (stream.isOnPreview) stream.stopPreview()
            stream.startPreview(view)
            rebuildLayers()
            emit(mapOf("type" to "previewBound"))
        } catch (t: Throwable) {
            Log.e(TAG, "bindPreview failed", t)
            emitError("PREVIEW_BIND_FAILED", t.message)
        }
    }

    /** Ignores stale views: a disposed old view must not stop the preview of a newer one. */
    fun unbindPreview(view: TextureView) {
        if (previewView !== view) return
        previewView = null
        try {
            if (stream.isOnPreview) stream.stopPreview()
        } catch (t: Throwable) {
            Log.w(TAG, "stopPreview failed", t)
        }
        emit(mapOf("type" to "previewUnbound"))
    }

    /**
     * Add or update the overlay [id]. width/x/y are percent (0-100) of the frame; height follows the
     * image's aspect ratio. [anchor] picks the reference point (topLeft, topCenter, topRight,
     * centerLeft, center, centerRight, bottomLeft, bottomCenter, bottomRight); x/y are then the
     * margin from that edge. With anchor "custom", x/y are the top-left corner.
     * Layers stack in the order they were first added.
     */
    fun setOverlay(id: String, png: ByteArray, widthPct: Float, anchor: String, xPct: Float, yPct: Float) {
        val layer = layers[id]
        if (layer != null) {
            layer.png = png
            layer.widthPct = widthPct
            layer.anchor = anchor
            layer.xPct = xPct
            layer.yPct = yPct
            val live = layer.filter
            if (live != null) {
                applyTransform(live, layer)
                return
            }
        } else {
            layers[id] = Layer(png, widthPct, anchor, xPct, yPct)
        }
        rebuildLayers()
    }

    fun removeOverlay(id: String) {
        val layer = layers.remove(id) ?: return
        layer.filter?.let { runCatching { stream.getGlInterface().removeFilter(it) } }
    }

    fun clearOverlays() {
        layers.values.forEach { l -> l.filter?.let { runCatching { stream.getGlInterface().removeFilter(it) } } }
        layers.clear()
    }

    private fun applyTransform(filter: ImageObjectFilterRender, layer: Layer) {
        val bmp = BitmapFactory.decodeByteArray(layer.png, 0, layer.png.size)
            ?: throw IllegalArgumentException("OVERLAY_DECODE_FAILED: bytes=${layer.png.size}")
        val aspect = bmp.width.toFloat() / bmp.height.toFloat()
        filter.setImage(bmp)
        // Scale is percent of the frame per axis; derive height from the image and frame aspects.
        val frameAspect = encW.toFloat() / encH.toFloat()
        val w = layer.widthPct
        val h = w * frameAspect / aspect
        val (px, py) = position(layer.anchor, w, h, layer.xPct, layer.yPct)
        filter.setScale(w, h)
        filter.setPosition(px, py)
    }

    /** Top-left corner (percent) for an overlay of size w x h placed at [anchor] with margins mx, my. */
    private fun position(anchor: String, w: Float, h: Float, mx: Float, my: Float): Pair<Float, Float> {
        val x = when {
            anchor.endsWith("Left") -> mx
            anchor.endsWith("Right") -> 100f - w - mx
            anchor == "custom" -> mx
            else -> (100f - w) / 2f // center, topCenter, bottomCenter
        }
        val y = when {
            anchor.startsWith("top") -> my
            anchor.startsWith("bottom") -> 100f - h - my
            anchor == "custom" -> my
            else -> (100f - h) / 2f // center, centerLeft, centerRight
        }
        return x to y
    }

    /**
     * RootEncoder's GL pipeline drops filters attached before a preview/stream transition, so every
     * layer is rebuilt from its cached PNG after startPreview and again before startStream.
     */
    private fun rebuildLayers() {
        layers.values.forEach { l -> l.filter?.let { runCatching { stream.getGlInterface().removeFilter(it) } } }
        layers.values.forEachIndexed { index, layer ->
            val filter = ImageObjectFilterRender()
            stream.getGlInterface().addFilter(index, filter)
            applyTransform(filter, layer)
            layer.filter = filter
        }
    }

    fun startStream(url: String) {
        if (!prepared) throw IllegalStateException("PREVIEW_NOT_READY: call initPreview first")
        if (!stream.isOnPreview) throw IllegalStateException("PREVIEW_NOT_BOUND: preview surface not attached")
        rebuildLayers()
        stream.startStream(url)
    }

    fun stopStream() {
        if (stream.isStreaming) stream.stopStream()
    }

    fun release() {
        runCatching { if (stream.isStreaming) stream.stopStream() }
        runCatching { if (stream.isOnPreview) stream.stopPreview() }
        runCatching { stream.release() }
        layers.clear()
        previewView = null
        prepared = false
    }

    // ConnectChecker
    override fun onConnectionStarted(url: String) {}
    override fun onConnectionSuccess() = emit(mapOf("type" to "connected"))
    override fun onConnectionFailed(reason: String) =
        emit(mapOf("type" to "disconnected", "reason" to reason))
    override fun onNewBitrate(bitrate: Long) {}
    override fun onDisconnect() =
        emit(mapOf("type" to "disconnected", "reason" to "Server closed connection"))
    override fun onAuthError() = emitError("AUTH_ERROR", "Authentication failed")
    override fun onAuthSuccess() {}

    companion object {
        private const val TAG = "RtmpScoreboardStreamer"
    }
}
