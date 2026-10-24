"""Budget arithmetic and failure controls; fixture numbers are not board measurements."""
import importlib.util
from pathlib import Path
import unittest

p = Path(__file__).resolve().parents[1]/'project/tools/io_timing_budget.py'
spec = importlib.util.spec_from_file_location('io_timing_budget',p)
budget = importlib.util.module_from_spec(spec)
spec.loader.exec_module(budget)


class BudgetTests(unittest.TestCase):
    def complete_paths(self):
        rows = []
        for port in ('sd_dclk','sd_mosi','sd_ncs','HDMI_CLK_P','HDMI_D0_P','HDMI_D1_P','HDMI_D2_P'):
            for kind, data, clock in (('setup',5.0,3.0),('hold',3.999,2.5)):
                rows.append({'begin':'output_reg','end':port,'Check Type':kind,
                             'Process':'slow' if kind=='setup' else 'fast',
                             'data_ns':data,'launch_clock_ns':clock})
        for kind, data in (('setup',4.0),('hold',2.001)):
            rows.append({'begin':'sd_miso','end':'capture','Check Type':kind,
                         'Process':'slow' if kind=='setup' else 'fast','data_ns':data,
                         'capture_clock_ns':2.0,'setup_ns':.1,'hold_ns':.05,'uncertainty_ns':.1})
        return rows

    def test_both_spi_modes(self):
        self.assertEqual(budget.spi_half_period_ns(100e6,248),2500)
        self.assertEqual(budget.spi_half_period_ns(100e6,0),20)
        self.assertEqual(budget.spi_half_period_ns(100e6,1),30)

    def test_read_equation_accounts_for_clock_skew_and_all_costs(self):
        r=budget.sd_read_budget(20,3,4,2,2,0.1,0.1,14)
        self.assertAlmostEqual(r['card_tco_plus_pcb_roundtrip_max_ns'],12.8)
        self.assertAlmostEqual(r['pcb_roundtrip_remaining_after_reference_card_ns'],-1.2)

    def test_negative_margin_is_not_clamped_to_pass(self):
        r=budget.sd_read_budget(20,3,4,2,2,0.1,0.1,20)
        self.assertLess(r['pcb_roundtrip_remaining_after_reference_card_ns'],0)

    def test_hdmi_ui_and_pair_limits_are_distinct(self):
        r=budget.hdmi_limits(25e6)
        self.assertEqual(r['ui_ns'],4)
        self.assertAlmostEqual(r['source_intrapair_limit_ns'],0.6)
        self.assertEqual(r['source_interpair_limit_ns'],8)

    def test_rc_rise_budget(self):
        self.assertAlmostEqual(budget.ddc_pullup_max_ohm(100),11802.1952,places=3)

    def test_invalid_or_nonfinite_inputs_are_rejected(self):
        for f,args in ((budget.spi_half_period_ns,(0,0)),(budget.spi_half_period_ns,(1e8,-1)),
                       (budget.hdmi_limits,(float('nan'),)),(budget.ddc_pullup_max_ohm,(0,))):
            with self.assertRaises(ValueError):f(*args)

    def test_missing_paths_cannot_be_complete(self):
        r=budget.calculate([])
        self.assertEqual(r['status'],'incomplete')
        self.assertFalse(r['physical_signoff'])

    def test_missing_minimum_path_is_not_complete(self):
        rows = [p for p in self.complete_paths() if not (p['end']=='sd_ncs' and p['Check Type']=='hold')]
        r = budget.calculate(rows)
        self.assertEqual(r['missing'],['sd_ncs hold path'])
        self.assertEqual(r['status'],'incomplete')

    def test_coordinate_removal_and_output_edge_budgets(self):
        r = budget.calculate(self.complete_paths())
        self.assertEqual(r['status'],'conditional')
        self.assertFalse(r['physical_signoff'])
        self.assertEqual(r['sd_fpga_terms_ns']['input_path_max'],3)
        self.assertEqual(r['output_path_envelopes_ns']['sd_dclk']['launch_plus_output_min_ns'],6.5)
        mode = r['sd_modes']['transfer']
        self.assertAlmostEqual(mode['pcb_mosi_minus_clock_setup_allowance_ns'],24.4)
        self.assertAlmostEqual(mode['miso_hold_margin_at_zero_pcb_tco_min_ns'],36.35)

    def test_virtual_clock_zero_does_not_erase_product_uncertainty(self):
        rows = self.complete_paths()
        for p in rows:
            if p['begin']=='sd_miso':p['uncertainty_ns']=0
        r = budget.calculate(rows)
        self.assertEqual(r['sd_fpga_terms_ns']['uncertainty'],.1)

    def test_crlf_report_fields_are_normalized(self):
        text=('Slack : 1.000ns\r\nBegin Point : sd_miso (rising edge)\r\n'
              'End Point : capture (rising edge)\r\nCheck Type : setup\r\n'
              'Process : slow\r\nData Path Delay : 103.000ns\r\n'
              'Delay Type Location\r\nlaunch edge 0.000 r 1.000\r\n'
              'capture edge 10.000 r 12.000\r\nsetup -0.100\r\n')
        r=budget.parse_paths(text)
        self.assertEqual(r[0]['Check Type'],'setup')
        self.assertEqual(r[0]['capture_clock_ns'],2)


if __name__=='__main__':unittest.main()
