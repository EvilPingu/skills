"""Befehle an den Hintergrund-Dienst schicken (schnell, Daten bleiben im Speicher).

    python frage.py spielstand.py naehe --insel Cinis --typ Officium --zu "Slot Roman Mountain"
    python frage.py spieldaten.py kette Mosaike
    python frage.py einsetzen.py --insel Cinis --item 54054 --naehe "Slot Roman Mountain" --probe
    python frage.py -c "sg = Savegame.load(); print([s.name for s in sg.sessions()])"
    python frage.py --status | --stop

Läuft kein Dienst, wird das Skript direkt ausgeführt (langsamer) bzw. bei -c abgebrochen.
"""
import json
import os
import runpy
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from anno117lib import CACHE_DIR, utf8_console  # noqa: E402

INFO = os.path.join(CACHE_DIR, 'dienst.json')


def send(req, timeout=900):
    with open(INFO, encoding='utf-8') as f:
        info = json.load(f)
    r = urllib.request.Request('http://127.0.0.1:%d/' % info['port'], data=json.dumps(req).encode('utf-8'),
                               headers={'X-Token': info['token'], 'Content-Type': 'application/json'})
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        return json.loads(resp.read())


def main():
    utf8_console()
    args = sys.argv[1:]
    if not args or args[0] in ('-h', '--help'):
        print(__doc__)
        return
    if args[0] == '--status':
        req = {'code': 'import os; print("Dienst läuft, PID", os.getpid()); '
                       'print("geladen:", list(lib._SAVE_CACHE))'}
    elif args[0] == '--stop':
        req = {'stop': True}
    elif args[0] == '-c':
        req = {'code': ' '.join(args[1:])}
    else:
        req = {'script': args[0], 'args': args[1:]}
    try:
        res = send(req)
    except (OSError, ValueError) as e:
        if 'script' not in req:
            sys.exit('Dienst nicht erreichbar (%s) – mit "python dienst.py" im Hintergrund starten.' % e)
        print('(Dienst nicht erreichbar – führe direkt aus)', file=sys.stderr)
        sys.argv = [os.path.join(HERE, args[0])] + args[1:]
        runpy.run_path(sys.argv[0], run_name='__main__')
        return
    sys.stdout.write(res['output'])
    if 'seconds' in res:
        print('(%.2f s im Dienst)' % res['seconds'], file=sys.stderr)
    sys.exit(res['status'])


if __name__ == '__main__':
    main()
