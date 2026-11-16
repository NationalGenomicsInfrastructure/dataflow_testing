#!/usr/bin/env python3
"""Compare the demux pipeline's FASTQs with the expected ones.

Each test runfolder ships <runfolder>/Demultiplexing/ with the FASTQs the
BCLs were generated from. This compares them with what nf-core/demultiplex
wrote under <results-root>/<FCID>/, file by file: same read count and same
sorted sequence lines. Headers and qualities are ignored (same rule as
BioMate/assets/compare_results.sh).

Files are matched on (sample name, lane, read); the directory layout and
the _S<n> number are ignored, since the realm runs BCL Convert once per
lane and numbers samples per lane. Index-read FASTQs (I1/I2) have no
expectation and are skipped.

Undetermined FASTQs are NOT checked: nf-core/demultiplex does not publish
them to the results directory, and BCL Convert writes them at full cycle
length while the expected ones are trimmed per OverrideCycles.

Runs inside the yggdrasil container: make compose-check-demux
"""

import argparse
import gzip
import re
import sys
from pathlib import Path

FASTQ_RE = re.compile(r"^(.+)_S\d+_(L\d{3})_([RI][12])_001\.fastq\.gz$")


def die(msg):
    print(f"check_demux_results: {msg}", file=sys.stderr)
    sys.exit(1)


def fastq_key(name):
    m = FASTQ_RE.match(name)
    return m.groups() if m else None


def sequences(path):
    with gzip.open(path, "rt") as fh:
        return sorted(line.rstrip("\n") for i, line in enumerate(fh) if i % 4 == 1)


def index_fastqs(root, errors, side):
    """Map (name, lane, read) -> path for every sample R1/R2 FASTQ under root."""
    found, skipped = {}, 0
    for path in sorted(root.rglob("*.fastq.gz")):
        key = fastq_key(path.name)
        if key is None:
            errors.append(f"{side}: unrecognised FASTQ name {path}")
        elif key[0] == "Undetermined":
            pass  # not checked, see module docstring
        elif key[2].startswith("I"):
            skipped += 1
        elif key in found:
            errors.append(f"{side}: duplicate {'_'.join(key)}: {found[key]} and {path}")
        else:
            found[key] = path
    return found, skipped


def check_flowcell(runfolder, results_root):
    """Return (flowcell id, files matched, files expected, errors)."""
    fcid = runfolder.name.rsplit("_", 1)[-1]
    expected_dir = runfolder / "Demultiplexing"
    errors = []
    expected, _ = index_fastqs(expected_dir, errors, "expected")
    results = results_root / fcid
    if not results.is_dir():
        return fcid, 0, len(expected), [f"no results directory {results}"]
    actual, skipped = index_fastqs(results, errors, "actual")
    if skipped:
        print(f"{fcid}: skipped {skipped} index-read FASTQs (no expectation)")

    matched = 0
    for key in sorted(expected.keys() | actual.keys()):
        label = "_".join(key)
        if key not in actual:
            errors.append(f"missing in results: {label}")
        elif key not in expected:
            errors.append(f"unexpected in results: {label} ({actual[key]})")
        else:
            exp, act = sequences(expected[key]), sequences(actual[key])
            if len(exp) != len(act):
                errors.append(f"read count: {label}: expected {len(exp)}, got {len(act)}")
            elif exp != act:
                diff = sum(a != b for a, b in zip(exp, act))
                errors.append(f"sequences differ: {label}: {diff} of {len(exp)} (sorted)")
            else:
                matched += 1
    return fcid, matched, len(expected), errors


def self_test():
    assert fastq_key("P38454_1001_S1_L001_R1_001.fastq.gz") == ("P38454_1001", "L001", "R1")
    assert fastq_key("Undetermined_S0_L004_R2_001.fastq.gz") == ("Undetermined", "L004", "R2")
    assert fastq_key("A_S1_B_S13_L003_I2_001.fastq.gz") == ("A_S1_B", "L003", "I2")
    assert fastq_key("reads.fastq.gz") is None
    print("self-test ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("flowcells", nargs="*", help="flowcell ids (default: all)")
    ap.add_argument("--expected-root", type=Path, default=Path("/Illumina/NextSeq"))
    ap.add_argument("--results-root", type=Path, default=Path("/work/nf-realm-results"))
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()

    runfolders = sorted(p.parent for p in args.expected_root.glob("*/Demultiplexing"))
    if not runfolders:
        die(f"no */Demultiplexing under {args.expected_root}")
    if args.flowcells:
        by_fcid = {r.name.rsplit("_", 1)[-1]: r for r in runfolders}
        for f in args.flowcells:
            if f not in by_fcid:
                die(f"no runfolder for flowcell {f} under {args.expected_root}")
        runfolders = [by_fcid[f] for f in args.flowcells]

    failed = False
    for runfolder in runfolders:
        fcid, matched, total, errors = check_flowcell(runfolder, args.results_root)
        for e in errors:
            print(f"{fcid}: FAIL {e}")
        print(f"{fcid}: {matched}/{total} files match" + ("" if not errors else " - FAILED"))
        failed = failed or bool(errors)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
