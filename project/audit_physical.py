#!/usr/bin/env python3
"""Collect PLL/SDRAM route evidence without rebuilding or programming hardware."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

PROJECT = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--td', type=Path, required=True)
    parser.add_argument('--tops', nargs='+', choices=('top', 'top_adc'), default=['top', 'top_adc'])
    parser.add_argument('--output', type=Path, required=True, help='New evidence directory')
    parser.add_argument('--timeout', type=int, default=180)
    args = parser.parse_args()
    tool, output = args.td.resolve(), args.output.resolve()
    script = PROJECT / 'audit_physical.tcl'
    if not tool.is_file() or args.timeout <= 0 or len(set(args.tops)) != len(args.tops):
        parser.error('Provide a TD executable, positive timeout and unique tops')
    if output.exists():
        parser.error('Output must be a new directory')
    for top in args.tops:
        if not (PROJECT / f'build/{top}/route.db').is_file():
            parser.error(f'{top}: run a full build first; routed checkpoint missing')
    output.mkdir(parents=True)
    record = {'recorded_utc': dt.datetime.now(dt.timezone.utc).isoformat(),
              'tool': str(tool), 'tool_sha256': sha(tool), 'script_sha256': sha(script),
              'project_sha256': sha(PROJECT / 'project.al'),
              'scope': 'Read-only checkpoint queries; completion does not waive critical warnings',
              'hardware_programmed': False, 'runs': []}
    for top in args.tops:
        folder = output / top
        folder.mkdir()
        checkpoint = PROJECT / f'build/{top}/route.db'
        before = sha(checkpoint)
        code, timed_out = None, False
        command = [str(tool), script.as_posix()]
        try:
            process = subprocess.run(command, cwd=folder, capture_output=True, timeout=args.timeout,
                                     env=dict(os.environ, CPR_TOP=top, CPR_AUDIT_OUTPUT=folder.as_posix()))
            raw, code = process.stdout + process.stderr, process.returncode
        except subprocess.TimeoutExpired as error:
            raw = (error.stdout or b'') + (error.stderr or b'') + b'\nAUDIT_TIMEOUT\n'
            timed_out = True
        except OSError as error:
            raw = str(error).encode('utf-8')
        (folder / 'audit.log').write_bytes(raw)
        log = raw.decode('utf-8', errors='replace')
        unchanged = before == sha(checkpoint)
        complete = (code == 0 and not timed_out and unchanged and
                    f'CPR_PHYSICAL_AUDIT_DONE {top}' in log and (folder / 'routed.pnl').is_file())
        record['runs'].append({'top': top, 'command': command, 'returncode': code,
                               'timed_out': timed_out, 'audit_complete': complete,
                               'checkpoint_sha256': before, 'checkpoint_unchanged': unchanged,
                               'critical_diagnostics': [line for line in log.splitlines()
                                   if re.search(r'\b(?:ERROR|FATAL)\b|CRITICAL-WARNING', line)],
                               'artifacts': {p.name: sha(p) for p in folder.iterdir() if p.is_file()}})
        print(f'{top}: audit_complete={complete}; findings retained, no timing signoff')
    record['tool_unchanged'] = record['tool_sha256'] == sha(tool)
    record['project_unchanged'] = record['project_sha256'] == sha(PROJECT / 'project.al')
    record['audit_complete'] = (all(r['audit_complete'] for r in record['runs']) and
                                record['tool_unchanged'] and record['project_unchanged'])
    (output / 'manifest.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
    return 0 if record['audit_complete'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
