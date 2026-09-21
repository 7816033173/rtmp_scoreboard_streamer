import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:rtmp_scoreboard_streamer/rtmp_scoreboard_streamer.dart';

void main() => runApp(const MaterialApp(home: Harness()));

/// Test harness: preview, RTMP push, and a scoreboard whose PNG is re-sent on every score change.
class Harness extends StatefulWidget {
  const Harness({super.key});

  @override
  State<Harness> createState() => _HarnessState();
}

class _HarnessState extends State<Harness> {
  final _plugin = RtmpScoreboardStreamer.instance;
  final _url = TextEditingController(text: 'rtmp://a.rtmp.youtube.com/live2/');
  StreamSubscription<RtmpEvent>? _sub;

  bool _ready = false;
  bool _live = false;
  bool _break = false;
  int _anchorIndex = 1; // 0 is custom; start at topLeft
  int _home = 0;
  int _away = 0;
  String _log = 'idle';

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _init();
  }

  Future<void> _init() async {
    final statuses = await [Permission.camera, Permission.microphone].request();
    if (statuses.values.any((s) => !s.isGranted)) {
      setState(() => _log = 'camera/microphone permission denied');
      return;
    }
    _sub = _plugin.events.listen((e) {
      setState(() {
        _log = e.toString();
        if (e.type == 'connected') _live = true;
        if (e.type == 'disconnected') _live = false;
      });
    });
    try {
      await _plugin.initPreview();
      await _pushScore();
      setState(() => _ready = true);
    } on PlatformException catch (e) {
      setState(() => _log = '${e.code}: ${e.message}');
    }
  }

  Future<Uint8List> _cardPng(String text, {double w = 640, double h = 120, double font = 56}) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, h), const Radius.circular(16)),
      Paint()..color = const Color(0xE6101820),
    );
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: Colors.white, fontSize: font, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: w);
    tp.paint(canvas, Offset((w - tp.width) / 2, (h - tp.height) / 2));
    final image = await recorder.endRecording().toImage(w.toInt(), h.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  Future<void> _pushScore() async => _plugin.setOverlay(
        'badge',
        await _cardPng('HOME  $_home  -  $_away  AWAY'),
        width: 40,
        anchor: OverlayAnchor.values[_anchorIndex],
        x: 2,
        y: 3,
      );

  Future<void> _moveBadge() async {
    setState(() => _anchorIndex = _anchorIndex % (OverlayAnchor.values.length - 1) + 1);
    await _pushScore();
  }

  Future<void> _toggleBreak() async {
    setState(() => _break = !_break);
    if (_break) {
      await _plugin.setOverlay(
        'break',
        await _cardPng('BREAK TIME', w: 800, h: 300, font: 110),
        width: 60,
        anchor: OverlayAnchor.center,
      );
    } else {
      await _plugin.removeOverlay('break');
    }
  }

  Future<void> _score(bool home) async {
    setState(() => home ? _home++ : _away++);
    await _pushScore();
  }

  Future<void> _toggleLive() async {
    try {
      if (_live) {
        await _plugin.stopStream();
        setState(() => _live = false);
      } else {
        await _plugin.startStream(_url.text.trim());
      }
    } on PlatformException catch (e) {
      setState(() => _log = '${e.code}: ${e.message}');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _plugin.release();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Row(
        children: [
          Expanded(
            child: _ready ? const RtmpScoreboardPreview() : Center(child: Text(_log, style: const TextStyle(color: Colors.white))),
          ),
          SizedBox(
            width: 280,
            child: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _url,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      decoration: const InputDecoration(labelText: 'RTMP url + key', labelStyle: TextStyle(color: Colors.white70)),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(onPressed: _ready ? _toggleLive : null, child: Text(_live ? 'Stop' : 'Go live')),
                    const SizedBox(height: 8),
                    OutlinedButton(onPressed: _ready ? () => _score(true) : null, child: const Text('Home +1')),
                    OutlinedButton(onPressed: _ready ? () => _score(false) : null, child: const Text('Away +1')),
                    OutlinedButton(onPressed: _ready ? _toggleBreak : null, child: Text(_break ? 'Hide break card' : 'Show break card')),
                    OutlinedButton(onPressed: _ready ? _moveBadge : null, child: Text('Move badge: ${OverlayAnchor.values[_anchorIndex].name}')),
                    OutlinedButton(onPressed: _ready ? _plugin.switchCamera : null, child: const Text('Flip camera')),
                    const SizedBox(height: 8),
                    Text(_log, style: const TextStyle(color: Colors.white70, fontSize: 11)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
