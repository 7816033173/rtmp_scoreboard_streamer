import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// A status event from the native streaming layer.
class RtmpEvent {
  const RtmpEvent(this.type, {this.code, this.message});

  /// One of: previewBound, previewUnbound, connected, disconnected, error.
  final String type;
  final String? code;
  final String? message;

  factory RtmpEvent.fromMap(Map<dynamic, dynamic> map) => RtmpEvent(
        map['type'] as String,
        code: map['code'] as String?,
        message: (map['message'] ?? map['reason']) as String?,
      );

  @override
  String toString() => 'RtmpEvent($type, $code, $message)';
}

/// Where an overlay sits on the frame. The `x`/`y` values passed with it are the margin (percent
/// of the frame) from the anchored edge(s); for [custom] they are the top-left corner instead.
enum OverlayAnchor {
  custom,
  topLeft,
  topCenter,
  topRight,
  centerLeft,
  center,
  centerRight,
  bottomLeft,
  bottomCenter,
  bottomRight,
}

/// Camera -> scoreboard overlay -> RTMP, composited natively so the overlay is part of the
/// video sent to every viewer. Flutter owns the UI; the native layer owns the video pipeline.
class RtmpScoreboardStreamer {
  RtmpScoreboardStreamer._();

  static final RtmpScoreboardStreamer instance = RtmpScoreboardStreamer._();

  static const MethodChannel _methods = MethodChannel('rtmp_scoreboard_streamer');
  static const EventChannel _events = EventChannel('rtmp_scoreboard_streamer/events');

  Stream<RtmpEvent>? _stream;

  /// Broadcast stream of native events. Listen before calling [initPreview].
  Stream<RtmpEvent> get events => _stream ??= _events
      .receiveBroadcastStream()
      .map((e) => RtmpEvent.fromMap(e as Map<dynamic, dynamic>));

  /// Prepares the encoder and camera. Show [RtmpScoreboardPreview] afterwards to bind the preview.
  Future<void> initPreview({
    int width = 1280,
    int height = 720,
    int fps = 30,
    int bitrate = 2500000,
    bool front = false,
  }) =>
      _methods.invokeMethod('initPreview', {
        'width': width,
        'height': height,
        'fps': fps,
        'bitrate': bitrate,
        'front': front,
      });

  /// [url] is the full RTMP endpoint including the stream key, e.g. `rtmp://a.rtmp.youtube.com/live2/KEY`.
  Future<void> startStream(String url) => _methods.invokeMethod('startStream', {'url': url});

  Future<void> stopStream() => _methods.invokeMethod('stopStream');

  Future<void> switchCamera() => _methods.invokeMethod('switchCamera');

  /// Mutes or unmutes the microphone in the outgoing stream.
  Future<void> setMuted(bool muted) => _methods.invokeMethod('setMuted', {'muted': muted});

  /// Adds or updates the overlay named [id] and draws [png] onto every outgoing frame.
  /// [width] is percent of the frame width; height follows the image's aspect ratio. Place it with
  /// [anchor] (e.g. [OverlayAnchor.center], [OverlayAnchor.topRight]) plus [x]/[y] as margins in
  /// percent, or with [OverlayAnchor.custom] and [x]/[y] as the top-left corner. Overlays stack in the order their ids were first used (later = on top).
  /// Call again with the same [id] to replace its image or move it.
  Future<void> setOverlay(
    String id,
    Uint8List png, {
    double width = 40,
    OverlayAnchor anchor = OverlayAnchor.topLeft,
    double x = 2,
    double y = 2,
  }) =>
      _methods.invokeMethod('setOverlay', {
        'id': id,
        'png': png,
        'width': width,
        'anchor': anchor.name,
        'x': x,
        'y': y,
      });

  /// Removes the overlay named [id]. No-op if it doesn't exist.
  Future<void> removeOverlay(String id) => _methods.invokeMethod('removeOverlay', {'id': id});

  /// Removes every overlay.
  Future<void> clearOverlays() => _methods.invokeMethod('clearOverlays');

  Future<void> release() => _methods.invokeMethod('release');
}

/// The live camera preview. Place it in the tree after calling [RtmpScoreboardStreamer.initPreview].
class RtmpScoreboardPreview extends StatelessWidget {
  const RtmpScoreboardPreview({super.key});

  @override
  Widget build(BuildContext context) {
    const viewType = 'rtmp_scoreboard_streamer/preview';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return const AndroidView(viewType: viewType, creationParamsCodec: StandardMessageCodec());
      case TargetPlatform.iOS:
        return const UiKitView(viewType: viewType, creationParamsCodec: StandardMessageCodec());
      default:
        return const SizedBox.shrink();
    }
  }
}
