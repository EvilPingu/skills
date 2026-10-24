"""Bibliothek für Anno-117-Spielstände und Spieldaten (eigenständig, nur Standardbibliothek).

Spielstand:
    sg = Savegame.load()                  # neuester lesbarer Spielstand, oder Savegame.load(pfad)
    for s in sg.sessions(): s.name, s.db, s.gsm
    s.dirty = True / sg.dirty = True      # nach eigenen Änderungen markieren
    sg.save_in_place()                    # in den Spielstand selbst; sichert vorher nach sicherung/
    sg.write('kopie.a8s')                 # oder als Kopie ohne Cloud-Vorspann
Spieldaten (mit Cache, erster Aufruf ~15 s, danach < 1 s):
    gd = GameData.load(); gd.assets[guid]; gd.text(line_id); gd.xml(guid)
"""
import glob
import hashlib
import json
import os
import pickle
import re
import shutil
import struct
import subprocess
import sys
import time
import winreg
import zlib

MAGIC = b'\x08\x00\x00\x00\xfd\xff\xff\xff'
EMPTY_ZLIB = b'\x78\xda\x03\x00\x00\x00\x00\x01'
NUL = bytes(1)
PLAYER_PROFILE = 41
UPLAY_ID = '921'
CACHE_DIR = os.path.join(os.environ.get('LOCALAPPDATA', os.path.expanduser('~')), 'anno117-spielstand')
SKILL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NAMES_FILE = os.path.join(SKILL_DIR, 'inselnamen.json')
SETTINGS_FILE = os.path.join(SKILL_DIR, 'einstellungen.json')
OUT_DIR = os.path.join(SKILL_DIR, 'ausgabe')
BACKUP_DIR = os.path.join(SKILL_DIR, 'sicherung')
CACHE_VERSION = 3   # bei Änderungen am Cache-Aufbau erhöhen
_SAVE_CACHE = {}    # Pfad -> Savegame (Wiederverwendung im selben Prozess, siehe Savegame.load)
_GAMEDATA = None


def utf8_console():
    for s in (sys.stdout, sys.stderr):
        try:
            s.reconfigure(encoding='utf-8')
        except AttributeError:
            pass


# ---------------------------------------------------------------- FileDB (verlustfrei)

class N:
    """Knoten: Tag (kids = Liste) oder Attribut (val = bytes)."""
    __slots__ = ('id', 'kids', 'val')

    def __init__(self, nid, kids=None, val=None):
        self.id, self.kids, self.val = nid, kids, val

    def clone(self):
        return N(self.id, [c.clone() for c in self.kids] if self.kids is not None else None, self.val)

    @property
    def is_tag(self):
        return self.kids is not None

    def is_filedb(self):
        return self.kids is None and len(self.val) >= 24 and self.val[-8:] == MAGIC


class DB:
    """FileDB, bytegenau zurückschreibbar. Vor dem Abschluss steht ein Zähler
    (kleine Dateien: Knotenzahl + 1); er wird um die Zahl neuer Knoten angepasst."""

    def __init__(self, b):
        if b[-8:] != MAGIC:
            raise ValueError('keine FileDB')
        self.tagsoff, self.attroff = struct.unpack_from('<II', b, len(b) - 16)
        self.tags = self._dict(b, self.tagsoff)
        self.attrs = self._dict(b, self.attroff)
        self.dictbytes = b[self.tagsoff:len(b) - 16]
        self.counter = struct.unpack_from('<I', b, len(b) - 20)[0]
        self.root = N(0, [])
        stack = [self.root]
        p = 0
        while p < self.tagsoff:
            size, nid = struct.unpack_from('<Ii', b, p)
            p += 8
            if nid <= 0:
                stack.pop()
            elif nid < 0x8000:
                n = N(nid, [])
                stack[-1].kids.append(n)
                stack.append(n)
            else:
                stack[-1].kids.append(N(nid, None, b[p:p + size]))
                p += (size + 7) & ~7
        self.root_closed = not stack
        self.nodes = self.count()

    @staticmethod
    def _dict(b, off):
        n = struct.unpack_from('<I', b, off)[0]
        ids = struct.unpack_from('<%dH' % n, b, off + 4)
        p = off + 4 + 2 * n
        names = []
        for _ in range(n):
            e = b.index(NUL, p)
            names.append(b[p:e].decode('latin1'))
            p = e + 1
        return dict(zip(ids, names))

    def count(self):
        total, todo = 0, [self.root]
        while todo:
            n = todo.pop()
            total += len(n.kids)
            todo += [c for c in n.kids if c.kids is not None]
        return total

    def name(self, n):
        if n.kids is not None:
            return self.tags.get(n.id, 'item' if n.id == 1 else 'tag%d' % n.id)
        return self.attrs.get(n.id, 'attr%d' % n.id)

    def child(self, n, name, default=KeyError):
        for c in n.kids:
            if self.name(c) == name:
                return c
        if default is KeyError:
            raise KeyError(name)
        return default

    def children(self, n, name):
        return [c for c in n.kids if self.name(c) == name]

    def get(self, n, name, default=KeyError):
        for c in n.kids:
            if c.kids is None and self.name(c) == name:
                return int.from_bytes(c.val, 'little', signed=True)
        if default is KeyError:
            raise KeyError(name)
        return default

    def set(self, n, name, value):
        c = self.child(n, name)
        c.val = value.to_bytes(len(c.val), 'little', signed=True)

    def paired(self, n):
        """Maps: abwechselnd Schlüssel-Attribut und Wert-Tag -> (Schlüssel, Tag)."""
        key = None
        for c in n.kids:
            if c.kids is None:
                key = int.from_bytes(c.val, 'little', signed=True)
            else:
                yield key, c

    def path(self, path, start=None):
        """'A/B[2]/C' -> Knoten; [i] wählt den i-ten (ab 0) gleichnamigen Kindknoten."""
        n = start or self.root
        for seg in [s for s in path.split('/') if s]:
            m = re.fullmatch(r'(.+?)(?:\[(\d+)\])?', seg)
            hits = self.children(n, m.group(1))
            i = int(m.group(2) or 0)
            if i >= len(hits):
                raise KeyError('%s nicht gefunden (in %s)' % (seg, path))
            n = hits[i]
        return n

    def dump(self):
        out = []
        w = out.append

        def rec(n):
            for c in n.kids:
                if c.kids is None:
                    w(struct.pack('<Ii', len(c.val), c.id))
                    w(c.val)
                    w(bytes(-len(c.val) % 8))
                else:
                    w(struct.pack('<Ii', 0, c.id))
                    rec(c)
                    w(bytes(8))
        rec(self.root)
        if self.root_closed:
            w(bytes(8))
        body = b''.join(out)
        d = bytearray(self.dictbytes)
        struct.pack_into('<I', d, len(d) - 4, self.counter + self.count() - self.nodes)
        return body + bytes(d) + struct.pack('<II', len(body), len(body) + self.attroff - self.tagsoff) + MAGIC


