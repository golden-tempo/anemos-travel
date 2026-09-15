import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/services/dictation_controller.dart';
import 'package:travel_route_planner/services/dictation_engine.dart';

/// Scripted engine: the test drives events onto the active session's stream.
class _FakeEngine implements DictationEngine {
  final bool initOk;
  int startCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  StreamController<DictationEvent>? _events;

  _FakeEngine({this.initOk = true});

  @override
  Future<bool> initialize() async => initOk;

  @override
  Stream<DictationEvent> start() {
    startCalls++;
    _events = StreamController<DictationEvent>();
    return _events!.stream;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    await end();
  }

  void emit(DictationEvent event) => _events!.add(event);

  Future<void> end() async {
    final events = _events;
    _events = null;
    if (events != null && !events.isClosed) await events.close();
  }
}

DictationController _controller(
  TextEditingController text, {
  _FakeEngine? primary,
  _FakeEngine? fallback,
  bool serverAvailable = false,
}) {
  return DictationController(
    textController: text,
    primary: primary,
    fallback: fallback,
    fallbackAvailable: () async => serverAvailable,
  );
}

void main() {
  test('available when the primary engine initializes', () async {
    final text = TextEditingController();
    final dictation = _controller(text, primary: _FakeEngine());
    await pumpEventQueue();
    expect(dictation.available, isTrue);
  });

  test('falls back to the recorder engine when primary cannot initialize',
      () async {
    final text = TextEditingController();
    final primary = _FakeEngine(initOk: false);
    final fallback = _FakeEngine();
    final dictation = _controller(text,
        primary: primary, fallback: fallback, serverAvailable: true);
    await pumpEventQueue();
    expect(dictation.available, isTrue);

    await dictation.toggle();
    expect(fallback.startCalls, 1);
    expect(primary.startCalls, 0);
  });

  test('unavailable when no path exists — mic hidden', () async {
    final text = TextEditingController();
    final dictation = _controller(text,
        primary: _FakeEngine(initOk: false),
        fallback: _FakeEngine(),
        serverAvailable: false);
    await pumpEventQueue();
    expect(dictation.available, isFalse);

    await dictation.toggle();
    expect(dictation.status, DictationStatus.idle);
  });

  test('appends transcripts to typed text; partials overlay, finals commit',
      () async {
    final text = TextEditingController(text: 'Also: ');
    final engine = _FakeEngine();
    final dictation = _controller(text, primary: engine);
    await pumpEventQueue();

    await dictation.toggle();
    expect(dictation.status, DictationStatus.listening);

    // Web Speech partials are cumulative — each replaces the previous
    // overlay rather than stacking.
    engine.emit(const DictationEvent('partial', text: 'two'));
    await pumpEventQueue();
    expect(text.text, 'Also: two');

    engine.emit(const DictationEvent('partial', text: 'two days in'));
    await pumpEventQueue();
    expect(text.text, 'Also: two days in');

    engine.emit(const DictationEvent('final', text: 'two days in athens'));
    await pumpEventQueue();
    expect(text.text, 'Also: two days in athens');
    expect(text.selection.baseOffset, text.text.length,
        reason: 'caret pinned to the end');

    await engine.end();
    await pumpEventQueue();
    expect(dictation.status, DictationStatus.idle);
    expect(text.text, 'Also: two days in athens',
        reason: 'transcript survives the session ending');
  });

  test('a session that ends with no speech leaves the field untouched',
      () async {
    final text = TextEditingController(text: 'typed');
    final engine = _FakeEngine();
    final dictation = _controller(text, primary: engine);
    await pumpEventQueue();

    await dictation.toggle();
    await engine.end();
    await pumpEventQueue();
    expect(text.text, 'typed');
    expect(dictation.status, DictationStatus.idle);
    expect(dictation.consumeError(), isNull);
  });

  test('a user edit while listening cancels the session and keeps the edit',
      () async {
    final text = TextEditingController();
    final engine = _FakeEngine();
    final dictation = _controller(text, primary: engine);
    await pumpEventQueue();

    await dictation.toggle();
    engine.emit(const DictationEvent('partial', text: 'hello'));
    await pumpEventQueue();
    expect(text.text, 'hello');

    text.text = 'hello everyone'; // genuine user edit
    await pumpEventQueue();
    expect(engine.cancelCalls, 1);
    expect(dictation.status, DictationStatus.idle);
    expect(text.text, 'hello everyone');
  });

  test('permission errors surface a one-shot message when there is no '
      'fallback to retry', () async {
    final text = TextEditingController();
    final engine = _FakeEngine();
    final dictation = _controller(text, primary: engine);
    await pumpEventQueue();

    await dictation.toggle();
    engine.emit(const DictationEvent('error', errorCode: 'permission'));
    await engine.end();
    await pumpEventQueue();

    expect(dictation.consumeError(), DictationError.permissionBlocked);
    expect(dictation.consumeError(), isNull, reason: 'one-shot');
    expect(dictation.status, DictationStatus.idle);
  });

  test(
      'a spurious not-allowed on the live path retries via the fallback '
      'before treating it as a real denial (mobile/WebKit quirk)', () async {
    final text = TextEditingController();
    final primary = _FakeEngine();
    final fallback = _FakeEngine();
    final dictation = _controller(text,
        primary: primary, fallback: fallback, serverAvailable: true);
    await pumpEventQueue();

    await dictation.toggle();
    expect(primary.startCalls, 1);

    primary.emit(const DictationEvent('error', errorCode: 'permission'));
    await pumpEventQueue();

    expect(fallback.startCalls, 1, reason: 'retried on the recorder path');
    expect(dictation.status, DictationStatus.listening);
    expect(dictation.available, isTrue);
    expect(dictation.consumeError(), isNull,
        reason: 'no error surfaced while the retry is in flight');

    // Later sessions go straight to the fallback.
    fallback.emit(const DictationEvent('final', text: 'hi'));
    await fallback.end();
    await pumpEventQueue();
    await dictation.toggle();
    expect(fallback.startCalls, 2);
    expect(primary.startCalls, 1);
  });

  test(
      'permission denied on both the live path and the fallback surfaces the '
      'permission message and hides the mic', () async {
    final text = TextEditingController();
    final primary = _FakeEngine();
    final fallback = _FakeEngine();
    final dictation = _controller(text,
        primary: primary, fallback: fallback, serverAvailable: true);
    await pumpEventQueue();

    await dictation.toggle();
    primary.emit(const DictationEvent('error', errorCode: 'permission'));
    await pumpEventQueue();
    expect(fallback.startCalls, 1);

    fallback.emit(const DictationEvent('error', errorCode: 'permission'));
    await fallback.end();
    await pumpEventQueue();

    expect(dictation.consumeError(), DictationError.permissionBlocked);
    expect(dictation.status, DictationStatus.idle);
  });

  test(
      'engine-failed on the live path switches to the fallback and retries once',
      () async {
    final text = TextEditingController();
    final primary = _FakeEngine();
    final fallback = _FakeEngine();
    final dictation = _controller(text,
        primary: primary, fallback: fallback, serverAvailable: true);
    await pumpEventQueue();

    await dictation.toggle();
    expect(primary.startCalls, 1);

    // Brave-style: API present, start fails at runtime.
    primary.emit(const DictationEvent('error', errorCode: 'engine-failed'));
    await pumpEventQueue();

    expect(fallback.startCalls, 1, reason: 'retried on the recorder path');
    expect(dictation.status, DictationStatus.listening);
    expect(dictation.available, isTrue);

    // Later sessions go straight to the fallback.
    fallback.emit(const DictationEvent('final', text: 'hi'));
    await fallback.end();
    await pumpEventQueue();
    await dictation.toggle();
    expect(fallback.startCalls, 2);
    expect(primary.startCalls, 1);
  });

  test('engine-failed with no usable fallback hides the mic', () async {
    final text = TextEditingController();
    final primary = _FakeEngine();
    final dictation = _controller(text,
        primary: primary, fallback: _FakeEngine(), serverAvailable: false);
    await pumpEventQueue();

    await dictation.toggle();
    primary.emit(const DictationEvent('error', errorCode: 'engine-failed'));
    await pumpEventQueue();

    expect(dictation.available, isFalse);
    expect(dictation.consumeError(), DictationError.unsupportedBrowser);
  });

  test('a 503 mid-session hides the mic going forward', () async {
    final text = TextEditingController();
    final fallback = _FakeEngine();
    final dictation = _controller(text,
        primary: _FakeEngine(initOk: false),
        fallback: fallback,
        serverAvailable: true);
    await pumpEventQueue();
    expect(dictation.available, isTrue);

    await dictation.toggle();
    fallback.emit(const DictationEvent('error', errorCode: 'unavailable'));
    await fallback.end();
    await pumpEventQueue();

    expect(dictation.available, isFalse);
    expect(dictation.consumeError(), DictationError.unavailable);
  });

  test('transcribing status is reported for the recorder path', () async {
    final text = TextEditingController();
    final fallback = _FakeEngine();
    final dictation = _controller(text,
        primary: _FakeEngine(initOk: false),
        fallback: fallback,
        serverAvailable: true);
    await pumpEventQueue();

    await dictation.toggle();
    await dictation.toggle(); // stop -> engine uploads
    expect(fallback.stopCalls, 1);

    fallback.emit(const DictationEvent('transcribing'));
    await pumpEventQueue();
    expect(dictation.status, DictationStatus.transcribing);

    fallback.emit(const DictationEvent('final', text: 'ferry to naxos'));
    await fallback.end();
    await pumpEventQueue();
    expect(text.text, 'ferry to naxos');
    expect(dictation.status, DictationStatus.idle);
  });
}
