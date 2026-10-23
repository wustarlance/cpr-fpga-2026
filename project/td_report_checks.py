#!/usr/bin/env python3
"""Audit TD check_timing coverage; positive slack alone is insufficient."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re


def review_timing_check(report: str, top: str) -> dict:
    checks = {int(n): {"name": name.strip(), "count": int(count), "severity": level}
              for n, name, count, level in re.findall(
                  r"(?m)^(\d+)\. checking (.+?)\((\d+)\) \((HIGH|MEDIUM)\)\s*$", report)}
    blocking, review = [], []
    if set(checks) != set(range(1, 15)):
        blocking.append("Missing or unrecognized check_timing summary sections")
    for number in (1, 2, 4, 6, 7, 8, 9, 12, 13):
        if checks.get(number, {}).get("count", 0):
            blocking.append(f"{checks[number]['name']}: {checks[number]['count']}")
    # Section 5 counts the PLLs examined, not the number of failed PLL checks.
    for count, problem in re.findall(
            r"There are (\d+) (clock pins that have no clock constraints|"
            r"clocks whose clock frequency do not match the PLL setting)", report):
        if int(count):
            blocking.append(f"{problem}: {count}")
    for number in (3, 10, 11, 14):
        if checks.get(number, {}).get("count", 0):
            review.append(f"{checks[number]['name']}: {checks[number]['count']}")
    rows = [{"total": int(total), "dominated": int(dominated),
             "shadowed": int(shadowed), "ignored": int(ignored), "constraint": command.strip()}
            for total, dominated, shadowed, ignored, command in re.findall(
                r"(?m)^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(set_max_delay[^\r\n]+)", report)]
    fifo_rows = [row for row in rows if "primary_addr_gray_reg" in row["constraint"]]
    for delay in ("24.700", "9.700"):
        matching = [row for row in fifo_rows if re.search(
            rf"\b{re.escape(delay)}\b", row["constraint"])]
        if not matching or not any(row["total"] > 0 for row in matching):
            blocking.append(f"Missing active frame FIFO Gray bound {delay} ns")
        elif any(row["total"] != row["dominated"] or row["ignored"] or row["shadowed"]
                 for row in matching):
            blocking.append(f"Frame FIFO Gray bound {delay} ns is overridden or inactive")
    for endpoint in (["u_page_status/u_transfer"] + (["u_mailbox"] if top == "top_adc" else [])):
        matching = [row for row in rows if endpoint in row["constraint"]]
        if not matching or not any(row["total"] > 0 and row["dominated"] == row["total"]
                                   and not row["ignored"] and not row["shadowed"]
                                   for row in matching):
            blocking.append(f"No active coherent mailbox bound for {endpoint}")
    return {"status": "failed" if blocking else "needs_review" if review else "passed",
            "blocking_findings": blocking, "review_findings": review,
            "checks": checks, "max_delay_rows": rows,
            "scope": "report coverage only; manual interface, CDC and physical review still required"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", type=Path, required=True)
    parser.add_argument("--top", choices=("top", "top_adc"), required=True)
    parser.add_argument("--output", type=Path, required=True, help="New JSON evidence file")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Output file already exists; use a new evidence filename")
    raw = args.check.read_bytes()
    result = review_timing_check(raw.decode("utf-8", errors="replace"), args.top)
    result.update(top=args.top, check_file=str(args.check.resolve()),
                  check_sha256=hashlib.sha256(raw).hexdigest(),
                  checker_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"{args.top}: {result['status']}; blocking={len(result['blocking_findings'])}; "
          f"review={len(result['review_findings'])}")
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
