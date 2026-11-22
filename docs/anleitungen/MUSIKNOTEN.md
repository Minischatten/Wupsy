# Musiknoten in Wupsy

[English](MUSIC-NOTES.md)

Mit einer Musiknotenebene kannst du Noten über dein Hintergrundbild schweben lassen, sie einer Kurve folgen lassen oder einen einzelnen Violinschlüssel platzieren. Die Arbeitsfläche hilft dir beim Anordnen. In der **Live-Vorschau** siehst du die Bewegung und das Zusammenspiel der Ebenen.

## Musiknoten hinzufügen und Symbole auswählen

1. Öffne dein Hintergrundbild im Wupsy-Editor. Wenn du mit einem Bild aus der Mediathek beginnst, wähle **Hintergrundbild bearbeiten …**.
2. Klicke neben **Ebenen / Effekte** auf **+** und wähle **Musiknoten**. Wähle die neue Musiknotenebene in der Liste aus, um ihre Einstellungen im Inspektor zu sehen.
3. Wähle unter **Platzierung** den Modus **Entlang der Strecke bewegen**. Aktiviere die Symbole, die vorkommen sollen. Zur Auswahl stehen **Viertelnote**, **Achtelnote**, **Doppelnote** und **Violinschlüssel**. Mindestens eines bleibt ausgewählt. Der Violinschlüssel ist bei einer neuen Ebene zunächst ausgeschaltet.
4. Stelle **Anzahl der Noten**, **Größe**, **Farbe** und **Deckkraft** ein. Bei der Deckkraft steht `1` für volle Sichtbarkeit und `0` für vollständig durchsichtig. Mit einer Anzahl von `0` kannst du die Notenlinien allein zeigen.

> **Screenshot-Platzhalter – Einstieg.** Zeige den Editor mit geöffnetem Plusmenü und markiertem Eintrag **Musiknoten**. Ein zweiter Ausschnitt soll die vier Symbolschalter und mehrere sichtbare Noten in der Live-Vorschau zeigen.

## Geradeaus, auf einer Linie oder im Kreis

| Gewünschte Bewegung | Einstellung im Inspektor |
| --- | --- |
| Frei durch den rechteckigen Bewegungsbereich | Wähle **Linear**. Bestimme mit den Pfeiltasten im Richtungsfeld oder mit **Richtung (°)**, wohin sich die Noten bewegen. Der Pfeil nach rechts entspricht `0°`. Am Rand tauchen die Noten auf der Gegenseite wieder auf. |
| Auf einer festen geraden Strecke | Wähle **Pfad**. Beim ersten Einschalten entsteht eine waagerechte Linie. Mit **Pfadvorlagen** → **Gerade Linie** kannst du diese Vorlage erneut einsetzen. |
| Auf einer ovalen Runde | Wähle **Pfad** und dann **Pfadvorlagen** → **Ellipse**. Die Vorlage ist **Geschlossen**. Die Noten laufen ohne Ausblenden am Übergang vom Ende zum Anfang weiter. |

Auf einem offenen Pfad blenden bewegte Noten am Ende aus und am anderen Ende wieder ein. Mit **Vorwärts** und **Rückwärts** kehrst du die Laufrichtung um. Die **Geschwindigkeit** stellst du per Regler oder Zahlenfeld ein. Mit `0` bleiben die Noten an ihren Stellen, können aber weiterhin schweben oder schaukeln.

Die **Pfadvorlagen** ersetzen die aktuelle Kurve. Wenn du eine eigene Kurve vorübergehend ausblenden möchtest, schalte auf **Linear**. Beim Wechsel zurück zu **Pfad** ist sie wieder da. **Pfad löschen** entfernt die gespeicherte Kurve.

## Einen eigenen Bézierpfad zeichnen

Ein **Anker** ist ein Punkt, durch den die Kurve verläuft. Die **Griffe** am ausgewählten Anker bestimmen, in welche Richtung die Kurve in den Punkt hinein- und wieder herausläuft.

