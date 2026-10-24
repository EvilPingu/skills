---
name: anno117-spielstand
description: Anno-117-Spielstände lesen und bearbeiten – Items/Spezialisten auf Inseln einlegen, Spielstand auswerten, Anno 117 Calculator aus dem Spielstand konfigurieren, Spieldaten (Items, Vorkommen, Gebäude) nachschlagen. Verwenden, wenn der Nutzer etwas an seinem Anno-117-Spielstand ändern, daraus auslesen oder ein Item "einimpfen" möchte.
---

# Anno-117-Spielstände bearbeiten

`<Skill>` steht im Folgenden für den Ordner dieser Datei. Aufruf der Skripte: `python <Skill>/scripts/<skript>.py …`.

## Schnell arbeiten (zuerst lesen)

1. **Dienst starten**, einmal pro Sitzung: `python <Skill>/scripts/dienst.py` mit `run_in_background`. Er hält Spieldaten und Spielstände im Speicher. Die erste Abfrage lädt den Spielstand (~6 s je Session), danach braucht eine Abfrage ~0,02 s. Ändert sich die Datei oder wurde etwas geändert, lädt er beim nächsten Aufruf neu.
2. **Alles über `frage.py` schicken**: `python <Skill>/scripts/frage.py <skript>.py <argumente>` oder `frage.py -c "<python>"` (Bibliothek ist importiert). Läuft kein Dienst, führt `frage.py` das Skript direkt aus.
3. **Fertige Befehle statt eigener Skripte**: `spieldaten.py kette/items/suche`, `spielstand.py gebaeude/naehe/suche-wert/baum`, `einlegen.py`, `einsetzen.py`. Für eine Frage, die kein Befehl abdeckt, kurzen Code über `frage.py -c` schicken. Kein neues Skript schreiben, das den Spielstand selbst lädt.
4. In Schleifen über Spieldaten `gd.catalog()` (Fabriken, Produzenten, Items, Pools, Radien) nutzen, nicht `gd.xml()` je Asset.
5. Wird eine Abfrage zum zweiten Mal gebraucht, als Befehl in `spielstand.py`/`spieldaten.py` aufnehmen und hier eintragen.
6. Spielstand-Analysen nur auf dem aktuellen Stand: Sobald Anno läuft, verschwindet das Cloud-„Session Backup“; maßgeblich ist das lokale `Session Backup.a8s`, das beim Beenden neu geschrieben wird. Vor Aussagen über die Insel mit `spielstand.py ordner` prüfen, welcher Stand vorliegt.

| Pfad | Inhalt |
|---|---|
| `scripts/` | Skripte und Bibliothek – **erst diese nutzen, nicht neu schreiben** |
| `sicherung/` | Sicherungen der Spielstände vor jeder Änderung (Name_JJJJMMTT-hhmmss), nicht im Git |
| `ausgabe/` | Calculator-Importdatei, Spielstand-Kopien (`.a8s`, nur auf Wunsch) |
| `einstellungen.json` | Spielstand-Ordner des Nutzers (nicht im Git, entsteht über `spielstand.py ordner`) |
| `inselnamen.json` | Inselnamen Area-ID → Name (nicht im Git, entsteht beim ersten Lauf, siehe unten) |

