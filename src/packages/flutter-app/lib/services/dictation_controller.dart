import 'dart:async';

import 'package:flutter/widgets.dart';

import 'dictation_engine.dart';

enum DictationStatus { idle, listening, transcribing }

/// Drives one composer's mic button (specs/voice-dictation). Owned by the
/// chat panel state alongside its [TextEditingController] — dictation state
/// is per-composer (the agent tab and the trip refine panel each have one),
/// so it lives here rather than in a global provider.
///
/// Transcripts are appended, never clobbering typed text: the session
/// snapshots the field as `_base`, partials render as an overlay on top of
/// it, and each final result is committed into it. A genuine user edit while
/// listening cancels the session and keeps the edit.
/// Why dictation stopped, as a code the UI turns into localized copy
/// (specs/i18n-spanish). The controller has no BuildContext of its own.
enum DictationError {
  permissionBlocked,
  unsupportedBrowser,
  unavailable,
  transcriptionFailed,
}

class DictationController extends ChangeNotifier {
  final TextEditingController textController;
  final DictationEngine? primary;
  final DictationEngine? fallback;

  /// Whether the server-side fallback is configured (cached provider read).
  final Future<bool> Function() fallbackAvailable;

  DictationController({
    required this.textController,
    required this.primary,
    required this.fallback,
    required this.fallbackAvailable,
  }) {
    textController.addListener(_onTextChanged);
    _init();
  }

  DictationEngine? _engine;
  DictationStatus _status = DictationStatus.idle;
  bool _available = false;
  bool _initDone = false;
  bool _fallbackDead = false;
  bool _disposed = false;

  StreamSubscription<DictationEvent>? _session;
  String _base = '';
  bool _applyingTranscript = false;
  bool _retriedWithFallback = false;

  /// One-shot user-facing error message; the widget shows it (SnackBar) and
  /// clears it via [consumeError].
  ///
  /// A code, not a sentence: this is a service with no BuildContext, so it
  /// cannot look up localized copy. The chat panel maps it (specs/i18n-spanish).
  DictationError? _errorMessage;

  DictationStatus get status => _status;

  /// False until init resolves, and false when no capture path exists — the
  /// mic button isn't rendered in either case.
  bool get available => _initDone && _available;

  DictationError? consumeError() {
    final message = _errorMessage;
    _errorMessage = null;
    return message;
  }

  Future<void> _init() async {
    var primaryOk = false;
    if (primary != null) primaryOk = await primary!.initialize();
    if (_disposed) return;
    if (primaryOk) {
      _engine = primary;
      _available = true;
    } else if (await _fallbackUsable()) {
      _engine = fallback;
      _available = true;
    } else {
      _available = false;
    }
    if (_disposed) return;
    _initDone = true;
    notifyListeners();
  }

  Future<bool> _fallbackUsable() async {
    if (fallback == null || _fallbackDead) return false;
    try {
      return await fallbackAvailable();
    } catch (_) {
      return false;
    }
  }

  /// Mic tap: idle starts a session, listening stops it (finals still
  /// arrive), transcribing ignores taps.
  Future<void> toggle() async {
    switch (_status) {
      case DictationStatus.idle:
        _startSession();
      case DictationStatus.listening:
        await _engine?.stop();
      case DictationStatus.transcribing:
        break;
    }
  }

  void _startSession() {
    final engine = _engine;
    if (engine == null || !_available) return;
    _base = textController.text.trimRight();
    _retriedWithFallback = false;
    _status = DictationStatus.listening;
    _session = engine.start().listen(_onEvent, onDone: _onSessionEnd);
    notifyListeners();
  }

  void _onEvent(DictationEvent event) {
    switch (event.type) {
      case 'partial':
        if (event.text.isNotEmpty) _setText(_joined(event.text));
      case 'final':
        if (event.text.isNotEmpty) {
          _base = _joined(event.text);
          _setText(_base);
        }
      case 'transcribing':
        _status = DictationStatus.transcribing;
        notifyListeners();
      case 'error':
        _onError(event.errorCode);
    }
  }

  String _joined(String transcript) {
    if (_base.isEmpty) return transcript;
    return '$_base $transcript';
  }

  void _setText(String text) {
    _applyingTranscript = true;
    textController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _applyingTranscript = false;
  }

  void _onError(String code) {
    switch (code) {
      case 'permission':
        // Several mobile/WebKit browsers (iOS Safari and iOS/Android Chrome
        // among them) report a spurious 'not-allowed' from the live engine
        // even though the microphone itself works fine — confirmed by the
        // `record` plugin succeeding on the same device/browser where
        // `speech_to_text` immediately errors. Retry once via the recorder
        // fallback before treating this as a real permission denial; if the
        // fallback also can't get the mic, it really was blocked.
        if (_engine == primary && fallback != null) {
          _switchToFallbackAndRetry(
              giveUpError: DictationError.permissionBlocked);
          return;
        }
        _errorMessage = DictationError.permissionBlocked;
      case 'engine-failed':
        // The live engine exists but doesn't work here (Brave-style forks).
        // Degrade to the recorder path for the rest of the app session and
        // retry this dictation once, so the tap isn't wasted.
        if (_engine == primary) {
          _switchToFallbackAndRetry();
          return;
        }
        _errorMessage = DictationError.unsupportedBrowser;
      case 'unavailable':
        // Server says the fallback is not configured — hide the mic.
        _fallbackDead = true;
        if (_engine == fallback) _available = false;
        _errorMessage = DictationError.unavailable;
      default:
        _errorMessage = DictationError.transcriptionFailed;
    }
    notifyListeners();
  }

  Future<void> _switchToFallbackAndRetry({
    DictationError giveUpError = DictationError.unsupportedBrowser,
  }) async {
    final retry = !_retriedWithFallback;
    _retriedWithFallback = true;
    await _endSession(cancelEngine: true);
    if (_disposed) return;
    if (await _fallbackUsable()) {
      _engine = fallback;
      if (retry) {
        _startSession();
        return;
      }
    } else {
      _available = false;
      _errorMessage = giveUpError;
    }
    notifyListeners();
  }

  void _onSessionEnd() {
    _session = null;
    if (_status != DictationStatus.idle) {
      _status = DictationStatus.idle;
      notifyListeners();
    }
  }

  Future<void> _endSession({bool cancelEngine = false}) async {
    final session = _session;
    _session = null;
    if (cancelEngine) await _engine?.cancel();
    await session?.cancel();
    if (_status != DictationStatus.idle) {
      _status = DictationStatus.idle;
      if (!_disposed) notifyListeners();
    }
  }

  void _onTextChanged() {
    // A user edit mid-session takes precedence: stop dictating, keep the
    // edit. Our own transcript writes are guarded.
    if (_applyingTranscript || _status != DictationStatus.listening) return;
    _endSession(cancelEngine: true);
  }

  @override
  void dispose() {
    _disposed = true;
    textController.removeListener(_onTextChanged);
    _endSession(cancelEngine: true);
    super.dispose();
  }
}