1. Wähle **Pfad** und dann **Pfad bearbeiten**. Die Kurve mit ihren Ankern erscheint auf der **Arbeitsfläche**. Bei einem offenen Pfad helfen das Quadrat, der orangefarbene Punkt und der Richtungspfeil, Start, Ende und Laufrichtung zu erkennen.
2. Doppelklicke auf die Kurve, um dort einen Anker einzufügen. Die Form bleibt zunächst gleich. Ziehe den neuen Anker zum Beispiel nach oben, um aus der geraden Linie einen Bogen zu machen.
3. Klicke einen Anker an und ziehe seine Griffe, bis die Kurve weich in die nächste Strecke übergeht. Zum Verschieben des ganzen Punkts ziehst du den Anker selbst. Anker und Griffe bleiben im Bewegungsrahmen.
4. Wähle einen überflüssigen Anker aus und drücke die **Löschtaste**. Mindestens zwei Anker müssen erhalten bleiben. **Escape** bricht ein laufendes Ziehen ab.
5. Klicke auf **Pfadbearbeitung beenden**, um wieder den Bewegungsrahmen zu bearbeiten. Ziehe in den Rahmen, um ihn zu verschieben. Seiten ändern jeweils eine Abmessung, Ecken beide. So kannst du die Kurve als Ganzes im Bild ausrichten.

> **Screenshot-Platzhalter – Kurve bearbeiten.** Zeige eine offene Kurve mit einem ausgewählten mittleren Anker und zwei sichtbaren Griffen. Beschrifte Anker, Griffe, Start, Ende und Richtungspfeil. Im Inspektor soll **Pfadbearbeitung beenden** sichtbar sein.

## Notenlinien, Schweben und Drehung

### Fünf Notenlinien gestalten

Aktiviere unter **Notenlinien** den Schalter **Notenlinien anzeigen**. Bei **Pfad** folgt die mittlere Linie deiner Kurve. Bei **Linear** verläuft sie durch die Mitte des Bewegungsrahmens in der gewählten Richtung.

- **Linienabstand** regelt den Abstand der fünf Linien. **Linienstärke** muss kleiner als der Abstand sein.
- **Linienfarbe** und **Liniendeckkraft** gelten unabhängig von Farbe und Deckkraft der Noten.
- Bei engen Bögen können sich Linien überschneiden. Ziehe die Kurve weiter oder verringere den Linienabstand.

### Sanftes Schweben und Schaukeln

Unter **Sanfte Bewegung** schiebt **Sanftes Schweben** die Symbole leicht quer zur Bewegung hin und her. Mit **Schwebestärke** bestimmst du, wie weit sie ausschwingen, und mit **Schwebegeschwindigkeit**, wie schnell sich die Bewegung wiederholt.

**Sanftes Schaukeln** kippt das Symbol abwechselnd in beide Richtungen. **Schaukelstärke** bestimmt, wie weit es kippt, und **Schaukelgeschwindigkeit**, wie oft es schaukelt. Du kannst Schweben und Schaukeln zusammen verwenden.

### Ein einzelnes Symbol platzieren oder drehen

- **Frei platzieren** zeigt ein einzelnes **Symbol**. Ziehe es auf der Arbeitsfläche an seinen Platz oder gib **X (Canvas)** und **Y (Canvas)** ein.
- **Am Pfad befestigen** hält das Symbol an der eingestellten **Pfadposition (%)**. Mit **An Pfadtangente ausrichten** folgt seine Ausrichtung der Kurve an dieser Stelle. Ohne aktiven Pfad bleibt es in der Mitte des Bewegungsrahmens.

Für ein einzelnes Symbol bietet **Drehmodus** die Auswahl **Keine Drehung**, **Sanftes Schaukeln** oder **Kontinuierlich drehen**. Bei kontinuierlicher Drehung kannst du die **Drehrichtung** und **Sekunden pro Umdrehung** einstellen. Je größer die Zeit, desto langsamer die Drehung. **Bildebene (2D)** dreht das Symbol wie einen Zeiger auf dem Bild. **Vertikale Achse (2,5D)** lässt es wie eine sich wendende Karte schmal werden und zeigt dann die gespiegelte Rückseite. Dabei können beide Drehrichtungen gleich aussehen. Schweben kannst du unabhängig vom Drehmodus einschalten.

## Noten vor und hinter einem Bildlayer

Für eine durchgehende Verdeckung reicht die Ebenenreihenfolge. Eine Bildebene, die vor den Noten gezeichnet wird, verdeckt sie an ihren deckenden Stellen. Für einen Wechsel entlang der Strecke verwende **Tiefenwechsel**.

