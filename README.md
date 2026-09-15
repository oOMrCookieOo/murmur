# Murmur

Hold a key, speak, release — the text appears at your cursor in whatever app is
focused. Entirely on-device.

- **Menu-bar only.** No Dock icon, no window in your way.
- **On-device.** Apple's `SpeechAnalyzer` (the Voice Memos engine). No network,
  no cloud, no telemetry, no analytics.
- **Works everywhere.** Native apps, Electron, web views, terminals.

Requires **macOS 27** on Apple Silicon.

---

## Quick start

```sh
make sign-cert   # once — see "Why sign-cert first" below
make run         # build, launch, and prompt for permissions
```

Then grant the three permissions (below), and hold **Right Option** to dictate.

### Why `sign-cert` first

macOS ties Accessibility and Input Monitoring grants to an app's **code
signature**. An ad-hoc signature is different on every build, so after a rebuild
macOS sees a different app: Murmur still looks ticked in System Settings, but
the permission silently stops applying and pasting quietly fails.

`make sign-cert` creates a self-signed certificate — no Apple Developer account,
no cost, trusted only on this Mac — so the signature stays constant and you
grant permissions **once**. It asks for your login password twice, because
importing a key and trusting it are two separate keychain operations.

You can skip it, but expect to re-grant Accessibility after most rebuilds.

---

## Permissions

Murmur needs three, and it will prompt for each on first launch. An app that has
never *requested* a permission does not appear in the System Settings list at
all, which is why launching it once is the first step.

| Permission | Why | Settings pane |
|---|---|---|
| **Microphone** | To hear you | Privacy & Security → Microphone |
| **Accessibility** | To send the paste keystroke to other apps | Privacy & Security → Accessibility |
| **Input Monitoring** | To notice the trigger key while another app is focused | Privacy & Security → Input Monitoring |

**Murmur → Settings… → Permissions** shows the live status of all three, with a
Grant button and a direct link to each pane. After changing one, use
**"Re-check and restart the key listener"** — macOS never tells an app that its
permissions changed, so nothing picks it up automatically otherwise.

If Murmur is not in a list, add it manually with the **+** button and select
`build/Murmur.app`.

Murmur is **not sandboxed**, and cannot be: the App Sandbox denies both the
Accessibility API and event posting, with no entitlement that grants them. Every
text-injection utility on macOS makes this same trade. It also means Murmur
could never ship on the Mac App Store.

---

## Using it

**Hold Right Option, speak, release.** The text lands at your cursor.

- A small pill appears next to the pointer with a live level meter and the
  transcript as it forms.
- **Esc** cancels an in-flight dictation and discards the audio.
- Recording stops automatically after 120 seconds (configurable) and transcribes
  what it captured, so a stuck key can never record forever.
- Presses shorter than 200 ms are ignored as accidental.

### Changing the trigger key

**Settings → General → Trigger key.** Choose from Right Option, Left Option,
Right Command, Right Control, Right Shift, or Fn/Globe.

Only modifier keys are offered, deliberately. Modifiers report a left/right
distinction, so Right Option can trigger dictation while Left Option keeps
typing `å`, `∂` and the rest. Murmur never swallows the trigger key — it passes
straight through to the focused app.

**Settings → General → Activation** switches between *Hold to talk* and *Tap to
start / stop* for longer dictations.

### Clipboard-only mode

**Settings → General → Transcript goes to → Copy to clipboard only**, or the
segmented control in the menu-bar panel.

Murmur also falls back to the clipboard **by itself** whenever pasting would be
unsafe — no app focused, focus moved to a different app mid-dictation, the
target app quit, or Accessibility access missing. The HUD says which happened.
Your words are never silently dropped.

### Custom vocabulary

**Settings → Vocabulary.** One word or phrase per line: names, jargon, project
nouns — anything the transcriber keeps getting wrong.

This uses `AnalysisContext.contextualStrings` to bias recognition toward your
words, entirely on-device. The model is fixed, but what it expects to hear is
not, so this is the largest accuracy lever available short of a different model.
Editing the list rebuilds the speech session, which costs ~35 ms on the next
dictation only.

### Recent transcripts

