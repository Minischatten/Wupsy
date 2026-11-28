# Wupsy – Unabhängiger technischer Analysebericht

Stand: Git-Tip `7943738` (28.11.2026), VERSION 0.8.0. Rein lesende Analyse, ausschließlich Quellcode und Dokumentation. Es wurde nichts gebaut, getestet, formatiert, committet oder geändert.

## 0. Umfang und Grenzen der Analyse

Das Projekt hat rund 46.000 Zeilen Produktivcode (Swift/Metal) und rund 56.000 Zeilen Tests (1.621 Testfunktionen). Eine vollständige Zeilenprüfung war nicht möglich. Ich habe so vorgegangen:

- **Vollständig oder weitgehend gelesen:** PROJECT.md, CONTRIBUTING.md, SECURITY.md, Anfang von docs/ARCHITECTURE.md, Renderer.swift, WSSStaticPlayer.swift (Zeichenpfad), ManagedWallpaperStore.swift (Import/Entfernen), Wallpaper.swift (Importauflösung), LibraryRestoreIO.swift (ZIP-Vorprüfung), GitHubReleaseClient.swift, GIFPlayer.swift, VideoOptimizer in MediaCache.swift, CustomWidget.swift, Teile von WallpaperPlaylist.swift, DesktopWidgets.swift, SystemReadings.swift, WSSAssetIO (WSSImageImport.swift), LibraryMutationBarrier, WSSPlaybackClock.
- **Nur per Stichwortsuche oder Stichprobe geprüft:** Concurrency-Muster (`@unchecked Sendable`, Locks, `assumeIsolated`), Observer und Timer, Force-Unwraps, `fatalError`, Prozessstart, WebView-Nutzung, Zeitbehandlung in Shadern.
- **Nicht oder nur oberflächlich geprüft:** Metal-Shader und die meisten Effekt-Renderer (Rain, Storm, Fog, Ripple, Slime, Music Notes), Editor-Interna (Undo, Masken, Vektorfelder), Restore-Transaktion und Journal, Lokalisierung, die meisten Testinhalte.

Aussagen wie „keine Probleme gefunden“ gelten deshalb nur für die genannten, gelesenen Bereiche.

Kennzeichnung der Nachweisstufe bei jedem Befund:
- **[Q]** durch Quellcodeanalyse nachgewiesen (Verhalten ergibt sich eindeutig aus dem Code).
- **[Q+T]** Code-Befund eindeutig, aber die Auswirkung für Anwender braucht einen praktischen Test.
- **[T]** nur Vermutung, braucht praktische Untersuchung.

## 1. Gesamteinschätzung

Wupsy ist für den Entwicklungsstand ungewöhnlich sorgfältig gebaut. Dateisystemzugriffe, Archivverarbeitung, Import, Update-Prüfung und Wiederherstellung sind defensiv und mit klaren Besitz- und Commit-Punkten umgesetzt. Die Dokumentation beschreibt Verträge, Grenzen und bekannte Einschränkungen offen.

In den geprüften Bereichen habe ich **keinen sicheren Absturz, kein sicheres Speicherleck und keine Datenverlust-Schwäche** gefunden. Es gibt **zwei konkrete Code-Defekte** (A1, A2) und eine Reihe von Risiken und Optimierungen mit niedriger bis mittlerer Dringlichkeit. Der wichtigste praktische Befund ist A2 (Import einer einzelnen HTML-Datei kopiert den gesamten Elternordner).

## 2. Bewertung der Architektur

- **Schichtung:** Typisiertes Dokument (`WSSSceneDocumentV1`) → validierte Szene → eigenständige Ressourcen → Player. Gespeicherte und laufende Zustände sind getrennt. Das ist sauber und gut testbar.
- **Besitz und Unveränderlichkeit:** Importe werden in eine verwaltete Bibliothek kopiert, Originale bleiben unberührt. Editor-Änderungen erzeugen unveränderliche Asset-Generationen, damit Undo funktioniert. Löschungen prüfen Besitz mehrfach (`ManagedWallpaperStore.remove`).
- **Pause und Wiedergabe:** Ein explizites Modell aus Pausegründen (global und je Display) mit gestaffelter Ressourcenfreigabe. Die Szenenuhr (`WSSPlaybackClock`) basiert auf `systemUptime`, das während des Systemschlafs nicht weiterläuft. Damit gibt es keinen Zeitsprung nach dem Aufwachen.
- **Metal:** Maximal zwei Frames in flight über eine Semaphore, GPU-Ressourcen werden bis zum Abschluss des Command Buffers festgehalten, Fehler werden im Completion-Handler behandelt.
- **Größenfrage:** `Library.swift` (1.666 Zeilen) bündelt Wiedergabe, Import, Energie-/Speicherrichtlinie und Zustand. Das ist eine Strukturpräferenz, kein Fehler. Ich empfehle keinen Umbau.

