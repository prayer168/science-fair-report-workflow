"""Check the rendered science-fair report against its fixed 30-page ceiling."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

from pypdf import PdfReader

LIMIT = 30
ALLOWED_REASONS = {"封面", "封底", "目錄"}


def check(pdf, exclusions=None, rules_source=None):
    pdf = Path(pdf)
    data = pdf.read_bytes()
    reader = PdfReader(pdf)
    total = len(reader.pages)
    if not total:
        raise ValueError("PDF has no pages")
    if exclusions is None:
        exclusions = {}
    if not isinstance(exclusions, dict):
        raise ValueError("Exclusions must be a JSON object of one-based page numbers to reasons")
    if exclusions and not (rules_source and rules_source.strip()):
        raise ValueError("Excluded pages require a verified official rules source")
    normalized = {}
    for page, reason in exclusions.items():
        if not str(page).isdigit() or str(int(page)) != str(page):
            raise ValueError("Use canonical one-based page numbers without ranges or leading zeros")
        number = int(page)
        if not 1 <= number <= total or reason not in ALLOWED_REASONS:
            raise ValueError("Only existing cover, back-cover, or contents pages may be excluded")
        normalized[str(number)] = reason
    counted = total - len(normalized)
    if counted < 1:
        raise ValueError("At least one report page must remain counted")
    return {
        "pdf": str(pdf.resolve()),
        "pdf_sha256": hashlib.sha256(data).hexdigest(),
        "total_pages": total,
        "excluded_pages": normalized,
        "official_rules_source": rules_source,
        "counted_pages": counted,
        "maximum_pages": LIMIT,
        "passed": counted <= LIMIT,
        "over_by": max(0, counted - LIMIT),
        "exclusion_review": "Caller must verify that every excluded physical page actually matches its stated reason.",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pdf", type=Path)
    parser.add_argument("--excluded-pages-json", type=Path,
                        help='JSON object such as {"1":"封面"}; no other reasons are accepted')
    parser.add_argument("--rules-source", help="Verified official URL or document citation supporting exclusions")
    parser.add_argument("--report-json", type=Path)
    args = parser.parse_args()
    try:
        exclusions = json.loads(args.excluded_pages_json.read_text(encoding="utf-8-sig")) if args.excluded_pages_json else {}
        report = check(args.pdf, exclusions, args.rules_source)
        output = json.dumps(report, ensure_ascii=False, indent=2)
        if args.report_json:
            args.report_json.write_text(output + "\n", encoding="utf8")
        print(output)
        return 0 if report["passed"] else 2
    except Exception as exc:
        print(f"Page check could not complete: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
