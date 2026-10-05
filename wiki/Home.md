# mzdiff

mzdiff compares a reference mzML (A) with an output under test (B) and reports every difference that changes what a reader would get, classed as critical, major, or minor. It was built to check a converter against a trusted one (mzBridge against ThermoRawFileParser, for Thermo `.raw` files), and checks any two mzML files the same way.

Two converters never write the same bytes: ids, offsets, number spelling, parameter order, and software names all differ. mzdiff ignores that bookkeeping by rule and compares what is left: every spectrum and chromatogram, paired in any order; every attribute, cvParam, and userParam; the decoded arrays; and the header. It also reports where B writes the same data in a form readers fail on. What a file must be on its own (index offsets, checksum, schema) is left to [mzValidate](https://github.com/eneskemalergin/mzValidate).

```bash
mzdiff REFERENCE.mzML OTHER.mzML                  # the report: difference classes, most severe first
mzdiff --view --html A.mzML B.mzML > diff.html    # the differing records as an interactive page
```

## Pages

- [Usage](Usage): modes, formats, selection, the view and the page, and the exit status.
- [What mzdiff compares](What-mzdiff-compares): what is compared, what is ignored, tolerances, and form.
- [Severity](Severity): what critical, major, and minor mean, which keys are which, and `--set`.
- [Reading a report](Reading-a-report): what each kind of difference says about the tool that wrote B.
- [Consumer check](Consumer-check): each severity set beside what a search engine did with the same defect.
- [JSON output](JSON-output): the machine interface.
- [Untrusted input](Untrusted-input): bounded memory and safe output for hostile files.
- [Development](Development): building, the source layout, and the three checking tools.
