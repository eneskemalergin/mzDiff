<!-- markdownlint-disable MD033 MD036 MD041 -->

<p align="center">
  <img src="assets/logo-readme.svg" alt="mzDiff" width="180">
</p>

<p align="center">
  Compares two mzML files by what they mean, not by their bytes. Native, streaming, in Zig.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/zig-0.16.0-F7A41D?style=flat-square&logo=zig&logoColor=white" alt="Zig 0.16.0">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-4B9D6E?style=flat-square" alt="MIT"></a>
  <img src="https://img.shields.io/badge/status-development-green?style=flat-square" alt="Status: development">
</p>

<p align="center">
  <a href="wiki/Usage.md">Usage</a> | <a href="wiki/What-mzdiff-compares.md">What it compares</a> | <a href="wiki/Severity.md">Severity</a> | <a href="wiki/Reading-a-report.md">Reading a report</a> | <a href="wiki/JSON-output.md">JSON output</a> | <a href="wiki/Development.md">Development</a>
</p>

---

mzdiff compares a reference mzML (A) with an output under test (B) and reports every difference that changes what a reader would get, classed as critical, major, or minor. I built it to check [mzBridge](https://github.com/eneskemalergin/mzBridge), my native Thermo `.raw` converter, against the ThermoRawFileParser mzML of the same run. It checks other converters the same way.

Two converters never write the same bytes: ids, offsets, number spelling, parameter order, and software names all differ. mzdiff ignores that bookkeeping by rule and compares what is left: every spectrum and chromatogram, paired in any order; every attribute, cvParam, and userParam; the decoded arrays; and the header. A difference it fails to report is its worst defect, so every check has a case in a defect harness that shows it can fail, and the severities were checked against what a search engine does with each defect ([Consumer check](wiki/Consumer-check.md)).

It also reports where B writes the same data in a form readers fail on (a charge written `2.0`, parameters moved into a group, Numpress arrays), since a file that matches the reference value for value can still break a search engine. What a file must be on its own (index offsets, checksum, schema, vocabulary) is left to [mzValidate](https://github.com/eneskemalergin/mzValidate).

## Quick start

```bash
mzdiff REFERENCE.mzML OTHER.mzML                  # report: difference classes, most severe first
mzdiff --summary REFERENCE.mzML OTHER.mzML        # one line: the verdict and its counts
mzdiff --list REFERENCE.mzML OTHER.mzML           # every difference, in the order found
mzdiff --view REFERENCE.mzML OTHER.mzML           # the differing records as a git-style diff
mzdiff --view --html A.mzML B.mzML > diff.html    # the same, as an interactive page to open
mzdiff -q A.mzML B.mzML && echo "nothing that matters differs"
```

```text
$ mzdiff --view --severity major --record "controllerType=0 controllerNumber=1 scan=5" trfp.mzML mzdata.mzML
controllerType=0 controllerNumber=1 scan=5
  spectrum
  - total ion current = 17442.453125                              MAJOR value differs
  + total ion current = 17442.513671875
  spectrum/precursor/isolationWindow
  - isolation window lower offset = 0.7                           MAJOR value differs
  + isolation window lower offset = 1.4000244
  - isolation window upper offset = 0.7                           MAJOR value differs
  + isolation window upper offset = 1.4000244
  spectrum/precursor/selectedIon
  + peak intensity = 0                                            MAJOR only in B
  spectrum/scan/instrumentConfiguration/analyzer
  + quadrupole                                                    MAJOR only in B

complete: differs | classes: critical 0, major 11, minor 14 | spectra: A 2103, B 2103, paired 2103 | chromatograms: A 1, B 2, paired 1
```

The verdict is `same`, `tolerated` (nothing at or above `--fail-on`, default `major`), or `differs`. Exit status 0 for same or tolerated, 1 for differs, 2 for a usage error, and 3 when the comparison cannot complete (a file missing, unreadable, or cut short), as for mzValidate. [Usage](wiki/Usage.md) covers every mode, format, and option, and [Reading a report](wiki/Reading-a-report.md) what each kind of difference says about the tool that wrote B.

## Install

Build from source with **Zig 0.16.0** exactly. mzdiff reads mzML through [zmz](https://github.com/eneskemalergin/zmz), which must be checked out beside this repository:

```bash
git clone https://github.com/eneskemalergin/zmz.git
git clone https://github.com/eneskemalergin/mzDiff.git
cd mzDiff
zig build -Doptimize=ReleaseFast
zig build test --summary all
```

The binary is `zig-out/bin/mzdiff`. Only x86_64 Linux is tested.

## Speed

Each file is read and decoded on its own thread, and memory stays bounded by the records in flight, not the file. A 5.3 GiB Astral run (156,082 spectra) compares in 17.1 s with 20.5 MB peak RSS; a 2,103-spectrum PRM run in about 100 ms. [Development](wiki/Development.md#speed-and-memory) has the measurement details.

## Status

In development. The CLI may still change; the exit status, the TSV columns, and the JSON keys and kinds are what scripts should rely on.

## Related

- [mzML 1.1.0](https://www.psidev.info/mzML): the input format
- [zmz](https://github.com/eneskemalergin/zmz): the mzML reader mzdiff is built on
- [mzValidate](https://github.com/eneskemalergin/mzValidate): validates each file on its own
- [mzBridge](https://github.com/eneskemalergin/mzBridge): the converter mzdiff was built to check
- [ThermoRawFileParser](https://github.com/CompOmics/ThermoRawFileParser): the reference for Thermo `.raw` files

## License

MIT. See [LICENSE](LICENSE).
