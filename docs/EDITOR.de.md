[English](EDITOR.md) | [Deutsch](EDITOR.de.md)

# Nativer Editor

## Erstellen oder öffnen

Erstelle in Wupsy ein natives Wallpaper oder importiere einen Projektordner mit scene.wss.json. Öffne das native Wallpaper im Editor. Bilder und Masken sind Benutzerinhalte; Wupsy liefert keine persönlichen Referenz-Wallpaper mit und konvertiert keine Projekte externer Engines. Ein ungültiges Projekt ist ein Fehler und kein Auftrag, fehlende Dateien zu rekonstruieren.

Die Ebenenliste bestimmt die Zeichenreihenfolge. Füge Bild-, Rain- oder CursorTrail-Ebenen hinzu, ordne sie um, benenne unterstützte Bildebenen um, schalte die Sichtbarkeit um oder lösche Ebenen, solange eine gültige Szene erhalten bleibt. Bildtransformationen verwenden logische Canvas-Koordinaten; das Hinzufügen oder Ersetzen eines Bildes normalisiert PNG/JPEG/HEIC/TIFF-Eingaben zu unabhängig verwalteten PNG-Daten. Beim Ersetzen bleiben die vorhandenen Transformations- und Effektregeln der Ebene erhalten; ihre Felder werden nicht automatisch neu abgetastet.

## Bildeffekte

Füge der ausgewählten Bildebene Ripple, Clouds oder Flow hinzu und wähle anschließend einen Effekt aus, um seine Bedienelemente zu bearbeiten. Siehe [gemeinsame Regeln für Effektreihenfolge und Validierung](effects/COMMON.md), einschließlich des Unterschieds zwischen den komfortablen Reglerbereichen und den gültigen gespeicherten Werten.

- [Ripple](effects/RIPPLE.md): Bedienelemente für Verschiebung, Bewegung und räumliche Struktur.
- [Clouds](effects/CLOUDS.md): Rauschen, Abdeckung, Tonwert und unterstützte Inspektor-Bedienelemente; die technische Beschreibung erläutert die anfängliche Maske und die erhalten bleibenden optionalen Felder.
- [Flow](effects/FLOW.md): Transport-Bedienelemente, Malen von Richtungen und Regeln für Regionen; die technische Beschreibung erläutert den neutralen Anfangszustand beim Hinzufügen, Malen/Radieren und das atomare Rückgängigmachen.

Wähle einen Effekt aus, um seine Maske zu prüfen oder zu bearbeiten, soweit dies unterstützt wird. Das Malen skalarer Masken schreibt unabhängige Dateigenerationen, niemals die Originaldatei. Die ausgewählte Überlagerung gehört zum Editorzustand; sie ist keine dauerhaft gespeicherte sichtbare Ebene.

## Musiknoten

Mit der [Benutzeranleitung für Musiknoten](anleitungen/MUSIKNOTEN.md) lernst du,
wie du Noten animierst, eigene Kurven zeichnest und Tiefenwechsel und Perspektive einstellst.

## Nebel

Wähle „Nebel“ im Menü zum Hinzufügen von Ebenen. Nebel startet mit einer
schwarzen Maske, aktivem Pinsel und einem Rahmen um die ganze Szene. Male,
um Nebel sichtbar zu machen. Halte die Wahltaste gedrückt, um zu radieren.
Nebel ohne Maskenreferenz zeigt beim Auswählen oder nach „Maske entfernen“
die Überlagerung mit voller Deckung. Erst ein wirksamer Strich erzeugt eine Maske. Die blaue Überlagerung folgt der Höhe und Weichheit. Rahmen und
Maske behalten ihre Szenenposition. Über das Maskenmenü kannst du die Maske
importieren, füllen, leeren oder entfernen. „Auf Standard zurücksetzen“
setzt die Nebelparameter zurück und erhält die Maske.
Die Ebenenreihenfolge bestimmt, welche Vordergrundelemente den Nebel verdecken.
Im Inspektor stellst du Dichte, Weichheit, Strukturgröße und Höhe ein. Die Farbe
wählst du über die native macOS-Farbauswahl. Acht Richtungstasten, der
Geschwindigkeitsregler und die numerischen X/Y-Felder steuern die Drift. Die
Geschwindigkeitsanzeige folgt dem Regler beim Ziehen. Die Live-Vorschau kann
Zwischenwerte überspringen. Beim Loslassen wird die endgültige Drift als ein
Undo-Schritt übernommen. [Nebel-Vertrag](effects/FOG.md)

