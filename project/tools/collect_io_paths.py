#!/usr/bin/env python3
"""Read routed checkpoints and collect I/O delay coordinates; never synthesize or program."""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import subprocess

from io_timing_budget import calculate, parse_paths

PROJECT = Path(__file__).resolve().parents[1]
REPO = PROJECT.parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tcl_string(path):
    value = path.as_posix()
    if any(c in value for c in '{}\r\n'):
        raise ValueError('Unsupported Tcl path characters')
    return '{'+value+'}'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--td', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True, help='Fresh verify_* directory')
    parser.add_argument('--output', type=Path, required=True, help='New evidence directory')
    args = parser.parse_args()
    tool, output = args.td.resolve(), args.output.resolve()
    if output.exists():
        parser.error('Output must not exist')
    build = json.loads((args.evidence/'results.json').read_text(encoding='utf-8'))
    if sha(tool) != build['tool_sha256'] or not build['sources_unchanged']:
        raise ValueError('Tool/build input mismatch')
    if any(not (REPO/n).is_file() or sha(REPO/n) != digest for n,digest in build['sources'].items()):
        raise ValueError('Current design differs from build evidence')
    for top in ('top','top_adc'):
        run = next(r for r in build['results'] if r['top']==top)
        if not run['pass_marker'] or run['returncode'] != 0:
            raise ValueError(top+': fresh internal-timing build did not complete')
        if sha(PROJECT/f'build/{top}/{top}.bit') != run['bitstream_sha256']:
            raise ValueError(top+': current build outputs no longer match recorded bitgen')
        checkpoint = PROJECT/f'build/{top}/route.db'
        if not args.evidence.stat().st_ctime <= checkpoint.stat().st_mtime <= (args.evidence/'results.json').stat().st_mtime:
            raise ValueError(top+': route checkpoint is outside the recorded build interval')
    output.mkdir(parents=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    profile_dir = PROJECT/'build'/('io_coordinates_'+stamp)
    profile_dir.mkdir()
    record = {'scope': 'Post-route extraction only; analysis coordinate SDC is never used for bitgen',
              'input_max_coordinate_ns': 1, 'input_min_coordinate_ns': .001,
              'output_max_coordinate_ns': 1, 'output_min_coordinate_ns': -.001,
              'coordinate_explanation': 'Each interface port has a separate virtual reference clock so all max/min I/O paths are reported. 1 ns is an analysis coordinate, removed from data delay; it is not a board delay. Coordinate failures are expected, not product failures.',
              'tool_sha256': sha(tool), 'build_results_sha256': sha(args.evidence/'results.json'),
              'collector_sha256': sha(Path(__file__)),
              'budget_calculator_sha256': sha(Path(__file__).with_name('io_timing_budget.py')),
              'hardware_programmed': False, 'runs': []}
    for top in ('top','top_adc'):
        folder = output/top
        folder.mkdir()
        profile = profile_dir/(top+'.sdc')
        coordinates = ['# Analysis coordinates only. NOT board delays. NEVER use for bitgen.',
                       'create_clock -name cpr_io_miso_ref -period 10',
                       'set_input_delay -clock [get_clocks {cpr_io_miso_ref}] -max 1 [get_ports {sd_miso}]',
                       'set_input_delay -clock [get_clocks {cpr_io_miso_ref}] -min 0.001 [get_ports {sd_miso}]']
        for port in ('sd_dclk','sd_mosi','sd_ncs','HDMI_CLK_P','HDMI_D0_P','HDMI_D1_P','HDMI_D2_P'):
            clock = 'cpr_io_'+port+'_ref'
            period = 10 if port.startswith('sd_') else 8
            coordinates += [f'create_clock -name {clock} -period {period}',
                            f'set_output_delay -clock [get_clocks {{{clock}}}] -max 1 [get_ports {{{port}}}]',
                            f'set_output_delay -clock [get_clocks {{{clock}}}] -min -0.001 [get_ports {{{port}}}]']
        profile.write_text('\n'.join(coordinates)+'\n', encoding='utf-8')
        checkpoint = PROJECT/f'build/{top}/route.db'
        before = sha(checkpoint)
        script = folder/'extract.tcl'
        script.write_text(f'''cd {tcl_string(PROJECT)}
if {{[catch {{
    import_device eagle_s20.db -package EG4S20BG256
    open_project project.al -single_run
    import_db {tcl_string(checkpoint)}
    read_sdc constraints/timing.sdc
    read_sdc {tcl_string(profile.relative_to(PROJECT))}
    update_timing -mode final
    set cpr_io_output {tcl_string(folder)}
    report_timing_summary -ep_num 10 -file $cpr_io_output/all-paths.rpt
    if {{[llength [get_regs {{*MISO_shift*}}]] == 0}} {{error "No MISO capture registers"}}
    report_timing_path -to [get_regs {{*MISO_shift*}}] -ep_num 20 -path_num 100 -file $cpr_io_output/miso-paths.rpt
    check_timing -verbose -file $cpr_io_output/coordinate-check.rpt
    puts "CPR_IO_PATHS_DONE {top}"
}} cpr_error]}} {{puts stderr "CPR_IO_PATHS_FAILED $cpr_error";exit 1}}
exit
''', encoding='utf-8')
        process = subprocess.run([str(tool), script.as_posix()], cwd=folder,
                                 capture_output=True, timeout=180)
        raw = process.stdout+process.stderr
        (folder/'console.log').write_bytes(raw)
        if process.returncode != 0 or f'CPR_IO_PATHS_DONE {top}'.encode() not in raw or sha(checkpoint) != before:
            raise ValueError(top+': I/O extraction failed or checkpoint changed')
        paths = []
        for name in ('all-paths.rpt','miso-paths.rpt'):
            paths += parse_paths((folder/name).read_text(encoding='utf-8'))
        budget = calculate(paths)
        if budget['status'] == 'incomplete':
            raise ValueError(top+': missing I/O paths: '+str(budget['missing']))
        (folder/'budget.json').write_text(json.dumps(budget,indent=2)+'\n',encoding='utf-8')
        record['runs'].append({'top': top, 'checkpoint_sha256': before,
            'checkpoint_unchanged': True, 'budget': budget,
            'analysis_profile_sha256': sha(profile),
            'artifacts_sha256': {p.name:sha(p) for p in folder.iterdir() if p.is_file()}})
        print(top+': I/O coordinates collected; physical_signoff=False',flush=True)
    record['tool_unchanged'] = sha(tool) == record['tool_sha256']
    (output/'manifest.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
    return 0


if __name__=='__main__':
    raise SystemExit(main())
