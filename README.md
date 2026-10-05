# mzdiff

Compares two mzML files by what they mean, not by their bytes: a reference (usually the
ThermoRawFileParser output next to each `.raw` in the corpus) and an output under test
(mzBridge or a peer). Built on zmz's streaming reader.

```sh
zig build -Doptimize=ReleaseFast
zig-out/bin/mzdiff REFERENCE.mzML OTHER.mzML
./corpus.sh [-t mzbridge|opentfraw|mzdata] [RAW...]   # whole corpus, one file at a time
```

Requires Zig 0.16.0 and zmz checked out beside this repo (`../zmz`). `corpus.sh` also uses the
mzBridge checkout beside it (`../mzBridge`, or `MZBRIDGE=PATH`) for `zig-out/bin/mzBridge`, the
peers and mzValidate in its `tools/bin/`.

## What it compares

- **Spectra**, paired by scan number from the native id (by position when a file has none). A
  spectrum on one side only is reported once; it does not shift the pairs after it. Paired
  spectra must carry the same native id, and a spectrum without a scan number, or with one not
  above the previous spectrum's, is reported (`records out of order`), since pairing relies on it.
- **Chromatograms**, paired by type and id, then by type alone, then by id alone, so many SRM
  traces of one type pair by id rather than by position.
- **The header**: file content, source file checksum, instrument configurations (model, serial,
  source, analyzer, detector), run start time. Header facts compare as a set.
- **Every attribute, cvParam, and userParam**, with group references expanded, per element path,
  with its unit: a unit on one side only is a difference.
- **Repeated elements as wholes**: when an element repeats in a record (two precursors of an MS3
  spectrum, several scan windows), each one of A, with its descendants, must match a distinct one
  of B. Charge 2 and charge 3 trading places between two precursors is `values regrouped`.
- **Each scan's instrument configuration**: the source, analyzer, and detector of the
  configuration the scan names (or the run's default), so a spectrum filed under the ion trap
  instead of the orbitrap differs even when both configurations exist in the header.
- **Arrays** as decoded values, matched by role (m/z, intensity, time, others) and unit; time
  arrays in seconds and in minutes compare as the same values.
- **The index trailer**: an indexed file must end with `indexListOffset`, `fileChecksum`, and
  `</indexedmzML>`, with the offset pointing at the index; B losing the index A has is a
  difference. A file cut short anywhere else fails to read (exit 2).

mzValidate checks what a file must be on its own: every index offset, the SHA-1 checksum, the
`index` attributes, the schema and vocabulary. mzdiff does not repeat those; `corpus.sh` runs both.

## What it does not complain about

- Tool names and versions, cvList versions and URIs, dataProcessing, file locations, ids, index
  offsets, list counts, encodings and compression, encoded lengths.
- Parameter order, attribute order, whitespace, number spelling (`50` and `50.000`), the order of
  repeated elements, seconds versus minutes for times, `.63Z` versus `.630Z`.

Differences that remain but carry no meaning are kept, as **minor**:

- the last printed digit (`79.106` and `79.107`), or a shorter spelling that is the longer one
  rounded (`1.6` and `1.59`, not `1.5`); a value printed as an integer never counts as rounded
  (`26` against `26.112` is a value difference), and the precision of seconds carries into minutes;
- values equal at 32-bit precision (one side stored a 32-bit float, the other the 64-bit value);
- m/z within `--ppm` (default 1 ppm), for m/z parameters and m/z arrays;
- array precision (32-bit versus 64-bit storage) and the same peaks in another order.

## Severity

`src/rules.zig` decides, by exact key first, then by ancestry in the bundled PSI-MS vocabulary:

- **critical**: peaks (m/z, intensity, time arrays), MS level, polarity, centroid or profile,
  spectrum type, scan start time, isolation target, selected ion m/z, charge, the activation
  method (any dissociation method term), the instrument model, a spectrum present on one side
  only, spectra out of scan order.
- **major**: isolation offsets, collision and supplemental energies, filter string, injection time,
  scan window, TIC, base peak, lowest and highest m/z, FAIMS voltage, selected-ion intensity,
  `spectrumRef`, source SHA-1, serial number, analyzer, ionization and detector terms (also per
  scan), chromatogram type, start time, file content, chromatograms present on one side only, the
  native id of paired spectra (`id`), the index trailer (`indexed`, `indexListOffset`).
- **minor**: everything else, including unknown terms and user parameters.

`--set KEY=LEVEL` overrides one key (`MS:1000512=minor`, `user:NAME=ignored`, `@spectrumRef=minor`,
`array:MS:1000515=major`).

## Output and exit status

Classes of differences, most severe and most frequent first, each with the number of records it
hits and examples (`--examples N`). `--tsv` prints one row per class for scripts. The exit status
is 0 when nothing at or above `--fail-on` (default `major`) differs, 1 when something does, and 2
for a usage error or an unreadable file.

`corpus.sh` rebuilds mzdiff (and mzBridge) before it starts, and writes `summary.tsv` with one
status per file (`same`, `differs`, `invalid` when mzValidate finds errors, `differs+invalid`,
`convert failed: ...`, `mzdiff failed: ...`), `classes.tsv` across the run, `run.txt` with the
commit and validator version, and the per-file TSVs (and any mzdiff stderr) under `files/`.

## Speed and memory

Each file is read and decoded on its own thread; the main thread pairs and compares. Measured on
the 5.3 GiB Astral run `Gong_1.raw` (TRFP 4.0 GB against mzBridge 3.6 GB, 156,082 spectra):
16.8 s and 16.7 MB peak RSS. The PRM fixture (2,103 spectra) takes 0.2 s. Most of the time is
zlib inflation and XML parsing inside zmz.
