# Development

## Build and test

```bash
zig build                                  # Debug build
zig build test --summary all               # unit tests; no data files needed
zig build -Doptimize=ReleaseFast           # the stripped build that ships and is measured
```

The tests sit beside the code in `src/` and build their inputs in memory. Real files are used only by the tools below.

## Source layout

```text
src/main.zig      CLI parsing, the header comparison, the threads, and the verdict
src/read.zig      one input on its own thread: header, trailer check, records to facts and arrays
src/pair.zig      pairing spectra by native id through a bounded join, chromatograms by id and then by type
src/compare.zig   facts, elements, value and array comparison, regrouping, the report
src/rules.zig     severity by key: exact keys, PSI-MS ancestry, --set overrides
src/output.zig    the report, summary, list, and view as text, TSV, and JSON
src/html.zig      the view as an HTML page
```

## Defect harness

A difference mzdiff fails to report is its worst defect, so every check has a case in `tools/mutate.py` that shows it can fail. The harness injects one defect at a time into a reference mzML and checks that mzdiff reports it at the expected class, or compares the same when the edit carries no meaning.

```bash
tools/mutate.py zig-out/bin/mzdiff REFERENCE.mzML [CASE...]
```

It exits 0 only when every case that applies behaves as expected; a case whose structure the reference lacks is skipped. Two public PRIDE datasets cover every case between them: the PRM run in PXD006618 (single precursors) and an MS3 run in PXD070648 (two precursors per spectrum). Use the ThermoRawFileParser mzML of each.

A new check gets its harness case first.

## Corpus runs

`tools/corpus.sh` converts Thermo `.raw` files with one tool (mzBridge, OpenTFRaw, or mzdata), compares each output with the ThermoRawFileParser mzML beside the `.raw`, and runs mzValidate on each output. It needs an [mzBridge](https://github.com/eneskemalergin/mzBridge) checkout beside this one (`../mzBridge`, or `MZBRIDGE=PATH`) with its `zig-out/bin/mzBridge` built and the peers and mzValidate in its `tools/bin/`.

```bash
tools/corpus.sh [-t mzbridge|opentfraw|mzdata] [-o OUT] [-c DIR] [-b BASELINE] [RAW...]
```

Named `.raw` files are checked as given; with none, it checks every `.raw` under `-c DIR` (or `MZDIFF_CORPUS`) that has a reference `.mzML` beside it. It rebuilds mzdiff (and mzBridge, for `-t mzbridge`) first, so a run never uses a stale binary, and works one file at a time. It writes:

- `summary.tsv`: one row per file: mzdiff's verdict (`same`, `tolerated`, `differs`, with `+invalid` when mzValidate found errors, or `nothing paired`), the class counts, and the paired spectra; or `convert failed: ...` and `mzdiff failed: ...`.
- `classes.tsv`: each difference class across the run, with the files and records it hits.
- `run.txt`: the mzdiff and mzBridge commits and the mzValidate version.
- `files/`: the JSON report per file, and any mzdiff stderr.

With `-b BASELINE` (an earlier run's directory), it also writes `changes.tsv`: per file, the status change and every class that is new, gone, or hits more or fewer records. It exits 1 when a critical or major class is new or grown, so a converter change can be checked against the last run in one command:

```bash
tools/corpus.sh -o /var/tmp/after -b /var/tmp/before
```

## Consumer runs

`tools/consumer.py` checks the severities against a real consumer: the Sage search engine that mzBridge's `tools/install.sh` builds. It injects one defect at a time into the spectra Sage identifies in a reference (200 rank-1 matches at 1% FDR, spread over the run), then runs mzdiff, mzValidate, and Sage on the result. Each case ends as `fatal` (Sage fails or reads nothing), `lost` (edited spectra vanish from its results), `wrong` (another peptide or charge, a lost 1% match, or a spectrum reported twice), `shifted` (other scores, times, or masses), or `none`, beside mzdiff's most severe class and mzValidate's error rules. A case is flagged `MISSED` when Sage is hurt and neither tool says major or an error. The last run's results are on [Consumer check](Consumer-check).

```bash
tools/consumer.py --fasta FASTA -o OUT zig-out/bin/mzdiff REFERENCE.mzML [CASE...]
tools/consumer.py --compare --fasta FASTA -o OUT zig-out/bin/mzdiff REFERENCE.mzML B.mzML...   # converter outputs
```

The FASTA (`--fasta`, or `MZDIFF_FASTA`) must match the reference's organism, and the engine settings suit Orbitrap HCD runs; a run takes about a minute per case on a 400 MB reference. Sage's FDR step is not fully deterministic, so a match that crosses 1% FDR counts as wrong only when its own score, time, or mass moved.

## Speed and memory

Each file is read and decoded on its own thread; the main thread pairs and compares, and memory stays bounded by the records in flight. Most of the time is zlib inflation and XML parsing inside zmz.

Measured with [zebrac](https://github.com/eneskemalergin/zebrac) 0.6.3 on the stripped ReleaseFast build, warm page cache, x86_64 Linux:

- An Orbitrap Astral run (PRIDE PXD055827, 5.3 GiB raw; ThermoRawFileParser's 4.0 GB mzML against mzBridge's 3.6 GB, 156,082 spectra): 17.1 s ± 0.08 s wall time over 3 runs, and 20.5 MB peak RSS pinned to one CPU.
- An Orbitrap Eclipse HeLa run (PRIDE PXD016921, a 400 MB mzML, 36,341 spectra) against itself: 2.6 s ± 0.3 s over 12 runs, and 10.4 MB peak RSS.
- The PRM fixture (2,103 spectra): 102 ms ± 3.5 ms over 50 runs, and 4.7 MB peak RSS unpinned.
- `--view --html` on the PRM pair against mzdata costs no time over `--list` (106 ms against 105 ms).
