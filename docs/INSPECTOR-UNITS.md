# Numerische Einheiten im WSS-Inspector

Stand Phase 2.2 E.2. Die Tabelle erfasst numerisch bearbeitbare Felder und
Regler. Gemeinsam beschriftete Achsen stehen in einer Zeile. Bereiche sind
Eingabegrenzen, gegebenenfalls ergänzt um den engeren Reglerbereich.
Effektspezifische Budgets und Beziehungen zwischen Feldern gelten zusätzlich.

- **A** kennzeichnet eine reine Beschriftungsänderung oder eine bereits
  passende Anzeige. **B** verlangt nur eine reversible Anzeige-/Eingabeumrechnung.
  Beide Kategorien lassen gespeicherte Werte, bestehende Wallpaper und
  Rendererberechnungen unverändert.
- **C** kennzeichnet eine Änderung der Semantik oder Renderermetrik, falls
  eine einheitliche Szenengröße verlangt wird. Veröffentlichte Effekte müssen
  ihre bisherige Semantik behalten. Bei ihnen kann die lokale Einheit bereits
  heute eindeutig bezeichnet werden. Nur räumliche Felder des unveröffentlichten Slime-Effekts wurden in E.1 und E.2 geändert.
- **S** bedeutet Szenenkoordinaten. Zoom, Vorschaugröße, Monitorauflösung und
  HiDPI ändern lediglich die Ausgabeprojektion. **L** bezeichnet lokale
  Bild-/Effektkoordinaten. Rotation und anisotrope Skalierung können Betrag,
  Richtung oder Breite im Szenenbild verändern. **N** normalisiert auf die
  jeweils angegebene Bezugsgröße. **F** bezeichnet Faktoren, Farben, Zeit-
  und Frequenzwerte, Seeds und Stückzahlen ohne räumliche Transformation.

Grundlage sind die Inspector-Controls in `Sources/Wupsy`, deren Bereiche,
`Resources/Localizable.xcstrings`, die [WSS-Spezifikation](../WSS-SCENE-FORMAT.md),
die [Effektverträge](effects) und der [CursorTrail-Vertrag](../WSS-TRAIL.md).
Native Farbfelder öffnen die macOS-Farbauswahl. Der Inspector besitzt dafür
keine eigenen numerischen RGB-Eingabefelder. Ebenso sind Rain-Seed und
Rain-Deckkraftspanne, CursorTrail-Emissionsrate, Ausblendzeiten und Seed
sowie die nicht exponierten Clouds-Parameter Teil des Formats, aber keine
numerischen Regler im Inspector. Music-Notes-Pfadanker und Bézier-Griffe
werden im Canvas gezogen. Dabei bleiben ihre Koordinaten Szenenwerte.

## Allgemeine Ebenen und Bearbeitungswerkzeuge

| Aktuell DE / EN | Bereich | Bedeutung und Abhängigkeit | Empfehlung und Eingriff |
|---|---|---|---|
| Mittelpunkt X / Center X<br>Mittelpunkt Y / Center Y | ±1.000.000 | S Mittelpunktkoordinaten | A Szenen-px |
| Breite / Width<br>Höhe / Height | >0…8192 | S Grundgröße (vor Achsenskalierung) | B Grundgröße kennzeichnen oder wirksame Größe mit Faktor umrechnen |
| Skalierung X / Scale X<br>Skalierung Y / Scale Y | >0…100 | F Achsenskalierung, beeinflusst angehängte Effekte | B Prozent |
| Drehung (Grad) / Rotation (degrees) | ±57.295.776° | S Winkel, gespeichert in Radiant | A Grad beibehalten |
| Deckkraft / Opacity | UI 0…100 % in ganzen Schritten, intern 0…1 | F Bildalpha | A vorhandene Prozentumrechnung beibehalten |
| Größe / Size | 1…2 × längste Seite des Ziels | L Pinseldurchmesser in Maskentexeln bzw. lokalen Bildeinheiten beim Richtungsmalen; Zoom ändert Projektion | A Bezugsraum je Werkzeug kennzeichnen |
| Bewegungsstärke / Movement strength | UI 0…100 %, intern 0…1 | F Länge des gemalten Richtungsvektors | A Prozent beibehalten |
| Deckkraft / Opacity | 0…100 % | F Maskenziel bzw. relative Löschstärke | A Prozent beibehalten |