def fmt_value(v, items=None):
    """Attributwert lesbar machen (Zahl, Float, UTF-16-Text oder Hex)."""
    if len(v) % 2 == 0 and len(v) >= 4 and all(v[k + 1] == 0 and 32 <= v[k] < 127 for k in range(0, len(v), 2)):
        return repr(v.decode('utf-16le'))
    if len(v) in (1, 2, 4, 8):
        i = int.from_bytes(v, 'little', signed=True)
        s = str(i)
        if len(v) == 4:
            f = struct.unpack('<f', v)[0]
            if not -100000 < i < 100000000 and 1e-4 < abs(f) < 1e7:
                s += ' (f=%g)' % f
        if items and i in items:
            s += '  <%s>' % items[i]
        return s
    return v[:32].hex() + ('… (%d Byte)' % len(v) if len(v) > 32 else '')


def print_tree(db, n, depth=99, maxkids=50, items=None, ind=0, out=sys.stdout):
    for k, c in enumerate(n.kids):
        if k >= maxkids:
            out.write('  ' * ind + '… (%d weitere)\n' % (len(n.kids) - k))
            break
        if c.kids is not None:
            out.write('  ' * ind + '<%s> (%d)\n' % (db.name(c), len(c.kids)))
            if ind < depth:
                print_tree(db, c, depth, maxkids, items, ind + 1, out)
        elif c.is_filedb():
            out.write('  ' * ind + '%s {FileDB}\n' % db.name(c))
            if ind < depth:
                sub = DB(c.val)
                print_tree(sub, sub.root, depth, maxkids, items, ind + 1, out)
        else:
            out.write('  ' * ind + '%s = %s\n' % (db.name(c), fmt_value(c.val, items)))


def walk(db, n=None, path=(), nested=True):
    """Liefert (db, Pfad-Tupel, Knoten) für alle Attribute, auch in verschachtelten FileDBs."""
    for c in (n or db.root).kids:
        nm = db.name(c)
        if c.kids is not None:
            yield from walk(db, c, path + (nm,), nested)
        elif nested and c.is_filedb():
            sub = DB(c.val)
            yield from walk(sub, sub.root, path + (nm + '{}',), nested)
        else:
            yield db, path + (nm,), c


def diff(db_a, a, db_b, b, path='', out=None, nested=True):
    """Unterschiede zweier Bäume als Liste von Textzeilen."""
    out = [] if out is None else out
    if (a.kids is None) != (b.kids is None) or a.id != b.id:
        out.append('%s: Knotentyp/Name verschieden' % path)
    elif a.kids is None:
        if a.val != b.val:
            if nested and a.is_filedb() and b.is_filedb():
                sa, sb = DB(a.val), DB(b.val)
                diff(sa, sa.root, sb, sb.root, path + '{}', out)
            else:
                out.append('%s: %s -> %s' % (path, fmt_value(a.val), fmt_value(b.val)))
    else:
        for k, (x, y) in enumerate(zip(a.kids, b.kids)):
            diff(db_a, x, db_b, y, '%s/%s[%d]' % (path, db_a.name(x), k), out, nested)
        if len(a.kids) != len(b.kids):
            out.append('%s: %d -> %d Kindknoten' % (path or '/', len(a.kids), len(b.kids)))
    return out


# ---------------------------------------------------------------- Archiv und Kompression

def a7s_unpack(raw):
    d = zlib.decompressobj()
    data = d.decompress(raw)
    if not d.eof or d.unused_data[:8] != EMPTY_ZLIB:
        raise ValueError('unbekanntes Kompressionsformat')
    return data


def a7s_pack(data):
    return zlib.compress(data, 9) + EMPTY_ZLIB + struct.pack('<I', len(data) & 0xffffffff)


def rda_read_save(path):
    """Spielstand-RDA (eine unkomprimierte Datei je Block) -> (Vorspann, Kopf, [(Eintrag, Inhalt)])."""
    with open(path, 'rb') as f:
        return rda_read_save_bytes(f.read(), path)


def rda_read_save_bytes(b, path='Daten'):
    base = b.find(b'Resource File V2.2')
    if base < 0:
        raise ValueError('Kein RDA-Archiv: %s' % path)
    pre, b = b[:base], b[base:]
    off = struct.unpack_from('<Q', b, 784)[0]
    files = []
    while 0 < off < len(b):
        flags, nfiles, dsize, dusize, nxt = struct.unpack_from('<IIQQQ', b, off)
        if flags or dsize != dusize:
            raise ValueError('Archivblock mit Flags %d wird nicht unterstützt' % flags)
        directory = b[off - dsize:off]
        for k in range(nfiles):
            e = directory[k * 560:(k + 1) * 560]
            o, c, _ = struct.unpack_from('<QQQ', e, 520)
            files.append((e, b[o:o + c]))
        if nxt == off or nxt >= len(b):
            break
        off = nxt
    return pre, b[:792], files


def rda_write_save(head, files):
    out = bytearray(head)
    blocks = []
    for entry, data in files:
        o = len(out)
        out += data
        e = bytearray(entry)
        struct.pack_into('<QQQ', e, 520, o, len(data), len(data))
        out += e
        blocks.append(len(out))
        out += bytes(32)
    for k, off in enumerate(blocks):
        nxt = blocks[k + 1] if k + 1 < len(blocks) else len(out)
        struct.pack_into('<IIQQQ', out, off, 0, 1, 560, 560, nxt)
    struct.pack_into('<Q', out, 784, blocks[0])
    return bytes(out)


