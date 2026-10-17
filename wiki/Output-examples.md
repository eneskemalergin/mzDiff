# Output examples

Every example on this page is real output from one pair of files: a PRM run on an Orbitrap Fusion from PRIDE [PXD006618](https://www.ebi.ac.uk/pride/archive/projects/PXD006618) (`1fmol_HSP90_SILpepmix_PRM.raw`, 2,103 spectra), converted twice. A, `trfp.mzML`, is ThermoRawFileParser's mzML; B, `mzdata.mzML`, is the [mzdata](https://github.com/mobiusklein/mzdata) converter's. They differ in 11 major and 14 minor classes, so every mode has something to show.

## The report

The default. Classes, most severe and most frequent first, each with its count of records and examples (`--examples N`, default 3). `--severity major` keeps the minor classes out of the way here.

```text
$ mzdiff --severity major --examples 1 trfp.mzML mzdata.mzML
A  trfp.mzML  (ThermoRawFileParser)
B  mzdata.mzML  (thermo_xcalibur)
spectra        A 2103  B 2103  paired 2103
chromatograms  A 1  B 2  paired 1
result         differs: 0 critical, 11 major, 14 minor difference classes

MAJOR
      2103  value differs              spectrum/precursor/isolationWindow  MS:1000828 (isolation window lower offset)
            controllerType=0 controllerNumber=1 scan=1  A: 0.7  B: 1.4000244
      2103  value differs              spectrum/precursor/isolationWindow  MS:1000829 (isolation window upper offset)
            controllerType=0 controllerNumber=1 scan=1  A: 0.7  B: 1.4000244
      2103  only in B                  spectrum/precursor/selectedIon  MS:1000042 (peak intensity)
            controllerType=0 controllerNumber=1 scan=1  A: -  B: 0
      2103  only in B                  spectrum/scan/instrumentConfiguration/analyzer  MS:1000081 (quadrupole)
            controllerType=0 controllerNumber=1 scan=1
      2014  value differs              spectrum  MS:1000285 (total ion current)
            controllerType=0 controllerNumber=1 scan=1  A: 15869.6875  B: 15869.7529296875
         1  record only in B           chromatogram  @id (chromatogram)
            TIC  A: -  B: TIC
         1  missing in B               mzML/fileDescription/fileContent  MS:1000810 (ion current chromatogram)
            header
         1  only in B                  mzML/instrumentConfiguration/analyzer  MS:1000081 (quadrupole)
            header
         1  only in B                  mzML/instrumentConfiguration/analyzer  MS:1000083 (radial ejection linear ion trap)
            header
         1  only in B                  mzML/instrumentConfiguration/detector  MS:1000253 (electron multiplier)
            header
         1  missing in B               run  @startTimeStamp
            header  A: 2015-10-14T03:22:49.63Z  B: -

11 of 25 classes shown (--severity, --key)
```

## The summary

One line, the same verdict and counts, for a quick look or a script.

```text
$ mzdiff --summary trfp.mzML mzdata.mzML
complete: differs | classes: critical 0, major 11, minor 14 | spectra: A 2103, B 2103, paired 2103 | chromatograms: A 1, B 2, paired 1
```

As TSV, with a header row:

```text
$ mzdiff --summary --tsv trfp.mzML mzdata.mzML
completion	status	fail_on	critical	major	minor	a_spectra	b_spectra	paired_spectra	a_chromatograms	b_chromatograms	paired_chromatograms
complete	differs	major	0	11	14	2103	2103	2103	1	2	1
```

As JSON, one document (schema 1):

```text
$ mzdiff --summary --json trfp.mzML mzdata.mzML
{
  "schema_version": 1,
  "tool": {"name": "mzdiff", "version": "0.1.0"},
  "a": {"path": "trfp.mzML", "software": "ThermoRawFileParser", "spectra": 2103, "chromatograms": 1},
  "b": {"path": "mzdata.mzML", "software": "thermo_xcalibur", "spectra": 2103, "chromatograms": 2},
  "paired": {"spectra": 2103, "chromatograms": 1},
  "completion": "complete",
  "status": "differs",
  "fail_on": "major",
  "totals": {"critical": 0, "major": 11, "minor": 14}
}
```

## The list

Every difference, in the order found, grouped under its record. `--limit` caps it and says how many it held back.

```text
$ mzdiff --list --severity major --limit 8 trfp.mzML mzdata.mzML
header
  MAJOR    missing in B               mzML/fileDescription/fileContent  MS:1000810 (ion current chromatogram)
  MAJOR    only in B                  mzML/instrumentConfiguration/analyzer  MS:1000081 (quadrupole)
  MAJOR    only in B                  mzML/instrumentConfiguration/analyzer  MS:1000083 (radial ejection linear ion trap)
  MAJOR    only in B                  mzML/instrumentConfiguration/detector  MS:1000253 (electron multiplier)
  MAJOR    missing in B               run  @startTimeStamp  A: 2015-10-14T03:22:49.63Z  B: -
controllerType=0 controllerNumber=1 scan=1
  MAJOR    value differs              spectrum  MS:1000285 (total ion current)  A: 15869.6875  B: 15869.7529296875
  MAJOR    value differs              spectrum/precursor/isolationWindow  MS:1000828 (isolation window lower offset)  A: 0.7  B: 1.4000244
  MAJOR    value differs              spectrum/precursor/isolationWindow  MS:1000829 (isolation window upper offset)  A: 0.7  B: 1.4000244

10424 more differences not shown (--limit)
complete: differs | classes: critical 0, major 11, minor 14 | spectra: A 2103, B 2103, paired 2103 | chromatograms: A 1, B 2, paired 1
```

As JSON Lines, one difference per line and a summary line at the end:

```text
$ mzdiff --list --json --severity major --limit 2 trfp.mzML mzdata.mzML
{"type": "difference", "record": "header", "severity": "major", "kind": "missing", "path": "mzML/fileDescription/fileContent", "key": "MS:1000810", "name": "ion current chromatogram", "a": "", "b": ""}
{"type": "difference", "record": "header", "severity": "major", "kind": "extra", "path": "mzML/instrumentConfigurationList/instrumentConfiguration/componentList/analyzer", "key": "MS:1000081", "name": "quadrupole", "a": "", "b": ""}
{"type": "summary", "schema_version": 1, "tool": {"name": "mzdiff", "version": "0.1.0"}, "a": {"path": "trfp.mzML", "software": "ThermoRawFileParser", "spectra": 2103, "chromatograms": 1}, "b": {"path": "mzdata.mzML", "software": "thermo_xcalibur", "spectra": 2103, "chromatograms": 2}, "paired": {"spectra": 2103, "chromatograms": 1}, "completion": "complete", "status": "differs", "fail_on": "major", "totals": {"critical": 0, "major": 11, "minor": 14}, "shown": 2, "not_shown": 10430}
```

## The view

The differing records as a diff: `-` for A, `+` for B, each pair tagged with its severity.

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

Side by side, `--side-by-side` with `--width N`:

```text
$ mzdiff --view --side-by-side --width 110 --severity major --record "controllerType=0 controllerNumber=1 scan=5" trfp.mzML mzdata.mzML
controllerType=0 controllerNumber=1 scan=5
                                           A                | B
  spectrum
  total ion current                        17442.453125     | 17442.513671875   MAJOR value differs
  spectrum/precursor/isolationWindow
  isolation window lower offset            0.7              | 1.4000244         MAJOR value differs
  isolation window upper offset            0.7              | 1.4000244         MAJOR value differs
  spectrum/precursor/selectedIon
  peak intensity                           -                | 0                 MAJOR only in B
  spectrum/scan/instrumentConfiguration/analyzer
  quadrupole                               -                | (present)         MAJOR only in B

complete: differs | classes: critical 0, major 11, minor 14 | spectra: A 2103, B 2103, paired 2103 | chromatograms: A 1, B 2, paired 1
```

When too many records differ to read, the view prints nothing and says how to narrow it:

```text
$ mzdiff --view trfp.mzML mzdata.mzML
mzdiff: too large to view: 2106 records differ (critical 0, major 2105, minor 1); the view shows at most 40.
mzdiff:   --key MS:1000081  (quadrupole) differs in 2104 records
mzdiff:   --key MS:1000485  (nanospray inlet) differs in 2104 records
mzdiff:   --key array:MS:1000515  (intensity array) differs in 2104 records
mzdiff:   --record ID shows one record; --limit N raises the cap; --list shows everything

complete: differs | classes: critical 0, major 11, minor 14 | spectra: A 2103, B 2103, paired 2103 | chromatograms: A 1, B 2, paired 1
```

## The page

`--view --html` writes the view as one self-contained page to open in a browser, with severity filters, search, a unified or side-by-side layout, and a tooltip on every key, severity, and kind:

```bash
mzdiff --view --html --record "controllerType=0 controllerNumber=1 scan=5" --record "controllerType=0 controllerNumber=1 scan=6" trfp.mzML mzdata.mzML > diff.html
```

![The page for two records of the PRM pair](https://github.com/eneskemalergin/mzDiff/raw/main/assets/html-view.png)

## A tolerated run

The same run converted by [mzBridge](https://github.com/eneskemalergin/mzBridge) differs only in intensity precision, a minor class, so the verdict is `tolerated` and the exit status 0:

```text
$ mzdiff trfp.mzML mzbridge.mzML
A  trfp.mzML  (ThermoRawFileParser)
B  mzbridge.mzML  (mzBridge)
spectra        A 2103  B 2103  paired 2103
chromatograms  A 1  B 1  paired 1
result         tolerated: 0 critical, 0 major, 1 minor difference classes

minor
      2103  array precision differs    spectrum  array:MS:1000515 (intensity array)
            controllerType=0 controllerNumber=1 scan=1  A: float64  B: float32
            controllerType=0 controllerNumber=1 scan=2  A: float64  B: float32
            controllerType=0 controllerNumber=1 scan=3  A: float64  B: float32
```

## A run that cannot complete

A missing or unreadable file exits 3. With `--json`, stdout still gets a JSON error object, and stderr the line for people:

```text
$ mzdiff --json trfp.mzML nothere.mzML
{"type": "error", "schema_version": 1, "tool": {"name": "mzdiff", "version": "0.1.0"}, "error": "FileNotFound", "side": "b", "path": "nothere.mzML", "message": "no such file"}
mzdiff: B nothere.mzML: no such file
```
