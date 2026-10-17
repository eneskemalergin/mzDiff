<!-- markdownlint-disable MD024 -->

# Changelog

All notable changes to mzdiff are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows [Semantic Versioning](https://semver.org/). Until 1.0, any version may change the output; scripts should rely on the exit status, the TSV columns, and the JSON keys and kinds, and every change to those is listed under its version.

## [Unreleased]

The first version of mzdiff, which compares a reference mzML (A) with an output under test (B) by meaning and reports each difference as critical, major, or minor. It needs Zig 0.16.0 to build and reads mzML through zmz 0.1.0.

### Added

- **Comparison:**
  - Pairs spectra by native id in any vendor's format, by scan number when the formats differ, or by position; chromatograms by id, then by type. Records pair in any order, in bounded memory.
  - Compares the header, every attribute, `cvParam`, and `userParam` with its unit, each scan's instrument configuration, the decoded arrays by role, and the index trailer.
  - Ignores bookkeeping by rule (ids, offsets, software, compression, number spelling, parameter order), so `--set` can turn any of it back on.
  - Treats rounding, 32-bit storage, and m/z within `--ppm` as minor; a term of the same kind in place of another as one difference; a more specific term as minor.
  - Reports data written in a form readers fail on: `form:integer`, `form:paramGroup`, and `form:numpress`.
- **Severity:** by exact key, then by ancestry in the bundled PSI-MS vocabulary, then minor; `--set KEY=LEVEL` overrides any key, and `--fail-on` sets the level that fails the run.
- **Output:**
  - The report, `--summary`, `--list`, `--view` (a git-style diff, unified or `--side-by-side`), and `-q`.
  - Text, `--tsv`, `--json` (JSON Lines with `--list`), and `--view --html`, a self-contained page with filters and search under a strict Content-Security-Policy.
  - Narrowing by `--severity`, `--key`, `--record`, and `--limit`, none of which changes the verdict.
- **Exit status:** 0 same or tolerated, 1 differs, 2 usage error, 3 the comparison could not complete; with `--json`, a run that cannot complete still prints a JSON error object.
- **Safety:** both inputs are untrusted. Memory stays bounded whatever the files hold, and control characters and bidirectional overrides from the files print as visible escapes.
- **Tools:** `tools/mutate.py` injects one defect at a time and checks that mzdiff reports it; `tools/corpus.sh` compares converter outputs with a reference across many runs; `tools/consumer.py` runs a search engine on the same defects.

[Unreleased]: https://github.com/eneskemalergin/mzDiff/commits/main
