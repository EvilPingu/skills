"""Anno-117-Spielstände untersuchen (lesend) und Sicherungen verwalten.

    python spielstand.py ordner                               Spielstand-Ordner und neueste Spielstände
    python spielstand.py ordner --lokal "PFAD"                lokalen Spielstand-Ordner des Spiels merken
    python spielstand.py ordner --weitere "PFAD" ["PFAD"…]    weitere Ordner mit Spielständen merken
    python spielstand.py info                                 Name, Sessions, Dateigrößen
    python spielstand.py inseln                               eigene Inseln (Name, Session, Area)
    python spielstand.py gebaeude --insel Cinis [--typ Officium] [--sockel]
                                                              Gebäude mit ID, Position und Sockeln
    python spielstand.py naehe --insel Cinis --typ Officium --zu "Slot Roman Mountain" [--radius 24]
                                                              was im Umkreis jedes Gebäudes liegt
    python spielstand.py baum "Latium:ItemSessionManager" [--tiefe 2] [--max 20]
    python spielstand.py baum "MetaGameManager/MetaReligionManager"
    python spielstand.py suche-wert 54054 [--bytes 4]         Fundstellen eines Zahlenwerts
    python spielstand.py suche-text Aeterna                   Fundstellen eines Textes (UTF-16)
    python spielstand.py vergleiche ALT NEU                   Unterschiede zweier Spielstände
    python spielstand.py sicherungen                          Sicherungen in sicherung/ (neueste zuerst)
    python spielstand.py wiederherstellen SICHERUNG [--save ZIEL]   Sicherung zurückspielen
                                                              (aktueller Stand wird vorher gesichert)

Pfade: "A/B[2]/C" ab der Wurzel von data.a7s; mit "Latium:" oder "Albion:" davor ab
GameSessionManager der Session. --save wählt den Spielstand (Standard: neuester lesbarer
Spielstand aus den bekannten Ordnern).
"""
import argparse
import os
import struct
import sys
import time
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from anno117lib import (DB, GameData, Savegame, backups, diff, find_island, find_saves,  # noqa: E402
                        island_objects, matches, nearby, newest_save, occupied, print_tree, restore, save_dirs,
                        save_settings, utf8_console, walk)


def resolve(sg, path):
    if ':' in path:
        sess, rest = path.split(':', 1)
        s = sg.session(sess)
        return s.db, s.db.path(rest, s.gsm)
    return sg.db, sg.db.path(path)


def short(path):
    return '/'.join(p for p in path if p != 'item' and not p.startswith('tag'))


def find(sg, pred, label):
    hits, examples = Counter(), defaultdict(list)
    roots = [((), sg.db, sg.db.root, False)] + [((s.name + ':',), s.db, s.gsm, True) for s in sg.sessions()]
    for prefix, db, root, nested in roots:
        for d, path, n in walk(db, root, prefix, nested):
            if pred(n.val):
                key = short(path).replace(':/', ':')
                hits[key] += 1
                if len(examples[key]) < 2:
                    examples[key].append(label(n.val))
    for k, c in hits.most_common(60):
        print('%5d  %s  %s' % (c, k, ', '.join(examples[k])))
    if not hits:
        print('nichts gefunden')