| Skript | Zweck | Laufzeit |
|---|---|---|
| `dienst.py` / `frage.py <skript> …` / `frage.py -c CODE` | Hintergrund-Dienst und Client (siehe oben) | ~0,02 s je Abfrage |
| `spielstand.py ordner [--lokal PFAD] [--weitere PFAD…]` | Spielstand-Ordner anzeigen/hinterlegen, neueste Spielstände | < 1 s |
| `spielstand.py gebaeude --insel X [--typ T] [--sockel]` | Gebäude mit Objekt-ID, Position und Sockelbelegung | – |
| `spielstand.py naehe --insel X --typ QUELLE --zu ZIEL [--radius R]` | was im Radius jedes Gebäudes liegt, Bauplätze mit frei/belegt | – |
| `einsetzen.py --insel X --item GUID (--gebaeude ID \| --naehe ZIEL [--typ T]) [--probe]` | neues Item direkt in einen freien Sockel setzen, mit Effekt; `--naehe` wählt das Gebäude mit den meisten freien Zielen im Radius | – |
| `spieldaten.py kette WARE [--region Roman]` / `items GEBÄUDE` | Produktionskette mit Bauplatz, Vorkommen und passenden Spezialisten / Items, die auf ein Gebäude wirken | < 0,2 s |
| `spielstand.py info/inseln/baum/suche-wert/suche-text/vergleiche` | Spielstand lesend untersuchen, Fundstellen suchen, zwei Stände vergleichen | 2–15 s |
| `spielstand.py sicherungen` / `wiederherstellen SICHERUNG [--save ZIEL]` | Sicherungen auflisten / zurückspielen (aktueller Stand wird vorher gesichert) | < 1 s |
| `spieldaten.py suche/zeige/refs/text/cache` | assets.xml + deutsche Texte durchsuchen (Cache in `%LOCALAPPDATA%\anno117-spielstand`) | < 1 s, Cache-Aufbau einmalig ~20 s |
| `einlegen.py --insel X --item Y [--anzahl N] [--kopie]` | Items ins Insellager legen – direkt im Spielstand (mit Sicherung) oder mit `--kopie` als `.a8s` nach `ausgabe/` | ~15 s |
| `calculator.py [SPIELSTAND] [--merge Export.json]` | Anno 117 Calculator aus dem Spielstand konfigurieren; Importdatei nach `ausgabe/`, Bericht auf stdout; lädt `params.js` des Rechners aus dem Netz (`--params DATEI` für eine lokale) | ~15 s |
| `anno117lib.py` | Bibliothek: `Savegame`, `Session`, `DB`/`N` (verlustfreie FileDB), `GameData`, `walk`, `diff`, `print_tree`, `insert_items`, `socket_item`, `check_origin` | – |

Alle Skripte haben `--help`; Spielstand mit `--save PFAD` (bei `calculator.py` als Argument), sonst der neueste lesbare Spielstand aus den bekannten Ordnern.

Format-Details und Fundstellen im Spielstand: [format.md](format.md).

## Erster Schritt: Wo liegen die Spielstände?

