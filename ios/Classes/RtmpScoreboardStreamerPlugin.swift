import AVFoundation
import Flutter
import HaishinKit
import UIKit

/// Registers the method/event channels and the camera preview platform view.
///
/// Mirrors the Android implementation: camera -> offscreen screen (camera + overlay images) ->
/// RTMP. Overlays are part of the encoded video, so every viewer sees them.
public class RtmpScoreboardStreamerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let controller = StreamController()
  private var events: FlutterEventSink?
  private var pending: [[String: Any]] = []

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = RtmpScoreboardStreamerPlugin()
    let channel = FlutterMethodChannel(name: "rtmp_scoreboard_streamer", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    let eventChannel = FlutterEventChannel(name: "rtmp_scoreboard_streamer/events", binaryMessenger: registrar.messenger())
    eventChannel.setStreamHandler(instance)
    registrar.register(
      PreviewFactory(controller: instance.controller),
      withId: "rtmp_scoreboard_streamer/preview"
    )
    instance.controller.onEvent = { [weak instance] event in instance?.emit(event) }
  }

  // MARK: Events

  private func emit(_ event: [String: Any]) {
    DispatchQueue.main.async {
      if let sink = self.events {
        sink(event)
      } else if self.pending.count < 32 {
        self.pending.append(event)
      }
    }
  }

  public func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
    events = eventSink
    let drained = pending
    pending.removeAll()
    drained.forEach { eventSink($0) }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    events = nil
    return nil
  }

  // MARK: Method calls

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    Task {
      do {
        switch call.method {
        case "initPreview":
          try await controller.prepare(
            width: args["width"] as? Int ?? 1280,
            height: args["height"] as? Int ?? 720,
            fps: args["fps"] as? Int ?? 30,
            bitrate: args["bitrate"] as? Int ?? 2_500_000,
            front: args["front"] as? Bool ?? false
          )
          result(nil)
        case "startStream":
          guard let url = args["url"] as? String else { throw PluginError.invalidArguments("url") }
          try await controller.startStream(url: url)
          result(nil)
        case "stopStream":
          await controller.stopStream()
          result(nil)
        case "switchCamera":
          try await controller.switchCamera()
          result(nil)
        case "setMuted":
          await controller.setMuted(args["muted"] as? Bool ?? false)
          result(nil)
        case "setOverlay":
          guard let id = args["id"] as? String,
                let png = (args["png"] as? FlutterStandardTypedData)?.data
          else { throw PluginError.invalidArguments("id/png") }
          try await controller.setOverlay(
            id: id,
            png: png,
            widthPct: args["width"] as? Double ?? 40,
            anchor: args["anchor"] as? String ?? "custom",
            x: args["x"] as? Double ?? 2,
            y: args["y"] as? Double ?? 2
          )
          result(nil)
        case "removeOverlay":
          guard let id = args["id"] as? String else { throw PluginError.invalidArguments("id") }
          await controller.removeOverlay(id: id)
          result(nil)
        case "clearOverlays":
          await controller.clearOverlays()
          result(nil)
        case "release":
          await controller.release()
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch let error as PluginError {
        result(FlutterError(code: error.code, message: error.message, details: nil))
      } catch {
        result(FlutterError(code: "NATIVE_ERROR", message: "\(error)", details: nil))
      }
    }
  }
}

enum PluginError: Error {
  case invalidArguments(String)
  case notReady(String)
  case decode
  case invalidUrl

  var code: String {
    switch self {
    case .invalidArguments: return "INVALID_ARGUMENTS"
    case .notReady: return "PREVIEW_NOT_READY"
    case .decode: return "OVERLAY_DECODE_FAILED"
    case .invalidUrl: return "INVALID_URL"
    }
  }

  var message: String {
    switch self {
    case .invalidArguments(let what): return "Missing or invalid argument: \(what)"
    case .notReady(let why): return why
    case .decode: return "Overlay PNG could not be decoded"
    case .invalidUrl: return "Expected rtmp://host/app/streamKey"
    }
  }
}

// MARK: - Preview platform view

final class PreviewFactory: NSObject, FlutterPlatformViewFactory {
  private let controller: StreamController