## Flow (Strömung)

| Aktuell DE / EN | Bereich | Bedeutung und Abhängigkeit | Empfehlung und Eingriff |
|---|---|---|---|
| Geschwindigkeit / Speed | 0…1024, Regler bis 256 | L lokale Einheiten/s für die Advektion | C lokales Tempo kennzeichnen; transformunabhängige Vektorgeschwindigkeit erfordert Semantikänderung |
| Stärke / Strength | 0…128 | L Halbauslenkung bei Einheitsvektor | C lokale Einheiten; anisotrope Transformation verhindert einen einzigen Szenenpixelwert |
| Randberuhigung (px) / Edge protection (px) | 0…4096 | L Abstand zur Bild- oder Regionsgrenze | C lokale Pixel präzisieren; konstanter Szenenabstand erfordert neue Distanzmetrik |

## Ripple (Wellen)

| Aktuell DE / EN | Bereich | Bedeutung und Abhängigkeit | Empfehlung und Eingriff |
|---|---|---|---|
| Wellenstärke / Amplitude | 0…256, Regler bis 64 | L Auslenkung | C lokale Einheiten; konstante Szenenauslenkung braucht neue Vektormetrik |
| Wellenlänge / Wavelength | 4…8192, Regler bis 1024 | L Grundwellenlänge vor Streckung/Drehung | C lokale Grundwellenlänge; definierte Szenenwellenlänge braucht neue Metrik |
| Ausbreitungsgeschwindigkeit / Travel speed | 0…4096, Regler bis 256 | L Wanderung pro s in Bewegungsrichtung | B Szenen-px/s entlang der transformierten Richtung |
| Bewegungsrichtung (°) / Movement direction (°)<br>Strukturrotation (°) / Structure rotation (°) | [0,360)° | L Bewegungsrichtung bzw. Strukturdrehung nach Streckung | A Grad im Bildraum |
| Streckung / Stretch<br>Seitliches Detail / Lateral detail | 0,125…8 | F Anisotropie bzw. Querfrequenzfaktor | A Faktoren |
| Evolution / Evolution | 0…8 | F zeitlicher Evolutionsfaktor | A Faktor |
| Seed / Seed | UInt32 | F deterministischer Seed | A Seed |

## Clouds (Wolken)

| Aktuell DE / EN | Bereich | Bedeutung und Abhängigkeit | Empfehlung und Eingriff |
|---|---|---|---|
| Horizontalgeschwindigkeit (px/s) / Horizontal speed (px/s)<br>Vertikalgeschwindigkeit (px/s) / Vertical speed (px/s)<br>Zweites Feld: Horizontalgeschwindigkeit (px/s) / Secondary horizontal speed (px/s)<br>Zweites Feld: Vertikalgeschwindigkeit (px/s) / Secondary vertical speed (px/s) | ±4096, Regler ±256 | L lokale Einheiten/s (X rechts, Y unten), Primär- und Zweitfeld | B lokale px/s präzisieren oder komponentenweise in Szenenachsen umrechnen |
| Primärskalierung / Primary scale | 1…8192, Regler bis 2048 | L primäre Kachelperiode in lokalen Einheiten | C lokale Kachelgröße; quadratische Szenenkachel bei anisotroper Skalierung braucht neue Metrik |
| Intensität / Intensity<br>Dichte / Density | 0…1 | F Effektstärke bzw. Bedeckungsverteilung | B Prozent einer Stärke, keine Flächenprognose |
| Helligkeit / Brightness | 0…2 | F SDR-Tonverstärkung | A Faktor |

## Fog (Nebel)