class RDA:
    """Allgemeiner RDA-V2.2-Leser (auch komprimierte Blöcke), z. B. für config.rda."""

    def __init__(self, path):
        self.f = open(path, 'rb')
        self.base = self.f.read(4096).find(b'Resource File V2.2')
        self.entries = {}
        size = self.f.seek(0, 2) - self.base
        off = struct.unpack('<Q', self._read(784, 8))[0]
        while 0 < off < size:
            flags, nfiles, dsize, _, nxt = struct.unpack('<IIQQQ', self._read(off, 32))
            if not flags & 2:
                directory = self._read(off - dsize, dsize)
                if flags & 1:
                    directory = zlib.decompress(directory)
                mem = None
                if flags & 4:
                    csz, _ = struct.unpack('<QQ', self._read(off - dsize - 16, 16))
                    mem = (off - dsize - 16 - csz, csz)
                for k in range(nfiles):
                    e = directory[k * 560:(k + 1) * 560]
                    name = e[:520].decode('utf-16le').split(chr(0))[0]
                    self.entries[name] = struct.unpack_from('<QQQ', e, 520) + (flags, mem)
            if nxt == off:
                break
            off = nxt

    def _read(self, off, n):
        self.f.seek(self.base + off)
        return self.f.read(n)

    def read(self, name):
        o, c, s, flags, mem = self.entries[name]
        if mem:
            raw = self._read(*mem)
            return (zlib.decompress(raw) if flags & 1 else raw)[o:o + s]
        raw = self._read(o, c)
        return zlib.decompress(raw) if flags & 1 else raw


# ---------------------------------------------------------------- Spielstand