## 3. Erkannte Stärken (mit Quellbezug)

1. **Archiv-Sicherheit:** `LibraryRestoreIO.swift:155-358` prüft das ZIP vor dem libarchive-Lesen selbst: Größen, ZIP64, Zentral- gegen Lokalheader, doppelte oder mehrdeutige Namen, Unicode-Pfad-Extra, Überlappungen, nur STORE und unverschlüsselt, keine Links. Zusätzlich gibt es eine Änderungsprüfung per `stat` (`unchanged()`) und einen JSON-Duplikatschlüssel-Scanner. Das ist über dem üblichen Niveau.
2. **Pfadsicherheit:** `WSSAssetIO` (`WSSImageImport.swift:8-80`) arbeitet deskriptorbasiert mit `O_NOFOLLOW`. `ManagedWallpaperStore` verweigert Symlinks in der Bibliothek und prüft Importbäume (`inspectTree`) vor und nach dem Kopieren.
3. **Update-Prüfung:** `GitHubReleaseClient.swift` verweigert Weiterleitungen, begrenzt die Antwort auf 1 MiB, pinnt die erlaubte URL auf das eigene Repository und hat Ratenlimit-Behandlung.
4. **Eigene Widgets:** `CustomWidget.swift:41-47,62-64` setzt CSP `default-src 'none'`, `script-src 'none'` und deaktiviert JavaScript. Navigation ist auf das Initialdokument beschränkt.
5. **Zeitpräzision:** Shader-Zeiten werden in `Double` auf Phasen reduziert, bevor sie nach `Float` gehen (`WSSStarfield.swift:111-115`, `WSSRainEffect.swift:169`, `WSSFlowEffect.swift:29`). Lange Laufzeiten führen so nicht zu Jitter.
6. **Neustart-Helfer:** `LibraryRestoreRestart.swift` startet ohne Shell, mit Handshake, Elternprozess-Prüfung und `F_SETNOSIGPIPE`.
7. **Nebenläufigkeit:** Die 14 `@unchecked Sendable`-Stellen sind jeweils durch Locks oder Unveränderlichkeit begründet (u. a. `LibraryMutationBarrier`). Keine `unowned`, kein `nonisolated(unsafe)`, ein einziges `try!`-artiges Konstrukt ist ein sicheres `entry!` (`LibraryBackup.swift:160`).
8. **Tests und Dokumentation:** Umfangreiche Tests inklusive Fehler-, Abbruch- und Symlink-Fälle; Verträge für Format, Backup und Restore sind dokumentiert.

## 4. Befunde nach Priorität

### A. Nachweisbare Fehler