| Aktuell DE / EN | Bereich | Bedeutung und Abhängigkeit | Empfehlung und Eingriff |
|---|---|---|---|
| Dichte / Density<br>Weichheit / Softness | 0…1 | F Dichte-/Weichheitsparameter | B Prozent der Stärke |
| Horizontale Drift / Horizontal Drift<br>Vertikale Drift / Vertical Drift | ±128 je Achse | S Driftkomponenten pro s | A Szenen-px/s |
| Geschwindigkeit / Speed | 0…128/max(abs(Richtungsvektor)) | S Betrag der Drift in Szenen-px/s | A Szenen-px/s |
| Strukturgröße / Structure Scale | 32…8192 | S Strukturgröße | A Szenen-px |
| Höhe (Anteil der Szenenhöhe) / Height (Canvas Fraction) | 0,05…1,5 | N Anteil an der Szenenhöhe | B Prozent der Szenenhöhe |

## Rain (Regen)

| Aktuell DE / EN | Bereich | Bedeutung und Abhängigkeit | Empfehlung und Eingriff |
|---|---|---|---|
| Menge / Amount | 0…2000, Regler bis 300 | N Tropfen je 1 Mio. Szenen-px², Anzahl hängt von Region und Budget ab | A Dichte pro Megapixel, keine Emissionsrate |
| Geschwindigkeit / Speed | 0…6000, Regler bis 3000 | S Grundgeschwindigkeit vor Tiefenvariation | A Szenen-px/s |
| Neigung (°) / Slant (°) | −180…180, Regler ±60° | S Winkel ab unten | A Grad |
| Tropfen N: Länge / Drop N: Length | 0,25…384, Regler 1…128 | S Grundlänge je Klasse, Tiefenstaffelung | A Basislänge in Szenen-px |
| Tropfen N: Dicke / Drop N: Width | 0,25…8, Regler bis 4 | S Grundbreite je Klasse, Tiefenstaffelung | A Basisbreite in Szenen-px |

## Starfield (Sternenfeld)

| Aktuell DE / EN | Bereich | Bedeutung und Abhängigkeit | Empfehlung und Eingriff |
|---|---|---|---|
| Bereich X / Region X<br>Bereich Y / Region Y | ±1.000.000 | S linke untere Ecke | A Szenen-px |
| Bereichsbreite / Region width<br>Bereichshöhe / Region height | 1…8192, Fläche ≤32 Mi px² | S Rechteckgröße | A Szenen-px |
| Sternanzahl / Star count | 0…16384 ganzzahlig | F Anzahl, Dichte hängt von Region ab | A Anzahl |
| Sterngröße / Star size | 0,25…16 | S Stern-Kernmaß | A Szenen-px |
| Helligkeit / Brightness | 0…4 | F Emissionsverstärkung | A Faktor |
| Farbvariation (0–1) / Color variation (0–1)<br>Funkelintensität / Twinkle intensity | 0…1 | F Farbstreuung je Kanal bzw. Modulationstiefe | B Prozent |
| Funkelgeschwindigkeit (Hz) / Twinkle speed (Hz) | 0…2 | F Basisfrequenz für acht Gruppen | A Hz |
| Horizontale Drift (Einheiten/s) / Horizontal drift (units/s)<br>Vertikale Drift (Einheiten/s) / Vertical drift (units/s) | ±10 | S Drift pro Sekunde, X rechts/Y oben | A Szenen-px/s |
| Seed / Seed | UInt32 | F deterministischer Seed | A Seed |

## Starfield – Sternschnuppen

| Aktuell DE / EN | Bereich | Bedeutung und Abhängigkeit | Empfehlung und Eingriff |
|---|---|---|---|
| Sternschnuppen pro 10 Minuten / Shooting stars per 10 minutes | 0…120 in der UI, gespeichert 0…12 | F erwartete Ereignisse je zehn Minuten, intern je Minute | A bestehende Darstellung beibehalten |
| Geschwindigkeit (Einheiten/s) / Speed (units/s) | 50…3000 | S Basisgeschwindigkeit, Variation pro Meteor | A Szenen-px/s |
| Schweiflänge / Tail length | 0…1024 | S Schweiflänge | A Szenen-px |
| Helligkeit / Brightness | 0…4 | F Emissionsverstärkung | A Faktor |
| Richtung (°) / Direction (°)<br>Richtungsvariation (±°) / Direction variation (±°) | 0…360° bzw. 0…90° | S Winkel ab rechts gegen Uhrzeigersinn und symmetrische Abweichung | A Grad |

## Starfield – Milchstraße

