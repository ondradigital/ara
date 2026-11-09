# Ara

Diktier-App für macOS. Ara sitzt in der Menüleiste, nimmt auf Tastendruck deine Stimme auf und fügt den Text dort ein, wo der Cursor steht. Die Spracherkennung läuft komplett auf dem Mac (Parakeet über [FluidAudio](https://github.com/FluidInference/FluidAudio) auf der Neural Engine), es geht kein Ton ins Internet.

## Voraussetzungen

- Mac mit Apple-Chip (M1 oder neuer)
- macOS 26 oder neuer
- Xcode 26 oder neuer aus dem App Store, einmal geöffnet
- Empfohlen: eine Apple-ID in Xcode unter Settings → Accounts (kostenlos, kein bezahlter Entwickler-Account nötig)

Ohne Apple-ID in Xcode läuft Ara auch. Dann fragt macOS aber nach jeder neuen Installation erneut nach der Freigabe für die Bedienungshilfen.

## Installation

```bash
git clone https://github.com/ondradigital/ara.git
cd ara
./scripts/install.sh
```

Das Skript prüft die Voraussetzungen, baut Ara, installiert es nach `/Applications` und startet es. Der erste Build lädt die Abhängigkeiten und dauert ein paar Minuten.

## Erster Start

1. **Bedienungshilfen:** Ara unter Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen erlauben. Ohne diese Freigabe kann Ara nicht einfügen und legt den Text nur in die Zwischenablage.
2. **Mikrofon:** Bei der ersten Aufnahme fragt macOS nach dem Mikrofon. Erlauben und erneut ⌥ Leertaste drücken.
3. **Sprachmodell:** Beim ersten Start lädt Ara das Modell (etwa 600 MB). Das Menü zeigt den Fortschritt, danach steht dort „Ready“.

## Bedienung

| Kurzbefehl | Wirkung |
|---|---|
| ⌥ Leertaste | Aufnahme starten, nochmal drücken zum Beenden und Einfügen |
| Esc | Laufende Aufnahme verwerfen |
| ⌃ ⌥ V | Letztes Diktat erneut einfügen, falls es nicht angekommen ist |
| ⌥ ⇧ Leertaste | Markiertes, korrigiertes Wort ins Wörterbuch übernehmen |

- **Einfügen:** Ara fügt über die Zwischenablage ein und legt danach deren alten Inhalt zurück. Kommt der Text in einem Feld nicht an, erscheint ein Hinweis, dann hilft ⌃ ⌥ V.
- **Wörterbuch:** Korrigierst du ein falsch erkanntes Wort direkt im Text, schlägt Ara eine Regel vor und übernimmt sie nach 5 Sekunden, wenn du nicht abbrichst. Sofort kommt der Vorschlag nur, wenn die Spracherkennung bei dem Wort unsicher war. Sonst wartet Ara, bis du dieselbe Korrektur ein zweites Mal machst, damit gewöhnliches Umformulieren nicht im Wörterbuch landet. Alle Regeln stehen im Menü unter „Personal Vocabulary…“. Manche Apps lassen ihren Text nicht auslesen. Dort markierst du das korrigierte Wort und drückst ⌥ ⇧ Leertaste.
- **Ton aus:** Während der Aufnahme schaltet Ara die Wiedergabe stumm, damit Musik nicht mit aufgenommen wird. Abschaltbar im Menü.
- **Bei Anmeldung starten:** im Menü einschaltbar.

## Aktualisieren

```bash
git pull
./scripts/install.sh
```

## Deinstallieren

```bash
pkill -x Ara; rm -rf /Applications/Ara.app
rm -rf ~/Library/Application\ Support/Ara ~/Library/Application\ Support/FluidAudio
defaults delete com.erikondra.Ara
```

Die zweite Zeile löscht das Wörterbuch und das Sprachmodell. Den Eintrag unter Bedienungshilfen entfernst du in den Systemeinstellungen mit der Minus-Taste.

## Entwicklung

- Projekt in Xcode öffnen: `open Ara.xcodeproj`
- Tests: `xcodebuild test -project Ara.xcodeproj -scheme AraTests -derivedDataPath build -quiet`
- Logs der laufenden App: `log show --last 1h --predicate 'subsystem == "com.erikondra.Ara"' --style compact`

Das Test-Target `AraTests` kompiliert nur die reinen Logik-Dateien mit (`CorrectionDiff.swift`, `Vocabulary.swift`). Eine neue Datei im Ordner `Ara` landet automatisch auch dort. Braucht sie KeyboardShortcuts oder FluidAudio, muss sie in Xcode aus dem Target `AraTests` genommen werden.

Hintergrund zu den Entscheidungen: [docs/RESEARCH.md](docs/RESEARCH.md).
