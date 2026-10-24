"""Hintergrund-Dienst: hält Spieldaten und Spielstände im Speicher, damit Abfragen schnell sind.

    python dienst.py            starten (im Hintergrund laufen lassen)
    python frage.py …           Befehle an den Dienst schicken (siehe frage.py)

Der Dienst hört nur auf 127.0.0.1, verlangt ein Zufallstoken und schreibt Port/Token nach
%LOCALAPPDATA%\\anno117-spielstand\\dienst.json. Er führt die Skripte dieses Ordners (oder
Python-Code) in seinem eigenen Prozess aus; Savegame.load() und GameData.load() liefern dort
bereits geladene Daten, solange sich die Datei nicht geändert hat und nichts verändert wurde.
"""
import contextlib
import io
import json
import os
import runpy
import secrets
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import anno117lib  # noqa: E402

INFO = os.path.join(anno117lib.CACHE_DIR, 'dienst.json')
TOKEN = secrets.token_hex(16)
LOCK = threading.Lock()
NAMESPACE = {'lib': anno117lib, '__name__': 'dienst'}
exec('from anno117lib import *', NAMESPACE)


def run(req):
    """req: {'script': 'spielstand.py', 'args': [...]} oder {'code': '...'}"""
    out = io.StringIO()
    status = 0
    t = time.time()
    with LOCK, contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        try:
            if req.get('code') is not None:
                exec(compile(req['code'], '<frage>', 'exec'), NAMESPACE)
            else:
                script = os.path.join(HERE, os.path.basename(req['script']))
                old = sys.argv
                sys.argv = [script] + list(req.get('args', []))
                try:
                    runpy.run_path(script, run_name='__main__')
                finally:
                    sys.argv = old
        except SystemExit as e:
            if e.code not in (None, 0):
                status = e.code if isinstance(e.code, int) else 1
                if not isinstance(e.code, int):
                    print(e.code)
        except Exception:
            status = 1
            traceback.print_exc()
    return {'status': status, 'output': out.getvalue(), 'seconds': round(time.time() - t, 2)}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.headers.get('X-Token') != TOKEN:
            self.send_error(403)
            return
        req = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        if req.get('stop'):
            body = {'status': 0, 'output': 'Dienst beendet.\n'}
            threading.Thread(target=self.server.shutdown).start()
        else:
            body = run(req)
        data = json.dumps(body).encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def main():
    anno117lib.utf8_console()
    server = HTTPServer(('127.0.0.1', 0), Handler)
    os.makedirs(anno117lib.CACHE_DIR, exist_ok=True)
    with open(INFO, 'w', encoding='utf-8') as f:
        json.dump({'port': server.server_address[1], 'token': TOKEN, 'pid': os.getpid()}, f)
    print('Dienst läuft auf 127.0.0.1:%d (PID %d)' % (server.server_address[1], os.getpid()), flush=True)
    # Spieldaten und neuesten Spielstand vorladen
    try:
        gd = anno117lib.GameData.load()
        gd.catalog()
        gd._raw()
        sg = anno117lib.Savegame.load()
        for s in sg.sessions():
            s.db
        print('Vorgeladen:', sg.path, flush=True)
    except Exception as e:
        print('Vorladen unvollständig:', e, flush=True)
    try:
        server.serve_forever()
    finally:
        with contextlib.suppress(OSError):
            os.remove(INFO)


if __name__ == '__main__':
    main()
