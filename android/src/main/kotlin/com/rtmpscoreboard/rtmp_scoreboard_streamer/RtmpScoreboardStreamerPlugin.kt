package com.rtmpscoreboard.rtmp_scoreboard_streamer

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class RtmpScoreboardStreamerPlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private lateinit var appContext: Context
    private var manager: StreamManager? = null

    private fun mgr(): StreamManager =
        manager ?: StreamManager(appContext).also { manager = it }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "rtmp_scoreboard_streamer")
        methods.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "rtmp_scoreboard_streamer/events")
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                mgr().setSink(sink)
            }

            override fun onCancel(arguments: Any?) {
                manager?.setSink(null)
            }
        })
        binding.platformViewRegistry.registerViewFactory(
            "rtmp_scoreboard_streamer/preview",
            object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
                    PreviewView(context) { manager }
            },
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        manager?.release()
        manager = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        try {
            when (call.method) {
                "initPreview" -> {
                    mgr().prepare(
                        call.argument<Int>("width") ?: 1280,
                        call.argument<Int>("height") ?: 720,
                        call.argument<Int>("fps") ?: 30,
                        call.argument<Int>("bitrate") ?: 2_500_000,
                        call.argument<Boolean>("front") ?: false,
                        call.argument<Boolean>("fill") ?: false,
                    )
                    result.success(null)
                }
                "startStream" -> {
                    mgr().startStream(call.argument<String>("url")!!)
                    result.success(null)
                }
                "stopStream" -> {
                    mgr().stopStream()
                    result.success(null)
                }
                "switchCamera" -> {
                    mgr().switchCamera()
                    result.success(null)
                }
                "setMuted" -> {
                    mgr().setMuted(call.argument<Boolean>("muted") ?: false)
                    result.success(null)
                }
                "setOverlay" -> {
                    mgr().setOverlay(
                        call.argument<String>("id")!!,
                        call.argument<ByteArray>("png")!!,
                        (call.argument<Double>("width") ?: 40.0).toFloat(),
                        call.argument<String>("anchor") ?: "custom",
                        (call.argument<Double>("x") ?: 2.0).toFloat(),
                        (call.argument<Double>("y") ?: 2.0).toFloat(),
                    )
                    result.success(null)
                }
                "removeOverlay" -> {
                    mgr().removeOverlay(call.argument<String>("id")!!)
                    result.success(null)
                }
                "clearOverlays" -> {
                    mgr().clearOverlays()
                    result.success(null)
                }
                "release" -> {
                    manager?.release()
                    manager = null
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            val msg = t.message ?: t.javaClass.simpleName
            val prefix = msg.substringBefore(':', "")
            val code = if (prefix.isNotEmpty() && prefix.all { it.isUpperCase() || it == '_' }) prefix else "NATIVE_ERROR"
            result.error(code, msg, null)
        }
    }
}