The menu lists your recent dictations; click one to copy it back. Every other
safeguard stops your words being *destroyed* — this is the one that lets you
*recover* a dictation that landed somewhere unexpected.

**In memory only, cleared when Murmur quits.** Everything you dictate passes
through here: spoken passwords, messages, private notes. A plaintext log on disk
of everything ever said to the app would be a far worse default than losing
history at quit. Settings → Advanced sets the count; 0 disables it.

### Microphone

**Settings → General → Microphone.** "System default" follows whatever macOS is
using, including AirPods coming and going. A specific device is remembered by
its stable UID, so it survives reboots and reconnection, and falls back to the
default if it is unplugged.

### Stopping automatically

**Settings → Advanced → "Stop automatically when I stop speaking"**, using
Apple's on-device voice activity detection.

Tap-to-start mode only. While you are holding the key, the key already says when
to stop, and being cut off mid-pause would be both surprising and unfixable.
Silence is only counted after your first word, so the gap between pressing the
key and starting to speak never triggers it.

### Cleanup

Two independent toggles in **Settings → Cleanup**, both off by default:

- **Strip filler words** — removes standalone "um", "uh", "erm". A plain
  word-boundary substitution: instant, offline, and incapable of inventing text.
- **Clean up with Apple Intelligence** — the on-device foundation model fixes
  capitalisation and punctuation. Local, and time-limited (1200 ms by default).

Cleanup is never allowed to lose your words. Murmur pastes the **raw transcript**
if the model is unavailable, times out, errors, hits its output-token limit, or
returns text that drifts too far from what you said (a length check plus a
content-word overlap check). That last guard is what stops a language model
answering your dictation instead of tidying it.

---

## How it stays fast

### Measured numbers

On Apple Silicon, with the model resident:

| Stage | Cost |
|---|---|
| `SpeechAnalyzer.start(inputSequence:)` at key-down | ~9 µs |
| `bestAvailableAudioFormat` (first call) | ~58 ms |
| `prepareToAnalyze(in:)` (first call / later) | ~35 ms / ~1.5 ms |
| **`finalizeAndFinishThroughEndOfInput()`** | **56–64 ms** (1–3 s speech), **106–110 ms** (8.5 s speech) |
| `results.value` after finalise | ~0.4 µs |

The honest reading: **the framework's own finalisation is the floor**, and for
utterances longer than a few seconds it alone approaches or exceeds 100 ms
before Murmur does anything. Short bursts — the common case for push-to-talk —
land comfortably under. Treat "~100 ms" as the app overhead target, not an
absolute round-trip guarantee.

Murmur measures itself: every dictation logs key-up → paste with a per-stage
breakdown, and the menu shows your last figure and a rolling median. Timed to
the instant Cmd+V is posted, not to when the paste call returns — the clipboard
restore happens ~250 ms later, and counting it would overstate what you actually
experience.

### What the design buys

The expensive work is moved off the critical path:

1. **`modelRetention: .processLifetime`** keeps the speech model resident
   between dictations instead of unloading it each time.
2. **`prepareToAnalyze(in:)`** builds the analyzer graph ahead of time.
3. A complete session is **prewarmed during idle** — at launch and again the
   moment each dictation finishes — so key-down only opens the mic and starts
   streaming.
4. **`ReportingOption.fastResults`** trades a little accuracy for earlier
   finalisation, which is the right trade for dictation.
5. The key listener runs its own `CFRunLoop` on a dedicated `.userInteractive`
   thread. An event tap whose run loop stalls gets disabled by the system, and a
   SwiftUI main thread stalls constantly.

The 2048-frame (~43 ms) tap request is advisory, and the system clamps it to
4800 frames (100 ms) in practice. `AVAudioEngine.stop()` flushes no further
audio, so cutting the stream at key-up would discard up to 100 ms — enough to
clip a word when you release on the last syllable. Murmur waits for that final
block to land, adaptively: a buffer boundary may be 5 ms away or 100 ms away, and
sleeping the worst case every time would hand the whole saving back as latency.
Settings → Advanced → "Keep listening after release"; 0 disables it.

---

## Building

```sh
make test      # cleanup safety tests
make build     # release build into ./build
make debug     # unoptimised, with debug info
make run       # build and relaunch
make check     # typecheck only — fastest feedback
make install   # copy to /Applications
make clean
```