#### A1 – Desktop-Okklusions-Observer wird versehentlich mit entfernt `[Q+T]`
- **Stelle:** `Renderer.swift:126-127` registriert `desktopOcclusionChanged` für `NSWindow.didChangeOcclusionStateNotification` am Desktop-Fenster. `stopWatchingTransitionWindow()` (`Renderer.swift:319-322`) ruft `removeObserver(self, name: didChangeOcclusionStateNotification, object: window)` auf. Das entfernt **alle** Registrierungen von `self` für dieses Name/Objekt-Paar, also auch die aus dem `init`.
- **Aufrufer:** `releaseResources()` (`:417`), `onFirstFramePresented` (`:334`, bei jedem Apply mit Übergangsbild beziehungsweise Bereitschaftsmeldung), `report()` (`:134`).
- **Begründung:** Nach dem ersten präsentierten Frame oder nach jeder Ressourcenfreigabe wird `desktopOcclusionChanged` nie mehr aufgerufen. Neu registriert wird nur der Übergangs-Observer (`:359`), nicht der Desktop-Observer. Kein Test referenziert `desktopOcclusionChanged` oder `desktopVisibilityChanged`.
- **Auswirkung:** `desktopVisibilityChanged()` stößt `scheduleRecovery()` an (erneutes Zeichnen eines eingefrorenen Desktops). Andere Auslöser bleiben bestehen (`requestDesktopRecovery`, `setDesktopSurfaceAvailable`, `desktopGeometryChanged`), daher ist die praktische Wirkung vermutlich klein. Denkbar ist ein eingefrorenes oder veraltetes Desktopbild nach Okklusionswechseln (Spaces, Vollbild, Mission Control), wenn gerade keiner der anderen Auslöser greift.
- **Korrektur:** Für den Übergang einen eigenen Observer-Token (blockbasiert) verwenden und nur diesen entfernen, oder in `stopWatchingTransitionWindow()` nur `transitionWindowVisibilityChanged` per Token abmelden. Dazu ein kleiner Regressionstest, der nach `releaseResources()` und `load()` prüft, dass die Okklusions-Benachrichtigung weiter ankommt.
- **Handlungsbedarf:** Niedrig bis mittel. Der Code-Defekt ist sicher, die Reichweite für Anwender muss mit einem Test (Schlafen/Wecken, Spaces, Vollbild mit pausiertem Desktop) bestätigt werden.

#### A2 – Import einer einzelnen HTML-Datei kopiert den gesamten Elternordner `[Q]` (Wirkung `[T]`)
- **Stelle:** `Wallpaper.swift:157` (`root = input.deletingLastPathComponent()` für Dateien), `ManagedWallpaperStore.swift:229-231` (`project = … kind == .web && Endung != "gif"`), `ManagedWallpaperStore.swift:277` (`copyItem(at: originalRoot, to: staging)`). Kein Größenlimit für Web-Projekte; ein Test deckt nur das Ordner-Szenario mit `index.html` ab (`ManagedLibraryTests.swift:170, 328`).
- **Begründung:** Wählt man eine einzelne `.html`/`.htm`-Datei (README: „HTML file or folder“), wird sie als „Projekt“ behandelt, und der **gesamte Ordner, in dem sie liegt**, wird in die Bibliothek kopiert. Liegt die Datei zum Beispiel in `~/Downloads` oder auf dem Schreibtisch, wird dieser Ordner komplett kopiert.
- **Auswirkung für Anwender:**
  - Beliebig viel Speicherplatz und Zeit (kein Limit).
  - Fremde, private Dateien landen in der verwalteten Bibliothek, in Backups und sind per `allowingReadAccessTo` für das Web-Wallpaper lesbar (`Renderer.swift:381-384`). Zusammen mit dem Netzwerkzugriff von Web-Wallpapern (siehe B1) vergrößert das den Schaden eines feindlichen Wallpapers.
  - Ein einzelner Symlink irgendwo in diesem Ordner lässt den Import mit „unsafePath“ scheitern. Die Fehlermeldung nennt den fremden Dateinamen, die Ursache ist für Anwender kaum nachvollziehbar.
- **Korrektur (ohne Umbau):** Bei einer einzelnen HTML-Datei entweder (a) nur diese Datei kopieren, (b) eine Bestätigung mit Ordnername und Größe verlangen, oder (c) mindestens ein Größen-/Dateianzahl-Limit einführen und den Nutzer vor dem Kopieren informieren. Die Entscheidung gehört in die Produktplanung (HTML-Dateien mit relativen Ressourcen brauchen den Ordner tatsächlich).
- **Handlungsbedarf:** Mittel bis hoch. Praktisch leicht prüfbar: eine `.html` in einem Ordner mit weiteren Dateien importieren und das Ergebnis unter `Application Support/…/Web/` ansehen.

### B. Konkrete technische Risiken

