# ploidycheck

Calls heterozygosity/polyploidy in an organism from short reads, using only the k-mer profile (no assembly, no reference genome). Extracted from the polyploidy module originally built inside [fungiflow](https://github.com/jlpitta/fungiflow), now as a standalone tool reusable by any pipeline — including [fungiflow](https://github.com/jlpitta/fungiflow) itself and [checkw](https://github.com/jlpitta/checkw), which now call it as an external dependency instead of reimplementing the logic.

## Why this exists

Genome quality assessment tools designed for bacteria (e.g. CheckM2) assume a haploid genome. When applied to a heterozygous/polyploid organism, allelic variants of the same gene on divergent copies are easily mistaken for contamination (multiple "near-identical" copies of a gene that should be single-copy). Before deciding whether a sample is contaminated, it helps to know whether it's polyploid/heterozygous in the first place — that's the only question `ploidycheck` answers.

It does not assemble the genome or perform any taxonomic inference: it only looks at the k-mer frequency distribution in the reads and decides, using an empirically validated criterion, whether there is a signal of heterozygosity.

## How it works

A 4-step pipeline, each step delegated to an established tool:

```
short reads (R1/R2)
   │
   ▼
FastK + Histex   → k-mer frequency histogram (k=21 by default)
   │
   ├─────────────────────────┐
   ▼                          ▼
GenomeScope2               Smudgeplot
(global heterozygosity,    (ploidy structure via pairs
 kmercov)                   of heterozygous k-mers — AB,
   │                         AAB, AABB, ...)
   │                          │
   └────────────┬─────────────┘
                ▼
        ploidy_call.py
   (combines both signals into a single verdict)
                │
                ▼
   <sample>.ploidy_call.json
```

### The decision criterion — and why it exists

Neither tool alone is reliable at the typically low k-mer coverage range (~11-12x) of the validation datasets used here:

- The `-L` cutoff that `smudgeplot cutoff` itself suggests automatically (~10, on these datasets) inflates the inferred 1n coverage by almost 2x relative to the actual GenomeScope2 `kmercov`, while keeping a deceptively "clean" AB smudge — in other words, the tool's suggested value produces a *more* convincing false positive, not less.
- Lower `-L` values recover the correct signal. `-L 7` gave the cleanest result in testing and is the default here (configurable via `--smudge-l`).

Because of this, heterozygosity is only called as real when **two signals agree simultaneously**:

1. The `AB` smudge is the majority of the mass detected by Smudgeplot (≥ `--ab-fraction-threshold`, default 0.5).
2. The 1n coverage inferred by Smudgeplot matches GenomeScope2's `kmercov` within a relative tolerance (`--coverage-tolerance`, default 0.3 = 30%).

This was validated against two synthetic *Saccharomyces cerevisiae* datasets (haploid and heterozygous with 1.5% divergence between haplotypes — see [Validation](#validation) below), and is the only combination that gave the right answer in both cases at once.

## Installation

```bash
git clone https://github.com/jlpitta/ploidycheck.git
cd ploidycheck
./install.sh
```

`install.sh`:
- Detects `mamba`/`micromamba`/`conda` on the PATH. **If none is found, it downloads and installs Miniforge3 automatically** (silent mode, `-b -p ~/miniforge3`) and continues the installation without needing a manual step.
- Creates the `ploidycheck` environment (dedicated env, not shared with bacflow/fungiflow/checkw) from `envs/ploidycheck.yaml`: `kmc`, `genomescope2`, `fastk`, `smudgeplot`.
- Applies a required patch to Smudgeplot (see [Technical note](#technical-note--smudgeplot-patch) below) idempotently — running it again does not duplicate the patch if the environment is already fixed.

## Usage

```bash
./ploidycheck \
  --sample my_sample \
  --r1 reads_R1.fastq.gz \
  --r2 reads_R2.fastq.gz \
  --outdir results/my_sample
```

### Options

| Flag | Default | Description |
|---|---|---|
| `--sample` | *(required)* | Sample name/prefix |
| `--r1` | *(required)* | Short reads R1 (fastq/fastq.gz) |
| `--r2` | *(required)* | Short reads R2 (fastq/fastq.gz) |
| `--outdir` | *(required)* | Output directory (created if it doesn't exist) |
| `--threads` | 4 | Threads for FastK/Smudgeplot |
| `--kmer-size` | 21 | K-mer size |
| `--smudge-l` | 7 | Smudgeplot `-L` cutoff — see [section above](#the-decision-criterion--and-why-it-exists) |
| `--ab-fraction-threshold` | 0.5 | Minimum AB smudge fraction to consider it dominant |
| `--coverage-tolerance` | 0.3 | Relative tolerance between `kmercov` and inferred 1n coverage |
| `--env` | `ploidycheck` | Name of the conda/mamba environment to use |

### Output

In `--outdir`:

- **`<sample>.ploidy_call.json`** — final result, schema:

```json
{
  "sample": "my_sample",
  "genomescope_kmercov": 11.71,
  "smudgeplot_haploid_coverage": 11.0,
  "smudgeplot_ab_fraction": 0.756,
  "coverage_relative_error": 0.061,
  "ab_fraction_threshold": 0.5,
  "coverage_tolerance": 0.3,
  "ab_dominant": true,
  "coverage_agrees": true,
  "heterozygous_detected": true
}
```

- `<sample>.histo` — k-mer histogram (Histex, format compatible with GenomeScope2)
- `gs2_out/` — full GenomeScope2 output (model, plots)
- `<sample>_smudgeplot_report.json` + PNGs — full Smudgeplot output

The only field most consumers need is `heterozygous_detected` — the rest exist for auditing/debugging the criterion.

## Validation

Tested on the two synthetic *S. cerevisiae* datasets from fungiflow (`genome_test/saccharomyces_cerevisiae_synthetic` and `genome_test/saccharomyces_cerevisiae_heterozygous`, ~30x short reads via wgsim):

| Dataset | genomescope_kmercov | AB fraction | 1n coverage (Smudgeplot) | `heterozygous_detected` | Expected |
|---|---|---|---|---|---|
| haploid (`scerevisiae_test`) | 11.71 | 43.7% | 11.0 | `false` | `false` ✅ |
| heterozygous 1.5% (`scerevisiae_het_test`) | 11.67 | 75.6% | 11.0 | `true` | `true` ✅ |

In the haploid dataset, the AB smudge does show up but stays well below the dominance threshold (43.7% < 50%) — this is expected noise (multi-copy rDNA, Ty elements, duplicated subtelomeric genes in *S. cerevisiae*), not real heterozygosity. This is exactly the noise the combined criterion exists to filter out.

## Technical note — Smudgeplot patch

Smudgeplot 0.5.3 (bioconda) breaks with pandas ≥3.0 (`AttributeError: Can only use .str accessor with string values`), a bug reported and still open in the [upstream issue #255](https://github.com/KamilSJaron/smudgeplot/issues/255). `patches/smudgeplot_pandas3_fix.patch` fixes two spots:

1. Forces the `structure` column to `str` right after building the smudges DataFrame — fixes the crash when zero smudges are detected.
2. Normalizes the smudges dictionary (a mix of lists and scalar NaN placeholders) before `DataFrame.from_dict` — the fix suggested in the upstream issue (`orient='index'`) regresses in this case; this version of the fix is our own, not from the issue.

`install.sh` applies this patch automatically and idempotently.

## Origin and related projects

Originally built as part of [fungiflow](https://github.com/jlpitta/fungiflow)'s (a fork of [bacflow](https://github.com/jlpitta/bacflow) for fungal genomes) polyploidy-handling plan, extracted into its own repository to also be reusable by [checkw](https://github.com/jlpitta/checkw) (a reference-free genomic contamination detection tool) — there, `heterozygous_detected` serves as context to relax the gene-redundancy signal for heterozygous/polyploid eukaryotic organisms, preventing allelic variants from being mistaken for contamination.

---

by João Pitta and Beatriz Toscano — Fiocruz-PE
