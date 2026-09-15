# Plan: Voice Dictation

> **HOW.** Translates `spec.md` into a file-level technical approach. Every
> decision should trace back to an acceptance criterion. See `../../CLAUDE.md`
> for repo conventions referenced below — don't restate them, point to them.

## Technical Approach

Two capture paths behind one Dart abstraction, one insertion contract:

1. **Primary — `speech_to_text` plugin** (Web Speech API on web; native
   recognizers on iOS/Android for free). Live partial transcripts. On web,
   `initialize()` only feature-detects — the browser permission prompt happens
   at first `listen()`, satisfying the user-gesture requirement.
2. **Fallback — `record` plugin** (MediaRecorder on web): capture opus audio
   (`audio/webm` on Chromium, `audio/ogg` on Firefox), POST raw bytes to
   `POST /api/v1/transcribe`, which forwards multipart to an
   **OpenAI-compatible** transcription provider. Default is Groq
   `whisper-large-v3-turbo` (fast, ~$0.04/audio-hour); OpenAI is a two-env-var
   swap via the configurable base URL — mirrors the `ANTHROPIC_BASE_URL` seam
   and the Duffel one-file-provider convention (CLAUDE.md → Key Constraints).
3. Capability detection: Web Speech availability from `initialize()`; server
   availability from `GET /api/v1/transcribe/availability` (cached
   FutureProvider). Neither → mic not rendered. Browsers that advertise Web
   Speech but fail at `start()` (Brave) degrade to the recorder path for the
   session — as do browsers where `start()` reports a spurious `not-allowed`
   without ever prompting (iOS Safari/Chrome and some Android Chrome builds):
   the controller retries once via the recorder before treating it as a real
   permission denial, since a genuinely denied prompt fails the same way on
   both paths.

Transcripts are **appended** into the composer's existing
`TextEditingController` (base-snapshot + partial overlay, finals commit to the
base); the existing send path and queue-while-streaming behavior are untouched.

Key sizing decisions: raw bytes (not multipart/base64) client→server because
the Flutter codebase has no multipart precedent and base64 inflates 33%;
60 s / 10 MiB caps; nginx `client_max_body_size 10m` on `/api/` with Go's
`bodyLimitMiddleware` staying the real per-endpoint enforcement (256 KiB
default, dedicated 10 MiB lane for `/transcribe`).

## Go API Changes

`src/packages/api/` (all files are `package main`):

- **Service:** new `transcription_service.go` following the
  `duffel_service.go` template — `TranscriptionService{APIKey, BaseURL, Model,
  Client}`, process-wide `transcriptionService` singleton, startup warning
  when the key is absent. One method `Transcribe(ctx, audio []byte, mimeType
  string) (string, error)`: builds a `mime/multipart` body (`file` part named
  `audio.<ext>` derived from the MIME type — Whisper-family endpoints key
  format off the filename — plus `model` field), POSTs
  `{BaseURL}/audio/transcriptions`, parses `{"text": ...}`.
- **Handlers:** new `transcribe_handler.go`:
  - `transcribeHandler` (POST): allowlist `Content-Type` (`audio/webm`,
    `audio/ogg`, `audio/mp4`, `audio/wav`; parameters like `;codecs=opus`
    stripped), reject empty body → 400; unconfigured service → 503
    configured-error (Duffel-style); upstream failure → 502 with generic
    message, details via `ctxLog`; success → `200 {"text","status":"success"}`.
  - `transcribeAvailabilityHandler` (GET): `200 {"available": bool}`.
- **Routes (`main.go`):** no auth (parity with `/plan`); dedicated
  `transcribeLimiter := newIPRateLimiter(10, 5)` following the `anonEvents`
  precedent — sharing `strict` (5/min) would starve `/plan` since each
  fallback dictation+send costs two tokens. Availability GET rides the
  general tier. Startup log line.
- **Middleware (`middleware.go`):** add a `/api/v1/transcribe` lane to
  `bodyLimitMiddleware` (`transcribeMaxRequestBodyBytes = 10 << 20`), same
  style as the `/plan` 4 MiB lane.
- **Types:** `TranscribeResponse{Text, Status}` and
  `TranscribeAvailabilityResponse{Available}` in `transcribe_handler.go`;
  errors reuse the existing `Response` shape.

## Flutter Changes

`src/packages/flutter-app/lib/`:

- **Models:** none — the two response shapes are tiny and parsed inline by the
  service (no `@JsonSerializable` model files needed; parity is still tracked
  below).