def game_running():
    try:
        out = subprocess.run(['tasklist', '/FI', 'IMAGENAME eq Anno117.exe', '/NH'],
                             capture_output=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return True   # im Zweifel als laufend behandeln
    return b'anno117.exe' in out.lower()


def backup(path):
    """Kopiert den Spielstand nach sicherung/ (mit Zeitstempel) und prüft die Kopie bytegenau."""
    os.makedirs(BACKUP_DIR, exist_ok=True)
    stem, ext = os.path.splitext(os.path.basename(path))
    dest = os.path.join(BACKUP_DIR, '%s_%s%s' % (stem, time.strftime('%Y%m%d-%H%M%S'), ext))
    shutil.copy2(path, dest)
    with open(path, 'rb') as a, open(dest, 'rb') as b:
        if hashlib.sha256(a.read()).digest() != hashlib.sha256(b.read()).digest():
            raise RuntimeError('Sicherung fehlerhaft: %s' % dest)
    return dest


def backups(path=None):
    """Sicherungen (neueste zuerst), optional nur die eines Spielstands."""
    stem = os.path.splitext(os.path.basename(path))[0] + '_' if path else ''
    files = glob.glob(os.path.join(BACKUP_DIR, stem + '*'))
    return sorted(files, key=os.path.getmtime, reverse=True)


def is_cloud_save(path):
    """Cloud-Spielstand von Ubisoft Connect (40 Byte Vorspann vor dem RDA-Archiv)?"""
    with open(path, 'rb') as f:
        return not f.read(18).startswith(b'Resource File')


def restore(saved, target):
    """Spielt eine Sicherung zurück; der aktuelle Stand wird vorher ebenfalls gesichert."""
    if game_running():
        raise RuntimeError('Anno 117 läuft – erst beenden')
    if is_cloud_save(target) or in_cloud_folder(target):
        raise RuntimeError('In Cloud-Spielstände wird nicht geschrieben – Sicherung in den lokalen Spielstand-Ordner kopieren')
    current = backup(target)
    if is_cloud_save(saved):
        # Sicherung eines Cloud-Spielstands: ohne Vorspann zurückspielen, so wie write() lokale Kopien schreibt
        with open(saved, 'rb') as f:
            data = f.read()
        tmp = target + '.tmp-anno117'
        with open(tmp, 'wb') as f:
            f.write(data[data.index(b'Resource File V2.2'):])
        os.replace(tmp, target)
    else:
        shutil.copy2(saved, target)
    return current


def load_settings():
    """einstellungen.json: {'lokaler_ordner': Spielstand-Ordner des Spiels, 'weitere_ordner': [...]}."""
    try:
        with open(SETTINGS_FILE, encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_settings(**changes):
    settings = load_settings()
    settings.update({k: v for k, v in changes.items() if v is not None})
    with open(SETTINGS_FILE, 'w', encoding='utf-8') as f:
        json.dump(settings, f, indent=4, ensure_ascii=False)
        f.write('\n')
    return settings


def cloud_roots():
    """savegames-Ordner von Ubisoft Connect (aus der Registry, sonst Standardpfad)."""
    roots = []
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r'SOFTWARE\WOW6432Node\Ubisoft\Launcher') as k:
            roots.append(os.path.join(winreg.QueryValueEx(k, 'InstallDir')[0], 'savegames'))
    except OSError:
        pass
    roots.append(r'C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\savegames')
    return list(dict.fromkeys(os.path.normcase(os.path.realpath(r)) for r in roots))


def in_cloud_folder(path):
    """Liegt path im Cloud-Ordner? realpath löst Kurznamen, Junctions und Symlinks auf."""
    p = os.path.normcase(os.path.realpath(path))
    return any(p.startswith(r + os.sep) for r in cloud_roots())


def cloud_dirs():
    """Spielstand-Ordner von Ubisoft Connect: ...\\savegames\\<Konto>\\921."""
    return [d for r in cloud_roots() for d in glob.glob(os.path.join(r, '*', UPLAY_ID))]


def save_dirs():
    """Alle bekannten Spielstand-Ordner: (Ordner, Art, lesbar)."""
    s = load_settings()
    out = [(d, 'Cloud (Ubisoft Connect)') for d in cloud_dirs()]
    if s.get('lokaler_ordner'):
        out.append((s['lokaler_ordner'], 'lokal (Spiel)'))
    out += [(d, 'weiterer Ordner') for d in s.get('weitere_ordner', [])]
    result = []
    for d, kind in out:
        try:
            os.listdir(d)
            ok = True
        except OSError:
            ok = False
        result.append((d, kind, ok))
    return result


def find_saves():
    """Alle lesbaren Spielstände: Cloud-.save (RDA, > 1 MB; die kleine Datei ist das Profil) und .a8s."""
    saves = []
    for d, kind, ok in save_dirs():
        if not ok:
            continue
        for f in glob.glob(os.path.join(d, '**', '*.save'), recursive=True) + \
                glob.glob(os.path.join(d, '**', '*.a8s'), recursive=True):
            try:
                with open(f, 'rb') as fh:
                    if b'Resource File V2.2' in fh.read(256) and os.path.getsize(f) > 1_000_000:
                        saves.append(f)
            except OSError:
                pass
    return sorted(set(saves), key=os.path.getmtime, reverse=True)


def newest_save():
    """Neuester lokaler Spielstand; der Cloud-Spielstand (nur Spiegel davon) nur, wenn es keinen lokalen gibt."""
    saves = find_saves()
    if not saves:
        raise FileNotFoundError('Kein Anno-117-Spielstand gefunden – Ordner mit '
                                '"spielstand.py ordner --lokal PFAD" angeben oder --save nutzen')
    return next((f for f in saves if not is_cloud_save(f)), saves[0])


newest_cloud_save = newest_save   # alter Name


def load_names():
    """inselnamen.json: Area-ID (als Text) -> Inselname."""
    try:
        with open(NAMES_FILE, encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def update_names(defaults):
    """Trägt fehlende Inseln mit ihrem Standardnamen ein; vorhandene Einträge bleiben.

    Eigene Inselnamen lassen sich nicht aus dem Spielstand zuordnen (der Spielstand
    verweist nirgends auf die ID des Namens) – sie werden in der Datei von Hand ersetzt.
    """
    names = load_names()
    missing = {str(a): n for a, n in defaults.items() if str(a) not in names}
    if not missing:
        return
    names.update(missing)
    with open(NAMES_FILE, 'w', encoding='utf-8') as f:
        json.dump(dict(sorted(names.items(), key=lambda x: int(x[0]))), f, indent=4, ensure_ascii=False)
        f.write('\n')


class Session:
    def __init__(self, sg, key, node):
        self.sg, self.key, self.node = sg, key, node
        self.guid = sg.db.get(sg.db.child(node, 'SessionDesc'), 'SessionGUID')
        self.bd = sg.db.child(sg.db.child(node, 'SessionData'), 'BinaryData')
        self._db = None
        self.dirty = False   # nach eigenen Änderungen auf True setzen, sonst schreibt write() sie nicht

    @property
    def db(self):
        if self._db is None:
            self._db = DB(self.bd.val)
            self.sg._open.append(self)
        return self._db

    @property
    def gsm(self):
        return self.db.child(self.db.root, 'GameSessionManager')

    @property
    def name(self):
        return {3245: 'Latium', 6627: 'Albion'}.get(self.guid, str(self.guid))

    def area_infos(self):
        return dict(self.db.paired(self.db.child(self.gsm, 'AreaInfo')))

    def area_manager(self, area):
        return self.db.child(self.db.child(self.gsm, 'AreaManagers'), 'AreaManager_%d' % area)


class Savegame:
    def __init__(self, path):
        self.path = path
        self.pre, self.head, self.files = rda_read_save(path)
        self.index = {e[:520].decode('utf-16le').split(chr(0))[0]: k for k, (e, _) in enumerate(self.files)}
        st = os.stat(path)
        self.stamp = (st.st_mtime_ns, st.st_size)
        self._db = None
        self._open = []
        self.dirty = False   # True, wenn außerhalb der Sessions geändert wurde

    @classmethod
    def load(cls, path=None):
        """Lädt einen Spielstand. Im selben Prozess (z. B. im Dienst) wird ein unveränderter,
        bereits geladener Stand wiederverwendet, solange sich die Datei nicht geändert hat."""
        path = os.path.abspath(path or newest_save())
        st = os.stat(path)
        sg = _SAVE_CACHE.get(path)
        if sg is not None and sg.stamp == (st.st_mtime_ns, st.st_size) and not sg.modified():
            return sg
        sg = cls(path)
        _SAVE_CACHE[path] = sg
        return sg

    def modified(self):
        return self.dirty or any(s.dirty for s in self._open)

    @property
    def is_cloud(self):
        """Cloud-Spielstand (Vorspann oder im Cloud-Ordner) – wird nie direkt geändert."""
        return bool(self.pre) or in_cloud_folder(self.path)

    def raw(self, name):
        return a7s_unpack(self.files[self.index[name]][1])

    @property
    def db(self):
        if self._db is None:
            self._db = DB(self.raw('data.a7s'))
        return self._db

    def meta(self):
        m = DB(self.raw('meta.a7s'))
        return {m.name(c): fmt_value(c.val) for c in m.root.kids if c.kids is None}

    def sessions(self):
        if getattr(self, '_sessions', None) is None:
            gs = self.db.path('MetaGameManager/GameSessions')
            self._sessions = [Session(self, k, n) for k, n in self.db.paired(gs)]
        return self._sessions

    def session(self, which):
        """Session nach Name (Latium/Albion), GUID oder Index."""
        ss = self.sessions()
        for s in ss:
            if str(which).lower() in (s.name.lower(), str(s.guid)):
                return s
        if str(which).isdigit() and int(which) < len(ss):
            return ss[int(which)]
        raise KeyError('Session %s nicht gefunden' % which)

    def islands(self, owner=PLAYER_PROFILE, texts=None, sessions=None):
        """Eigene Inseln: [{name, area, session (Session-Objekt), info}]; sessions schränkt ein.

        Namen kommen aus inselnamen.json, sonst aus den Spieltexten (CityNameGuid). Mit texts
        werden neue Inseln mit ihrem Standardnamen in inselnamen.json nachgetragen.
        """
        overrides = load_names()
        texts = texts or {}
        out, defaults = [], {}
        for s in sessions or self.sessions():
            for area, info in s.area_infos().items():
                if s.db.get(info, 'OwnerProfile', -1) != owner:
                    continue
                default = (texts.get(s.db.get(info, 'CityNameGuid', 0)) or '').strip()
                if default:
                    defaults[area] = default
                name = overrides.get(str(area)) or default or 'Area %d' % area
                out.append({'name': name.strip(), 'area': area, 'session': s, 'info': info})
        update_names(defaults)
        return out

    def _packed(self):
        changed = [s for s in self._open if s.dirty]
        for s in changed:
            s.bd.val = s.db.dump()
        k = self.index['data.a7s']
        files = list(self.files)
        if self._db is not None and (changed or self.dirty):
            files[k] = (files[k][0], a7s_pack(self._db.dump()))
        return rda_write_save(self.head, files)

    def write(self, out):
        """Als neue Datei schreiben, immer ohne Cloud-Vorspann (also .a8s), nie in den Cloud-Ordner."""
        if os.path.abspath(out) == os.path.abspath(self.path):
            raise ValueError('Für den Spielstand selbst save_in_place() verwenden')
        if in_cloud_folder(out):
            raise ValueError('In den Cloud-Ordner von Ubisoft Connect wird nicht geschrieben')
        with open(out, 'wb') as f:
            f.write(self._packed())
        return os.path.abspath(out)

    def save_in_place(self):
        """Änderungen in den Spielstand selbst schreiben. Sichert ihn vorher zwingend.

        Bricht ab, wenn Anno läuft, die Datei sich seit dem Laden geändert hat oder es ein
        Cloud-Spielstand ist (dessen Synchronisierung gehört Ubisoft Connect; dafür write()).
        Gibt den Pfad der Sicherung zurück.
        """
        if self.is_cloud:
            raise RuntimeError('Cloud-Spielstand wird nicht direkt geändert – Kopie mit write() schreiben')
        if game_running():
            raise RuntimeError('Anno 117 läuft – erst beenden, sonst überschreibt das Spiel die Änderung')
        st = os.stat(self.path)
        if (st.st_mtime_ns, st.st_size) != self.stamp:
            raise RuntimeError('Spielstand wurde seit dem Laden verändert – neu laden und wiederholen')
        data = self.pre + self._packed()
        DB(a7s_unpack(rda_read_save_bytes(data)[2][self.index['data.a7s']][1]))   # lässt sich wieder lesen?
        saved = backup(self.path)
        tmp = self.path + '.tmp-anno117'
        with open(tmp, 'wb') as f:
            f.write(data)
        os.replace(tmp, self.path)
        return saved


# ---------------------------------------------------------------- Spieldaten mit Cache

def find_game_dir():
    try:
        key = 'SOFTWARE\\WOW6432Node\\Ubisoft\\Launcher\\Installs\\' + UPLAY_ID
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key) as k:
            return winreg.QueryValueEx(k, 'InstallDir')[0]
    except OSError:
        return None


class GameData:
    """assets.xml und deutsche Texte, zwischengespeichert unter %LOCALAPPDATA%\\anno117-spielstand.

    assets[guid] = {'guid', 'template', 'name' (intern), 'de', 'start', 'end'} – start/end sind
    Byte-Offsets in der zwischengespeicherten assets.xml (für xml()).
    """

    def __init__(self, cache):
        self.assets, self.texts, self.xml_path = cache['assets'], cache['texts'], cache['xml_path']

    @classmethod
    def load(cls, game_dir=None, refresh=False):
        global _GAMEDATA
        if _GAMEDATA is not None and not refresh:
            return _GAMEDATA
        _GAMEDATA = cls._load(game_dir, refresh)
        return _GAMEDATA

    @classmethod
    def _load(cls, game_dir=None, refresh=False):
        game_dir = game_dir or find_game_dir()
        if not game_dir:
            raise FileNotFoundError('Anno-117-Installation nicht gefunden')
        cfg = os.path.join(game_dir, 'maindata', 'config.rda')
        stamp = '%d-%d' % (os.path.getmtime(cfg), os.path.getsize(cfg))
        os.makedirs(CACHE_DIR, exist_ok=True)
        idx = os.path.join(CACHE_DIR, 'index.pickle')
        xml_path = os.path.join(CACHE_DIR, 'assets.xml')
        if not refresh and os.path.exists(idx) and os.path.exists(xml_path):
            with open(idx, 'rb') as f:
                cache = pickle.load(f)
            if cache.get('stamp') == stamp and cache.get('version') == CACHE_VERSION:
                return cls(cache)
        print('Baue Spieldaten-Cache (einmalig, ~20 s) …', file=sys.stderr)
        rda = RDA(cfg)
        xml = rda.read('data/base/config/export/assets.xml')
        with open(xml_path, 'wb') as f:
            f.write(xml)
        import xml.etree.ElementTree as ET
        texts = {}
        for t in ET.fromstring(rda.read('data/base/config/gui/texts_german.xml')).iter('Text'):
            lid = t.findtext('LineId')
            if lid is not None:
                texts[int(lid)] = t.findtext('Text')
        assets = {}
        # Asset-Grenzen und Kernfelder per Regex (schneller als ein Baum für 35 MB)
        starts = [m.start() for m in re.finditer(rb'<Asset>(?=\s*<)', xml)]   # nicht <Asset>123</Asset>
        for k, s in enumerate(starts):
            chunk = xml[s:starts[k + 1] if k + 1 < len(starts) else len(xml)]
            g = re.search(rb'<GUID>(-?\d+)</GUID>', chunk)
            last = chunk.rfind(b'</Asset>')
            if not g or last < 0:
                continue
            end = s + last + len(b'</Asset>')
            tpl = re.search(rb'<Template>([^<]*)</Template>', chunk[:g.start()])
            nm = re.search(rb'<Name>([^<]*)</Name>', chunk)
            oid = re.search(rb'<(?:OasisId|LocaText)>(-?\d+)</', chunk)
            base = re.search(rb'<BaseAssetGUID>(\d+)</BaseAssetGUID>', chunk[:g.start()])
            guid = int(g.group(1))
            assets[guid] = {
                'guid': guid,
                'template': tpl.group(1).decode() if tpl else None,
                'base': int(base.group(1)) if base else None,
                'name': nm.group(1).decode('utf-8', 'replace') if nm else None,
                'de': texts.get(int(oid.group(1))) if oid else None,
                'start': s, 'end': end,
            }
        for a in assets.values():   # abgeleitete Assets (BaseAssetGUID) erben Template und Namen
            b, seen = a, set()
            while b and b['template'] is None and b['base'] in assets and b['guid'] not in seen:
                seen.add(b['guid'])
                b = assets[b['base']]
            if a['template'] is None and b:
                a['template'] = b['template']
            if a['de'] is None and a['base'] in assets:
                a['de'] = assets[a['base']]['de']
        cache = {'stamp': stamp, 'version': CACHE_VERSION, 'assets': assets, 'texts': texts, 'xml_path': xml_path}
        with open(idx, 'wb') as f:
            pickle.dump(cache, f, protocol=pickle.HIGHEST_PROTOCOL)
        return cls(cache)

    def text(self, line_id):
        return self.texts.get(int(line_id))

    def label(self, guid):
        a = self.assets.get(guid)
        if not a:
            return '%d ?' % guid
        return '%d %s [%s]' % (guid, (a['de'] or a['name'] or '').strip(), a['template'])

    def _raw(self):
        if getattr(self, '_xml', None) is None:
            with open(self.xml_path, 'rb') as f:
                self._xml = f.read()
        return self._xml

    def xml(self, guid):
        a = self.assets[guid]
        return self._raw()[a['start']:a['end']].decode('utf-8', 'replace')

    # ------------------------------------------------ Verzeichnisse (zwischengespeichert)

    def catalog(self):
        """Aufbereitete Verzeichnisse, einmal berechnet und neben dem Cache gespeichert:

        factories[guid] = {inputs: [(Produkt, Menge)], outputs: [...], fertility: [GUID], slot,
                           regions, fuel (bool), cycle (s), radius}
        producers[Produkt] = [Fabrik-GUIDs]
        items[guid] = {rarity, origin, niche, scope, targets: [GUID], buffs: [GUID],
                       added_fertility: [GUID]}
        pools[guid] = [Mitglieder-GUIDs]   (AssetPool, z. B. "Weingüter")
        radius[guid] = RadiusDistance von Gebäuden mit EffectSource
        """
        if getattr(self, '_catalog', None) is not None:
            return self._catalog
        path = os.path.join(CACHE_DIR, 'katalog.pickle')
        try:
            with open(path, 'rb') as f:
                cat = pickle.load(f)
            if cat.get('xml_size') == os.path.getsize(self.xml_path) and cat.get('version') == CACHE_VERSION:
                self._catalog = cat
                return cat
        except (OSError, pickle.PickleError, EOFError):
            pass
        print('Baue Spieldaten-Verzeichnisse (einmalig) …', file=sys.stderr)
        raw = self._raw()
        num = lambda pat, x: [int(v) for v in re.findall(pat, x)]  # noqa: E731
        fac, prod, items, pools, radius, fert_buff = {}, {}, {}, {}, {}, {}
        for g, a in self.assets.items():
            x = raw[a['start']:a['end']]
            r = re.search(rb'<EffectSource>.*?<RadiusDistance>(\d+)<', x, re.S)
            if r:
                radius[g] = int(r.group(1))
            outs = re.search(rb'<FactoryOutputs>(.*?)</FactoryOutputs>', x, re.S)
            if outs:
                ins = re.search(rb'<FactoryInputs>(.*?)</FactoryInputs>', x, re.S)
                pair = lambda m: [(int(p), int(n or 1)) for p, n in re.findall(  # noqa: E731
                    rb'<Product>(\d+)</Product>(?:\s*<Amount>([\d.]+)</Amount>)?', m.group(1))] if m else []
                f = {'inputs': pair(ins), 'outputs': pair(outs),
                     'fertility': num(rb'<NeededFertility>(\d+)<', x),
                     'slot': (re.findall(rb'<SlotType>(\w+)<', x) or [b''])[0].decode() or None,
                     'regions': (re.findall(rb'<AssociatedRegions>([^<]*)<', x) or [b''])[0].decode(),
                     'fuel': b'<NeedsFuelInput>1<' in x,
                     'cycle': int((re.findall(rb'<CycleTime>(\d+)<', x) or [0])[0])}
                fac[g] = f
                for p, _ in f['outputs']:
                    prod.setdefault(p, []).append(g)
            af = num(rb'<AddedFertility>(\d+)<', x)
            if af:
                fert_buff[g] = af
            if a['template'] == 'AssetPool' or b'<AssetPool>' in x:
                pools[g] = num(rb'<Asset>(\d+)</Asset>', x)
            if a['template'] in ITEM_TEMPLATES:
                eff = re.search(rb'<Effect>(.*?)</Effect>', x, re.S)
                e = eff.group(1) if eff else b''

                def guids(tag):
                    m = re.search(rb'<%s>(.*?)</%s>' % (tag, tag), e, re.S)
                    return [int(v) for v in re.findall(rb'<GUID>(\d+)</GUID>', m.group(1))] if m else []

                def txt(tag, src=x):
                    v = re.findall(rb'<%s>([^<]*)<' % tag, src)
                    return v[0].decode() if v else None

                items[g] = {'rarity': txt(b'Rarity'), 'origin': txt(b'Origin'), 'niche': txt(b'Niche'),
                            'scope': txt(b'EffectScope', e), 'targets': guids(b'Targets'), 'buffs': guids(b'Buffs')}
        for it in items.values():
            it['added_fertility'] = [f for b in it['buffs'] for f in fert_buff.get(b, [])]
        cat = {'xml_size': len(raw), 'version': CACHE_VERSION, 'factories': fac, 'producers': prod, 'items': items,
               'pools': pools, 'radius': radius}
        with open(path, 'wb') as f:
            pickle.dump(cat, f, protocol=pickle.HIGHEST_PROTOCOL)
        self._catalog = cat
        return cat

    def expand(self, guid):
        """GUID plus alle Mitglieder, falls es ein AssetPool ist."""
        pools = self.catalog()['pools']
        out, todo = [], [guid]
        while todo:
            g = todo.pop()
            if g not in out:
                out.append(g)
                todo += pools.get(g, [])
        return out

    def items_for(self, building=None, fertility=None):
        """Items, die auf ein Gebäude wirken bzw. eine Fruchtbarkeit/ein Vorkommen hinzufügen."""
        out = []
        for g, it in self.catalog()['items'].items():
            if fertility is not None and fertility in it['added_fertility']:
                out.append(g)
            elif building is not None and any(building in self.expand(t) for t in it['targets']):
                out.append(g)
        return out

    def element(self, guid):
        import xml.etree.ElementTree as ET
        return ET.fromstring(self.xml(guid))

    def search(self, text, template=None):
        t = text.lower()
        return [a for a in self.assets.values()
                if (t in (a['de'] or '').lower() or t in (a['name'] or '').lower())
                and (template is None or (a['template'] or '').lower() == template.lower())]

    def references(self, guid):
        """GUIDs aller Assets, die die GUID als Wert enthalten."""
        pat = re.compile(rb'>%d<' % guid)
        with open(self.xml_path, 'rb') as f:
            xml = f.read()
        hits = []
        for m in pat.finditer(xml):
            for a in self._owner(m.start()):
                if a != guid and a not in hits:
                    hits.append(a)
        return hits

    def _owner(self, offset):
        if not hasattr(self, '_sorted'):
            self._sorted = sorted((a['start'], a['end'], g) for g, a in self.assets.items())
            self._starts = [s for s, _, _ in self._sorted]
        import bisect
        k = bisect.bisect_right(self._starts, offset) - 1
        while k >= 0:
            s, e, g = self._sorted[k]
            if s <= offset < e:
                yield g
                return
            k -= 1

    def item_names(self):
        return {g: (a['de'] or a['name'] or '').strip() for g, a in self.assets.items()
                if a['template'] in ('Item', 'ItemWithBoost', 'ItemWithUI', 'ItemQuest')}


# ---------------------------------------------------------------- Items einlegen

ITEM_TEMPLATES = ('Item', 'ItemWithBoost', 'ItemWithUI', 'ItemQuest')


def storage(session, area):
    """SlotList des Item-Lagers einer Insel."""
    db = session.db
    return db.path('AreaItemManager/AreaSlotContainer/SlotList', session.area_manager(area))


def stacks(db, slots):
    """[(Slot-Knoten, Items im Stapel)] eines Item-Lagers."""
    return [(s, db.path('Stack/value/Stack', s).kids) for s in slots.kids]


def insert_items(session, area, guid, count=1, unique=False, gd=None):
    """Legt count Exemplare der Item-GUID ins Lager der Insel; gibt die neuen Item-IDs zurück.

    Neue Items bekommen fortlaufende IDs (ItemIdCounter + 1, Präfix 2^58), einen Eintrag in
    ItemSessionManager/ItemMap und kommen auf einen Stapel gleicher Items im Insellager.
    Vorlagen für die Knoten werden aus vorhandenen Einträgen derselben Session geklont.
    Unikate und nicht gekaufte Inhalte (check_origin) werden abgelehnt.
    """
    gd = gd or GameData.load()
    check_origin(session.sg, gd, guid)
    unique = unique or gd.catalog()['items'].get(guid, {}).get('rarity') == 'Unique'
    db, gsm = session.db, session.gsm
    ism = db.child(gsm, 'ItemSessionManager')
    im = db.child(ism, 'ItemMap')
    entries = [e for _, e in db.paired(im)]
    ids = {db.get(e, 'ItemID') for e in entries}
    prefix = min(ids) >> 56 << 56
    counter = db.get(ism, 'ItemIdCounter')
    if any(i >> 56 << 56 != prefix for i in ids) or max(ids) - prefix > counter:
        raise ValueError('Item-IDs haben ein unerwartetes Format')
    if unique or any(c.kids is None and int.from_bytes(c.val, 'little') == guid
                     for c in db.child(ism, 'UniqueItemExists').kids):
        raise ValueError('Unikat – wird nicht eingefügt')

    key_tpl = next(c for c in im.kids if c.kids is None)
    entry_tpl = next((e for e in entries if db.get(e, 'EffectID') == 0
                      and not db.child(e, 'QuestID').kids and not db.child(e, 'BoostCondition').kids), None)
    slot_tpl = None
    for am in db.child(gsm, 'AreaManagers').kids:
        try:
            sl = db.path('AreaItemManager/AreaSlotContainer/SlotList', am)
        except (KeyError, TypeError):
            continue
        slot_tpl = slot_tpl or next((s for s, its in stacks(db, sl) if its), None)
    if entry_tpl is None or slot_tpl is None:
        raise ValueError('keine Vorlage für Items in dieser Session')

    slots = storage(session, area)
    target = next((its for _, its in stacks(db, slots) if its and db.get(its[0], 'GUID') == guid), None)
    if target is None:
        slot = slot_tpl.clone()
        slots.kids.append(slot)
        target = db.path('Stack/value/Stack', slot).kids
        stack_tpl = target[0]
        del target[:]
    else:
        stack_tpl = target[0]

    new_ids = []
    for _ in range(count):
        counter += 1
        new_id = prefix + counter
        key = key_tpl.clone()
        key.val = new_id.to_bytes(len(key.val), 'little')
        entry = entry_tpl.clone()
        db.set(entry, 'ItemID', new_id)
        db.set(entry, 'GUID', guid)
        im.kids += [key, entry]
        st = stack_tpl.clone()
        db.set(st, 'ID', new_id)
        db.set(st, 'GUID', guid)
        target.append(st)
        new_ids.append(new_id)
    db.set(ism, 'ItemIdCounter', counter)
    session.dirty = True
    return new_ids


def check_origin(sg, gd, guid):
    """Prüft die Herkunft eines Items vor dem Einfügen; gibt sie zurück (None = Grundspiel).

    Items aus DLCs, Vorbesteller-Boni usw. nur, wenn der Spielstand schon Items derselben
    Herkunft enthält – nicht gekaufte Inhalte werden nicht freigeschaltet. Test-Items nie.
    """
    items = gd.catalog()['items']
    origin = items.get(guid, {}).get('origin')
    if not origin:
        return None
    if origin == 'Testing':
        raise ValueError('Test-Item – wird nicht eingefügt')
    for s in sg.sessions():
        db = s.db
        im = db.path('ItemSessionManager/ItemMap', s.gsm)
        if any(items.get(db.get(e, 'GUID', 0), {}).get('origin') == origin for _, e in db.paired(im)):
            return origin
    raise ValueError('Item aus %s, aber der Spielstand enthält keine Items aus %s – '
                     'nicht gekaufte Inhalte werden nicht eingefügt' % (origin, origin))



# ---------------------------------------------------------------- Inselobjekte und Sockel

def island_objects(session, area, gd=None):
    """Objekte einer Insel: [{node, guid, id, pos (x, z), label, sockets}].

    sockets: Liste der SocketItems-Einträge (GUID 0 = frei), nur bei Gebäuden mit Sockeln.
    """
    db = session.db
    objs = db.path('AreaObjectManager/GameObject/objects', session.area_manager(area))
    out = []
    for o in objs.kids:
        if o.kids is None:
            continue
        g = db.get(o, 'guid', 0)
        p = db.child(o, 'Position', None)
        pos = None
        if p is not None and p.kids is None and len(p.val) == 12:
            x, _, z = struct.unpack('<fff', p.val)
            pos = (x, z)
        sockets = None
        try:
            si = db.path('ItemContainer/SocketContainer/SocketItems', o)
            sockets = [db.get(i, 'GUID', 0) for i in si.kids if i.kids is not None]
        except KeyError:
            pass
        out.append({'node': o, 'guid': g, 'id': db.get(o, 'ID', 0), 'pos': pos, 'sockets': sockets,
                    'label': gd.label(g) if gd else str(g)})
    return out


def matches(obj, text, gd):
    """Passt ein Objekt zu einem Suchtext (GUID, deutscher oder interner Name)?"""
    if str(text).isdigit():
        return obj['guid'] == int(text)
    a = gd.assets.get(obj['guid'], {})
    t = str(text).lower()
    return t in (a.get('de') or '').lower() or t in (a.get('name') or '').lower()


def dist(a, b):
    return ((a['pos'][0] - b['pos'][0]) ** 2 + (a['pos'][1] - b['pos'][1]) ** 2) ** 0.5


def occupied(objs, slot, gd):
    """Steht auf einem Bauplatz (Slot) schon ein Slot-Gebäude?"""
    return any(o['pos'] and gd.assets.get(o['guid'], {}).get('template') == 'SlotFactoryBuilding7'
               and dist(o, slot) < 4 for o in objs)


def nearby(objs, src, text, gd, radius, free_only=False):
    """Objekte zu text im Umkreis radius (Luftlinie) um src: [(Abstand, Objekt)].

    free_only: bei Bauplätzen nur unbebaute (siehe occupied).
    """
    if not src['pos']:
        return []
    hits = []
    for o in objs:
        if o is not src and o['pos'] and matches(o, text, gd):
            d = dist(o, src)
            if d <= radius and not (free_only and occupied(objs, o, gd)):
                hits.append((d, o))
    return sorted(hits, key=lambda h: h[0])


def socket_item(session, area, building_id, guid, gd):
    """Setzt ein neues Item direkt in einen freien Sockel eines Gebäudes; gibt (Item-ID, Effekt-ID) zurück.

    Angelegt werden wie bei einem im Spiel eingesetzten Item:
      - ItemMap-Eintrag mit EffectID (ItemIdCounter + 1)
      - Effekt in AreaEffectManager/Effects: Id = Area * 2^46 + NextEffectIndex, Quelle = Gebäude,
        SourcePosition = Position des Gebäudes, Distance = Radius des Gebäudes
      - Sockel-Eintrag {GUID, ActivationTime, ItemReference{ID, GUID}}
    Vorlagen kommen aus einem bereits gesockelten Item derselben Session.
    Unikate und nicht gekaufte Inhalte (check_origin) werden abgelehnt.
    """
    db, gsm = session.db, session.gsm
    it = gd.catalog()['items'].get(guid)
    if not it:
        raise ValueError('%d ist kein Item' % guid)
    if it['scope'] != 'Radius':
        raise ValueError('nur Items mit Wirkung im Radius werden unterstützt (hier: %s)' % it['scope'])
    check_origin(session.sg, gd, guid)
    ism = db.child(gsm, 'ItemSessionManager')
    if it['rarity'] == 'Unique' or any(c.kids is None and int.from_bytes(c.val, 'little') == guid
                                       for c in db.child(ism, 'UniqueItemExists').kids):
        raise ValueError('Unikat – wird nicht eingefügt')
    obj = next((o for o in island_objects(session, area) if o['id'] == building_id), None)
    if obj is None or obj['sockets'] is None:
        raise ValueError('Gebäude %d hat keine Sockel' % building_id)
    si = db.path('ItemContainer/SocketContainer/SocketItems', obj['node'])
    free = next((i for i in si.kids if i.kids is not None and db.get(i, 'GUID', 0) == 0), None)
    if free is None:
        raise ValueError('kein freier Sockel in Gebäude %d' % building_id)

    # Vorlagen: gesockeltes Item mit Effekt (Sockel-Eintrag, Effekt, ItemMap-Eintrag)
    im = db.child(ism, 'ItemMap')
    entries = {db.get(e, 'ItemID'): e for _, e in db.paired(im)}
    sock_tpl = eff_tpl = entry_tpl = None
    for am in db.child(gsm, 'AreaManagers').kids:
        if am.kids is None:
            continue
        try:
            effects = {db.get(e, 'Id'): e for e in db.path('AreaEffectManager/Effects', am).kids if e.kids is not None}
            objs = db.path('AreaObjectManager/GameObject/objects', am).kids
        except KeyError:
            continue
        for o in objs:
            try:
                items = db.path('ItemContainer/SocketContainer/SocketItems', o).kids
            except (KeyError, TypeError):
                continue
            for s in items:
                if s.kids is None or not db.get(s, 'GUID', 0):
                    continue
                e = entries.get(db.get(db.child(s, 'ItemReference'), 'ID', 0))
                ef = effects.get(db.get(e, 'EffectID', 0)) if e is not None else None
                if ef is not None and all(db.child(ef, n, None) is not None
                                          for n in ('Source', 'SourcePosition', 'Distance', 'Scope')):
                    sock_tpl, entry_tpl, eff_tpl = s, e, effects[db.get(e, 'EffectID')]
                    break
            if sock_tpl:
                break
        if sock_tpl:
            break
    if sock_tpl is None:
        raise ValueError('keine Vorlage für ein gesockeltes Item in dieser Session')

    # Item-ID
    ids = list(entries)
    prefix = min(ids) >> 56 << 56
    counter = db.get(ism, 'ItemIdCounter') + 1
    item_id = prefix + counter
    if item_id in entries:
        raise ValueError('Item-ID %d ist schon vergeben' % item_id)

    # Effekt
    am = session.area_manager(area)
    aem = db.child(am, 'AreaEffectManager')
    index = db.get(aem, 'NextEffectIndex')
    effect_id = (area << 46) | index
    effects = db.child(aem, 'Effects')
    if any(e.kids is not None and db.get(e, 'Id', 0) == effect_id for e in effects.kids):
        raise ValueError('Effekt-ID %d ist schon vergeben' % effect_id)
    eff = eff_tpl.clone()
    db.set(eff, 'Guid', guid)
    db.set(eff, 'Id', effect_id)
    db.set(db.child(eff, 'Source'), 'ObjectID', building_id)
    db.child(eff, 'SourcePosition').val = db.child(obj['node'], 'Position').val
    db.set(eff, 'Distance', gd.catalog()['radius'].get(obj['guid'], db.get(eff_tpl, 'Distance')))
    effects.kids.append(eff)
    db.set(aem, 'NextEffectIndex', index + 1)

    # ItemMap
    key = next(c for c in im.kids if c.kids is None).clone()
    key.val = item_id.to_bytes(len(key.val), 'little')
    entry = entry_tpl.clone()
    db.set(entry, 'ItemID', item_id)
    db.set(entry, 'GUID', guid)
    db.set(entry, 'EffectID', effect_id)
    im.kids += [key, entry]
    db.set(ism, 'ItemIdCounter', counter)

    # Sockel
    sock = sock_tpl.clone()
    db.set(sock, 'GUID', guid)
    ref = db.child(sock, 'ItemReference')
    db.set(ref, 'ID', item_id)
    db.set(ref, 'GUID', guid)
    si.kids[si.kids.index(free)] = sock
    session.dirty = True
    return item_id, effect_id


def find_island(sg, gd, name):
    """Eigene Insel nach Name oder Area-ID; öffnet die Sessions nacheinander und hört beim Treffer auf."""
    q, seen = str(name).lower(), []
    for s in sg.sessions():
        found = sg.islands(texts=gd.texts, sessions=[s])
        seen += found
        hit = [i for i in found if i['name'].lower() == q or str(i['area']) == q]
        if hit:
            return hit[0]
    raise KeyError('Insel "%s" nicht gefunden; vorhanden: %s' % (name, ', '.join(i['name'] for i in seen)))
