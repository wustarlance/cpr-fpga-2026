"""Reject incomplete interface inventories and keep TD group counts distinct from pins."""
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'project'))
from audit_interfaces import review_report


def fixture():
    return '''3. checking dummy nodes (HIGH)
There are 2 nodes are dangling
DummyNode in Model: LSLICE
\tu_logic.a
\tu_logic.b
DummyNode in Model: PAD
\tu_pad.opad
4. checking invalid constraints (HIGH)
10. checking no input delay (MEDIUM)
There are 1 input ports
\tHDMI_DDC_SDA
11. checking no output delay (MEDIUM)
There are 1 output ports
\tHDMI_DDC_SDA
12. checking partial input delay (MEDIUM)
'''


class InterfaceAuditTests(unittest.TestCase):
    def test_model_groups_are_not_pin_counts(self):
        record = review_report(fixture(), {'HDMI_DDC_SDA': 'R2'}, 'top')
        self.assertEqual(record['dummy_summary_count'], 2)
        self.assertEqual(record['dummy_listed_pin_count'], 3)
        self.assertEqual(record['status'], 'needs_review')

    def test_inout_port_is_not_counted_twice(self):
        record = review_report(fixture(), {'HDMI_DDC_SDA': 'R2'}, 'top')
        self.assertEqual(record['unique_missing_delay_port_count'], 1)

    def test_missing_model_group_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'model-group'):
            review_report(fixture().replace('There are 2 nodes', 'There are 3 nodes'),
                          {'HDMI_DDC_SDA': 'R2'}, 'top')

    def test_missing_port_detail_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'detail count mismatch'):
            review_report(fixture().replace('There are 1 input', 'There are 2 input'),
                          {'HDMI_DDC_SDA': 'R2'}, 'top')

    def test_unknown_interface_cannot_be_silently_classified(self):
        with self.assertRaisesRegex(ValueError, 'Unclassified'):
            review_report(fixture().replace('HDMI_DDC_SDA', 'unknown_io'),
                          {'unknown_io': 'R2'}, 'top')


if __name__ == '__main__':
    unittest.main()
