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

A known limit: the 2048-frame (~43 ms) tap request is advisory, and the system
clamps it to 4800 frames (100 ms) in practice. `AVAudioEngine.stop()` flushes no
further audio, so releasing the key mid-syllable can clip the last fraction of a
word.

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
  Input/        HotkeyMonitor          CGEventTap on a dedicated thread
                TriggerKey             modifier keys + device-dependent masks
  Output/       TextInjector           the paste pipeline
                PasteboardSnapshot     capture / restore the clipboard
                FocusSnapshot          which app to paste into
  Cleanup/      TranscriptCleaner      optional, guarded, falls back to raw
  Permissions/  PermissionsModel       status, prompts, Settings deep links
  UI/           MenuBarPanel, SettingsView, HUDController, HUDView
Config/         Info.plist, Murmur.entitlements
Scripts/        build-app.sh, make-signing-cert.sh
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
