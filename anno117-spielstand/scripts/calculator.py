"""Liest einen Anno-117-Spielstand und erzeugt eine Importdatei für den
Anno 117 Calculator (https://anno-mods.github.io/anno-117-calculator/).

Pro eigener Insel werden Session, Wohnhäuser und Produktionsgebäude als
"<GUID>.buildings.constructed" eingetragen, dazu Items, Effekte, Patron,
Bedürfnisse und die eigenen Handelsrouten. Inselnamen kommen aus den
Spieltexten; eigene Namen lassen sich in inselnamen.json (Area-ID -> Name) festlegen.

Aufruf:
    python calculator.py [SPIELSTAND] [--merge EXPORT.json] [--out DATEI.json]

Ohne SPIELSTAND wird der neueste lesbare Spielstand genommen (Ordner: spielstand.py ordner).
Ausgabe (Importdatei) landet standardmäßig in ausgabe/, der Bericht auf stdout.
Mit --merge werden die Inseln in einen vorhandenen Export des Rechners
eingearbeitet, sodass Einstellungen, Items usw. erhalten bleiben.
"""
import argparse
import json
import math
import os
import re
import struct
import sys
import urllib.request
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from anno117lib import (DB, OUT_DIR, PLAYER_PROFILE, GameData,  # noqa: E402
                        Savegame, find_game_dir, load_names, update_names, utf8_console)

PARAMS_URL = 'https://anno-mods.github.io/anno-117-calculator/js/params.js'


# ---------------------------------------------------------------- FileDB

class Node:
    __slots__ = ('name', 'children', 'value')

    def __init__(self, name, value=None):
        self.name = name
        self.children = [] if value is None else None
        self.value = value

    def first(self, name):
        for c in self.children or ():
            if c.name == name:
                return c

    def tags(self):
        return [c for c in self.children or () if c.children is not None]

    def int(self, name, default=None):
        c = self.first(name)
        return default if c is None or c.children is not None else int.from_bytes(c.value, 'little', signed=True)


def parse_filedb(b):
    """FileDB (über DB aus der Bibliothek) als Baum mit Namen; verschachtelte FileDBs werden aufgelöst."""
    def convert(db, n, name):
        if n.kids is None and not n.is_filedb():
            return Node(name, n.val)
        if n.kids is None:
            db = DB(n.val)
            n = db.root
        node = Node(name)
        node.children = [convert(db, c, db.name(c)) for c in n.kids]
        return node

    db = DB(b)
    return convert(db, db.root, '<root>')


def paired(node):
    """FileDB-Maps bestehen aus abwechselnd Schlüssel-Attribut und Wert-Tag."""
    key = None
    for c in node.children:
        if c.children is None:
            key = int.from_bytes(c.value, 'little', signed=True)
        else:
            yield key, c


# ---------------------------------------------------------------- Auswertung


def load_params(path):
    if path:
        with open(path, encoding='utf-8') as f:
            text = f.read()
    else:
        with urllib.request.urlopen(PARAMS_URL, timeout=30) as r:
            text = r.read().decode('utf-8')
    return json.loads(text[text.index('{'):text.rindex('}') + 1])


def german(e):
    return (e.get('locaText') or {}).get('german') or e.get('name') or str(e['guid'])