  init(controller: StreamController) {
    self.controller = controller
    super.init()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    PreviewPlatformView(frame: frame, controller: controller)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

final class PreviewPlatformView: NSObject, FlutterPlatformView {
  private let container: UIView
  private let hkView: MTHKView
  private let controller: StreamController

  init(frame: CGRect, controller: StreamController) {
    self.controller = controller
    container = UIView(frame: frame)
    hkView = MTHKView(frame: frame)
    super.init()
    hkView.videoGravity = .resizeAspect
    hkView.frame = container.bounds
    hkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    container.backgroundColor = .black
    container.addSubview(hkView)
    let view = hkView
    Task { await controller.attachPreview(view) }
  }

  func view() -> UIView { container }

  deinit {
    let view = hkView
    let controller = controller
    Task { await controller.detachPreview(view) }
  }
}

// MARK: - Stream controller

/// Owns the mixer, the RTMP connection and the overlay layers. All calls come in from Flutter's
/// method channel; HaishinKit's own actors handle the threading.
actor StreamController {
  nonisolated(unsafe) var onEvent: (([String: Any]) -> Void)?

  private let mixer = MediaMixer(multiCamSessionEnabled: false, multiTrackAudioMixingEnabled: false)
  private let layers = OverlayLayers()
  private var connection: RTMPConnection?
  private var stream: RTMPStream?
  private var statusTask: Task<Void, Never>?
  private var previews: [ObjectIdentifier: MTHKView] = [:]

  private var prepared = false
  private var front = false
  private var size = CGSize(width: 1280, height: 720)
  private var bitrate = 2_500_000

  private func emit(_ event: [String: Any]) {
    onEvent?(event)
  }

  // MARK: Preview

  func attachPreview(_ view: MTHKView) async {
    previews[ObjectIdentifier(view)] = view
    await mixer.addOutput(view)
    emit(["type": "previewBound"])
  }

  func detachPreview(_ view: MTHKView) async {
    previews.removeValue(forKey: ObjectIdentifier(view))
    await mixer.removeOutput(view)
    emit(["type": "previewUnbound"])
  }

  // MARK: Prepare

  func prepare(width: Int, height: Int, fps: Int, bitrate: Int, front: Bool) async throws {
    size = CGSize(width: width, height: height)
    self.bitrate = bitrate
    self.front = front

    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
    try session.setActive(true)

    await mixer.setFrameRate(Float64(fps))
    await mixer.setSessionPreset(height >= 1080 ? .hd1920x1080 : .hd1280x720)
    // Offscreen mode renders the camera plus overlay objects into every frame before encoding.
    await mixer.setVideoMixerSettings(VideoMixerSettings(mode: .offscreen))
    await mixer.setVideoOrientation(await Self.currentVideoOrientation())
    await layers.configure(mixer: mixer, size: size)

    try await mixer.attachAudio(AVCaptureDevice.default(for: .audio))
    try await mixer.attachVideo(Self.camera(front: front))
    prepared = true
  }

  func switchCamera() async throws {
    guard prepared else { throw PluginError.notReady("call initPreview first") }
    front.toggle()
    try await mixer.attachVideo(Self.camera(front: front))
  }

  func setMuted(_ muted: Bool) async {
    var settings = await mixer.audioMixerSettings
    settings.isMuted = muted
    await mixer.setAudioMixerSettings(settings)
  }

  private static func camera(front: Bool) -> AVCaptureDevice? {
    AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back)
  }

  @MainActor
  private static func currentVideoOrientation() -> AVCaptureVideoOrientation {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    switch scene?.interfaceOrientation {
    case .landscapeLeft: return .landscapeLeft
    case .landscapeRight: return .landscapeRight
    default: return .landscapeRight
    }
  }

  // MARK: Streaming

  /// `url` is `rtmp://host/app/streamKey`; the last path segment is the stream key.
  func startStream(url: String) async throws {
    guard prepared else { throw PluginError.notReady("call initPreview first") }
    guard let slash = url.lastIndex(of: "/") else { throw PluginError.invalidUrl }
    let base = String(url[..<slash])
    let key = String(url[url.index(after: slash)...])
    guard !key.isEmpty, base.hasPrefix("rtmp") else { throw PluginError.invalidUrl }

    await stopStream()

    let connection = RTMPConnection()
    let stream = RTMPStream(connection: connection)
    self.connection = connection
    self.stream = stream

    var settings = await stream.videoSettings
    settings.videoSize = size
    settings.bitRate = bitrate
    await stream.setVideoSettings(settings)
    await mixer.addOutput(stream)

    statusTask = Task { [weak self] in
      for await status in await connection.status {
        guard let self else { return }
        if status.code == RTMPConnection.Code.connectClosed.rawValue
          || status.code == RTMPConnection.Code.connectFailed.rawValue
          || status.code == RTMPConnection.Code.connectRejected.rawValue
        {
          await self.emit(["type": "disconnected", "reason": status.description])
        }
      }
    }

    do {
      _ = try await connection.connect(base)
      _ = try await stream.publish(key)
      emit(["type": "connected"])
    } catch {
      await stopStream()
      emit(["type": "disconnected", "reason": "\(error)"])
      throw error
    }
  }

  func stopStream() async {
    statusTask?.cancel()
    statusTask = nil
    if let stream {
      _ = try? await stream.close()
      await mixer.removeOutput(stream)
    }
    try? await connection?.close()
    stream = nil
    connection = nil
  }

  // MARK: Overlays

  func setOverlay(id: String, png: Data, widthPct: Double, anchor: String, x: Double, y: Double) async throws {
    try await layers.set(mixer: mixer, id: id, png: png, widthPct: widthPct, anchor: anchor, x: x, y: y)
  }

  func removeOverlay(id: String) async {
    await layers.remove(mixer: mixer, id: id)
  }

  func clearOverlays() async {
    await layers.clear(mixer: mixer)
  }

  // MARK: Teardown

  func release() async {
    await stopStream()
    await layers.clear(mixer: mixer)
    for view in previews.values { await mixer.removeOutput(view) }
    previews.removeAll()
    try? await mixer.attachVideo(nil)
    try? await mixer.attachAudio(nil)
    prepared = false
  }
}

// MARK: - Overlay layers

/// Named overlay images drawn on the mixer's offscreen screen. Insertion order is z-order.
/// Kept on HaishinKit's ScreenActor because ScreenObject is isolated to it.
@ScreenActor
final class OverlayLayers {
  private var objects: [String: ImageScreenObject] = [:]
  private var frame = CGSize(width: 1280, height: 720)

