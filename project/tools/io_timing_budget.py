#!/usr/bin/env python3
"""Compute conditional connector budgets from TD paths, without declaring board signoff."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re


def number(value):
    value = float(value)
    if not math.isfinite(value):
        raise ValueError('Timing values must be finite')
    return value


def spi_half_period_ns(clock_hz, divider):
    clock_hz = number(clock_hz)
    if clock_hz <= 0 or isinstance(divider, bool) or not isinstance(divider, int) or not 0 <= divider <= 65535:
        raise ValueError('Invalid SPI clock/divider')
    return 1e9 * (divider + 2) / clock_hz


def sd_read_budget(half_ns, sck_launch_max, sck_output_max, capture_clock_min,
                   input_path_max, setup_max, uncertainty, card_tco):
    values = list(map(number, (half_ns, sck_launch_max, sck_output_max, capture_clock_min,
                               input_path_max, setup_max, uncertainty, card_tco)))
    if any(values[i] < 0 for i in (0, 2, 4, 5, 6, 7)):
        raise ValueError('Negative physical delay/requirement')
    # Conservative mixed-corner bound, with no CRPR credit. All clock delays
    # are relative to their nominal edge and the same board reference clock.
    available = values[0] + values[3] - sum(values[i] for i in (1, 2, 4, 5, 6))
    return {'card_tco_plus_pcb_roundtrip_max_ns': round(available, 3),
            'pcb_roundtrip_remaining_after_reference_card_ns': round(available-values[7], 3)}


def hdmi_limits(pixel_hz):
    pixel_hz = number(pixel_hz)
    if pixel_hz <= 0:
        raise ValueError('Invalid pixel clock')
    character = 1e9 / pixel_hz
    return {'character_ns': character, 'ui_ns': character / 10,
            'source_intrapair_limit_ns': character / 10 * .15,
            'source_interpair_limit_ns': character * .20}


def ddc_pullup_max_ohm(capacitance_pf, rise_limit_ns=1000):
    capacitance_pf, rise_limit_ns = number(capacitance_pf), number(rise_limit_ns)
    if min(capacitance_pf, rise_limit_ns) <= 0:
        raise ValueError('I2C capacitance/rise limit must be positive')
    return rise_limit_ns * 1000 / (.8473 * capacitance_pf)


def parse_paths(text):
    paths = []
    for block in re.split(r'(?m)^Slack\s+:', text)[1:]:
        head = block.split('Delay Type', 1)[0]
        fields = {k: re.search(r'(?m)^'+re.escape(k)+r'\s*:\s*(.*)', head)
                  for k in ('Begin Point', 'End Point', 'Check Type', 'Process', 'Data Path Delay')}
        if not all(fields.values()):
            continue
        item = {k: v[1].strip() for k, v in fields.items()}
        item['begin'] = item['Begin Point'].split(' (', 1)[0]
        item['end'] = item['End Point'].split(' (', 1)[0]
        item['data_ns'] = number(item['Data Path Delay'].split('ns')[0])
        item['slack_ns'] = number(block.split('ns')[0].strip())
        for edge in ('launch', 'capture'):
            match = re.search(r'(?m)^'+edge+r' edge\s+([-+0-9.]+)\s+[rf]\s+([-+0-9.]+)', block)
            if match:
                item[edge+'_clock_ns'] = number(match[2])-number(match[1])
        match = re.search(r'(?m)^setup\s+([-+0-9.]+)', block)
        item['setup_ns'] = abs(number(match[1])) if match else 0.0
        match = re.search(r'(?m)^hold\s+([-+0-9.]+)', block)
        item['hold_ns'] = abs(number(match[1])) if match else 0.0
        match = re.search(r'Clock Uncertainty\s*:\s*([-+0-9.]+)ns', head)
        item['uncertainty_ns'] = number(match[1]) if match else 0.0
        paths.append(item)
    return paths


def calculate(paths, input_origin_ns=1.0, output_origin_ns=1.0):
    miso = [p for p in paths if p['begin'] == 'sd_miso' and p['Check Type'] == 'setup']
    sck = [p for p in paths if p['end'] == 'sd_dclk' and p['Check Type'] == 'setup']
    outputs = ('HDMI_CLK_P', 'HDMI_D0_P', 'HDMI_D1_P', 'HDMI_D2_P')
    hdmi = {port: [p for p in paths if p['end'] == port and p['Check Type'] == 'setup'] for port in outputs}
    output_ports = ('sd_dclk', 'sd_mosi', 'sd_ncs') + outputs
    missing = []
    for port, endpoint in [('sd_miso', 'begin')] + [(p, 'end') for p in output_ports]:
        for kind in ('setup', 'hold'):
            if not any(p[endpoint] == port and p['Check Type'] == kind for p in paths):
                missing.append(port+' '+kind+' path')
    result = {'status': 'incomplete' if missing else 'conditional', 'missing': missing,
              'physical_signoff': False, 'card': {'brand': 'Netac', 'capacity_gb': 16,
                  'series': None, 'electrical_timing_verified': False},
              'scope': 'Routed FPGA delay budget plus protocol requirements; connector/PCB/card verification remains separate',
              'hdmi_requirements': hdmi_limits(25e6),
              'ddc_requirements': {'mode': 'Standard-mode', 'f_scl_max_hz': 100000,
                  'scl_low_min_ns': 4700, 'scl_high_min_ns': 4000,
                  'sda_setup_min_ns': 250, 'sda_hold_min_ns': 0,
                  'rise_max_ns': 1000, 'fall_max_ns': 300,
                  'actual_scl_waveform_verified': False, 'actual_bus_capacitance_pf': None}}
    envelopes = {}
    for port in output_ports:
        maximum = [p for p in paths if p['end'] == port and p['Check Type'] == 'setup']
        minimum = [p for p in paths if p['end'] == port and p['Check Type'] == 'hold']
        if maximum and minimum:
            envelopes[port] = {
                'launch_plus_output_max_ns': round(max(p['launch_clock_ns']+p['data_ns']-output_origin_ns for p in maximum),3),
                # The analysis-only minimum output coordinate is -0.001 ns.
                'launch_plus_output_min_ns': round(min(p['launch_clock_ns']+p['data_ns']+.001 for p in minimum),3),
                'reported_max_processes': sorted({p['Process'] for p in maximum}),
                'reported_min_processes': sorted({p['Process'] for p in minimum})}
    result['output_path_envelopes_ns'] = envelopes
    if miso and sck:
        data_in = max(p['data_ns']-input_origin_ns for p in miso)
        data_out = max(p['data_ns']-output_origin_ns for p in sck)
        all_miso = [p for p in paths if p['begin'] == 'sd_miso']
        capture = min(p['capture_clock_ns'] for p in all_miso)
        launch = max(p['launch_clock_ns'] for p in sck)
        setup = max(p['setup_ns'] for p in miso)
        reported_uncertainty = max(p['uncertainty_ns'] for p in miso)
        # TD virtual-clock paths default to zero, while this product's real
        # clock paths reserve 0.100 ns. Preserve that reserve in the budget.
        uncertainty = max(.100, reported_uncertainty)
        result['sd_fpga_terms_ns'] = {'input_path_max': round(data_in,3), 'sck_output_max': round(data_out,3),
             'capture_clock_min': round(capture,3), 'sck_launch_clock_max': round(launch,3),
             'setup_max': setup, 'uncertainty': uncertainty,
             'reported_virtual_clock_uncertainty': reported_uncertainty,
             'minimum_budget_uncertainty_from_product_sta': .100}
        result['sd_modes'] = {}
        for name, div, tco in (('initialization',248,50), ('transfer',1,14), ('legacy_25mhz',0,14)):
            half = spi_half_period_ns(100e6,div)
            result['sd_modes'][name] = {'divider':div,'half_period_ns':half,
                'frequency_hz':1e9/(half*2),'reference_card_tco_ns':tco,
                **sd_read_budget(half,launch,data_out,capture,data_in,setup,uncertainty,tco)}
            if 'sd_dclk' in envelopes and 'sd_mosi' in envelopes:
                sk, mo = envelopes['sd_dclk'], envelopes['sd_mosi']
                result['sd_modes'][name].update({
                    'pcb_mosi_minus_clock_setup_allowance_ns': round(half+sk['launch_plus_output_min_ns']-mo['launch_plus_output_max_ns']-5-uncertainty,3),
                    'pcb_clock_minus_mosi_hold_allowance_ns': round(half+mo['launch_plus_output_min_ns']-sk['launch_plus_output_max_ns']-5-uncertainty,3)})
            hold_paths = [p for p in all_miso if p['Check Type'] == 'hold']
            if hold_paths and 'sd_dclk' in envelopes:
                # Earliest next card transition occurs one half-cycle later.
                # Reference tCO(min)=0, PCB roundtrip=0: a positive trace delay
                # improves this bound. No CRPR credit is used.
                result['sd_modes'][name]['miso_hold_margin_at_zero_pcb_tco_min_ns'] = round(
                    half+envelopes['sd_dclk']['launch_plus_output_min_ns']
                    +min(p['data_ns']-.001 for p in hold_paths)
                    -max(p['capture_clock_ns'] for p in all_miso)
                    -max(p['hold_ns'] for p in hold_paths)-uncertainty,3)
    if all(hdmi.values()):
        # Comparison of reported digital paths, not an analog lane-skew result.
        arrivals = {port: max(p['launch_clock_ns']+p['data_ns']-output_origin_ns for p in rows)
                    for port, rows in hdmi.items()}
        spread = max(arrivals.values())-min(arrivals.values())
        result['hdmi_reported_paths'] = {'clock_plus_output_max_delay_ns': arrivals,
            'interpair_spread_ns': round(spread,3),
            'pcb_interpair_remaining_ns': round(result['hdmi_requirements']['source_interpair_limit_ns']-spread,3),
            'intrapair_skew_and_eye_verified': False,
            'limit': 'Reported maximum digital paths only; process labels are in the envelopes. Not measured skew or an analog eye check.'}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reports', type=Path, nargs='+', required=True)
    parser.add_argument('--input-origin-ns', type=float, default=1)
    parser.add_argument('--output-origin-ns', type=float, default=1)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Output must be new')
    records, hashes = [], {}
    for p in args.reports:
        raw = p.read_bytes()
        records += parse_paths(raw.decode('utf-8', errors='replace'))
        hashes[str(p.resolve())] = hashlib.sha256(raw).hexdigest()
    result = calculate(records, number(args.input_origin_ns), number(args.output_origin_ns))
    result['report_sha256'] = hashes
    result['reference_sources'] = {
      'sd_reference': 'Supplied SDSDv17.pdf pp36-37; reference contract only, not a Netac model-specific guarantee',
      'hdmi': 'https://ez.analog.com/video/a/documents/c/hdmi-faq/DO9240/hdmi-layout-guideline',
      'ddc': 'https://www.nxp.com/docs/en/user-guide/UM10204.pdf Table 11'}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(result, indent=2))
    return 1 if result['status'] == 'incomplete' else 0


if __name__ == '__main__':
    raise SystemExit(main())
