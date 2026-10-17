# Severity

Every difference has one of three severities. They answer one question: what does this cost a reader of B who expected A?

- **critical**: the data itself or what it means. A reader gets other peaks, another precursor, another MS level, or loses spectra or the whole file.
- **major**: a value search engines and other readers commonly use, or a valid form that known readers cannot handle. Results can change, or a reader can stumble.
- **minor**: nothing a reader would compute differently: tolerances, more specific terms, and parameters no reader is known to use.

The verdict follows from them: `differs` when anything reaches `--fail-on` (default `major`), `tolerated` when something differs below it, `same` when nothing differs at all.

## Which keys are which

Severity is decided by key: exact keys first, then the key's ancestry in the bundled PSI-MS vocabulary, then the default.

- **critical**: peaks (m/z, intensity, and time arrays), MS level, polarity, centroid or profile, spectrum type, scan start time (also when its unit is dropped), isolation target, selected ion m/z, charge, the dissociation method, the instrument model, a spectrum present on one side only, a total ion current that drops to zero (readers take the spectrum for empty and skip it), and `form:integer`.
- **major**: isolation offsets, collision and supplemental energies, filter string, injection time, scan window, total ion current, base peak, lowest and highest m/z, FAIMS voltage, selected-ion intensity, `spectrumRef`, source SHA-1, serial number, a calibration spectrum, analyzer, ionization and detector terms (also per scan), chromatogram type, the run's start time, file content, a chromatogram present on one side only, peaks in another order (`array:peaks`), spectra out of their files' order (`order`), precursors in another order (`precursorOrder`), the native ids of spectra paired by scan number (`id`), the index trailer (`indexed`, `indexListOffset`), any other array, `form:paramGroup`, and `form:numpress`.
- **minor**: everything else, including unknown terms and user parameters.

A unit B drops is capped at major, except a time's. A term in place of another of the same kind takes that kind's severity; a more specific term is minor. [Consumer check](Consumer-check) sets these levels beside what a search engine did with each defect.

## Keys

A key is a PSI-MS accession (`MS:1000016`), `user:NAME` for a userParam, `@NAME` for an attribute, `array:ACCESSION` for an array, a named check (`id`, `order`, `precursorOrder`, `indexed`, `indexListOffset`, `instrumentConfiguration`, `element`, `array:peaks`), or a form check (`form:integer`, `form:paramGroup`, `form:numpress`). The report, the list, and the JSON all name the key of every difference.

## Overrides

`--set KEY=LEVEL` gives one key a severity (`critical`, `major`, `minor`, or `ignored`). It wins over every rule, including where a check chooses the severity itself (tolerances, a lost record, a zeroed total ion current). Repeat it for more keys.

```bash
mzdiff --set MS:1000512=minor A.mzML B.mzML        # filter string
mzdiff --set user:NAME=ignored A.mzML B.mzML       # a userParam
mzdiff --set @spectrumRef=minor A.mzML B.mzML      # an attribute
mzdiff --set array:peaks=minor A.mzML B.mzML       # peaks in another order
```
