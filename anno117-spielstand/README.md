# anno117-spielstand

Skill zum Lesen und Bearbeiten von Anno-117-Spielständen (nur Einzelspieler):

- Items und Spezialisten ins Insellager legen oder direkt in Gebäudesockel einsetzen
- Spielstand auswerten (Inseln, Gebäude, Bauplätze im Umkreis, Handelsrouten)
- [Anno 117 Calculator](https://anno-mods.github.io/anno-117-calculator/) aus dem Spielstand konfigurieren
- Spieldaten nachschlagen (Produktionsketten, Vorkommen, passende Items)

Anleitung für Claude: [SKILL.md](SKILL.md), Dateiformat: [format.md](format.md).

## Voraussetzungen

- Windows mit installiertem Anno 117 (die Skripte lesen Spieldaten aus der Installation)
- Python 3

## Was die Skripte bewusst nicht tun

- **Keine nicht gekauften Inhalte**: Items aus DLCs, Vorbesteller-Boni o. Ä. werden nur eingefügt, wenn der Spielstand bereits Items derselben Herkunft enthält. Test-Items und Unikate werden nie eingefügt. Die Prüfung sitzt in der Bibliothek, gilt also für alle Skripte.
- **Keine Cloud-Spielstände ändern**: Spielstände im Ordner von Ubisoft Connect werden nur gelesen, und in diesen Ordner wird nichts geschrieben; Änderungen landen dann als Kopie in `ausgabe/`.
- **Kein Mehrspieler**: Nur für Einzelspieler-Spielstände gedacht. Bearbeitete Spielstände in Koop- oder Mehrspielerpartien zu verwenden, verschafft einen Vorteil gegenüber anderen und verstößt gegen die Nutzungsbedingungen.

## Hinweise

- Inoffizielles Fan-Projekt, nicht mit Ubisoft verbunden. „Anno“ und „Ubisoft“ sind Marken von Ubisoft Entertainment bzw. ihren Tochtergesellschaften. Der Ordner enthält keine Spieldateien; Spieldaten und Spielstände werden zur Laufzeit aus der eigenen Installation gelesen.
- Bearbeiten von Spielständen auf eigene Gefahr. Die Skripte sichern den Spielstand vor jeder Änderung nach `sicherung/`.
- Netzzugriff: `calculator.py` lädt die Spieldaten des Rechners (`params.js`) von anno-mods.github.io; mit `--params DATEI` wird eine lokale Kopie verwendet. Sonst greifen die Skripte nicht aufs Netz zu.
- `dienst.py` führt für schnelle Abfragen Skripte und Python-Code aus, die ihm `frage.py` schickt. Er hört nur auf `127.0.0.1` und verlangt ein Zufallstoken, das er in `%LOCALAPPDATA%\anno117-spielstand` ablegt.
