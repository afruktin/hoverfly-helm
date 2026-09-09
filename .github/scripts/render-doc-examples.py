#!/usr/bin/env python3
"""Render every values example in the chart README against the chart.

Documentation drifts silently: a value gets renamed, a new validation starts
rejecting a combination, and the example that used to work now fails only in a
reader's terminal. Extracting the yaml blocks and templating each one turns that
into a failing build instead.

Every ```yaml block in charts/hoverfly/README.md is a values example -- prose and
shell go in other fence types -- so all of them are rendered, not just the ones
under Scenarios.
"""
import pathlib
import re
import subprocess
import sys
import tempfile

CHART = "charts/hoverfly"
README = pathlib.Path(CHART) / "README.md"

blocks = re.findall(r"```yaml\n(.*?)```", README.read_text(encoding="utf-8"), re.S)
if not blocks:
    sys.exit(f"no yaml examples found in {README} -- the extraction is broken")

failed = 0
with tempfile.TemporaryDirectory() as tmp:
    for index, block in enumerate(blocks, 1):
        values = pathlib.Path(tmp) / f"example-{index}.yaml"
        values.write_text(block, encoding="utf-8")
        result = subprocess.run(
            ["helm", "template", "rel", CHART, "--values", str(values)],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            print(f"  ok   example {index}")
            continue
        failed += 1
        print(f"  FAIL example {index}")
        for line in block.strip().splitlines():
            print(f"       | {line}")
        for line in result.stderr.strip().splitlines():
            print(f"       {line}")

print(f"\n{len(blocks)} example(s) in {README}, {failed} failed")
sys.exit(1 if failed else 0)
