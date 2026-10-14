#!/usr/bin/env python3
"""检验对比度计算、透明合成和独立检查的失败行为。"""
import contextlib
import importlib.util
import io
import sys
import unittest
from unittest.mock import patch
from pathlib import Path

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('visual_contract', Path(__file__).with_name('verify-visual-v2.py'))
visual = importlib.util.module_from_spec(spec)
spec.loader.exec_module(visual)


class VisualContractTests(unittest.TestCase):
    def test_black_white_contrast(self):
        self.assertAlmostEqual(visual.contrast_values([0, 0, 0], [1, 1, 1]), 21)

    def test_identical_colors_have_no_contrast(self):
        self.assertEqual(visual.contrast_values([.5, .5, .5], [.5, .5, .5]), 1)

    def test_opacity_composition(self):
        self.assertEqual(visual.composite([0, .5, 1], [1, 1, 1], 0), [1, 1, 1])
        self.assertEqual(visual.composite([0, .5, 1], [1, 1, 1], 1), [0, .5, 1])
        self.assertEqual(visual.composite([0, 0, 0], [1, 1, 1], .5), [.5, .5, .5])

    def test_secondary_text_fading_can_break_contrast(self):
        foreground = visual.rgb('ToolTextSecondary', False)
        background = visual.rgb('ToolSurface', False)
        self.assertGreaterEqual(visual.contrast_values(foreground, background), 4.5)
        self.assertLess(visual.contrast_values(visual.composite(foreground, background, .5), background), 4.5)

    def test_tinted_status_background_is_checked(self):
        for dark in (False, True):
            self.assertIn('36', visual.check_text(dark))

    def test_brand_failure_does_not_skip_color_or_doc_checks(self):
        output = io.StringIO()
        with patch.object(visual, 'check_brand', side_effect=AssertionError('测试注入')):
            with contextlib.redirect_stdout(output):
                result = visual.main()
        self.assertTrue(result)
        self.assertIn('FAIL 品牌隔离', output.getvalue())
        self.assertIn('PASS Light 正文', output.getvalue())
        self.assertIn('PASS Dark 正文', output.getvalue())
        self.assertIn('PASS 规范与资源', output.getvalue())

    def test_resource_drift_fails_documentation_check(self):
        original = visual.rgb
        def altered(name, dark):
            return [0, 0, 0] if name == 'ToolText' and not dark else original(name, dark)
        with patch.object(visual, 'rgb', side_effect=altered):
            with self.assertRaisesRegex(AssertionError, '规范与资源漂移'):
                visual.check_documentation()


if __name__ == '__main__':
    unittest.main()
