"""Items ins Item-Lager einer eigenen Insel legen.

    python einlegen.py --insel Cinis --item 54054 [--anzahl N] [--save SPIELSTAND]
    python einlegen.py --insel Aeterna --item "Silbersucher" --kopie

--item: GUID oder eindeutiger Name. Standard: Der Spielstand wird direkt geändert; vorher
wird er zwingend nach sicherung/ kopiert (Abbruch, wenn Anno läuft). Mit --kopie/--out
und bei Cloud-Spielständen entsteht stattdessen eine Kopie als .a8s in ausgabe/.
Items aus DLCs/Vorbesteller-Boni nur, wenn der Spielstand schon Items derselben Herkunft hat.
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from anno117lib import (ITEM_TEMPLATES, OUT_DIR, GameData, Savegame, in_cloud_folder,  # noqa: E402
                        insert_items, load_settings, utf8_console)


def pick_item(gd, query):
    if query.lstrip('-').isdigit():
        a = gd.assets.get(int(query))
        if not a or a['template'] not in ITEM_TEMPLATES:
            sys.exit('GUID %s ist kein Item.' % query)
        return a
    hits = [a for a in gd.search(query) if a['template'] in ITEM_TEMPLATES]
    exact = [a for a in hits if (a['de'] or '').strip().lower() == query.lower()]
    if len(exact) == 1 or len(hits) == 1:
        return (exact or hits)[0]
    for a in hits:
        print('  %7d  %s' % (a['guid'], gd.label(a['guid'])))
    sys.exit('"%s" ist nicht eindeutig – bitte GUID angeben.' % query if hits else 'Kein Item "%s".' % query)


def main():
    utf8_console()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--insel', required=True, help='Name oder Area-ID')
    ap.add_argument('--item', required=True, help='GUID oder Name')
    ap.add_argument('--anzahl', type=int, default=1)
    ap.add_argument('--save', help='Spielstand (Standard: neuester lesbarer Spielstand)')
    ap.add_argument('--kopie', action='store_true', help='nicht den Spielstand ändern, sondern Kopie nach ausgabe/')
    ap.add_argument('--out', help='Kopie unter diesem Namen schreiben (statt den Spielstand zu ändern)')
    a = ap.parse_args()
    if not 1 <= a.anzahl <= 50:
        ap.error('--anzahl muss zwischen 1 und 50 liegen')
    if a.out and in_cloud_folder(a.out):
        ap.error('--out: in den Cloud-Ordner von Ubisoft Connect wird nicht geschrieben')

    gd = GameData.load()
    item = pick_item(gd, a.item)
    rarity = re.search(r'<Rarity>(\w+)</Rarity>', gd.xml(item['guid']))
    origin = re.search(r'<Origin>(\w+)</Origin>', gd.xml(item['guid']))
    sg = Savegame.load(a.save)
    print('Spielstand:', sg.path)
    # Sessions nacheinander öffnen und bei der ersten passenden aufhören (spart je Session ~4 s)
    q, islands, match = a.insel.lower(), [], []
    for s in sg.sessions():
        found = sg.islands(texts=gd.texts, sessions=[s])
        islands += found
        match = [i for i in found if i['name'].lower() == q or str(i['area']) == q]
        if match:
            break
    if len(match) != 1:
        sys.exit('Insel "%s" nicht gefunden; vorhanden: %s' % (a.insel, ', '.join(i['name'] for i in islands)))
    isl = match[0]
    try:
        ids = insert_items(isl['session'], isl['area'], item['guid'], a.anzahl, gd=gd)
    except ValueError as e:
        sys.exit('Abgebrochen: %s' % e)
    name = (item['de'] or item['name']).strip()
    print('%d × %s (%s%s) ins Lager von %s gelegt' % (
        len(ids), name, rarity.group(1) if rarity else '–', ', ' + origin.group(1) if origin else '', isl['name']))
    if sg.is_cloud and not (a.kopie or a.out):
        print('Cloud-Spielstand wird nicht direkt geändert – schreibe eine Kopie.')
    if a.kopie or a.out or sg.is_cloud:
        out = a.out or os.path.join(OUT_DIR, re.sub(r'[^\w.-]+', '_', '%s_%s' % (isl['name'], name)) + '.a8s')
        print('Kopie geschrieben:', sg.write(out))
        local = load_settings().get('lokaler_ordner')
        print('Zum Laden in den lokalen Spielstand-Ordner kopieren%s.' % (': ' + local if local else ''))
        return
    try:
        saved = sg.save_in_place()
    except RuntimeError as e:
        sys.exit('Nicht gespeichert: %s' % e)
    print('Sicherung:', saved)
    print('Spielstand geändert:', sg.path)


if __name__ == '__main__':
    main()