def extract_islands(root, params, owner, route_areas):
    buildings = {}
    for kind in ('residenceBuildings', 'factories', 'modules'):
        for e in params[kind]:
            buildings[e['guid']] = (kind, german(e))
    session_names = {s['guid']: german(s) for s in params['sessions']}

    islands = []
    for _, sess in paired(root.first('MetaGameManager').first('GameSessions')):
        sguid = sess.first('SessionDesc').int('SessionGUID')
        gsm = sess.first('SessionData').first('BinaryData').first('GameSessionManager')
        infos = dict(paired(gsm.first('AreaInfo')))
        for am in gsm.first('AreaManagers').tags():
            area = int(am.name.split('_')[1])
            info = infos.get(area)
            if info is None or info.int('OwnerProfile') != owner:
                continue
            aom = am.first('AreaObjectManager')
            go = aom and aom.first('GameObject')
            objs = go.first('objects').tags() if go and go.first('objects') else []
            counts, paused = Counter(), Counter()
            supplied = {}    # Wohnhaus-GUID -> {Bedürfnis-Produkt: Anzahl versorgter Häuser}
            positions = {}   # Objekt-ID -> (x, z), für Quellen von Effekten
            placed = []      # (GUID, x, z, am Aquädukt) aller bekannten Gebäude
            for o in objs:
                guid = o.int('guid')
                pos = o.first('Position')
                xz = struct.unpack_from('<fxxxxf', pos.value) if pos is not None and len(pos.value) == 12 else None
                if xz:
                    positions[o.int('ID')] = xz
                if guid not in buildings:
                    continue
                counts[guid] += 1
                pr = o.first('Pausable') and o.first('Pausable').first('PausedReasons')
                if pr is not None and pr.value and b'1' in pr.value:
                    paused[guid] += 1
                r7 = o.first('Residence7')
                cs = r7 and r7.first('ConsumptionStates')
                for product, state in paired(cs) if cs else ():
                    # Schlüssel 0 zählt, in wie vielen Häusern das Bedürfnis überhaupt freigeschaltet ist
                    supplied.setdefault(guid, Counter())[(product, 'aktiv')] += 1
                    sat = state.first('CurrentSaturation')
                    if sat is not None and struct.unpack('<f', sat.value)[0] > 0:
                        supplied[guid][product] += 1
                aq = o.first('AqueductConsumer')
                if xz:
                    placed.append((guid, xz[0], xz[1], aq is not None and aq.int('IsSuppliedByDistributor', 0) > 0))
            if counts or area in route_areas:
                islands.append({
                    'session': sguid,
                    'sessionName': session_names.get(sguid, str(sguid)),
                    'area': area,
                    'cityName': info.int('CityNameGuid'),
                    'history': trade_history(info),
                    'counts': counts,
                    'paused': paused,
                    'placed': placed,
                    'supplied': supplied,
                    'effects': area_effects(am, positions),
                    'residences': sum(c for g, c in counts.items() if buildings[g][0] == 'residenceBuildings'),
                })
    islands.sort(key=lambda i: (i['sessionName'], -i['residences'], -sum(i['counts'].values())))
    return islands, buildings


def name_islands(islands, texts, overrides):
    used, per_session = set(), Counter()
    for isl in islands:
        per_session[isl['sessionName']] += 1
        name = (overrides.get(str(isl['area'])) or texts.get(isl['cityName']) or '').strip()
        if not name:
            name = '%s %d' % (isl['sessionName'], per_session[isl['sessionName']])
        if name in used or name == 'All Islands':
            name = '%s (%s)' % (name, isl['sessionName'])
        used.add(name)
        isl['name'] = name


def area_effects(am, positions):
    """Aktive Effekte einer Insel mit Quellposition und Reichweite (für Items und Nachbarschaftseffekte)."""
    aem = am.first('AreaEffectManager')
    eff = aem and aem.first('Effects')
    result = []
    for e in eff.tags() if eff else ():
        pos = None
        sp, src = e.first('SourcePosition'), e.first('Source')
        if sp is not None and len(sp.value) == 12:
            pos = struct.unpack_from('<fxxxxf', sp.value)
        elif src is not None:
            pos = positions.get(src.int('ObjectID'))
        sf = e.first('ScalingFactor')
        result.append({'guid': e.int('Guid'), 'pos': pos, 'distance': e.int('Distance'),
                       'scaling': struct.unpack('<f', sf.value)[0] if sf is not None else None})
    return result


def player_patrons(root, owner):
    """{Area-ID: [(Devotion, Patron-GUID)]} des Spielers."""
    result = {}
    rm = root.first('MetaGameManager').first('MetaReligionManager')
    ppi = rm and rm.first('ParticipantPatronInfos')
    data = ppi and ppi.first('Data')
    for participant, info in paired(data) if data else ():
        if participant != owner or info.first('Patrons') is None:
            continue
        for patron, p in paired(info.first('Patrons')):
            dpa = p.first('DevotionPerArea')
            values = [int.from_bytes(c.value, 'little', signed=True) for c in dpa.children] if dpa else []
            for area, devotion in zip(values[::2], values[1::2]):
                result.setdefault(area, []).append((devotion, patron))
    return result