## Rain und CursorTrail

[Rain](effects/RAIN.md) ist eine separate rechteckige Szenenebene. Passe ihre Region und Regenparameter an und platziere sie zwischen Bildern, damit Vordergrundbilder den Regen verdecken. Die technische Rain-Beschreibung definiert Profilaktionen, Standardwerte beim Hinzufügen und die Bedeutung von Dichte beziehungsweise Tropfenanzahl.

[CursorTrail](../WSS-TRAIL.md) ist eine prozedurale Ebene, die in Live-Vorschau und Wiedergabe vom lokalen Mauszeiger gesteuert wird. Ihre technische Beschreibung definiert Bedienelemente, Standardwerte, die ausdrückliche Palettenumwandlung und die proportionale Anpassung von Lebensdauer und Ein-/Ausblendzeiten.

## Zahlenfelder und Rückgängig

Zahlenfelder behalten ihre angezeigte Schreibweise, solange sie den Fokus haben. Während der Eingabe sind leere oder unvollständige Texte zulässig. Return und ein erfolgreicher Fokuswechsel übernehmen gültige, endliche Werte innerhalb des zulässigen Bereichs. Ungültiger Text behält einen Fehlerhinweis und verändert das Dokument nicht; Escape stellt den letzten Modellwert wieder her. Deutsche Dezimalkommas werden akzeptiert; die direkte Eingabe erhält die unterstützte Float/Double-Genauigkeit.

Eine gerundete Anzeige rundet nicht die gespeicherten Parameter. Ein Fokuswechsel ohne Textänderung erhält den ursprünglichen internen Wert, auch wenn die Anzeige gerundet ist. Aktualisierungen durch Regler oder Modell aktualisieren unveränderte Felder; ein bearbeiteter Entwurf bleibt editierbar, während der beim Abbrechen wiederherzustellende Ausgangswert dem neueren Modell folgt. Nur tatsächliche Modelländerungen werden in den Rückgängig-/Wiederholen-Verlauf des Dokuments aufgenommen. Sichern prüft noch ausstehende Eingaben vor der Übernahme der Daten.

## Arbeitsfläche und Vorschau

Die statische Arbeitsfläche zeigt das Bildlayout ohne Effekte, Rain oder Trail. Die Live-Vorschau rendert die bearbeitete native Szene mit derselben Laufzeitumgebung wie die Desktop-Wiedergabe. Mauszeigerbewegungen und Vorschauzeit sind keine Dokumentänderungen. Parameter- oder Strukturänderungen können Vorschauressourcen ersetzen und den flüchtigen Trail-Verlauf zurücksetzen; Pausen-, Ruhezustands- und Sitzungssteuerung schreiben das Projekt nicht um.

## Sichern, Sichern unter und schließen

Die Bearbeitung aktualisiert das Arbeitsmodell. Sichern validiert das codierte JSON, referenzierte Assets und die beim Laden erfassten Fingerabdrücke, installiert zuerst unveränderliche Assets und ersetzt scene.wss.json zuletzt atomar. Sichern wählt niemals ein anderes Desktop-Wallpaper aus; bei einer bereits aktiven passenden UUID wird die laufende Desktop-Wiedergabe auf den gesicherten Stand aktualisiert, ohne den Zustand der Wiedergabelisten zu ändern.

Sichern unter erstellt ein unabhängig verwaltetes Projekt in der Mediathek, begrenzt auf 512 MiB, mit neuem Titel und neuer Identität. Nach erfolgreicher Übernahme wechselt derselbe Editor zum gesicherten Projekt B ohne ausstehende Änderungen und mit leerem Rückgängig-/Wiederholen-Verlauf; A sowie die Verweise von Desktop und Wiedergabelisten bleiben unverändert. Scheitert die Übernahme in die Mediathek, kann ein vollständiges, aber nicht referenziertes Projekt zurückbleiben; es findet keine automatische Speicherbereinigung statt.

