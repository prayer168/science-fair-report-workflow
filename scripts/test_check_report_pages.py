import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from pypdf import PdfWriter
from check_report_pages import check


class PageLimitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def pdf(self, count):
        path = self.root / f"{count}.pdf"
        writer = PdfWriter()
        for _ in range(count):
            writer.add_blank_page(width=595, height=842)
        writer.write(path)
        return path

    def test_thirty_passes_and_thirty_one_fails(self):
        self.assertTrue(check(self.pdf(30))["passed"])
        result = check(self.pdf(31))
        self.assertFalse(result["passed"])
        self.assertEqual(result["over_by"], 1)

    def test_excluded_cover_counts_against_exact_boundary(self):
        self.assertTrue(check(self.pdf(31), {"1": "封面"}, "official rules")["passed"])
        self.assertFalse(check(self.pdf(32), {"1": "封面"}, "official rules")["passed"])

    def test_unverified_or_invalid_exclusions_are_rejected(self):
        pdf = self.pdf(31)
        for exclusions, source in [({"1": "封面"}, None), ({"31": "參考文獻"}, "rules"),
                                   ({"32": "目錄"}, "rules"), ({"01": "封面"}, "rules")]:
            with self.subTest(exclusions=exclusions, source=source):
                with self.assertRaises(ValueError):
                    check(pdf, exclusions, source)

    def test_cli_fails_and_persists_report_when_over_limit(self):
        report = self.root / "report.json"
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("check_report_pages.py")),
                                 str(self.pdf(31)), "--report-json", str(report)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        saved = json.loads(report.read_text(encoding="utf8"))
        self.assertFalse(saved["passed"])
        self.assertEqual(saved["counted_pages"], 31)


if __name__ == "__main__":
    unittest.main()
