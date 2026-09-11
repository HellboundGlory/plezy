import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/quest/quest_platform.dart';
import 'package:plezy/quest/theater3d_bridge.dart';

const _methodChannelName = 'com.edde746.plezy/theater3d';
const _eventChannelName = 'com.edde746.plezy/theater3d/events';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(const MethodChannel(_methodChannelName), null);
  });

  Future<void> sendEvent(Object? event) async {
    const codec = StandardMethodCodec();
    final done = Completer<void>();
    await messenger.handlePlatformMessage(_eventChannelName, codec.encodeSuccessEnvelope(event), (_) => done.complete());
    await done.future;
    await Future<void>.delayed(Duration.zero);
  }

  group('Theater3DBridge.isAvailable', () {
    tearDown(() => QuestPlatform.debugSetIsQuest(null));

    test('is false when the device is not a Quest', () {
      QuestPlatform.debugSetIsQuest(false);
      expect(Theater3DBridge.isAvailable, isFalse);
    });

    test('still requires the THEATER_MODE_BUILD dart-define even on a detected Quest device', () {
      QuestPlatform.debugSetIsQuest(true);
      // This test binary is not compiled with --dart-define=THEATER_MODE_BUILD=true,
      // so kTheaterModeBuild const-folds false and isAvailable must stay false too
      // -- it is an AND of both signals, not isQuest alone.
      expect(kTheaterModeBuild, isFalse);
      expect(Theater3DBridge.isAvailable, isFalse);
    });
  });

  test('open sends every field the native loadfile/stereo/shader path needs', () async {
    MethodCall? call;
    messenger.setMockMethodCallHandler(const MethodChannel(_methodChannelName), (methodCall) async {
      call = methodCall;
      return null;
    });

    final bridge = Theater3DBridge();
    await bridge.open(
      uri: 'https://example.com/movie.mkv',
      headers: const {'X-Plex-Token': 'abc'},
      position: const Duration(milliseconds: 45500),
      audioTrackId: 2,
      subtitleTrackId: 3,
      stereoMode: TheaterStereoMode.synthetic,
      shaderPath: '/data/cache/shaders/pseudo3d/Pseudo3DSbs_s075.glsl',
    );

    expect(call?.method, 'open');
    expect(call?.arguments, {
      'uri': 'https://example.com/movie.mkv',
      'headers': {'X-Plex-Token': 'abc'},
      'positionMs': 45500,
      'audioTrackId': 2,
      'subtitleTrackId': 3,
      'stereoMode': 'synthetic',
      'shaderPath': '/data/cache/shaders/pseudo3d/Pseudo3DSbs_s075.glsl',
    });
  });

  test('open defaults to off/no tracks/zero position and no shader when unset', () async {
    MethodCall? call;
    messenger.setMockMethodCallHandler(const MethodChannel(_methodChannelName), (methodCall) async {
      call = methodCall;
      return null;
    });

    final bridge = Theater3DBridge();
    await bridge.open(uri: 'file:///movie.mp4', stereoMode: TheaterStereoMode.off);

    expect(call?.arguments, {
      'uri': 'file:///movie.mp4',
      'headers': <String, String>{},
      'positionMs': 0,
      'audioTrackId': null,
      'subtitleTrackId': null,
      'stereoMode': 'off',
      'shaderPath': null,
    });
  });

  test('synthetic mode still carries its own wire value distinct from sbs/ou', () async {
    MethodCall? call;
    messenger.setMockMethodCallHandler(const MethodChannel(_methodChannelName), (methodCall) async {
      call = methodCall;
      return null;
    });

    final bridge = Theater3DBridge();
    await bridge.open(uri: 'file:///movie.mp4', stereoMode: TheaterStereoMode.synthetic);

    expect((call?.arguments as Map)['stereoMode'], 'synthetic');
  });

  test('a caller error (already_open) surfaces as a PlatformException', () async {
    messenger.setMockMethodCallHandler(const MethodChannel(_methodChannelName), (call) async {
      throw PlatformException(code: 'already_open', message: 'A theater session is already active');
    });

    final bridge = Theater3DBridge();
    await expectLater(
      () => bridge.open(uri: 'file:///movie.mp4', stereoMode: TheaterStereoMode.off),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'already_open')),
    );
  });

  test('onExit demuxes only onExit-tagged events, decoding positionMs', () async {
    final bridge = Theater3DBridge();
    final events = <TheaterExitEvent>[];
    final subscription = bridge.onExit.listen(events.add);
    addTearDown(subscription.cancel);

    // An onError event on the same wire must not leak into onExit.
    await sendEvent(const {'event': 'onError', 'reason': 'panel registration failed'});
    expect(events, isEmpty);

    await sendEvent(const {'event': 'onExit', 'positionMs': 12345});
    expect(events, [const TheaterExitEvent(12345)]);
  });

  test('onError demuxes only onError-tagged events, decoding reason', () async {
    final bridge = Theater3DBridge();
    final events = <TheaterErrorEvent>[];
    final subscription = bridge.onError.listen(events.add);
    addTearDown(subscription.cancel);

    await sendEvent(const {'event': 'onExit', 'positionMs': 1});
    expect(events, isEmpty);

    await sendEvent(const {'event': 'onError', 'reason': 'mpv init failed'});
    expect(events, [const TheaterErrorEvent('mpv init failed')]);
  });

  test('onExit and onError are independent broadcast streams over one raw channel', () async {
    final bridge = Theater3DBridge();
    final exits = <TheaterExitEvent>[];
    final errors = <TheaterErrorEvent>[];
    final exitSub = bridge.onExit.listen(exits.add);
    final errorSub = bridge.onError.listen(errors.add);
    addTearDown(exitSub.cancel);
    addTearDown(errorSub.cancel);

    await sendEvent(const {'event': 'onExit', 'positionMs': 500});
    await sendEvent(const {'event': 'onError', 'reason': 'load failed'});

    expect(exits, [const TheaterExitEvent(500)]);
    expect(errors, [const TheaterErrorEvent('load failed')]);
  });
}
