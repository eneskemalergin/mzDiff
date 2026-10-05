<!-- markdownlint-disable MD033 MD036 MD041 -->
<h1 align="center">mzdiff</h1>

<p align="center">
  Compares two mzML files by what they mean, not by their bytes. Native, streaming, in Zig.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/zig-0.16.0-F7A41D?style=flat-square&logo=zig&logoColor=white" alt="Zig 0.16.0">
  <img src="https://img.shields.io/badge/license-MIT-4B9D6E?style=flat-square" alt="MIT">
  <img src="https://img.shields.io/badge/status-development-green?style=flat-square" alt="Status: development">
</p>

---

mzdiff compares a reference mzML (A) with an output under test (B) and reports every difference that changes what a reader would get, classed as critical, major, or minor. I built it to check mzBridge against the gold references: the ThermoRawFileParser (TRFP) mzML beside each `.raw` in the corpus. It checks the peers (OpenTFRaw, mzdata) the same way.

A difference mzdiff fails to report is its worst defect, so every check comes with a case in the `tools/mutate.py` defect harness that shows it can fail. What a file must be on its own (index offsets, checksum, schema, vocabulary) is left to mzValidate; `tools/corpus.sh` runs both.

## Quick start

```bash
zig build -Doptimize=ReleaseFast                         # needs zmz checked out next to this repository (../zmz)
zig build test --summary all                             # self-contained tests; no data files needed
./zig-out/bin/mzdiff REFERENCE.mzML OTHER.mzML           # report: difference classes, most severe first
./zig-out/bin/mzdiff --summary REFERENCE.mzML OTHER.mzML # one line: the verdict and its counts
./zig-out/bin/mzdiff --list REFERENCE.mzML OTHER.mzML    # every difference, in the order found
tools/corpus.sh [-t mzbridge|opentfraw|mzdata] [RAW...]  # convert and compare the corpus, one file at a time
tools/mutate.py zig-out/bin/mzdiff REFERENCE.mzML        # inject defects and check each one is caught
```

Requires **Zig 0.16.0** and the zmz package (`../zmz`), which reads the mzML. `corpus.sh` also uses the mzBridge checkout beside this one (`../mzBridge`, or `MZBRIDGE=PATH`): its `zig-out/bin/mzBridge`, and the peers and mzValidate in its `tools/bin/`.

## Usage

Modes choose what is shown, formats choose how, and selection narrows it. None of them changes the verdict.

- **Modes**, one at a time: the report by default (difference classes, most severe and most frequent first, with `--examples N` examples each); `--summary` (one line: the verdict and its counts); `--list` (every difference, one per line, in the order found, grouped under its record; an array that differs is one line with how many values differ and the largest difference); `-q`, `--quiet` (nothing; the exit status is the answer).
- **Formats**: text by default, colored under `--color auto|always|never` (`NO_COLOR` and `CLICOLOR_FORCE` are honored); `--json` (one document for the report and the summary, JSON Lines for `--list`, ending with a summary line); `--tsv` (the report's columns are stable for scripts).
- **Selection**: `--severity LEVEL` shows that level and above; `--key KEY` and, with `--list`, `--record ID` keep only those keys and records (each repeatable); `--limit N` caps a list and says how much it held back.
- **Verdict**: `same` (no difference), `tolerated` (nothing at or above `--fail-on`, default `major`), or `differs`; `incomplete` when `--max-spectra` stopped early. Exit status 0 for same or tolerated, 1 for differs, 2 for a usage error or an unreadable file.

Watching how two tools write the same file:

```bash
mzdiff --list --severity major trfp.mzML tool.mzML                 # everything that matters, spectrum by spectrum
mzdiff --list --key MS:1000512 trfp.mzML tool.mzML                 # how each filter string differs
mzdiff --list --record "controllerType=0 controllerNumber=1 scan=5" trfp.mzML tool.mzML
mzdiff --list --json trfp.mzML tool.mzML | jq -r 'select(.type == "difference") | .key' | sort | uniq -c
mzdiff -q trfp.mzML tool.mzML && echo "nothing that matters differs"
```

JSON schema 1 carries `schema_version`, both sides (`path`, `software`, `spectra`, `chromatograms`), `paired`, `completion`, `status`, `fail_on`, and `totals` (classes per severity). The report adds `classes`, each with `severity`, `kind`, `label`, `path`, `key`, `name`, `records`, and `examples`. A list line has `type`, `record`, `severity`, `kind`, `path`, `key`, `name`, `a`, `b`, and for arrays `values`, `differing`, and `largest`. Keys and kinds are the stable contract; labels and names may improve. There is no library API: the JSON is the machine interface.

## What it compares

- **Spectra**, paired by their native id in any vendor's format (Thermo, Waters, Sciex, Bruker, or a mix), by the scan number when the two files write different id formats, or by position when neither works. Pairing needs no order: a spectrum on one side only is reported once (`record missing in B`, `record only in B`), a spectrum in another place pairs anyway and is reported as `records out of order`, and the pairs around both stay correct. Memory stays bounded: beyond 1,024 spectra waiting for a partner, the oldest are reported missing.
- **Chromatograms**, paired by type and id, then by type alone, then by id alone, so many SRM traces of one type pair by id rather than by position.
- **The header**: file content, source file checksum, instrument configurations (model, serial, source, analyzer, detector), run start time. Header facts compare as a set.
- **Every attribute, cvParam, and userParam**, with group references expanded, per element path, with its unit. A unit B drops is a difference, at most major since the value is intact; a unit B adds is minor, and whether the term allows it is mzValidate's check.
- **Repeated elements as wholes.** When an element repeats in a record (two precursors of an MS3 spectrum, several scan windows), each one of A, with its descendants, must match a distinct one of B. Charge 2 and charge 3 trading places between two precursors is `values regrouped`.
- **Each scan's instrument configuration**: the source, analyzer, and detector of the configuration the scan names (or the run's default), so a spectrum filed under the ion trap instead of the orbitrap differs even when both configurations exist in the header.
- **Arrays** as decoded values, matched by role (m/z, intensity, time, others) and unit. Time arrays in seconds and in minutes compare as the same values.
- **The index trailer.** An indexed file must end with `indexListOffset`, `fileChecksum`, and `</indexedmzML>`, with the offset pointing at the index. B losing the index A has is a difference. A file cut short anywhere else fails to read (exit 2).