| Aktuell DE / EN | Bereich | Bedeutung und Abhängigkeit | Empfehlung und Eingriff |
|---|---|---|---|
| Position X (0–1) / Position X (0–1)<br>Position Y (0–1) / Position Y (0–1) | 0…1 | N Position im Sternenfeldrechteck | B Prozent je Rechteckachse |
| Bandwinkel (°) / Band angle (°) | 0…360° | S Bandwinkel gegen Uhrzeigersinn | A Grad |
| Bandbreite (0,03–1) / Band width (0.03–1) | 0,03…1 | N Anteil der kürzeren Seite des Sternenfeldrechtecks | B Prozent der kürzeren Seite |
| Intensität / Intensity | 0…2 | F Emissionsverstärkung | A Faktor |
| Strukturstärke / Structure<br>Staubbänder / Dust lanes | 0…1 | F Strukturmodulation bzw. Abdunklung des Bandlichts | B Prozent der Stärke |
| Milchstraßen-Seed / Milky Way seed | UInt32 | F deterministischer Seed | A Seed |

## Storm (Gewitter)

| Aktuell DE / EN | Bereich | Bedeutung und Abhängigkeit | Empfehlung und Eingriff |
|---|---|---|---|
| Position X / Position X<br>Position Y / Position Y | ±1.000.000 | S Blitzursprung | A Szenen-px |
| Länge / Length<br>Ausbreitung / Spread<br>Blitzdicke / Bolt Thickness<br>Glow-Breite / Glow width | 1…8192; 0…2048; 0,25…32; 0…128 | S Länge, Streuung, volle Kernbreite und zusätzliche Glow-Halbbreite | A Szenen-px mit eindeutigen Maßbegriffen |
| Richtung (°) / Direction (°) | [0,360)° | S Winkel ab unten | A Grad |
| Helligkeit / Brightness | 0…8 | F Blitzverstärkung | A Faktor |
| Verzweigungstiefe (0–3) / Branch depth (0–3)<br>Aufflackern (1–3) / Flashes (1–3) | 0…3 bzw. 1…3 ganzzahlig | F Verzweigungstiefe bzw. Zahl der Impulse | A Anzahl |
| Ereignisabstand (s) / Event interval (s)<br>Impulsdauer (s) / Pulse duration (s)<br>Impulspause (s) / Pulse gap (s) | 0,5…3600; 0,01…0,5; 0,02…0,5 | F Sekunden, zusätzlich gemeinsames Ereignisbudget | A Sekunden |
| Seed / Seed | UInt32 | F deterministischer Seed | A Seed |
| Lichtintensität (EV) / Light intensity (EV) | 0…4 | F Belichtung der Komposition | A EV |
| Schattenanhebung / Shadow lift | 0…0,25 | F linearer Schattenbeitrag | B Prozent linearer Beitrag |

## Music Notes (Musiknoten)

| Aktuell DE / EN | Bereich | Bedeutung und Abhängigkeit | Empfehlung und Eingriff |
|---|---|---|---|
| Anzahl der Noten / Note count | 0…128 ganzzahlig | F Anzahl in animierter Platzierung | A Anzahl |
| Größe / Size | 4…512 | S Grundgröße, tatsächliche Größe kann auf 48 % der kurzen Regionsseite begrenzt und perspektivisch skaliert werden | A Basisgröße in Szenen-px |
| Deckkraft / Opacity<br>Liniendeckkraft / Line opacity | 0…1 | F Alpha für Noten bzw. Notenlinien | B Prozent |
| Richtung (°) / Direction (°) | 0…360° | S lineare Bewegungsrichtung ab rechts, gegen Uhrzeigersinn | A Grad |
| Geschwindigkeit / Speed | 0…256 | S Geschwindigkeit entlang Linie/Pfad pro Sekunde | A Szenen-px/s |
| Schwebestärke / Hover strength | 0…25 % | N Auslenkung relativ zur gezeichneten Symbolgröße | A Prozent der Symbolgröße |
| Schwebegeschwindigkeit / Hover frequency<br>Schaukelgeschwindigkeit / Rocking frequency | 0,05…1 | F Schwebe- bzw. Schaukelfrequenz | A Hz |
| Schaukelstärke / Rocking strength | 0…200 % | F Anteil an 0,32 rad Schaukelamplitude | B Winkelamplitude in Grad |
| Sekunden pro Umdrehung / Seconds per revolution | 5…300 | F Sekunden je Umdrehung | A Sekunden |
| Linienabstand / Line spacing<br>Linienstärke / Line thickness | 1…256 bzw. 0,25…64, Stärke < Abstand | S Linienabstand und -stärke, mit Perspektive variabel | A Basismaße in Szenen-px |
| X (Canvas) / X (canvas)<br>Y (Canvas) / Y (canvas) | ±1.000.000 | S Position des freien Symbols | A Szenen-px |
| Pfadposition (%) / Path position (%)<br>Pfadposition (%) / Path position (%) | 0…100 % | N relative Bogenlänge eines Wechselpunkts bzw. Pfadankers | A Prozent des Pfads |
| Größe am Anfang (%) / Size at path start (%)<br>Größe am Ende (%) / Size at path end (%) | 10…200 % | F Größenfaktor an den Enden eines offenen Pfads | A Prozent der Basisgröße |

