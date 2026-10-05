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

A difference mzdiff fails to report is its worst defect, so every check comes with a case in the `mutate.py` defect harness that shows it can fail. What a file must be on its own (index offsets, checksum, schema, vocabulary) is left to mzValidate; `corpus.sh` runs both.

## Quick start

```bash
zig build -Doptimize=ReleaseFast                          # needs zmz checked out next to this repository (../zmz)
zig build test --summary all                              # self-contained tests; no data files needed
./zig-out/bin/mzdiff REFERENCE.mzML OTHER.mzML            # report, most severe classes first
./zig-out/bin/mzdiff --tsv REFERENCE.mzML OTHER.mzML      # one row per difference class
./corpus.sh [-t mzbridge|opentfraw|mzdata] [RAW...]       # convert and compare the corpus, one file at a time
./mutate.py zig-out/bin/mzdiff REFERENCE.mzML             # inject defects and check each one is caught
```

Requires **Zig 0.16.0** and the zmz package (`../zmz`), which reads the mzML. `corpus.sh` also uses the mzBridge checkout beside this one (`../mzBridge`, or `MZBRIDGE=PATH`): its `zig-out/bin/mzBridge`, and the peers and mzValidate in its `tools/bin/`.

## What it compares

- **Spectra**, paired by scan number from the native id (by position when a file has none). A spectrum on one side only is reported once; it does not shift the pairs after it. Paired spectra must carry the same native id. A spectrum without a scan number, or with one not above the previous spectrum's, is reported (`records out of order`), since pairing relies on it.
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

- **critical**: peaks (m/z, intensity, time arrays), MS level, polarity, centroid or profile, spectrum type, scan start time, isolation target, selected ion m/z, charge, the activation method (any dissociation method term), the instrument model, a spectrum present on one side only, spectra out of scan order.
- **major**: isolation offsets, collision and supplemental energies, filter string, injection time, scan window, TIC, base peak, lowest and highest m/z, FAIMS voltage, selected-ion intensity, `spectrumRef`, source SHA-1, serial number, analyzer, ionization and detector terms (also per scan), chromatogram type, start time, file content, chromatograms present on one side only, the native id of paired spectra (`id`), the index trailer (`indexed`, `indexListOffset`).
- **minor**: everything else, including unknown terms and user parameters.

`--set KEY=LEVEL` overrides one key: `MS:1000512=minor`, `user:NAME=ignored`, `@spectrumRef=minor`, `array:MS:1000515=major`.

## Output and exit status

The report lists classes of differences, most severe and most frequent first, each with the number of records it hits and examples (`--examples N`). `--tsv` prints one row per class for scripts. The exit status is 0 when nothing at or above `--fail-on` (default `major`) differs, 1 when something does, and 2 for a usage error or an unreadable file.

## Corpus runs

`corpus.sh` rebuilds mzdiff (and mzBridge, for `-t mzbridge`) before it starts, so a run never uses a stale binary. It writes:

- `summary.tsv`: one status per file: `same`, `differs`, `invalid` (mzValidate found errors), `differs+invalid`, `convert failed: ...`, or `mzdiff failed: ...`.
- `classes.tsv`: each difference class across the run, with the files and records it hits.
- `run.txt`: the mzdiff and mzBridge commits and the mzValidate version.
- `files/`: the per-file TSVs, and any mzdiff stderr.

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