## What it does not complain about

- Tool names and versions, cvList versions and URIs, dataProcessing, file locations, ids, index offsets, list counts, encodings and compression, encoded lengths.
- Parameter order, attribute order, whitespace, number spelling (`50` and `50.000`), the order of repeated elements, seconds against minutes for times, `.63Z` against `.630Z`.

Differences that remain but carry no meaning are kept as **minor**:

- The last printed digit (`79.106` and `79.107`), or a shorter spelling that is the longer one rounded (`1.6` and `1.59`, not `1.5`). A value printed as an integer never counts as rounded (`26` against `26.112` is a value difference), and the precision of seconds carries into minutes.
- Values equal at 32-bit precision: one side stored a 32-bit float, the other the 64-bit value.
- m/z within `--ppm` (default 1 ppm), for m/z parameters and m/z arrays.
- Array precision (32-bit against 64-bit storage), and the same peaks in another order.

## Severity

`src/rules.zig` decides, by exact key first, then by ancestry in the bundled PSI-MS vocabulary.

- **critical**: peaks (m/z, intensity, time arrays), MS level, polarity, centroid or profile, spectrum type, scan start time, isolation target, selected ion m/z, charge, the activation method (any dissociation method term), the instrument model, a spectrum present on one side only.
- **major**: isolation offsets, collision and supplemental energies, filter string, injection time, scan window, TIC, base peak, lowest and highest m/z, FAIMS voltage, selected-ion intensity, `spectrumRef`, source SHA-1, serial number, analyzer, ionization and detector terms (also per scan), chromatogram type, start time, file content, chromatograms present on one side only, spectra out of their files' order (`order`), the native id of spectra paired by scan number (`id`), the index trailer (`indexed`, `indexListOffset`).
- **minor**: everything else, including unknown terms and user parameters.

`--set KEY=LEVEL` overrides one key: `MS:1000512=minor`, `user:NAME=ignored`, `@spectrumRef=minor`, `array:MS:1000515=major`.

## Corpus runs

`corpus.sh` rebuilds mzdiff (and mzBridge, for `-t mzbridge`) before it starts, so a run never uses a stale binary. It writes:

- `summary.tsv`: one row per file: mzdiff's verdict (`same`, `tolerated`, `differs`, with `+invalid` when mzValidate found errors, or `nothing paired`), the class counts, and the paired spectra; or `convert failed: ...` and `mzdiff failed: ...`.
- `classes.tsv`: each difference class across the run, with the files and records it hits.
- `run.txt`: the mzdiff and mzBridge commits and the mzValidate version.
- `files/`: the JSON report per file, and any mzdiff stderr.

## Speed and memory

Each file is read and decoded on its own thread; the main thread pairs and compares, and memory stays bounded by the records in flight. Most of the time is zlib inflation and XML parsing inside zmz.

Measured with [zebrac](https://github.com/eneskemalergin/zebrac) 0.6.3 on the stripped ReleaseFast build, warm page cache, x86_64 Linux:

- `Gong_1.raw`, the 5.3 GiB Astral run (TRFP 4.0 GB against mzBridge 3.6 GB, 156,082 spectra): 17.1 s ± 0.08 s wall time over 3 runs, and 20.5 MB peak RSS pinned to one CPU.
- The PRM fixture (2,103 spectra): 102 ms ± 3.5 ms over 50 runs, and 4.7 MB peak RSS unpinned.

## References

- [mzML 1.1.0 spec](https://www.psidev.info/mzML): the input format
- [zmz](https://github.com/eneskemalergin/zmz): the mzML reader mzdiff is built on
- [ThermoRawFileParser](https://github.com/CompOmics/ThermoRawFileParser): the gold reference for Thermo `.raw` files
- [mzValidate](https://github.com/eneskemalergin/mzValidate): validates each file on its own
- [zebrac](https://github.com/eneskemalergin/zebrac): the benchmark runner behind the numbers above

## License

MIT. See [LICENSE](LICENSE).