def player_global_effects(root, islands, params, owner):
    """Forschung und Patron-Segen mit Wirkung im ganzen Reich: {Effekt-GUID: Anzahl}."""
    meta = {e['guid'] for e in params['effects'] if e['effectScope'].endswith('Meta')}
    active = Counter()
    for e in root.first('MetaGameManager').first('MetaEffectManager').first('Effects').tags():
        if e.int('TargetParticipant') == owner and e.int('Guid') in meta:
            active[e.int('Guid')] += 1
    for isl in islands:
        for ef in isl['effects']:
            if ef['guid'] in meta and ef['guid'] not in active:
                active[ef['guid']] = 1
    return active


RADIUS_TOLERANCE = 2.0  # Reichweite wird ab Gebäuderand gemessen, Positionen sind Gebäudemitten


def coverage(isl, instances, target):
    """(abgedeckt, gesamt) der Gebäude vom Typ target im Radius einer der Effektquellen."""
    covered = total = 0
    for guid, x, z, _ in isl['placed']:
        if guid != target:
            continue
        total += 1
        if any(ef['pos'] and ef['distance'] and
               math.hypot(x - ef['pos'][0], z - ef['pos'][1]) <= ef['distance'] + RADIUS_TOLERANCE
               for ef in instances):
            covered += 1
    return covered, total


def island_settings(isl, params, patrons, incoming=frozenset()):
    """Speicherwerte des Rechners für Items, Effekte, Schutzpatron und Aquädukt einer Insel."""
    settings, report = {}, []
    items = {it['guid']: it for it in params['items']}
    effects = {e['guid']: e for e in params['effects']}
    residences = {r['guid'] for r in params['residenceBuildings']}
    names = {e['guid']: german(e) for kind in ('factories', 'residenceBuildings', 'items', 'effects', 'patrons')
             for e in params[kind]}
    patron_effects = {le['effect']: p['guid'] for p in params['patrons'] for le in p.get('localEffects') or ()}

    by_guid = {}
    for ef in isl['effects']:
        by_guid.setdefault(ef['guid'], []).append(ef)

    for guid, inst in sorted(by_guid.items()):
        if guid in items:
            # Items wirken im Radius um ihr Gebäude; der Rechner kennt nur "ganzer Betriebstyp an/aus"
            for target in dict.fromkeys(items[guid]['targets']):
                cov, total = coverage(isl, inst, target)
                if total:
                    on = cov * 2 >= total
                    settings['%d[%d].scaling' % (target, guid)] = '1' if on else '0'
                    report.append('Item %s → %s: %d/%d im Radius%s' % (
                        names[guid], names.get(target, target), cov, total, '' if on else ' (nicht gesetzt)'))
            continue
        e = effects.get(guid)
        if e is None or e['effectScope'].endswith('Meta'):
            continue
        if guid in patron_effects:
            continue  # ergibt sich aus Schutzpatron und Devotion
        if e.get('source') == 'building':
            house_cov = house_total = 0
            for target in dict.fromkeys(e.get('targets') or ()):
                cov, total = coverage(isl, inst, target)
                if not total:
                    continue
                if target in residences:
                    house_cov, house_total = house_cov + cov, house_total + total
                else:
                    on = cov * 2 >= total
                    settings['%d[%d].scaling' % (target, guid)] = '1' if on else '0'
                    report.append('%s → %s: %d/%d in Reichweite' % (names[guid], names.get(target, target), cov, total))
            if house_total:
                share = round(house_cov / house_total, 2)
                settings['island.effect.%d.scaling' % guid] = str(share)
                street = ' (Luftlinie statt Straßenweg)' if e['effectScope'] == 'StreetDistance' else ''
                report.append('%s: %d/%d Wohnhäuser in Reichweite%s' % (names[guid], house_cov, house_total, street))
        else:
            scaling = inst[0]['scaling'] or 1
            settings['island.effect.%d.scaling' % guid] = '%g' % scaling
            report.append('%s aktiv' % names[guid])

    if patrons.get(isl['area']):
        devotion, patron = max(patrons[isl['area']])
        settings['selectedPatron'] = str(patron)
        settings['devotion'] = str(devotion)
        report.append('Schutzpatron %s, Devotion %d' % (names.get(patron, patron), devotion))

    # Bedürfnisse: an, wenn mindestens die Hälfte der Häuser im Spiel versorgt ist – oder wenn die Ware
    # auf der Insel hergestellt bzw. per Route angeliefert wird (dann ist es ein Engpass, kein Verzicht)
    needs = {n['guid']: n for n in params['needs']}
    level_names = {lv['guid']: german(lv) for lv in params['populationLevels']}
    produced = {o['product'] for f in params['factories'] if isl['counts'].get(f['guid'])
                for o in f.get('outputs') or ()}
    for r in params['residenceBuildings']:
        houses = isl['counts'].get(r['guid'])
        if not houses:
            continue
        off, partial, short = [], [], []
        for nl in r['needsList']:
            need = needs[nl['need']]
            product = need['needProduct']
            states = isl['supplied'].get(r['guid'], Counter())
            ok = states[product]
            unlocked = states[(product, 'aktiv')] * 2 >= houses  # z. B. Item-Bedürfnisse ohne Item: nicht vorhanden
            arrives = not need.get('isBuilding') and (product in produced or product in incoming)
            on = ok * 2 >= houses or (unlocked and arrives)
            settings['%d[%d].checked' % (r['populationLevel'], nl['need'])] = '1' if on else '0'
            label = german(need) + (' %d/%d' % (ok, houses) if ok else '')
            if not on:
                off.append(label)
            elif ok * 2 < houses:
                short.append('%s %d/%d' % (german(need), ok, houses))
            elif ok < houses:
                partial.append(label)
        level = level_names[r['populationLevel']]
        if off:
            report.append('%s – Bedürfnisse aus: %s' % (level, ', '.join(off)))
        if short:
            report.append('%s – Ware kommt an, reicht aber nicht (bleibt an): %s' % (level, ', '.join(short)))
        if partial:
            report.append('%s – nur teilweise versorgt (bleibt an): %s' % (level, ', '.join(partial)))

    for f in params['factories']:
        if not f.get('aqueductProductivityBuff') or not isl['counts'].get(f['guid']):
            continue
        flags = [aq for g, _, _, aq in isl['placed'] if g == f['guid']]
        share = round(sum(flags) / len(flags), 2) if flags else 0
        settings['%d.aqueductBuff.checked' % f['guid']] = str(share)
        if share:
            report.append('Aquädukt %s: %d/%d angeschlossen' % (names[f['guid']], sum(flags), len(flags)))
    return settings, report


