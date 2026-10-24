"""Ein neues Item direkt in den freien Sockel eines Gebäudes setzen (wie im Spiel eingesetzt).

    python einsetzen.py --insel Cinis --item 54054 --gebaeude 43709882171466
    python einsetzen.py --insel Cinis --item 54054 --naehe "Slot Roman Mountain" [--typ Officium]
    python einsetzen.py … --probe          nur anzeigen, welches Gebäude gewählt würde

--naehe wählt unter den Gebäuden mit freiem Sockel (optional nur --typ) das mit den meisten
freien passenden Objekten im eigenen Radius. Standard: Der Spielstand wird direkt geändert und
vorher zwingend nach sicherung/ kopiert (Abbruch, wenn Anno läuft); --kopie und Cloud-Spielstände
schreiben nach ausgabe/. Unterstützt sind Items mit Wirkung im Radius, keine Unikate; Items aus
DLCs/Vorbesteller-Boni nur, wenn der Spielstand schon Items derselben Herkunft hat.
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from anno117lib import (ITEM_TEMPLATES, OUT_DIR, GameData, Savegame, find_island,  # noqa: E402
                        island_objects, load_settings, matches, nearby, socket_item, utf8_console)


def main():
    utf8_console()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--insel', required=True)
    ap.add_argument('--item', required=True, help='GUID')
    ap.add_argument('--gebaeude', type=int, help='Objekt-ID des Gebäudes (siehe spielstand.py gebaeude --sockel)')
    ap.add_argument('--naehe', help='Gebäude automatisch wählen: meiste freie Objekte dieser Art im Radius')
    ap.add_argument('--typ', help='bei --naehe nur Gebäude dieses Typs (Name/GUID)')
    ap.add_argument('--probe', action='store_true', help='nichts schreiben, nur Auswahl zeigen')
    ap.add_argument('--kopie', action='store_true', help='Kopie nach ausgabe/ statt den Spielstand zu ändern')
    ap.add_argument('--save')
    a = ap.parse_args()
    if not (a.gebaeude or a.naehe):
        ap.error('--gebaeude oder --naehe angeben')

    gd = GameData.load()
    guid = int(a.item)
    if gd.assets.get(guid, {}).get('template') not in ITEM_TEMPLATES:
        sys.exit('%s ist kein Item' % a.item)
    radius = gd.catalog()['radius']
    sg = Savegame.load(a.save)
    print('Spielstand:', sg.path)
    try:
        isl = find_island(sg, gd, a.insel)
    except KeyError as e:
        sys.exit('Abgebrochen: %s' % e)
    objs = island_objects(isl['session'], isl['area'], gd)
    cands = [o for o in objs if o['sockets'] is not None and 0 in o['sockets']
             and (not a.typ or matches(o, a.typ, gd))]
    if a.gebaeude:
        chosen = next((o for o in cands if o['id'] == a.gebaeude), None)
        if chosen is None:
            sys.exit('Gebäude %d hat keinen freien Sockel (oder gibt es nicht)' % a.gebaeude)
    else:
        scored = []
        for o in cands:
            hits = nearby(objs, o, a.naehe, gd, radius.get(o['guid'], 24), free_only=True)
            scored.append((len(hits), o, hits))
            print('  %-40s ID %d (%.0f, %.0f): %d freie "%s" im Radius %d' % (
                o['label'][:40], o['id'], o['pos'][0], o['pos'][1], len(hits), a.naehe, radius.get(o['guid'], 24)))
        scored.sort(key=lambda x: -x[0])
        if not scored or scored[0][0] == 0:
            sys.exit('Kein Gebäude mit freiem Sockel hat freie "%s" im Radius.' % a.naehe)
        chosen = scored[0][1]
    print('Gewählt: %s ID %d bei (%.0f, %.0f)' % (chosen['label'], chosen['id'], chosen['pos'][0], chosen['pos'][1]))
    if a.probe:
        return
    try:
        item_id, effect_id = socket_item(isl['session'], isl['area'], chosen['id'], guid, gd)
    except ValueError as e:
        sys.exit('Abgebrochen: %s' % e)
    print('%s eingesetzt (Item-ID %d, Effekt-ID %d)' % (gd.label(guid), item_id, effect_id))
    if sg.is_cloud and not a.kopie:
        print('Cloud-Spielstand wird nicht direkt geändert – schreibe eine Kopie.')
    if a.kopie or sg.is_cloud:
        name = re.sub(r'[^\w.-]+', '_', '%s_%s' % (isl['name'], (gd.assets[guid]['de'] or str(guid)).strip()))
        print('Kopie geschrieben:', sg.write(os.path.join(OUT_DIR, name + '.a8s')))
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
