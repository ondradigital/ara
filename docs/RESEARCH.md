# Ara: Recherche-Ergebnis und Plan

Die App hieß bis 2026-10-01 „Diktat“.

Stand: 2026-10-01. Zielsystem: MacBook Pro M2 Pro, 32 GB, macOS 27, Xcode 27.

Die Benchmarks stammen überwiegend von App-Herstellern und wurden auf M4/M5 gemessen.
Alle M2-Pro-Zahlen sind Hochrechnungen und müssen in Schritt 4 nachgemessen werden.

## Entscheidungen

| Bereich | Wahl | Grund |
|---|---|---|
| Sprache/UI | Swift, SwiftUI (`MenuBarExtra`) + AppKit (`NSPanel`-Overlay) | direkter Zugriff auf CoreAudio, Accessibility, CGEvent, CoreML |
| Audio | Core Audio direkt am Eingabegerät (IOProc), umgerechnet auf 16 kHz mono Float32 | Eingabeformat aller Kandidaten-Modelle; `AVAudioEngine` blieb nach einem Gerätewechsel hängen (Messwerte, 2026-10-03) |
| STT (Standard) | Parakeet Ultra über FluidAudio (CoreML, Neural Engine) | 68 ms Median pro Äußerung, Deutsch 3,61 % WER (FLEURS, Modellkarte) |
| STT (Alternativen) | Whisper large-v3-turbo (WhisperKit), Qwen3-ASR 1.7B (speech-swift) | bessere Deutsch-Zahlen in unabhängiger Messung, Prompt- bzw. Kontext-Biasing |
| VAD | Silero (in FluidAudio) | lange Diktate segmentieren, leere Aufnahmen verwerfen |
| Wörterbuch | deterministische Ersetzung nach der Transkription, JSON-Datei (`vocabulary.json`) | keine Latenz, unabhängig von der Engine; JSON statt SQLite, weil es bei wenigen hundert Einträgen reicht und von Hand lesbar ist |
| Post-Processing | in V1 keines | +0,8 bis 1 s Latenz, Halluzinationsrisiko kleiner Modelle |
| Hotkey | `KeyboardShortcuts` (Carbon `RegisterEventHotKey`), Fallback `CGEventTap` | keine Berechtigung nötig, Tastendruck wird geschluckt |
| Audio-Ducking | CoreAudio-Mute am Ausgabegerät; V1.1 AppleScript-Pause für Spotify/Music | keine öffentliche API zum Pausieren; MediaRemote seit macOS 15.4 gesperrt |
| Text einfügen | `NSPasteboard` + `CGEvent` Cmd+V, Zwischenablage wiederherstellen | zuverlässiger als direktes Schreiben über Accessibility |
| Build | Xcode-Projekt, ohne Sandbox, feste Signatur | ohne feste Signatur geht die Bedienungshilfen-Freigabe bei jedem Build verloren |
| Lokal/Cloud | komplett lokal | schneller als jeder Netzwerk-Roundtrip; Cloud später über das Engine-Protokoll nachrüstbar |

## Offene Risiken