def trade_history(info):
    """{RouteID: [(Zeit in ms, {Ware: Menge})]}; Menge > 0 = auf dieser Insel entladen."""
    pt = info.first('PassiveTrade')
    hist = pt and pt.first('History') and pt.first('History').first('TradeRouteEntries')
    result = {}
    for route_id, entries in paired(hist) if hist else ():
        lst = []
        for e in entries.tags():
            goods = Counter()
            tg = e.first('TradedGoods')
            for g in tg.tags() if tg else ():
                goods[g.int('GoodGuid')] += g.int('GoodAmount', 0)
            lst.append((e.int('ExecutionTime', 0), goods))
        result[route_id] = sorted(lst, key=lambda x: x[0])
    return result


def extract_routes(root, owner):
    routes = []
    rm = root.first('MetaGameManager').first('SessionTradeRouteManager').first('RouteMap')
    for _, r in paired(rm):
        if r.int('Owner') != owner:
            continue
        stations = []
        for s in r.first('Stations').tags():
            goods = {}
            gi = s.first('GoodInfos')
            for g in gi.tags() if gi else ():
                goods[g.int('ProductGUID')] = g.int('IsLoading', 1) == 1
            stations.append((s.int('AreaID'), goods))
        name = r.first('Name')
        routes.append({'id': r.int('ID'), 'stations': stations,
                       'name': name.value.decode('utf-16le') if name is not None else str(r.int('ID'))})
    return routes


