# Consumer check

A severity is a claim about what a difference costs a reader. This page holds the evidence for those claims: one defect at a time injected into a real file, and what mzdiff, mzValidate, and a search engine (Sage) each made of it.

## How it was run

`tools/consumer.py` ([Development](Development#consumer-runs)) edited the same 200 spectra in each case: rank-1 target matches at 1% FDR in the reference, spread over the run. The reference was the ThermoRawFileParser mzML of a HeLa run on an Orbitrap Eclipse (PRIDE PXD016921, 36,341 spectra, about 11,290 target matches at 1% FDR), searched against the human proteome with Sage 0.15.0-beta.2.

Sage's outcome for the 200 spectra, in the Sage column: **fatal** (the run fails or reads nothing), **lost** (spectra vanish from its results), **wrong** (another peptide or charge, or a lost 1% match), **shifted** (the same matches with other scores, times, or masses), or **none**.

## Results

| Defect in B                  | mzDiff                    | mzValidate      | Sage                          |
| ---------------------------- | ------------------------- | --------------- | ----------------------------- |
| spectrum removed             | critical                  | error           | 200 lost                      |
| spectrum written twice       | critical                  | error           | 200 reported twice            |
| charge changed               | critical                  | valid           | 110 lost, 90 wrong            |
| charge removed               | critical                  | valid           | 6 wrong, 4 shifted            |
| charge written `2.0`         | critical (`form:integer`) | error           | fatal                         |
| precursor m/z 1 isotope off  | critical                  | valid           | 1 lost, 70 wrong, 129 shifted |
| precursor m/z 10 ppm off     | critical                  | valid           | 4 lost, 191 wrong             |
| precursor m/z 0.5 ppm off    | minor (`ppm`)             | valid           | 200 shifted                   |
| precursor m/z removed        | critical                  | valid           | 2 wrong, 43 shifted           |
| isolation target 1 m/z off   | critical                  | valid           | none                          |
| isolation offsets doubled    | major                     | valid           | none                          |
| precursor intensity removed  | major                     | valid           | none                          |
| `spectrumRef` removed        | major                     | valid           | none                          |
| collision energy changed     | major                     | valid           | none                          |
| ms level 2 written as 1      | critical                  | valid           | 200 lost                      |
| ms level written `2.0`       | critical (`form:integer`) | error           | fatal                         |
| centroid flag removed        | critical                  | error           | fatal                         |
| centroid changed to profile  | critical                  | valid           | fatal                         |
| total ion current set to 0   | critical                  | valid           | 200 lost                      |
| total ion current doubled    | major                     | valid           | none                          |
| filter string changed        | major                     | valid           | none                          |
| injection time doubled       | major                     | valid           | none                          |
| ms level through a group     | major (`form:paramGroup`) | valid           | 200 lost                      |
| time unit dropped            | critical                  | error           | fatal                         |
| time in minutes, labelled s  | critical                  | valid           | 1 wrong, 199 shifted          |
| time converted to seconds    | same                      | valid           | none                          |
| time one minute later        | critical                  | valid           | 200 shifted                   |
| time removed                 | critical                  | valid           | 2 wrong, 198 shifted          |
| intensity array removed      | critical                  | error           | fatal                         |
| most intense peak removed    | critical                  | valid           | 3 wrong, 95 shifted           |
| peaks in falling m/z order   | major (`array:peaks`)     | valid           | 6 wrong, 192 shifted          |
| intensities stored as 32-bit | minor (`precision`)       | valid           | none                          |
| m/z stored as 32-bit         | minor (`precision`)       | valid           | none                          |
| arrays uncompressed          | same                      | valid           | none                          |
| m/z array in Numpress        | major (`form:numpress`)   | error (wrongly) | 200 lost                      |
| Base64 broken across lines   | same (not visible yet)    | valid           | fatal                         |
| `defaultArrayLength` + 1     | exit 3                    | error           | none                          |
| native ids renamed           | critical                  | error           | none                          |
| index removed                | major (`indexed`)         | valid           | none                          |

- mzValidate reports MS-Numpress as an error, though Numpress is standard mzML.
- Base64 broken across lines is valid mzML; mzdiff cannot see it until its reader reports it.

## What it shows

- Every defect that changes Sage's matches or loses its spectra is major or critical in mzdiff, except base64 broken across lines, which mzdiff cannot see yet ([Form](What-mzdiff-compares#form)).
- mzdiff reports several defects mzValidate passes as valid (a changed charge, a zeroed total ion current, a profile label, a parameter group), while mzValidate checks what a file must be on its own, such as index offsets and checksums, which mzdiff leaves to it. Run both.
- Some critical or major differences cost Sage nothing (the isolation target, collision energy, the filter string). Sage is one reader: DIA tools take the isolation target as the precursor, and spectrum predictors use the collision energy.
- Four severities were raised because of this check: a total ion current of zero, a dropped time unit, peaks in falling order, and precursors in another order (which Sage reads through the first precursor). The `form:` checks came from it too.