- **Parakeet und Sprache:** Sprache lässt sich nicht erzwingen; Berichte, dass die Erkennung
  auf Englisch kippt (FluidAudio Issue #303). Entscheidet der Vergleichstest in Schritt 4.
- **Parakeet und Vokabular:** CTC-Rescoring erzeugt 9–23 % falsche Ersetzungen
  (FluidAudio Issue #967). In V1 nicht aktivieren.
- **Deutsch-Genauigkeit:** In derselben Messkette (FLEURS): Qwen3-ASR 1.7B 2,85 %,
  Whisper Turbo 4,05 %, Parakeet v3 6,26 %. Ultra ist besser als v3, aber dort nicht gemessen.
- **Option+Space auf macOS 27:** Geklärt am 2026-10-01. `RegisterEventHotKey` mit reinem
  Option-Modifier liefert auf macOS 27.0.1 Status 0 (kein Fehler -9868 wie in macOS 15.0/15.1).
- **Mute-Wiederherstellung:** Externe DACs stellen den Zustand teils nicht wieder her
  (VoiceInk Issue #640). Lautstärke und Mute selbst sichern, auch über Abstürze hinweg.
- **Erster Modellstart:** 17–20 s Kompilierung für die Neural Engine, auch nach Systemupdates.

## Lernendes Wörterbuch

Stand 2026-10-01: Bestätigung statt Zählschwelle (Wunsch von Erik).

1. Nach dem Einfügen das fokussierte Textfeld über Accessibility lesen, alle 0,5 s, bis 120 s,
   nur den eingefügten Abschnitt vergleichen. Eine Änderung zählt erst nach 1,5 s Ruhe.
   Wechselt der Fokus woandershin, pausiert die Beobachtung nur (seit 2026-10-01), damit man
   die richtige Schreibweise aus einem anderen Fenster kopieren und über das Wort einfügen kann.
2. Kandidat nur, wenn 1–3 Wörter durch ähnlich klingende ersetzt wurden.
3. Ist das gehörte Wort ein gewöhnliches Wort (Rechtschreibprüfung de/en kennt es), wird die
   Regel um das Nachbarwort erweitert ("Cloud Code" statt "Cloud").
4. Ein kleines Fenster fragt "Add to vocabulary?" mit Add und Cancel. Erst Add legt die Regel an;
   sie gilt dann sofort. Cancel speichert nichts, dieselbe Korrektur wird später wieder gefragt.
5. Wird eine automatische Ersetzung zurückgeändert, fragt das Fenster "Remove from vocabulary?".

## Plan Version 1

- [x] 1. App-Gerüst als Menüleisten-App
- [x] 2. Option+Space-Toggle
- [x] 3. Mikrofonaufnahme
- [x] 4. Speech-to-Text mit Parakeet Ultra. Vergleichstest gestrichen (2026-10-01): Parakeet liefert im Alltag in Deutsch und Englisch kaum Fehler; Aufnahmen werden nicht mehr gespeichert
- [x] 5. Text einfügen
- [x] 6. Audio stummschalten
- [x] 7. Wörterbuch mit Korrektur-Beobachter und Verwaltungsansicht
- [ ] 8. Post-Processing (zurückgestellt; erst bauen, wenn es gebraucht wird)
- [x] 9. Overlay und Status (Aufnahme-Anzeige, Hinweis bei gelernten Korrekturen)
- [ ] 10. Performance: Modell wird vorgeladen; VAD-Segmente zurückgestellt, bis lange Diktate spürbar warten lassen
- [x] 11. Autostart (`SMAppService`) und Installation nach /Applications (`scripts/install.sh`)

## Messwerte auf dem M2 Pro

- 2026-10-01, Parakeet Ultra: Modell laden (warm) 0,14 s; 10,9 s Audio in 0,18 s transkribiert.
- 2026-10-02, Hotkey bis Aufnahme läuft (aus dem Systemlog): 0,08 s mit wiederverwendeter
  `AVAudioEngine`, 0,75–1,05 s mit einer neuen Engine pro Aufnahme (davon rund 0,6 s für das
  Verbinden mit Mikrofon und Ausgabegerät). Die Engine wurde deshalb behalten und nur nach einem
  Gerätewechsel ersetzt (überholt am 2026-10-03). Die App schreibt den Wert bei jedem Diktat als
  „recording running after …“ ins Log.
- 2026-10-03, Aufnahme ohne `AVAudioEngine`: Die App hing dauerhaft im Hauptthread in
  `AVAudioEngine.inputNode` (Endlosschleife in `AVAudioIOUnit_OSX::_GetHWFormat`, macOS 27.0.1),
  als die Engine nach einem Gerätewechsel ersetzt wurde. Vier Minuten vorher hatten beim Wechsel
  des Eingabegeräts zwei Threads gleichzeitig das Gerät der behaltenen Engine umgestellt; dabei
  blieben ihre Listener am neuen Aggregat-Gerät hängen, und die neue Engine konnte ihr Gerät
  nicht setzen („listener was already added“, Fehler `nope`). Der Recorder öffnet seitdem pro
  Aufnahme einen IOProc direkt auf dem Standard-Eingabegerät und behält nichts zwischen den
  Aufnahmen. Im Testprogramm mit dem Sennheiser Profile: `start()` kehrt nach 0,08–0,09 s zurück,
  auch bei fünf Aufnahmen hintereinander. Wechselt das Gerät während der Aufnahme die Abtastrate,
  rechnet der Recorder mit der neuen Rate weiter; das Gerät selbst liefert beim Umschalten knapp
  eine Sekunde lang nichts.

## Latenzziele (M2 Pro, Schätzung)

| Phase | Parakeet Ultra | Whisper Turbo |
|---|---|---|
| Hotkey bis Aufnahme läuft | unter 100 ms | gleich |
| Kurzer Satz bis Text | 150–350 ms | 1,5–2,5 s |
| 30 Sekunden | 300–600 ms | 1,5–2,5 s |
| 2 Minuten, segmentiert | 100–300 ms | 2–3 s |

## Quellen

- https://huggingface.co/moondream/parakeet-ultra
- https://whispernotes.app/blog/apple-speech-vs-whisper
- https://dicta.to/blog/speech-to-text-engine-comparison-mac-2026/
- https://vocai.net/blog/parakeet-vs-whisper-mac-benchmark-2026/
- https://github.com/FluidInference/FluidAudio
- https://github.com/FluidInference/FluidAudio/issues/967
- https://github.com/FluidInference/FluidAudio/issues/303
- https://github.com/Bjoernbom/yap/pull/11
- https://github.com/heyalchang/mlx-qwen3-asr
- https://github.com/soniqo/speech-swift
- https://github.com/argmaxinc/OpenBench/blob/main/BENCHMARKS.md
- https://github.com/sindresorhus/KeyboardShortcuts
- https://github.com/Beingpax/VoiceInk/issues/640
- https://github.com/abgregs/freeflow/pull/34
- https://github.com/lintyai/linty/pull/43