def measured_rate(dst, route_id, product):
    """Tatsächlich entladene Tonnen pro Minute laut Lieferhistorie der Zielinsel."""
    entries = [(t, g[product]) for t, g in dst['history'].get(route_id, []) if g[product] > 0]
    if len(entries) < 2 or entries[-1][0] <= entries[0][0]:
        return None
    return sum(a for _, a in entries[1:]) / (entries[-1][0] - entries[0][0]) * 60000


def route_flows(routes, islands, params):
    """Übersetzt Spielrouten in Routen des Rechners (je Ware: Quellinsel -> Zielinsel)."""
    by_area = {i['area']: i for i in islands}
    products = {p['guid']: german(p) for p in params['products']}
    producers = {}
    for f in params['factories']:
        for o in f.get('outputs') or ():
            producers.setdefault(o['product'], set()).add(f['guid'])

    def production(isl, product):
        return sum(n for g, n in isl['counts'].items() if g in producers.get(product, ()))

    flows, skipped = [], []
    for r in routes:
        for product in sorted({p for _, goods in r['stations'] for p in goods}):
            src = [a for a, goods in r['stations'] if goods.get(product) is True]
            dst = [a for a, goods in r['stations'] if goods.get(product) is False]
            for s in src:
                for d in dst:
                    if s == d:
                        continue
                    if product not in products or s not in by_area or d not in by_area:
                        skipped.append((r['name'], products.get(product, product)))
                        continue
                    flows.append({'route': r, 'product': product, 'productName': products[product],
                                  'from': by_area[s], 'to': by_area[d],
                                  'rate': measured_rate(by_area[d], r['id'], product)})

    # Standardlieferant nur, wenn die Zielinsel die Ware nicht selbst herstellt;
    # bei mehreren Quellen die mit der größten Produktion.
    groups = {}
    for fl in flows:
        groups.setdefault((fl['to']['area'], fl['product']), []).append(fl)
    for (_, product), fls in groups.items():
        local = production(fls[0]['to'], product)
        best = max(fls, key=lambda fl: production(fl['from'], product))
        for fl in fls:
            fl['default'] = not local and fl is best
            fl['amount'] = 0 if fl['default'] else round(fl['rate'] or 0, 2)
            fl['local'] = local
    return flows, skipped


def from_savegame(key):
    """Inselwerte, die das Skript aus dem Spielstand setzt (werden bei --merge ersetzt)."""
    return (key.endswith('.buildings.constructed') or key.endswith('].scaling') or key.endswith('.aqueductBuff.checked')
            or key.startswith('island.effect.') or key in ('selectedPatron', 'devotion')
            or re.fullmatch(r'\d+\[\d+\]\.checked', key) is not None)  # Bedürfnis an/aus


def build_config(islands, flows, global_effects, params, base):
    config = dict(base or {})
    names = json.loads(config.get('islandNames', '[]'))
    for isl in islands:
        data = json.loads(config[isl['name']]) if isl['name'] in config else {}
        data = {k: v for k, v in data.items() if not from_savegame(k)}
        data['session'] = isl['session']
        for guid, n in sorted(isl['counts'].items()):
            data['%d.buildings.constructed' % guid] = str(n)
        data.update(isl['settings'])
        config[isl['name']] = json.dumps(data, indent=4)
        if isl['name'] not in names:
            names.append(isl['name'])
    config['islandNames'] = json.dumps(names)

    imported = {i['name'] for i in islands}
    routes = [r for r in json.loads(config.get('tradeRoutes', '[]'))
              if r['from'] not in imported and r['to'] not in imported]
    for fl in flows:
        routes.append({'productGUID': fl['product'], 'from': fl['from']['name'], 'to': fl['to']['name'],
                       'userSetAmount': fl['amount'], 'isDefaultSupplier': fl['default']})
    config['tradeRoutes'] = json.dumps(routes, indent=4)

    ge = json.loads(config.get('globalEffects', '{}'))
    for e in params['effects']:
        if e['effectScope'].endswith('Meta'):
            ge['%d.scaling' % e['guid']] = global_effects.get(e['guid'], 0)
    config['globalEffects'] = json.dumps(ge, indent=4)
    return config


