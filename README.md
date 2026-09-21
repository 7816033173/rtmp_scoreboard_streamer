# rtmp_scoreboard_streamer

Flutter plugin that streams the phone camera over RTMP with overlay images composited into the
video natively, so every viewer sees the overlays (a Flutter widget alone cannot draw into an
outgoing RTMP feed).

Flutter owns the UI and state. You render any widget to a PNG and hand it to the plugin; the
native layer draws it on each frame before encoding.

| | Android | iOS |
|---|---|---|
| Engine | [RootEncoder](https://github.com/pedroSG94/RootEncoder) 2.7.2 | [HaishinKit](https://github.com/HaishinKit/HaishinKit.swift) 2.0.9 |
| Status | Tested on a device | Written, not yet built or tested |

## Usage

```dart
final rtmp = RtmpScoreboardStreamer.instance;

rtmp.events.listen((e) => debugPrint('$e'));   // previewBound, connected, disconnected, error
await rtmp.initPreview(width: 1280, height: 720, fps: 30, bitrate: 2500000);

// Show the preview somewhere in your tree
const RtmpScoreboardPreview();

// Overlays are named layers; later ones draw on top.
await rtmp.setOverlay('badge', badgePng, width: 25, anchor: OverlayAnchor.topLeft, x: 2, y: 3);
await rtmp.setOverlay('break', breakPng, width: 60, anchor: OverlayAnchor.center);
await rtmp.removeOverlay('break');

await rtmp.startStream('rtmp://a.rtmp.youtube.com/live2/STREAM_KEY');
await rtmp.stopStream();
await rtmp.release();
```

`width` is a percent of the frame width; height follows the image's aspect ratio. With an anchor
(`topLeft`, `topCenter`, `topRight`, `centerLeft`, `center`, `centerRight`, `bottomLeft`,
`bottomCenter`, `bottomRight`), `x`/`y` are margins in percent of the frame. With
`OverlayAnchor.custom` they are the top-left corner.

Broadcasting is landscape-only. Request camera and microphone permission before `initPreview`.

## Setup notes

- **Android:** RootEncoder is only on JitPack; the plugin registers the repository itself. It is
  pinned to 2.7.2 because 2.8.x requires compileSdk 37 / AGP 9.3+.
- **iOS:** HaishinKit is pinned to 2.0.9, the last release on CocoaPods (2.1+ is Swift Package
  Manager only). Add `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` to Info.plist.
- Overlays are re-applied after preview/stream start on Android because RootEncoder's GL pipeline
  drops filters across those transitions.

The `example/` app is a test harness: preview, go live, score buttons, a break card, and a button
that cycles the badge through every anchor.
