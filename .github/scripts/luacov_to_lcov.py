#!/usr/bin/env python3
"""Convert luacov.report.out to LCOV format for Datadog Code Coverage upload.

Background:
  - pongo runs tests inside a Docker container mounted at /kong-plugin/
  - luacov generates luacov.report.out with container-absolute paths (SF:/kong-plugin/...)
  - Datadog's coverage upload requires LCOV format; we pass base-path=/kong-plugin
    so the tool strips the container prefix and resolves paths relative to the repo root

luacov.report.out format (per section):
  ======...======   (separator, 30+ = signs)
  /path/to/file.lua
  ======...======
     N source line  (hit count N, or ***0 for unexecuted)
     ...
"""
import re
import sys

INPUT = "luacov.report.out"
OUTPUT = "coverage.lcov"

try:
    with open(INPUT) as f:
        content = f.read()
except FileNotFoundError:
    print(f"Error: {INPUT} not found", file=sys.stderr)
    sys.exit(1)

sections = re.split(r"(?m)^={30,}\n", content)
lcov = []
i = 1
while i < len(sections):
    fname = sections[i].strip()
    if not fname:
        i += 1
        continue
    i += 1
    data = sections[i] if i < len(sections) else ""
    lcov.append(f"SF:{fname}")
    lf = lh = 0
    line_no = 1
    for line in data.splitlines():
        m = re.match(r"^(\*{3}0|\s*(\d+))\s", line)
        if m:
            hits_str = m.group(1).strip()
            hits = 0 if hits_str.startswith("*") else int(hits_str)
            lcov.append(f"DA:{line_no},{hits}")
            lf += 1
            if hits > 0:
                lh += 1
        line_no += 1
    lcov.extend([f"LF:{lf}", f"LH:{lh}", "end_of_record"])
    i += 1

with open(OUTPUT, "w") as f:
    f.write("\n".join(lcov) + "\n")

n_files = sum(1 for l in lcov if l.startswith("SF:"))
print(f"Converted {n_files} files to LCOV → {OUTPUT}")