| # | Risiko | Stelle | Stufe | Handlungsbedarf |
|---|---|---|---|---|
| B1 | **Web-Wallpaper haben Netzwerk- und Dateilesezugriff.** Die Navigationsrichtlinie (`Renderer.swift:582-592`) erfasst nur Navigationen, nicht `fetch`, `XHR`, `WebSocket`, Bilder oder Skripte. Das ist in SECURITY.md ausdrücklich dokumentiert („trusted content“). In Verbindung mit A2 steigt die Wirkung. | `Renderer.swift:373-385` | [Q], dokumentiert | Niedrig. Optional: Hinweis beim Import eines Web-Wallpapers, dass es Skripte und Netzwerk nutzen darf. |
| B2 | **Private KVC-Schlüssel:** `view.setValue(false, forKey: "drawsBackground")` am `WKWebView`. Entfällt der Schlüssel in einem künftigen macOS, wirft das eine nicht abfangbare ObjC-Exception und das Widget-Fenster stürzt ab. | `CustomWidget.swift:66` | [Q], Eintrittswahrscheinlichkeit unbekannt | Niedrig. Auf macOS 26/27 funktioniert es offenbar. Bei jeder neuen Betriebssystem-Beta prüfen oder per `responds(to:)`/`NSObject`-Prüfung absichern. |
| B3 | **Mindestversion macOS 14 ungeprüft.** README nennt macOS 14/15 selbst „nicht geprüft“; es gibt kein einziges `#available`; die CI läuft nur auf `macos-26`. | `Package.swift`, README, `ci.yml` | [T] | Mittel (vor dem Versprechen von 14+). Ein Testlauf in einer macOS-14- und einer macOS-15-VM (Start, Import, Wiedergabe, Editor) würde das klären. |
| B4 | **Keine automatische Regressionssicherung.** Alle drei Workflows sind `workflow_dispatch`, also nur manuell. Es gibt rund 175 zeitabhängige Wartestellen in Tests; ein CI-Flake ist in PROJECT.md bereits dokumentiert (`PerformanceDiagnosisTests`). Metal-Präsentationstests sind nur mit `WUPSY_REQUIRE_METAL_PRESENTATION=1` streng. | `.github/workflows/*.yml`, Tests | [Q] | Niedrig bis mittel. Mindestens Format und Build/Teilmenge der Tests bei jedem Push wäre ein günstiger Schutz. |
| B5 | **Energie bei Widgets:** Sobald ein CPU-, Speicher-, Netzwerk- oder eigenes Widget aktiv ist, tickt ein Timer alle 0,5 s (Toleranz 25 ms), baut SwiftUI-Zustand neu auf und führt bei eigenen Widgets pro Tick `callAsyncJavaScript` aus. | `DesktopWidgets.swift:349-359`, `CustomWidget.swift:79-100` | [Q+T] | Optional. Ein 1-s-Takt oder ein Takt abhängig vom tatsächlichen Datenbedarf spart Wakeups. Mit Instruments/Energy messen. |
| B6 | **Häufige Observer:** `NSWindow.didUpdateNotification` ohne Objektfilter (`WSSEditorCoordinator.swift:100`) und je Vorschaufenster (`WSSPreviewView.swift:266-280`, ruft `updatePlayback()`) feuern bei jedem Fensterupdate. Die Arbeit je Aufruf ist klein, die Häufigkeit aber hoch. | siehe Stellen | [T] | Optional, nur bei messbarer CPU-Last im Leerlauf. |
| B7 | **GIF-Grenzen:** Nur die Bildanzahl ist begrenzt (≤ 20.000, `GIFPlayer.swift:47`). Für Abmessungen und Gesamtspeicher gibt es kein Limit; jeder Frame wird einzeln per ImageIO dekodiert. Eine große oder feindliche GIF kann viel CPU/Speicher brauchen. | `GIFPlayer.swift`, `MediaCache.swift` (Dekodierung) | [T] | Niedrig. Praktisch mit einer sehr großen/langen GIF prüfen. |

### C. Noch nicht bestätigte Vermutungen