1. Wähle **Entlang der Strecke bewegen** und aktiviere **Pfad**.
2. Wähle unter **Tiefenwechsel** bei **Vordergrund-Layer** die gewünschte Bildebene. Prüfe, dass **Tiefenwechsel aktivieren** eingeschaltet ist. Für eine Person brauchst du eine eigene Vordergrundebene mit freigestellter Person und transparentem Umfeld, etwa eine PNG-Datei. Ein flaches Foto verdeckt die Noten überall dort, wo es deckend ist. Eine über **Bild hinzufügen …** hinzugefügte Vordergrundebene eignet sich als Ziel.
3. Wähle bei **Am Pfadanfang** die erste Position, **Vor dem Bildlayer** oder **Hinter dem Bildlayer**.
4. Klicke auf **Wechselpunkt hinzufügen**. Gib eine **Pfadposition (%)** zwischen Anfang und Ende ein und wähle bei **Nach diesem Punkt** die gewünschte Seite. Du kannst bis zu acht Wechselpunkte setzen. Setze jeden Punkt auf einen eigenen Wert größer als `0` und kleiner als `100`.
5. Wenn auch die fünf sichtbaren Linien hinter dem Bild verschwinden sollen, wähle bei **Tiefenwechsel anwenden auf** den Eintrag **Noten und Notenlinien**. Mit **Nur Noten** behalten die Linien ihre normale Position in der Ebenenreihenfolge.

Durchsichtige Bildbereiche lassen die Noten sichtbar. Teiltransparenz oder eine geringere Deckkraft der Bildebene verdeckt sie nur teilweise. Liegt ein Wechselpunkt mitten in einer deckenden Fläche, können Noten dort abrupt verschwinden oder erscheinen. Für einen natürlichen Übergang platziere ihn möglichst knapp außerhalb der Silhouette.

## Perspektive von Groß zu Klein und Klein zu Groß

Mit **Perspektive** wirken Noten so, als bewegten sie sich in die Ferne oder auf dich zu. Die Einstellung gilt für **Entlang der Strecke bewegen** auf einem aktiven **offenen** Pfad. Sie verändert die sichtbare Größe entlang der Strecke bei gleichbleibendem Tempo. Bei eingeschalteten Notenlinien ändern sich auch Linienabstand und Linienstärke entlang des Pfads.

1. Wähle **Pfad** und **Offen**. Schalte **Perspektive** ein.
2. Für **Groß → Klein** stelle **Größe am Anfang (%)** auf `100` und **Größe am Ende (%)** auf `30`. Das sind auch die Vorgabewerte.
3. Für **Klein → Groß** klicke **Anfang und Ende tauschen**. Jetzt beginnt die Strecke bei `30` und endet bei `100`. Beide Felder erlauben Werte von `10` bis `200`.

Anfang und Ende beziehen sich auf die gezeichnete Kurve. Bei **Rückwärts** durchlaufen die Noten den Größenverlauf in umgekehrter Richtung. **Anfang und Ende tauschen** ändert nur den Größenverlauf. Auf einem **geschlossenen** Pfad setzt Wupsy die Perspektive aus, damit die Größe am Übergang nicht springt. Die Werte werden wieder wirksam, sobald du zu einem offenen Pfad mit bewegten Noten zurückkehrst.

> **Abbildungsplatzhalter – Größenverlauf.** Zeige zwei Ansichten desselben offenen Pfads mit **Vorwärts**. Markiere in beiden den Pfadanfang und das Pfadende. Zeige oben `100 → 30 %` und unten `30 → 100 %`, jeweils mit sichtbaren Noten und den passenden Werten im Inspektor.

## Drei Beispiele zum Nachmachen

### 1. Noten schweben von links nach rechts

1. Füge eine Musiknotenebene hinzu. Wähle **Entlang der Strecke bewegen** und **Linear**.
2. Klicke auf den Rechtspfeil bei **Richtung (°)**. Beginne mit **Anzahl der Noten** `8`, **Größe** `48` und **Geschwindigkeit** `24`.
3. Aktiviere **Sanftes Schweben** und lass **Sanftes Schaukeln** zunächst aus. Prüfe in der **Live-Vorschau**, ob das Tempo zum Bild passt.

### 2. Noten verschwinden hinter einer Person