def main():
    utf8_console()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('savegame', nargs='?', help='Spielstand (.a8s/.save); Standard: neuester lesbarer Spielstand')
    ap.add_argument('--params', help='lokale params.js statt der Online-Version')
    ap.add_argument('--game-dir', help='Installationsordner von Anno 117 (für Inselnamen); Standard: aus der Registry')
    ap.add_argument('--merge', help='vorhandener Export des Rechners (Anno117CalculatorConfig.json)')
    ap.add_argument('--owner', type=int, default=PLAYER_PROFILE, help='OwnerProfile des Spielers (Standard 41)')
    ap.add_argument('--out', default=os.path.join(OUT_DIR, 'Anno117CalculatorConfig.json'))
    args = ap.parse_args()

    sg = Savegame.load(args.savegame)
    print('Spielstand:', sg.path)
    print('Name:', sg.meta().get('CorporationSaveGameName', '?').strip("'"))
    root = parse_filedb(sg.raw('data.a7s'))

    params = load_params(args.params)
    routes = extract_routes(root, args.owner)
    route_areas = {a for r in routes for a, _ in r['stations']}
    islands, buildings = extract_islands(root, params, args.owner, route_areas)
    if not islands:
        sys.exit('Keine eigenen Inseln gefunden – stimmt --owner?')

    texts = {}
    game_dir = args.game_dir or find_game_dir()
    try:
        texts = GameData.load(game_dir).texts if game_dir else {}
    except (OSError, KeyError, ValueError) as e:
        print('Inselnamen nicht lesbar (%s) – nutze Platzhalter.' % e)
    update_names({i['area']: texts[i['cityName']].strip() for i in islands if texts.get(i['cityName'])})
    name_islands(islands, texts, load_names())
    flows, skipped = route_flows(routes, islands, params)
    patrons = player_patrons(root, args.owner)
    for isl in islands:
        incoming = {fl["product"] for fl in flows if fl["to"] is isl}
        isl["settings"], isl["report"] = island_settings(isl, params, patrons, incoming)
    global_effects = player_global_effects(root, islands, params, args.owner)

    base = None
    if args.merge:
        with open(args.merge, encoding='utf-8') as f:
            base = json.load(f)
    config = build_config(islands, flows, global_effects, params, base)
    with open(args.out, 'w', encoding='utf-8') as f:
        json.dump(config, f, indent=4, ensure_ascii=False)

    effect_names = {e['guid']: german(e) for e in params['effects']}
    print('\nForschung und Segen (ganzes Reich): %s' % (
        ', '.join(effect_names[g] for g in sorted(global_effects)) or '–'))
    for isl in islands:
        total = sum(isl['counts'].values())
        print('\n%s – %s (Area %d): %d Wohnhäuser, %d Produktionsgebäude' % (
            isl['name'], isl['sessionName'], isl['area'], isl['residences'], total - isl['residences']))
        for guid, n in sorted(isl['counts'].items(), key=lambda x: (buildings[x[0]][0] != 'residenceBuildings', -x[1])):
            p = isl['paused'].get(guid)
            print('  %4d × %s%s' % (n, buildings[guid][1], ' (davon %d pausiert)' % p if p else ''))
        for line in isl['report']:
            print('    · ' + line)

    print('\nHandelsrouten:')
    for r in routes:
        print('\n  %s' % r['name'])
        for fl in (f for f in flows if f['route'] is r):
            rate = '%.2f t/min' % fl['rate'] if fl['rate'] is not None else 'keine Lieferhistorie'
            if fl['default']:
                mode = 'Standardlieferant'
            elif fl['local']:
                mode = 'Zusatzlieferung %.2f t/min (Zielinsel produziert selbst)' % fl['amount']
            else:
                mode = 'Zusatzlieferung %.2f t/min (weitere Quelle)' % fl['amount']
            print('    %-22s %s → %s  [gemessen %s; %s]' % (
                fl['productName'], fl['from']['name'], fl['to']['name'], rate, mode))
    for route, product in skipped:
        print('  übersprungen: %s in %s (unbekannte Ware oder Insel)' % (product, route))
    print('\nGeschrieben:', os.path.abspath(args.out))


if __name__ == '__main__':
    main()
