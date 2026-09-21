package com.rtmpscoreboard.rtmp_scoreboard_streamer

import android.content.Context
import android.graphics.SurfaceTexture
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import io.flutter.plugin.platform.PlatformView

class PreviewView(
    context: Context,
    private val manager: () -> StreamManager?,
) : PlatformView, TextureView.SurfaceTextureListener {

    private val textureView = TextureView(context).also {
        it.surfaceTextureListener = this
        it.layoutParams = ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
        )
    }

    override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
        manager()?.bindPreview(textureView)
    }

    override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {
        manager()?.previewResized(textureView, width, height)
    }

    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
        manager()?.unbindPreview(textureView)
        return true
    }

    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {}

    override fun getView(): View = textureView

    override fun dispose() {
        manager()?.unbindPreview(textureView)
    }
}