1. Verwende ein Hintergrundbild und füge über **Bild hinzufügen …** eine freigestellte Person mit transparentem Umfeld hinzu.
2. Füge **Musiknoten** hinzu. Wähle **Pfad** → **Pfadvorlagen** → **Gerade Linie**, dann **Pfad bearbeiten**. Füge per Doppelklick einen Anker nahe der Bildmitte ein und ziehe ihn etwas nach oben. Forme mit seinen Griffen einen weichen Bogen, der die Person auf Höhe der Schultern kreuzt.
3. Wähle die Personenebene als **Vordergrund-Layer**. Aktiviere **Tiefenwechsel** und setze **Am Pfadanfang** auf **Vor dem Bildlayer**.
4. Setze zwei Wechselpunkte, als Startwerte etwa bei `35` und `65`. Wähle nach dem ersten Punkt **Hinter dem Bildlayer** und nach dem zweiten **Vor dem Bildlayer**. Passe beide Prozentwerte an den tatsächlichen Verlauf vor der Person an. Wenn du die Linien mit verdecken möchtest, aktiviere sie und wähle **Noten und Notenlinien**.

> **Screenshot-Platzhalter – Verdeckung.** Zeige die freigestellte Figur vor einem ruhigen Hintergrund. In der Live-Vorschau sollen die Noten links und rechts der Figur sichtbar sein und hinter ihrer Silhouette verschwinden. Der Inspektor soll den gewählten Vordergrund-Layer und beide Wechselpunkte zeigen.

### 3. Noten wachsen auf dich zu

1. Wähle **Entlang der Strecke bewegen**, **Pfad**, **Gerade Linie**, **Offen** und **Vorwärts**. Ziehe bei Bedarf in **Pfad bearbeiten** den Endanker etwas nach unten. So führt die Strecke von einem höheren Bildbereich in den Vordergrund.
2. Aktiviere **Perspektive** und klicke bei den Standardwerten auf **Anfang und Ende tauschen**. Prüfe, dass **Größe am Anfang (%)** auf `30` und **Größe am Ende (%)** auf `100` steht.
3. Lass die **Live-Vorschau** laufen. Die Noten beginnen klein und werden auf dem Weg zum Pfadende allmählich größer. Wenn sie in der Vorschau kleiner werden, prüfe **Vorwärts** und die beiden Prozentwerte.

## Wenn etwas anders aussieht als erwartet

- **Es sind keine Noten zu sehen.** Prüfe, ob die Musiknotenebene sichtbar ist, die **Anzahl der Noten** über `0` liegt und die **Deckkraft** hoch genug ist. Prüfe auch, ob eine deckende Ebene davorliegt.
- **Die Noten bewegen sich nicht.** Prüfe die **Live-Vorschau**, die **Geschwindigkeit** und die **Platzierung**. Ein frei platziertes oder befestigtes Symbol bleibt an seinem Ort. Die Arbeitsfläche zeigt bei einem einzelnen Symbol die neutrale Darstellung.
- **Große Noten wachsen kaum weiter.** Bei bewegten und am Pfad befestigten Symbolen begrenzt ein kleiner Bewegungsrahmen die sichtbare Größe. Vergrößere den Rahmen oder probiere eine kleinere Grundgröße für einen deutlicheren Perspektivverlauf.
- **Der Neustart am Pfadende wirkt abrupt.** Bei einer kurzen Strecke und hohem Tempo kann die Blende kaum zu sehen sein. Senke die **Geschwindigkeit** oder verlängere den Pfad. Bei **Geschlossen** gibt es keine Endblende. Unterschiedliche Tiefen am Anfang und Ende können an der Verbindungsstelle trotzdem einen sichtbaren Wechsel erzeugen.
- **Das Ziel für den Tiefenwechsel fehlt.** Wähle eine geeignete sichtbare Bildebene. Ist das gewählte Ziel ausgeblendet oder fehlt es, gilt wieder die normale Ebenenreihenfolge. **Tiefenwechsel** und **Perspektive** stehen für einzelne Symbole nicht zur Verfügung.
- **Du möchtest neu anfangen.** **Auf Standardwerte zurücksetzen** stellt die Vorgaben wieder her und wechselt zu **Linear**. Die gezeichnete Kurve und der Bewegungsrahmen bleiben erhalten. Mit **Sichern** speicherst du deine fertige Szene.

[Zur deutschen Editor-Anleitung](../EDITOR.de.md) · [Technische Dokumentation zum Musiknoten-Effekt](../effects/MUSIC-NOTES.md)