There are two ways to build, and they produce the same app:

- **Xcode** — open `Murmur.xcodeproj`. Normal workflow, full debugger.
- **`make`** — `swiftc` directly against the macOS SDK. No Xcode needed; the
  Command Line Tools SDK is enough.

One limitation of the `make` path: SwiftUI's macros (`@State`, `#Preview`) need
a compiler plugin that ships only with Xcode, so the code avoids `@State` and
keeps view state in `@Observable` models instead. `@Observable` and `@Bindable`
work fine. If you build in Xcode you are not restricted.

### Logs

```sh
/usr/bin/log stream --predicate 'subsystem == "com.mrcookie.Murmur"' --info
```

Transcripts are never logged, at any level.

---

## Layout

```
Murmur/
  App/          MurmurApp.swift        @main, MenuBarExtra, AppDelegate
  Core/         DictationController    the state machine
                AppSettings            observable, auto-persisting prefs
                DictationPhase         idle → listening → … → finished
  Speech/       SpeechEngine           actor: AVAudioEngine → SpeechAnalyzer
                BufferConverter        mic format → analyzer format
                ModelCatalog           AssetInventory download / reserve
                LevelMeter             render-thread-safe input level
                SpeechActivity         voice activity, for auto-stop
                AudioDevices           CoreAudio microphone enumeration
  Input/        HotkeyMonitor          CGEventTap on a dedicated thread
                TriggerKey             modifier keys + device-dependent masks
  Output/       TextInjector           the paste pipeline
                PasteboardSnapshot     capture / restore the clipboard
                FocusSnapshot          which app to paste into
  Cleanup/      TranscriptCleaner      optional, guarded, falls back to raw
  Core/         TranscriptHistory      recent dictations, in memory only
                Timeout                wall-clock-bounded race helper
  Permissions/  PermissionsModel       status, prompts, Settings deep links
  UI/           MenuBarPanel, SettingsView, HUDController, HUDView
Config/         Info.plist, Murmur.entitlements
Scripts/        build-app.sh, make-signing-cert.sh
Tests/          CleanupTests.swift — run with `make test`
```

### The paste pipeline

```
key down → capture frontmost app → show HUD → open mic
key up   → finalise transcript → optional cleanup
         → snapshot clipboard → write transcript → wait for modifiers to clear
         → post ⌘V → wait → restore clipboard
```

Two details worth knowing:

- The clipboard is restored **only if `changeCount` still matches** what Murmur
  wrote. If you copied something else in the meantime, that newer content wins
  rather than being clobbered.
- The transcript is supplied **lazily**, so the restore happens the moment the
  target actually reads it instead of after a fixed delay. This is an
  optimisation, never a correctness requirement: the first read caches the value
  and no later read re-fires the callback, so a clipboard manager that reads on
  change consumes the signal. When that happens Murmur falls back to the timed
  restore, so the result is faster or identical, never worse.
- The clipboard write is tagged `org.nspasteboard.ConcealedType`, so clipboard
  managers do not archive every dictation and Universal Clipboard does not push
  it to your other devices.
- Murmur waits for physically-held modifiers to clear (up to 60 ms) before
  posting ⌘V. Without it, a still-held Right Option turns the synthetic paste
  into ⌥⌘V in the target app.

Murmur never sends a blind ⌘Z to another app.

---

## Troubleshooting

**Pasting does nothing.** Accessibility is missing or was granted to a previous
ad-hoc signature. Run `make sign-cert`, rebuild, remove Murmur from the
Accessibility list, and grant it again.

**Pastes occasionally come out empty.** The target app is slow to read the
clipboard. Raise **Settings → Advanced → Restore clipboard after**.

**The trigger key does nothing.** Input Monitoring is missing, or a secure input
field (a password box) has the keyboard locked. Murmur re-arms its tap
automatically when the system disables it.

**Nothing transcribed.** Check **Settings → Speech** for the model status. The
first launch in a new language downloads a model; Murmur reserves the locale
afterwards so the system does not evict it.

---

## License

MIT. Built on patterns from `yuichirokato/SpeechAnalyzerSample`,
`conrader/plainsay` and `gbrlpzz/transcribe`, all MIT.