- **Service (`services/`):**
  - `dictation_engine.dart` — abstract `DictationEngine`
    (`initialize()`, `start()`, `stop()`, `cancel()`, event stream of
    `partial`/`final`/`done`/`error`) with `SpeechToTextEngine` (wraps
    `speech_to_text`; `pauseFor: 3s`, `listenFor: 60s`) and `RecorderEngine`
    (wraps `record` → stop → upload via the transcribe service → one final).
  - `transcribe_api_service.dart` — `transcribe(bytes, mimeType)` POSTs raw
    bytes with the recorder's reported MIME passed through verbatim (Firefox
    emits ogg); `availability()` GET.
  - `dictation_controller.dart` — `DictationController extends
    ChangeNotifier`, one per composer, owned next to the composer's
    `TextEditingController`. Status machine `idle → listening →
    (transcribing) → idle` + transient error. Append semantics: snapshot
    `_base` at session start, render `_base + sep + partial` with caret at
    end, commit finals into `_base`; a genuine user edit while listening
    stops the session and keeps the edit (self-write guard flag). Engine
    selection + Brave-style runtime fallback lives here.
- **Provider (`providers/`):** `dictation_provider.dart` — engine factory
  provider (overridable in tests) and a cached availability `FutureProvider`;
  a 503 from `/transcribe` flips availability false (mic hides going
  forward).
- **Widget (`widgets/chat_panel.dart`):** `_ChatPanelState` owns the
  `DictationController`; `_InputBar` stays stateless and gains a `dictation`
  param — mic `IconButton` between the text field and send button inside a
  `ListenableBuilder` (`mic_none` idle, accented `mic` listening, small
  `CircularProgressIndicator` transcribing, absent when unavailable). Errors
  via `SnackBar` — the chat error banner stays reserved for stream failures.
- **Platform permissions** (needed by `speech_to_text`/`record`; web needs
  nothing): iOS `NSMicrophoneUsageDescription` +
  `NSSpeechRecognitionUsageDescription`; Android `RECORD_AUDIO` + speech
  recognition `<queries>` intent; macOS `com.apple.security.device.audio-input`
  entitlements + usage string.

## Contract Parity  ← anti-drift gate

| JSON key | Go type (`transcribe_handler.go`) | Dart type (`transcribe_api_service.dart`) | Nullable? | ✓ |
|----------|-----------------------------------|-------------------------------------------|-----------|---|
| *(request body)* | raw `[]byte`, `Content-Type: audio/*` | `Uint8List` + explicit content-type header | n/a | ☑ |
| `text` | `string` | `String` | no | ☑ |
| `status` | `string` (`"success"`) | `String` (unused, informational) | no | ☑ |
| `message` (errors) | `string` (existing `Response`) | `String` | no | ☑ |
| `available` | `bool` | `bool` | no | ☑ |

## Cross-cutting

- **Env vars** (added to `src/packages/api/.env.sample`):
  - `TRANSCRIPTION_API_KEY` — empty ⇒ fallback disabled (degraded mode); mic
    still works in Web-Speech browsers.
  - `TRANSCRIPTION_BASE_URL` — default `https://api.groq.com/openai/v1`; any
    OpenAI-compatible endpoint works; doubles as the httptest seam.
  - `TRANSCRIPTION_MODEL` — default `whisper-large-v3-turbo`.
- **Gateway:** new paths need no proxy config, but both gateways need
  `client_max_body_size 10m;` in the `/api/` location
  (`dockerize/development/nginx/default.conf`,
  `dockerize/deployment/nginx/snippets/app-locations.conf` — the snippet is
  included by both :80 and :443 servers). nginx default is 1 MiB, below the
  audio clip cap.
- **COOP/COEP:** the deployed app is cross-origin-isolated; `getUserMedia`,
  `MediaRecorder`, and Web Speech are device APIs, not embedded cross-origin
  subresources, so COEP does not gate them — but verify once on a deployment
  build (rarely-tested combination).
- **Privacy page:** add a dictation sentence to `dockerize/static/privacy.html`
  (browser vendor speech service on the live path; configured provider on the
  fallback; audio never stored).

## Verification

(Mirror into `tasks.md` as the final tasks.)

- `make api-fmt && make api-vet && make api-test`.
- `make flutter-analyze && make flutter-test`.
- Go unit tests: service (httptest stub asserting outbound multipart + auth
  header, MIME→filename mapping, upstream errors), handler (503 unconfigured,
  400 bad content type/empty body, happy path via BaseURL stub, availability
  both ways), middleware (10 MiB transcribe lane).
- Flutter tests: controller (append semantics, status transitions,
  edit-stops-session, errors) with a fake engine; widget (mic states, hidden
  when unavailable, dictated send goes through the normal queue path);
  transcribe service with `MockClient`.
- Manual end-to-end via the gateway (`make docker-dev` →
  `http://localhost:3000`): Chrome live path; Firefox fallback path (needs
  `TRANSCRIPTION_API_KEY`); no-key + Firefox → mic hidden; dictate while
  streaming → queued. `curl` example:
  `curl -X POST http://localhost:3000/api/v1/transcribe -H 'Content-Type: audio/webm' --data-binary @clip.webm`.
- One deployment-build check that dictation works under the COOP/COEP
  isolation headers.
