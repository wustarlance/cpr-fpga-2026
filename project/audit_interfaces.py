#!/usr/bin/env python3
"""Classify missing TD interface delays; never generate delays or waive findings."""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import re

REPO = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def role(port, top, external_io=False):
    if port.startswith(('ext_keys_n[', 'depth_sw_n[')):
        return 'configured_external_inputs_cdc_review' if external_io else 'inactive_external_io_default'
    if port.startswith('key_panel_n['):
        return 'key_panel_configuration_cdc_review'
    # SW4 now controls WAV playback in both tops, including top_adc.
    if port.startswith('dip_sw[') or port in ('key1', 'key2', 'key3'):
        return 'asynchronous_controls_cdc_review'
    if port == 'rst_n':
        return 'asynchronous_reset_release_review'
    if port.startswith(('led[', 'seg_data[', 'seg_sel[')):
        return 'human_visible_output_no_capture_clock'
    if port in ('sd_dclk', 'sd_mosi', 'sd_ncs', 'sd_miso'):
        return 'sd_spi_interface_timing_open'
    if port.startswith('HDMI_DDC_'):
        return 'hdmi_ddc_ip_timing_open'
    if port in ('HDMI_CLK_P', 'HDMI_D0_P', 'HDMI_D1_P', 'HDMI_D2_P'):
        return 'hdmi_tmds_serial_interface_timing_open'
    return 'unclassified'


def review_report(report, pins, top, external_io=False):
    result = {'missing_delay_ports': {}, 'dummy_models': {}}
    for number, direction in ((10, 'input'), (11, 'output')):
        section = re.search(rf'(?ms)^{number}\. checking no {direction} delay \(MEDIUM\).*?(?=^{number+1}\. checking)', report)
        if not section:
            raise ValueError(f'Missing {top} {direction} detail')
        names = re.findall(r'(?m)^\t(\S+)\s*$', section[0])
        declared = int(re.search(r'There are (\d+) .* ports', section[0])[1])
        if len(names) != declared or len(set(names)) != declared:
            raise ValueError(f'{top} {direction} detail count mismatch')
        entries = [{'port': n, 'pin': pins[n], 'classification': role(n, top, external_io)} for n in names]
        if any(e['classification'] == 'unclassified' for e in entries):
            raise ValueError('Unclassified interface')
        result['missing_delay_ports'][direction] = entries
    section = re.search(r'(?ms)^3\. checking dummy nodes.*?(?=^4\. checking)', report)
    if not section:
        raise ValueError('Missing dummy-node detail')
    for model, body in re.findall(r'(?ms)^DummyNode in Model: (\S+)\s*\n(.*?)(?=^DummyNode in Model:|\Z)', section[0]):
        nodes = re.findall(r'(?m)^\t(\S+)\s*$', body)
        if model in result['dummy_models']:
            raise ValueError('Duplicate dummy model')
        result['dummy_models'][model] = {'listed_pin_count': len(nodes), 'pins': nodes}
    declared = int(re.search(r'There are (\d+) nodes are dangling', section[0])[1])
    if declared != len(result['dummy_models']):
        raise ValueError('Dummy summary does not match model-group details')
    result['dummy_summary_count'] = declared
    result['dummy_summary_unit'] = 'model_groups_in_this_TD_report'
    result['dummy_listed_pin_count'] = sum(m['listed_pin_count'] for m in result['dummy_models'].values())
    result['classification_counts'] = {
        d: dict(collections.Counter(e['classification'] for e in entries))
        for d, entries in result['missing_delay_ports'].items()}
    result['unique_missing_delay_port_count'] = len({
        e['port'] for entries in result['missing_delay_ports'].values() for e in entries})
    result['status'] = 'needs_review'
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True, help='verify_* directory containing both tops')
    parser.add_argument('--output', type=Path, required=True, help='New JSON evidence file')
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Evidence output must be new')
    pins = {}
    pin_file = REPO / 'project/constraints/pin.adc'
    for line in pin_file.read_text(encoding='utf-8').splitlines():
        if line.lstrip().startswith('#'):
            continue
        match = re.search(r'set_pin_assignment\s*\{\s*(\S+)\s*\}\s*\{\s*LOCATION\s*=\s*(\w+)', line)
        if match:
            if match[1] in pins:
                raise ValueError('Duplicate pin constraint: ' + match[1])
            pins[match[1]] = match[2]
    result = {'scope': 'Default parameters parsed from each top; classification is not timing signoff',
              'evidence': str(args.evidence.resolve()), 'pin_file_sha256': sha(pin_file),
              'auditor_sha256': sha(Path(__file__)), 'reports': {}, 'source_sha256': {}}
    for top in ('top', 'top_adc'):
        path = args.evidence / top / 'timing_check.rpt'
        source = REPO / ('project/rtl/top_adc.v' if top == 'top_adc' else 'project/rtl/top/top_tf_hdmi_audio.v')
        match = re.search(r'parameter\s+USE_EXTERNAL_IO\s*=\s*([01])\b', source.read_text(encoding='utf-8'))
        if not match:
            raise ValueError('Cannot determine default USE_EXTERNAL_IO')
        manifest_path = args.evidence / 'results.json'
        if manifest_path.is_file():
            manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
            for current in (source, pin_file):
                recorded = manifest.get('sources', {}).get(current.relative_to(REPO).as_posix())
                if recorded is None or recorded != sha(current):
                    raise ValueError('Report/source configuration mismatch: ' + str(current))
        record = review_report(path.read_text(encoding='utf-8'), pins, top, match[1] == '1')
        record['default_use_external_io'] = int(match[1])
        record['report_sha256'] = sha(path)
        result['reports'][top] = record
    for name in ('project/rtl/top/top_tf_hdmi_audio.v', 'project/rtl/top_adc.v',
                 'project/rtl/input_filter.v', 'project/rtl/cpr_control.v',
                 'project/rtl/contrast_controls.v', 'project/rtl/reset_release.v',
                 'project/rtl/cpr_seg_scan.v', 'project/vendor/SD/spi_master.v',
                 'project/vendor/SD/sd_card_top.v',
                 'project/vendor/hdmi_lab/lane_lvds_10_1.v'):
        result['source_sha256'][name] = sha(REPO / name)
    result['status'] = 'needs_review'
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    for top, record in result['reports'].items():
        print(top, record['status'], record['classification_counts'])
        print('Dummy model groups:', record['dummy_summary_count'],
              'listed pins:', record['dummy_listed_pin_count'])
    # Nonzero means unresolved interface review, even though collection succeeded.
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
