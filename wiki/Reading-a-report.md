# Reading a report

Each difference has a kind, and the kind says what the tool that wrote B did. Read the report most severe first; within a severity, the kinds below tell you whether B left something out, added something, wrote it wrong, or wrote it in a way readers fail on.

## What B did

- **B left something out**
  - Kinds: `missing in B`, `record missing in B`, `array missing in B`, `count differs` (fewer)
  - What to check: a field it does not read or does not write; spectra it drops
- **B added something**
  - Kinds: `only in B`, `record only in B`, `array only in B`, `count differs` (more)
  - What to check: a field it invents, or one the reference tool leaves out (then B may be right)
- **B wrote another value**
  - Kinds: `value differs`, `unit differs`, `array length differs`, `array values differ`
  - What to check: a decoding or conversion error: scale, unit, offset, or a field read from the wrong place
- **B named another term**
  - Kinds: `another term`
  - What to check: a lookup table: which analyzer, polarity, or method the tool maps an instrument field to
- **B named a more specific term**
  - Kinds: `a more specific term` (minor)
  - What to check: usually nothing: B says more than A
- **B put things in another place**
  - Kinds: `values regrouped`, `in another order` (precursors), `records out of order`, `same peaks, other order`
  - What to check: how the tool groups precursors, orders spectra, or sorts peaks
- **B wrote the same data another way**
  - Kinds: `form:` keys
  - What to check: a valid or invalid form that readers fail on ([Form](What-mzdiff-compares#form))
- **B matched within a tolerance**
  - Kinds: `last digit differs`, `equal at 32-bit precision`, `m/z within tolerance`, `array precision differs` (all minor)
  - What to check: nothing, unless the precision matters to you
- **B paired spectra by scan number**
  - Kinds: `paired ids differ`
  - What to check: the native id format the tool writes

The reference can be wrong too. A difference says that B disagrees with A, not which one is right: when ThermoRawFileParser names an Orbitrap Eclipse's analyzer `fourier transform ion cyclotron resonance mass spectrometer` and the tool under test names it `orbitrap`, the report shows `another term`, and the tool under test is the one that is right.

## Following a difference down

The report names each class's key and gives examples with their record ids. From there:

```bash
mzdiff --list --key KEY A.mzML B.mzML                        # every record where KEY differs
mzdiff --view --record "ID" A.mzML B.mzML                    # one record as a diff
mzdiff --view --html --severity major A.mzML B.mzML > d.html # what matters, as a page to browse
```

When the text view refuses because too many records differ, it says how many records differ at each severity and which keys differ most, so the narrowing command is obvious.

## A clean report is not a proof

mzdiff compares what both files say. A field both tools get wrong the same way compares the same, and a reference that lacks a field cannot show that B's is wrong. For confidence beyond the comparison, run the files through a consumer: [Development](Development#consumer-runs) describes how mzdiff's severities were checked against a search engine.
