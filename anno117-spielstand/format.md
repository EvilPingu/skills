# Anno-117-Spielstandformat

Alles hier wurde an echten Spielständen geprüft; Lesen und Zurückschreiben ist bytegenau (Ausnahme: geänderte Knoten).

## Dateihülle

- **Cloud-Spielstand (`.save`)**: 40 Byte Vorspann (`u64 0x24` + 32 Hex-Zeichen, wechselt je Speichervorgang, ist *kein* MD5 des Inhalts), danach RDA-Archiv.
- **Lokaler Spielstand (`.a8s`)**: RDA-Archiv ohne Vorspann. Kopien in diesem Format wurden im Spiel erfolgreich geladen.

## RDA V2.2

- Kopf: `"Resource File V2.2"` (18 Byte) + 766 Byte + `u64` Offset des ersten Blockkopfs = 792 Byte.
- Je Datei ein Block, Flags 0 (unkomprimiert, unverschlüsselt): Inhalt, Verzeichnis (560 Byte), Blockkopf (32 Byte).
- Verzeichniseintrag: Name UTF-16LE (520 Byte), `u64` Offset, `u64` Größe, `u64` Größe, `u64` Zeitstempel, `u64`.
- Blockkopf: `u32 flags, u32 nfiles, u64 dirsize, u64 dirsize, u64 next` – `next` zeigt auf den **nächsten Blockkopf**, beim letzten auf das Dateiende.
- Dateien: `meta.a7s` (u. a. `CorporationSaveGameName`), `header.a7s`, `gamesetup.a7s`, `data.a7s`.

## Kompression der .a7s-Dateien

`zlib(Daten, Stufe 9)` + leerer zlib-Strom `78 da 03 00 00 00 00 01` + `u32` unkomprimierte Länge. Mit Python `zlib.compress(data, 9)` entsteht exakt dasselbe.

## FileDB

- Knoten: `u32 size, i32 id`. `id == 0` → Ende des Tags; `1 ≤ id < 0x8000` → Tag (`1` = „item“); `id ≥ 0x8000` → Attribut, Wert `size` Byte, auf 8 aufgefüllt (Nullen).
- Der Datenstrom endet mit dem Ende-Knoten der Wurzel (8 Nullbytes).
- Danach: Tag-Wörterbuch, Attribut-Wörterbuch (`u32 n`, `n × u16` IDs, `n` nullterminierte Namen, Füllbytes), dann `u32` Zähler, dann `u32 tagsoff, u32 attroff` und Magic `08 00 00 00 FD FF FF FF`.
- Der Zähler ist bei kleinen Dateien Knotenzahl + 1, bei den Session-Blobs deutlich kleiner als die Knotenzahl → offenbar nur Hinweis; beim Einfügen um die Zahl neuer Knoten erhöhen.
- Wörterbuch-Bytes unverändert übernehmen; neue Namen möglichst vermeiden (Neuaufbau der Wörterbücher ist nicht bytegenau verifiziert).
- Maps: abwechselnd Schlüssel-Attribut (oft `attr32768`) und Wert-Tag.
- Verschachtelte FileDBs: Attributwerte, die auf das Magic enden – v. a. `MetaGameManager/GameSessions/<Session>/SessionData/BinaryData`.

## Wichtige Pfade in data.a7s

Session-Blob: `MetaGameManager/GameSessions` (Map) → `SessionDesc/SessionGUID` (3245 Latium, 6627 Albion), `SessionData/BinaryData{FileDB}/GameSessionManager`:

| Pfad (unter GameSessionManager) | Inhalt |
|---|---|
| `AreaInfo` (Map Area → Info) | `OwnerProfile` (Spieler = 41), `CityNameGuid` (LineId des Inselnamens) |
| `AreaManagers/AreaManager_<Area>/AreaObjectManager/GameObject/objects` | Gebäude: `guid`, `ID`, `Position`, `Residence7`, `Pausable`, `ItemContainer/SocketContainer/SocketItems` (eingesetzte Items) |
| `AreaManagers/AreaManager_<Area>/AreaItemManager/AreaSlotContainer/SlotList` | **Item-Lager der Insel**: je Eintrag `item/Stack{index=2, value/Stack{item{ID, GUID}…}}`, gleiche Items in einem Stapel |
| `AreaManagers/AreaManager_<Area>/AreaEffectManager/Effects` | aktive Effekte (Guid, Quelle, Reichweite) |
| `ItemSessionManager/ItemIdCounter` | zuletzt vergebene laufende Nummer |
| `ItemSessionManager/ItemMap` | Map ItemID → `{ItemID, GUID, QuestID{}, EffectID, BoostCondition{}}`; im Lager `EffectID = 0` |
| `ItemSessionManager/UniqueItemExists` | GUIDs vorhandener Unikate |
| `SessionTradeRouteManager/RouteMap` | Handelsrouten |
| `VolcanoEruptionManager` | Vulkan der Session (DLC01) |

Item-IDs: `2^58 + laufende Nummer` (je Session eigener Zähler). Neues Item: Zähler + 1, Eintrag in `ItemMap` **und** im Lager der Insel.

Außerhalb der Sessions: `MetaGameManager/MetaGameObjectManager/MetaObjectMap/MetaItemTransfer/GlobalItemContainer` (globales Lager), `MetaReligionManager/ParticipantPatronInfos` (Patrone), `ParticipantUnlockManager` (Freischaltungen).

## Benutzertexte

`MetaGameManager/MetaUserGeneratedTextManager/UserGeneratedTexts`: Map ID → `{NetState, TextOriginator, RawText, SanitizedText, DisplayText}` für alle vom Spieler vergebenen Namen (Inseln, Schiffe …). Die ID taucht sonst nirgends im Spielstand auf; eine Zuordnung zur Insel ist bisher nicht möglich.

## Inseln

Area-IDs sind je Spiel verschieden – immer mit `spielstand.py inseln` holen. Die DLC01-Vulkaninsel ist das Asset `roman_dlc01_island_continental_01` (Standardname „Cinis“).