Beim Schließen werden ungesicherte Änderungen geklärt. Eine native Sicherung erfasst den gesicherten Stand, nicht ungesicherte Editorentwürfe oder den Rückgängig-Verlauf. Die Wiederherstellung klärt den Zustand aller Editoren und wartet vor der unumkehrbaren Übernahme auf das Ende laufender Laufzeitoperationen; anschließend muss die App beendet und erneut geöffnet werden. Siehe [Architektur](ARCHITECTURE.md), [Sicherung](../BACKUP-FORMAT.md) und [Wiederherstellung](../RESTORE-TRANSACTION.md).

Verwaltete statische Bilder lassen sich über „Hintergrundbild bearbeiten …“ als unabhängige WSS-Entwürfe öffnen. Das erste Speichern bietet eine zusätzliche Szene (Voreinstellung) oder das Ersetzen des ursprünglichen Eintrags an. Erneutes Öffnen derselben Quelle fokussiert die vorhandene Editorsitzung. Akzeptiert werden nur Einzelbilder; mehrseitige TIFFs werden abgewiesen. Die Normalisierung verwendet acht Bit sRGB-PNG und erhält daher nicht den vollen HDR-/Wide-Gamut-Farbumfang. Die Herkunft bleibt Sitzungszustand und wird nicht im Szenen-JSON gespeichert.

Beim Ersetzen bleiben Quell-UUID und aktuelle Mediathekposition erhalten; Favoriten und Playlist-Verweise bleiben gültig. Datensatz und Fingerprint der beim Öffnen gelesenen Bildbytes werden erneut geprüft. Erst nach unabhängiger Projektveröffentlichung wird library.json atomar ausgetauscht. Umbenennen, Entfernen, Ersetzen oder geänderte Bildbytes führen zu einem Konflikt; zusätzliches Speichern bleibt möglich. Gleiche Anzeigenamen bleiben erlaubt. Externe und alte verwaltete Bilddateien werden nicht gelöscht. Ersetzen ist während der Hintergrundbild- und Playlist-Wiedergabe möglich. Inaktive Einträge lösen keinen Desktopwechsel aus; die Playlist verwendet die Szene beim nächsten regulären Durchlauf. Aktive Einträge erhalten zunächst verdeckt gestartete Ersatzrenderer. Nur Renderer mit derselben UUID werden ausgetauscht; Pause, Playlist-Timer und Shuffle-Zustand bleiben erhalten. Neuere Aktionen haben Vorrang. Bei einem Fehler der Desktopaktualisierung bleibt die Szene gespeichert und eine Warnung erscheint; bei synchronem Startfehler bleibt der vorherige Renderer erhalten. Laufende Apply-Anfragen werden ohne zweiten Request auf den neuen Datensatz umgestellt. Displayänderungen können die automatische Übergabe verhindern; die nächste Aktivierung verwendet die gespeicherte Szene. Ein erfolgreicher Start garantiert noch keinen ersten sichtbaren GPU-Frame. Normales Erstellen und „Speichern unter …“ behalten ihren bisherigen Namensdialog.

## Abgeschlossene Abnahme

Der Maintainer hat die abschließende Abnahme der Bearbeitung und Ersetzung von Mediathek-Bildern am 14.11.2026 bestätigt:

| System | Tests | Fehler | Skips | Praktische GUI-Prüfungen | Ersetzen des aktiven Playlist-Wallpapers |
| --- | ---: | ---: | ---: | --- | --- |
| macOS 26 | 1.250 | 0 | 11 | Erfolgreich | Erfolgreich |
| macOS 27 | 1.250 | 0 | 11 | Erfolgreich | Erfolgreich |

Die Ergebnisse gelten für die abgeschlossene Funktion aus Etappe 1–3 einschließlich zusätzlichem Speichern, Ersetzen mit erhaltener Identität und Sortierung sowie der Wiedergabeübergabe während einer laufenden Playlist.