def main():
    utf8_console()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('befehl', choices=['ordner', 'info', 'inseln', 'gebaeude', 'naehe', 'baum', 'suche-wert',
                                       'suche-text', 'vergleiche', 'sicherungen', 'wiederherstellen'])
    ap.add_argument('--insel', help='Insel (Name oder Area-ID) für gebaeude/naehe')
    ap.add_argument('--typ', help='nur Objekte, deren Name/GUID passt (gebaeude); Quelle bei naehe')
    ap.add_argument('--zu', help='Ziel-Objekte bei naehe, z. B. "Slot Roman Mountain" oder 2920')
    ap.add_argument('--radius', type=float, help='Umkreis bei naehe (Standard: Radius des Gebäudes)')
    ap.add_argument('--sockel', action='store_true', help='nur Gebäude mit Sockeln (gebaeude/naehe)')
    ap.add_argument('--lokal', help='lokaler Spielstand-Ordner des Spiels (bei ordner)')
    ap.add_argument('--weitere', nargs='+', help='weitere Ordner mit Spielständen (bei ordner)')
    ap.add_argument('args', nargs='*')
    ap.add_argument('--save', help='Spielstand (.save/.a8s)')
    ap.add_argument('--tiefe', type=int, default=8)
    ap.add_argument('--max', type=int, default=40, help='höchstens so viele Kindknoten je Ebene')
    ap.add_argument('--bytes', type=int, choices=[1, 2, 4, 8], help='nur Werte dieser Länge (suche-wert)')
    ap.add_argument('--namen', action='store_true', help='Item-Namen zu GUIDs anzeigen (lädt Spieldaten)')
    a = ap.parse_args()

    if a.befehl == 'ordner':
        if a.lokal or a.weitere:
            save_settings(lokaler_ordner=a.lokal, weitere_ordner=a.weitere)
        for d, kind, ok in save_dirs():
            print('  %-24s %s%s' % (kind, d, '' if ok else '   (kein Zugriff)'))
        saves = find_saves()
        print('Neueste lesbare Spielstände:' if saves else 'Kein lesbarer Spielstand gefunden.')
        for f in saves[:5]:
            print('  ', f)
        return

    if a.befehl == 'sicherungen':
        for f in backups(a.save):
            print('  %s  %10d Byte  %s' % (time.strftime('%d.%m.%Y %H:%M', time.localtime(os.path.getmtime(f))),
                                           os.path.getsize(f), f))
        return

    if a.befehl == 'wiederherstellen':
        if len(a.args) != 1:
            ap.error('wiederherstellen SICHERUNG [--save ZIEL]')
        target = a.save or newest_save()
        print('Aktueller Stand gesichert:', restore(a.args[0], target))
        print('Zurückgespielt nach:', target)
        return

    if a.befehl == 'vergleiche':
        if len(a.args) != 2:
            ap.error('vergleiche ALT NEU')
        x, y = Savegame.load(a.args[0]), Savegame.load(a.args[1])
        for name in x.index:
            if name not in y.index:
                print(name, 'fehlt in NEU')
                continue
            ra, rb = x.raw(name), y.raw(name)
            if ra == rb:
                print(name, 'gleich')
                continue
            da, db = DB(ra), DB(rb)
            lines = diff(da, da.root, db, db.root)
            print(name, '%d Unterschiede' % len(lines))
            for line in lines[:200]:
                print('   ', line)
        return

    sg = Savegame.load(a.save)
    print('Spielstand:', sg.path, file=sys.stderr)
    if a.befehl == 'info':
        for k, v in sg.meta().items():
            print('%s: %s' % (k, v))
        for e, data in sg.files:
            print('  %-15s %10d Byte gepackt' % (e[:520].decode('utf-16le').split(chr(0))[0], len(data)))
        for s in sg.sessions():
            print('  Session %s (GUID %d): %d Byte' % (s.name, s.guid, len(s.bd.val)))
    elif a.befehl == 'inseln':
        texts = {}
        try:
            texts = GameData.load().texts
        except OSError:
            pass
        for i in sg.islands(texts=texts):
            print('  %-20s %-8s Area %d' % (i['name'], i['session'].name, i['area']))
    elif a.befehl in ('gebaeude', 'naehe'):
        if not a.insel or (a.befehl == 'naehe' and not (a.typ and a.zu)):
            ap.error('gebaeude --insel X [--typ T] [--sockel] | naehe --insel X --typ QUELLE --zu ZIEL [--radius R]')
        gd = GameData.load()
        names = gd.item_names()
        radius = gd.catalog()['radius']
        isl = find_island(sg, gd, a.insel)
        objs = island_objects(isl['session'], isl['area'], gd)
        sel = [o for o in objs if (not a.typ or matches(o, a.typ, gd)) and (not a.sockel or o['sockets'] is not None)]
        print('%s (Area %d, %s): %d von %d Objekten' % (isl['name'], isl['area'], isl['session'].name, len(sel), len(objs)))
        for o in sorted(sel, key=lambda o: o['label']):
            pos = '(%.0f, %.0f)' % o['pos'] if o['pos'] else '–'
            sock = ''
            if o['sockets'] is not None:
                sock = '  Sockel: ' + ', '.join(names.get(g, str(g)) if g else 'frei' for g in o['sockets'])
            print('  %-45s ID %d  %s%s' % (o['label'][:45], o['id'], pos, sock))
            if a.befehl == 'naehe':
                r = a.radius or radius.get(o['guid'], 24)
                hits = nearby(objs, o, a.zu, gd, r)
                free = sum(1 for _, h in hits if not occupied(objs, h, gd))
                print('      %d × "%s" im Umkreis %g, davon %d frei: %s' % (len(hits), a.zu, r, free, ', '.join(
                    '(%.0f, %.0f) in %.0f%s' % (h['pos'][0], h['pos'][1], d, ' belegt' if occupied(objs, h, gd) else '')
                    for d, h in hits[:10])))
    elif a.befehl == 'baum':
        items = GameData.load().item_names() if a.namen else None
        for p in a.args:
            db, n = resolve(sg, p)
            print('<%s>' % p)
            if n.kids is None:
                print_tree(db, N_wrap(n), a.tiefe, a.max, items, 1)
            else:
                print_tree(db, n, a.tiefe, a.max, items, 1)
    elif a.befehl == 'suche-wert':
        v = int(a.args[0])
        lens = [a.bytes] if a.bytes else [4, 8]
        targets = set()
        for L in lens:
            try:
                targets.add(v.to_bytes(L, 'little', signed=True))
            except OverflowError:
                pass
        find(sg, lambda b: b in targets, lambda b: str(int.from_bytes(b, 'little', signed=True)))
    elif a.befehl == 'suche-text':
        t = a.args[0].encode('utf-16le')
        find(sg, lambda b: t in b, lambda b: repr(b.decode('utf-16le', 'replace')[:40]))


def N_wrap(n):
    from anno117lib import N
    return N(0, [n])


if __name__ == '__main__':
    main()