## CursorTrail (Maustrail)

| Aktuell DE / EN | Bereich | Bedeutung und Abhängigkeit | Empfehlung und Eingriff |
|---|---|---|---|
| Länge / Length | >0…16384 oder unbegrenzt, Regler 1…min(16384, Szenendiagonale) | S räumliche Historie der Mauspositionen; Zeithistorie kann vorher begrenzen | A Szenen-px |
| Lebenszeit / Lifetime | >0…10, Regler 0,1…5 | F Lebensdauer eines Samples | A Sekunden |
| Dicke / Width | >0…256, Regler 1…64 | S volle geometrische Bandbreite | A Szenen-px |
| Kurvenauslenkung / Curve amount | 0…0,5 | F dimensionslose Auslenkung der Kurveninterpolation | A Faktor |

## Slime (Schleim)

| Aktuell DE / EN | Bereich | Bedeutung und Abhängigkeit | Empfehlung und Eingriff |
|---|---|---|---|
| Ansatz X (px) / Anchor X (px)<br>Ansatz Y (px) / Anchor Y (px) | ±1.000.000 | S Ansatzmittelpunkt | A Szenen-px |
| Horizontale Größe (px) / Horizontal Size (px)<br>Vertikale Größe (px) / Vertical Size (px) | 4…128 | S Ansatzausdehnung je Achse; die vertikale Größe beeinflusst auch die Fallbeschleunigung | A Ansatzgröße in Szenen-px |
| Deckkraft (0–1) / Opacity (0–1) | 0…1 | F Alpha einschließlich Reflexionen | A Wertebereich in 3.1.1 sichtbar gemacht |
| Glanz (Faktor) / Gloss (Factor) | 0…2 | F Reflexionsverstärkung | A Faktor |
| Fadenbreite (px) / Filament Width (px) | 9…36 | S voller Durchmesser am ersten Fadenstützpunkt | C in E.2 umgesetzt |
| Tropfengröße (px) / Drop Size (px) | 9,5…38 | S voller Querdurchmesser des Tropfens beim Abriss | C in E.2 umgesetzt |
| Maximale Fadenlänge (px) / Maximum Filament Length (px) | 24…300 | S Länge der segmentierten Mittellinie beim Abriss, bei kurzer Fallstrecke begrenzt | C in E.2 umgesetzt |
| Zyklusgeschwindigkeit (Faktor) / Cycle Speed (Factor) | 0…3 | F Multiplikator der Zyklusuhr, 0 ruht | A Faktor |
| Zyklusversatz / Cycle Offset | [0,1), UI 0…99 % | N Anteil am vollständigen Zyklus | A Prozent |
| Fallrichtung im Bild (°) / Scene fall direction (°) | 0…360° | S Fallrichtung ab oben im Uhrzeigersinn, unabhängig von Ansatzrotation | A Grad |
| Fallstrecke ab Ansatz (px) / Fall Distance from Anchor (px) | 24…9159, UI dynamisch | S Projektion vom Ansatzmittelpunkt zum endgültigen Tropfenmittelpunkt | C seit E.1 Szenen-px, seit E.2 Bezug am Ansatz |