1. `spielstand.py ordner` ausführen. Cloud-Spielstände von Ubisoft Connect werden über die Registry gefunden (`<Launcher>\savegames\<Konto>\921\`; die große `.save`-Datei ist der Spielstand, die kleine ~240 KB das Profil). Die Cloud-Kopie ist nur vorübergehend da (verschwindet beim Spielstart).
2. Die eigentlichen Spielstände liegen lokal unter `%USERPROFILE%\Documents\Anno 117 - Pax Romana\accounts\<Konto>\<Profil>\` (`Session Backup.a8s`, `Autosave NNN.a8s`; `accountdata.a8s` ist kein Spielstand). Ist der Ordner nicht hinterlegt, **den Nutzer fragen**, ob er dort bzw. wo er liegt, und mit `spielstand.py ordner --lokal "PFAD"` (bzw. `--weitere`) speichern. Der Unterordner kann lesbar sein, auch wenn `Documents` selbst gesperrt ist.
3. Zeigt die Ausgabe „(kein Zugriff)“, nicht versuchen, das zu umgehen und keine Rechteänderung vorschlagen. Dann mit dem Spielstand aus dem Cloud-Ordner arbeiten: lesen ja, Änderungen nur als Kopie (siehe Grundregeln).

Ohne `--save` nehmen die Skripte den neuesten lokalen Spielstand, den Cloud-Spielstand nur, wenn es keinen lokalen gibt.

## Grundregeln

- **Den Spielstand direkt ändern – kein neuer Spielstand nötig.** Aber **vorher zwingend sichern**: `Savegame.save_in_place()` (und damit `einlegen.py`) kopiert den Spielstand nach `sicherung/`, prüft die Kopie bytegenau und schreibt erst dann. Nie an der Sicherung vorbei schreiben (kein `open(..., 'wb')` auf den Spielstand). Eine Kopie (`--kopie`) nur, wenn der Nutzer sie ausdrücklich will.
- **Cloud-Spielstände (`.save` im Launcher-Ordner) werden nie direkt geändert** – die Synchronisierung gehört Ubisoft Connect. `save_in_place()` und `wiederherstellen` verweigern das; `einlegen.py`/`einsetzen.py` schreiben dann automatisch eine Kopie nach `ausgabe/`, die der Nutzer in den lokalen Ordner legt.
- **Nur gekaufte Inhalte**: Items mit `Origin` (DLC01, DLC02, PreOrder …) nur einfügen, wenn der Spielstand schon Items derselben Herkunft enthält (`check_origin()`, steckt in `insert_items()` und `socket_item()` selbst); Test-Items und Unikate nie. Nicht umgehen, auch nicht auf Wunsch – auch nicht mit eigenem Code, der Knoten an diesen Funktionen vorbei anlegt. Die Prüfung schließt aus vorhandenen Items auf den DLC-Besitz; ob DLC-Items auch ohne DLC in einen Spielstand gelangen können (z. B. über Händler), ist nicht geprüft.
- **Nur Einzelspieler**: keine Spielstände aus Koop-/Mehrspielerpartien bearbeiten.
- **Anno muss beendet sein.** `save_in_place()` bricht ab, wenn `Anno117.exe` läuft oder sich die Datei seit dem Laden geändert hat (das Spiel würde sonst die Änderung überschreiben).
- Nach jeder Änderung: `spielstand.py vergleiche <Sicherung> <Spielstand>` – außer den beabsichtigten Knoten darf sich nichts ändern. Dem Nutzer den Pfad der Sicherung nennen; Rückweg ist `spielstand.py wiederherstellen <Sicherung>`.

## Inselnamen

`inselnamen.json` wird beim ersten Lauf mit den Standardnamen des Spiels erzeugt; neue Inseln werden nachgetragen, vorhandene Einträge bleiben. Vom Spieler vergebene Namen lassen sich nicht automatisch zuordnen: Der Spielstand speichert sie unter `MetaGameManager/MetaUserGeneratedTextManager/UserGeneratedTexts`, aber nichts verweist auf deren ID. Nennt der Nutzer seine Insel anders als der Standardname, nach seinen Namen fragen und in der Datei ersetzen (`spielstand.py inseln` zeigt Standardname, Session und Area).

## Häufige Aufgaben

- **Item einlegen**: `spieldaten.py suche <Text> --template Item` → GUID, dann `einlegen.py --insel <Name|Area> --item <GUID|Name>`. Unikate und nicht gekaufte DLC-Items werden verweigert, gleiche Items kommen auf den vorhandenen Stapel. Danach vergleichen und dem Nutzer Sicherung + Rückweg nennen. (Im Spiel getestet als Kopie `.a8s` im lokalen Ordner; die direkte Änderung erzeugt dieselben Bytes.)
- **Spieldaten-Frage** („gibt es ein Item, das …“): `spieldaten.py suche`, `zeige GUID`, `refs GUID` (wer verwendet diese GUID). Zusammenhänge:
  - Spezialist mit Vorkommen: Item → `Effect/Buffs` → BuildingBuff mit `FactoryUpgrade/AddedFertility`; `EffectScope` (bisher alle `Radius`), `Targets` = Gebäude/AssetPool.
  - Minen: `Factory7/NeededFertility` + `Slot/SlotType` (z. B. Mountain) – ein Vorkommen-Item ersetzt nie den Bauplatz.
  - DLC-Herkunft: `Item/Origin` (DLC01 = Prophecies of Ash, DLC-Asset 67902). Ob der Nutzer ein DLC hat, zeigen Items derselben Herkunft im Spielstand (`check_origin()`).
- **Item direkt einsetzen**: `einsetzen.py --insel X --item GUID --naehe "Slot Roman Mountain" --typ Officium --probe` zeigt das gewählte Gebäude, ohne `--probe` wird geschrieben (mit Sicherung). Unikate und nicht gekaufte DLC-Items werden verweigert. Angelegt werden Sockel-Eintrag, Effekt (`Id = Area·2^46 + NextEffectIndex`, Quelle/Position/Radius des Gebäudes) und ItemMap-Eintrag mit `EffectID`. Im Spiel getestet (Gutachterin im Officium, direkt im lokalen `Session Backup.a8s`).
- **Bauplätze**: Bergplätze heißen „Slot Roman Mountain“ (2882) und „Fixed Slot Roman Mountain“ (37926, abgeleitet); die Suche nach „Slot Roman Mountain“ findet beide. Ein Slot-Objekt bleibt unter einem Gebäude bestehen; `naehe` markiert solche als „belegt“.
- **Etwas im Spielstand finden**: bekannten Wert suchen (`spielstand.py suche-wert <GUID> --bytes 4`), Struktur ansehen (`spielstand.py baum "Latium:<Pfad>" --namen --tiefe 3`).
- **Calculator**: `calculator.py [SPIELSTAND] [--merge Export.json]`; der Nutzer importiert `ausgabe/Anno117CalculatorConfig.json` im Rechner.

## Neue Bearbeitungen entwickeln

Kleines Skript im Scratchpad, das die Bibliothek importiert:

```python
import os, sys
sys.path.insert(0, r'<Skill>\scripts')
from anno117lib import Savegame, GameData, OUT_DIR

sg = Savegame.load(pfad)                    # ohne Pfad: neuester lesbarer Spielstand
s = sg.session('Latium'); db = s.db
node = db.path('AreaManagers/AreaManager_<Area>/AreaItemManager', s.gsm)
# ändern: db.set(knoten, 'Name', wert); Vorlagen mit .clone() kopieren
s.dirty = True                              # sonst wird die Session nicht zurückgeschrieben
print('Sicherung:', sg.save_in_place())    # sichert zwingend vorher; Kopie stattdessen: sg.write(os.path.join(OUT_DIR, 'X.a8s'))
```

1. Fundstelle per `suche-wert` finden, Struktur mit `baum` ansehen.
2. Vorhandene Einträge **klonen** statt Knoten neu zu bauen (IDs und Wertlängen stimmen dann).
3. Zähler/IDs fortschreiben, alle Querverweise mitpflegen (Beispiel: `insert_items`).
4. Mit `spielstand.py vergleiche` prüfen.
5. Bewährte neue Bearbeitungen als Funktion in `anno117lib.py` plus Skript in `scripts/` aufnehmen und hier eintragen.

## Fallstricke

- Das Write-Tool macht aus `'\0'` im Python-Code ein echtes NUL-Byte → `bytes(1)`, `chr(0)` oder `b'\x00'` verwenden; Dateien danach auf NUL und CRLF prüfen.
- Windows-Konsole ist cp1252: `utf8_console()` aus der Bibliothek aufrufen.
- Bash-Heredocs mit Backslashes/Anführungszeichen sind fehleranfällig – längere Skripte mit Write in den Scratchpad legen.
- Zlib-Stufe 9 erzeugt exakt die Bytes des Spiels; nicht ändern.
- Im Spiel gibt es den Begriff „SavegameChecksum“; bisher wurden geänderte Spielstände problemlos geladen. Lehnt Anno eine Kopie ab, den genauen Fehlertext erfragen.
