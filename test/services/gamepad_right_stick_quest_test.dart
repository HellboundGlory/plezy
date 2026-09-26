// Meta Quest Touch controllers report their single thumbstick on the
// right-stick axes. Verified with `getevent` on a Quest 3: the controllers emit
// ABS_RX/ABS_RY only, and never ABS_X/ABS_Y, so navigation that listens solely
// to the left stick gets nothing at all on the headset.
//
// The other half of the fix is in packages/universal_gamepad, which is vendored
// so the Android plugin maps AXIS_RX/AXIS_RY in the first place.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/gamepad_service.dart';
import 'package:universal_gamepad/universal_gamepad.dart';

void main() {
  testWidgets('right stick down navigates down, like the left stick', (tester) async {
    final events = await _pumpKeyEventRecorder(tester);
    final service = GamepadService.forTesting(duplicateInputGuard: GamepadDuplicateInputGuard(enabled: () => false));

    service.debugHandleGamepadEvent(_axis(GamepadAxis.rightStickY, 1.0));
    await tester.pump();

    expect(_downCount(events, LogicalKeyboardKey.arrowDown), 1);
    service.debugHandleGamepadEvent(_axis(GamepadAxis.rightStickY, 0.0));
    await tester.pump();
  });

  testWidgets('right stick up navigates up', (tester) async {
    final events = await _pumpKeyEventRecorder(tester);
    final service = GamepadService.forTesting(duplicateInputGuard: GamepadDuplicateInputGuard(enabled: () => false));

    service.debugHandleGamepadEvent(_axis(GamepadAxis.rightStickY, -1.0));
    await tester.pump();

    expect(_downCount(events, LogicalKeyboardKey.arrowUp), 1);
    service.debugHandleGamepadEvent(_axis(GamepadAxis.rightStickY, 0.0));
    await tester.pump();
  });

  testWidgets('right stick left and right navigate horizontally, not inverted', (tester) async {
    final events = await _pumpKeyEventRecorder(tester);
    final service = GamepadService.forTesting(duplicateInputGuard: GamepadDuplicateInputGuard(enabled: () => false));

    service.debugHandleGamepadEvent(_axis(GamepadAxis.rightStickX, -1.0));
    await tester.pump();
    expect(_downCount(events, LogicalKeyboardKey.arrowLeft), 1);
    expect(_downCount(events, LogicalKeyboardKey.arrowRight), 0, reason: 'pushing left must not navigate right');

    service.debugHandleGamepadEvent(_axis(GamepadAxis.rightStickX, 0.0));
    await tester.pump();
    service.debugHandleGamepadEvent(_axis(GamepadAxis.rightStickX, 1.0));
    await tester.pump();
    expect(_downCount(events, LogicalKeyboardKey.arrowRight), 1);

    service.debugHandleGamepadEvent(_axis(GamepadAxis.rightStickX, 0.0));
    await tester.pump();
  });

  testWidgets('a centred right stick inside the deadzone does not navigate', (tester) async {
    final events = await _pumpKeyEventRecorder(tester);
    final service = GamepadService.forTesting(duplicateInputGuard: GamepadDuplicateInputGuard(enabled: () => false));

    service.debugHandleGamepadEvent(_axis(GamepadAxis.rightStickY, 0.2));
    service.debugHandleGamepadEvent(_axis(GamepadAxis.rightStickX, -0.3));
    await tester.pump();

    expect(_downCount(events, LogicalKeyboardKey.arrowDown), 0);
    expect(_downCount(events, LogicalKeyboardKey.arrowLeft), 0);
  });
}

GamepadAxisEvent _axis(GamepadAxis axis, double value) {
  return GamepadAxisEvent(gamepadId: 1, timestamp: 0, axis: axis, value: value);
}

int _downCount(List<KeyEvent> events, LogicalKeyboardKey key) =>
    events.where((e) => e is KeyDownEvent && e.logicalKey == key).length;

Future<List<KeyEvent>> _pumpKeyEventRecorder(WidgetTester tester) async {
  final events = <KeyEvent>[];
  final focusNode = FocusNode();
  await tester.pumpWidget(
    MaterialApp(
      home: Focus(
        focusNode: focusNode,
        autofocus: true,
        onKeyEvent: (node, event) {
          events.add(event);
          return KeyEventResult.handled;
        },
        child: const SizedBox.expand(),
      ),
    ),
  );
  await tester.pump();
  return events;
}