  func configure(mixer: MediaMixer, size: CGSize) async {
    frame = size
    let screen = await mixer.screen
    screen.size = size
  }

  func set(mixer: MediaMixer, id: String, png: Data, widthPct: Double, anchor: String, x: Double, y: Double) async throws {
    guard let image = UIImage(data: png)?.cgImage else { throw PluginError.decode }
    let screen = await mixer.screen

    let object: ImageScreenObject
    if let existing = objects[id] {
      object = existing
    } else {
      object = ImageScreenObject()
      objects[id] = object
      try screen.addChild(object)
    }

    // Width is percent of the frame width; height follows the image aspect ratio.
    let width = frame.width * CGFloat(widthPct / 100)
    let height = width * CGFloat(image.height) / CGFloat(image.width)
    let marginX = frame.width * CGFloat(x / 100)
    let marginY = frame.height * CGFloat(y / 100)

    object.cgImage = image
    object.size = CGSize(width: width, height: height)
    object.horizontalAlignment = Self.horizontal(anchor)
    object.verticalAlignment = Self.vertical(anchor)
    object.layoutMargin = UIEdgeInsets(top: marginY, left: marginX, bottom: marginY, right: marginX)
    object.invalidateLayout()
  }

  func remove(mixer: MediaMixer, id: String) async {
    guard let object = objects.removeValue(forKey: id) else { return }
    let screen = await mixer.screen
    screen.removeChild(object)
  }

  func clear(mixer: MediaMixer) async {
    let screen = await mixer.screen
    for object in objects.values { screen.removeChild(object) }
    objects.removeAll()
  }

  // "custom" places the top-left corner at (x, y): left/top alignment with those margins.
  private static func horizontal(_ anchor: String) -> ScreenObject.HorizontalAlignment {
    if anchor.hasSuffix("Left") || anchor == "custom" { return .left }
    if anchor.hasSuffix("Right") { return .right }
    return .center
  }

  private static func vertical(_ anchor: String) -> ScreenObject.VerticalAlignment {
    if anchor.hasPrefix("top") || anchor == "custom" { return .top }
    if anchor.hasPrefix("bottom") { return .bottom }
    return .middle
  }
}
