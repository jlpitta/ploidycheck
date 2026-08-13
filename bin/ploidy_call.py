#!/usr/bin/env python3
# By João Pitta (jlpitta82@gmail.com) and Beatriz Toscano (beatriz.melo@fiocruz.br)
# At Fiocruz-PE
"""Combine GenomeScope2 + Smudgeplot output into a single ploidy/heterozygosity call.

Neither tool alone is reliable at the low k-mer coverage typical of small test
datasets (~11-12x): Smudgeplot's own suggested -L cutoff can shift the inferred
1n coverage ~2x off from GenomeScope2's kmercov while still reporting a
misleadingly "clean" dominant AB smudge (validated manually against the
saccharomyces_cerevisiae_synthetic/heterozygous test datasets — see README).
So heterozygosity is only called when BOTH signals agree: the AB smudge is a
majority of the mass, AND Smudgeplot's inferred coverage is close to
GenomeScope2's kmercov.
"""
import argparse
import json
import re


def parse_genomescope_kmercov(model_path):
    with open(model_path) as f:
        for line in f:
            m = re.match(r"^kmercov\s+([0-9.eE+-]+)", line)
            if m:
                return float(m.group(1))
    raise ValueError(f"kmercov not found in {model_path}")


def parse_smudgeplot_report(report_path):
    with open(report_path) as f:
        data = json.load(f)
    haploid_coverage = data.get("haploid_coverage")
    ab_fraction = 0.0
    for smudge in data.get("smudges", []):
        if smudge.get("structure") == "AB":
            ab_fraction = smudge.get("fraction", 0.0)
            break
    return haploid_coverage, ab_fraction


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sample", required=True)
    ap.add_argument("--genomescope-model", required=True, help="GenomeScope2 <prefix>_model.txt")
    ap.add_argument("--smudgeplot-json", required=True, help="Smudgeplot --json_report output")
    ap.add_argument("--ab-fraction-threshold", type=float, default=0.5)
    ap.add_argument("--coverage-tolerance", type=float, default=0.3)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    gs2_kmercov = parse_genomescope_kmercov(args.genomescope_model)
    smudge_coverage, ab_fraction = parse_smudgeplot_report(args.smudgeplot_json)

    coverage_relative_error = None
    coverage_agrees = False
    if smudge_coverage is not None and gs2_kmercov:
        coverage_relative_error = abs(smudge_coverage - gs2_kmercov) / gs2_kmercov
        coverage_agrees = coverage_relative_error <= args.coverage_tolerance

    ab_dominant = ab_fraction >= args.ab_fraction_threshold
    heterozygous_detected = bool(ab_dominant and coverage_agrees)

    data = {
        "sample": args.sample,
        "genomescope_kmercov": gs2_kmercov,
        "smudgeplot_haploid_coverage": smudge_coverage,
        "smudgeplot_ab_fraction": ab_fraction,
        "coverage_relative_error": coverage_relative_error,
        "ab_fraction_threshold": args.ab_fraction_threshold,
        "coverage_tolerance": args.coverage_tolerance,
        "ab_dominant": ab_dominant,
        "coverage_agrees": coverage_agrees,
        "heterozygous_detected": heterozygous_detected,
    }

    with open(args.out, "w") as f:
        json.dump(data, f, indent=2)


if __name__ == "__main__":
    main()
