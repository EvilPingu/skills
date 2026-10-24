"""Anno-117-Spieldaten durchsuchen (assets.xml + deutsche Texte, mit Cache).

    python spieldaten.py suche Gutachter [--template Item]   Assets nach Name suchen
    python spieldaten.py zeige 54054                          XML eines Assets
    python spieldaten.py refs 4053                            Assets, die eine GUID verwenden
    python spieldaten.py kette Mosaike                        Produktionskette einer Ware mit
                                                              Vorkommen, Bauplatz und Spezialisten
    python spieldaten.py items 2920                           Items, die auf ein Gebäude wirken
    python spieldaten.py text -6914700906073587896            Text zu einer LineId
    python spieldaten.py cache                                Cache neu aufbauen
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from anno117lib import GameData, utf8_console  # noqa: E402


def resolve_product(gd, text):
    if text.lstrip('-').isdigit():
        return int(text)
    prods = gd.catalog()['producers']
    hits = [a['guid'] for a in gd.search(text, 'Product') if a['guid'] in prods]
    exact = [g for g in hits if (gd.assets[g]['de'] or '').strip().lower() == text.lower()]
    if len(exact or hits) != 1:
        sys.exit('Ware "%s" nicht eindeutig: %s' % (text, ', '.join(gd.label(g) for g in hits) or 'keine'))
    return (exact or hits)[0]


def chain(gd, product, depth=0, seen=None, region=None):
    cat = gd.catalog()
    seen = seen or set()
    ind = '    ' * depth
    producers = [f for f in cat['producers'].get(product, [])
                 if not region or not cat['factories'][f]['regions'] or region in cat['factories'][f]['regions']]
    if not producers:
        print('%s%s – kein Produktionsgebäude (Rohstoff/Handel)' % (ind, gd.label(product)))
        return
    for f in producers:
        fa = cat['factories'][f]
        extra = []
        if fa['slot']:
            extra.append('Bauplatz %s' % fa['slot'])
        if fa['fuel']:
            extra.append('braucht Brennstoff')
        if fa['cycle']:
            extra.append('%d s je Zyklus' % fa['cycle'])
        print('%s%s ← %s  [%s; %s]' % (ind, gd.label(product), gd.label(f), fa['regions'] or '–', ', '.join(extra)))
        for fert in fa['fertility']:
            its = gd.items_for(fertility=fert)
            print('%s    braucht %s; Spezialisten dafür: %s' % (
                ind, gd.label(fert), ', '.join('%s (%s, %s)' % (gd.label(i), cat['items'][i]['rarity'],
                                                               cat['items'][i]['scope']) for i in its) or 'keine'))
        if f in seen:
            continue
        seen.add(f)
        for p, n in fa['inputs']:
            chain(gd, p, depth + 1, seen, region)


def main():
    utf8_console()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('befehl', choices=['suche', 'zeige', 'refs', 'kette', 'items', 'text', 'cache'])
    ap.add_argument('wert', nargs='?')
    ap.add_argument('--template', help='nur Assets dieses Templates (bei suche)')
    ap.add_argument('--region', help='nur Gebäude dieser Region, z. B. Roman oder Celtic (bei kette)')
    ap.add_argument('--game-dir')
    a = ap.parse_args()
    gd = GameData.load(a.game_dir, refresh=a.befehl == 'cache')
    if a.befehl == 'cache':
        c = gd.catalog()
        print('%d Assets, %d Texte, %d Produktionsgebäude, %d Items im Cache' % (
            len(gd.assets), len(gd.texts), len(c['factories']), len(c['items'])))
    elif a.befehl == 'suche':
        for x in sorted(gd.search(a.wert, a.template), key=lambda x: (x['template'] or '', x['guid'])):
            print('%9d  %-22s %-45s %s' % (x['guid'], x['template'], (x['de'] or '').replace('\n', ' ')[:45], x['name']))
    elif a.befehl == 'zeige':
        print(gd.xml(int(a.wert)))
    elif a.befehl == 'refs':
        for g in gd.references(int(a.wert)):
            print(gd.label(g))
    elif a.befehl == 'kette':
        chain(gd, resolve_product(gd, a.wert), region=a.region)
    elif a.befehl == 'items':
        cat = gd.catalog()
        for g in gd.items_for(building=int(a.wert)):
            it = cat['items'][g]
            print('  %s  %s %s %s%s' % (gd.label(g), it['rarity'], it['scope'], it['origin'] or '',
                                        ' +Vorkommen ' + ', '.join(gd.label(f) for f in it['added_fertility'])
                                        if it['added_fertility'] else ''))
    elif a.befehl == 'text':
        print(gd.text(a.wert))


if __name__ == '__main__':
    main()