- **C1 – Video-Cache-Kollision:** `VideoOptimizer.preparedURL` prüft `fileExists(output)`, exportiert dann lange und verschiebt zuletzt mit `moveItem` (`MediaCache.swift:397`). Laufen zwei Exporte für dieselbe Datei und dasselbe Profil gleichzeitig, schlägt der zweite `moveItem` fehl. Im normalen Ablauf serialisiert `Library.prepare` über `generation`/`preparation`, daher vermutlich nicht erreichbar. `[T]`
- **C2 – GPU-Zähler beim Pausieren:** `desktopGPU.count` wird beim Encodieren erhöht und nur im Completed-Handler verringert (`WSSStaticPlayer.swift:~597-640`). Würde ein Command Buffer nie abgeschlossen (GPU-Hänger), bliebe das Auslaufen der Pause offen. Es gibt dafür eine 200-ms-Frist für Präsentationsdaten, der Zähler selbst wird aber nicht zeitlich begrenzt. `[T]`
- **C3 – Dekompressionslast bei Bildern:** `ImageLoader`/Import-Validierung dekodieren Bilder über ImageIO. Ob extrem große PNGs vor der Verkleinerung vollständig dekodiert werden, habe ich nicht verfolgt. `[T]`
- **C4 – Farbwähler (bekannt):** Die in PROJECT.md dokumentierte, sporadische Starfield-Farbübergabe ist ungeklärt und bleibt eine bekannte Einschränkung.

### D. Optionale Verbesserungen und Stil

- **Nur-Quelltext-Tests:** `OverviewActionsTests.swift:15-30` und ähnliche (`WSSDraftTests.swift:278`) prüfen mit `contains(...)` auf Quelltext-Zeichenketten, auch mit Zeilenumbrüchen. Sie brechen bei reinen Formatänderungen und prüfen kein Verhalten. Besser durch Verhaltenstests ersetzen oder bewusst klein halten.
- **Release-Binary enthält Prüf-Argumente** (`--benchmark`, `--verify-localization`, `--restore-relaunch-helper`). Rein lokal und harmlos; optional per `#if DEBUG` einschränken, soweit sie nicht für die Release-Prüfung gebraucht werden.
- **Kleinigkeiten:** Toter Wert `let native: String? = nil` (`LibraryBackup.swift:137`). `dist-diagnostics/` (28 MB) ist nicht in `.gitignore` aufgeführt, `git status` meldete aber nichts; vermutlich greift eine globale Ignore-Regel.

## 5. Tests: Aussagekraft und Lücken

- **Stärken:** Rund 56.000 Zeilen Tests, viele Fehlerinjektionen (Checkpoints, Rollback), Dateisystem- und Symlink-Fälle, deterministische Metal-Pixelprüfungen, Lokalisierungsprüfungen.
- **Lücken, die ich gesehen habe:**
  1. Observer-Lebenszyklus am Renderer (A1) ist ungetestet.
  2. Import einer einzelnen HTML-Datei (A2) ist ungetestet.
  3. Verhalten auf macOS 14/15 ist komplett ungetestet (B3).
  4. Zeitabhängige Tests (~175 Sleeps) sind eine Flake-Quelle.
  5. Metal-Präsentation wird in der CI nicht erzwungen; echte Hardwareabläufe (Mehr-Display, Schlafen/Wecken) sind nur manuell abgedeckt (laut PROJECT.md gut dokumentiert, aber nicht automatisierbar).
  6. Einige Tests prüfen Quelltext statt Verhalten.

## 6. Empfohlene nächste Schritte

1. **A2** praktisch bestätigen (5 Minuten) und die Produktentscheidung zum Einzel-HTML-Import treffen.
2. **A1** mit einem kleinen Protokoll- oder Testlauf bestätigen (Schlafen/Wecken, Spaces, Vollbild bei pausiertem Desktop) und den Observer-Token-Fix umsetzen.
3. **B3** eine macOS-14- und -15-VM durchlaufen, bevor 14+ beworben wird.
4. **B4** wenigstens Format und Build bei jedem Push automatisch laufen lassen.
5. Alles Übrige ist optional und sollte nur bei messbarem Nutzen angegangen werden. Umbauten der Architektur sind aus meiner Sicht nicht nötig.

## 7. Hinweis zur Arbeitsweise

Ich habe ausschließlich lesende Befehle ausgeführt (`cat`, `sed`, `grep`, `find`, `du`, `git log`, `git ls-files`). Ein einzelner `git status` am Anfang kann nur den Stat-Cache des Git-Index aktualisieren; an Dateien, Index-Inhalt, Branches oder Commits wurde nichts geändert. Alle weiteren Git-Aufrufe liefen mit `--no-optional-locks`.
