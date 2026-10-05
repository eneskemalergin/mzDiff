# Usage

```text
mzdiff [options] A.mzML B.mzML
```

A is the reference, B the output under test; mzdiff judges B against A. `mzdiff --help` lists every option.

Modes choose what is shown, formats choose how, and selection narrows it. None of them changes the verdict.

## Modes

One at a time:

- **The report** (default): difference classes, most severe and most frequent first, with `--examples N` examples each.
- `--summary`: one line, the verdict and its counts.
- `--list`: every difference, one per line, in the order found, grouped under its record. An array that differs is one line with how many values differ and the largest difference.
- `--view`: the differing records as a git-style diff (see [The view](#the-view)).
- `-q`, `--quiet`: nothing; the exit status is the answer.

## Formats

- Text by default, colored under `--color auto|always|never`. `NO_COLOR` and `CLICOLOR_FORCE` are honored.
- `--json`: one document for the report and the summary, JSON Lines for `--list`, ending with a summary line. See [JSON output](JSON-output).
- `--tsv`: the report as tab-separated rows; the columns are stable for scripts.
- `--html`: with `--view`, one self-contained page (see [The page](#the-page)).

## Selection

- `--severity LEVEL` shows that level and above.
- `--key KEY` and, with `--list` or `--view`, `--record ID` keep only those keys and records. Each is repeatable.
- `--limit N` caps a list and says how much it held back, or sets how many records the view shows before it refuses (default 40, and 500 for the page).

[Severity](Severity#keys) lists the keys: PSI-MS accessions, `user:NAME`, `@NAME`, `array:ACCESSION`, the named checks, and the `form:` checks.

## Comparison options

- `--ppm X`: m/z within X ppm is a minor difference (default 1).
- `--set KEY=LEVEL`: give one key a severity (`critical`, `major`, `minor`, or `ignored`); see [Severity](Severity#overrides).
- `--no-header`: skip the header.
- `--max-spectra N`: stop after N paired spectra; the result is marked `incomplete`.
- `--fail-on LEVEL`: exit 1 at this severity or above (default `major`).

## Verdict and exit status

- `same`: no difference at all.
- `tolerated`: nothing at or above `--fail-on`.
- `differs`: something at or above `--fail-on`.

With `--max-spectra`, the result is also marked `incomplete`.

Exit status 0 for same or tolerated, 1 for differs, 2 for a usage error or an unreadable file. A file cut short or malformed fails to read; mzdiff never prints a partial report as if it were complete.

## The view

`--view` shows each differing record the way `git diff` shows a file: the record's native id, the element path, then `-` for A and `+` for B, with `~` where the difference is within a tolerance (rounding, 32-bit storage, ppm). Each pair is tagged with its severity. `--side-by-side` puts A and B in two columns (`--width N`, else `COLUMNS`, else 160).

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
```

The view is built in a bounded buffer while the comparison runs. When more than `--limit` records differ (default 40) or the text passes 1 MB, it shows nothing. Instead it says how many records differ at each severity, which severity would narrow it, and the keys that differ in the most records, so the next command is obvious.

## The page

`--view --html` writes the view as one self-contained page. Open it in any browser; nothing is fetched from the network. Each differing record is a collapsible section with A and B side by side (or unified, A above B), and the page has:

- severity filters that count the differences they hide or show, and a search over keys, names, values, and record ids (`/`);
- a layout switch (`u`), expand and collapse all (`e`, `c`), and `j`/`k` to step through the records;
- tooltips for every key, severity, and kind of difference, and for values too long for their column;
- the filters kept in the address (`diff.html#q=isolation&hide=minor&layout=unified`), so a link opens the same view;
- light and dark themes from the system setting.

Like the text view, the page is built in a bounded buffer: past 500 records (`--limit N`) or 16 MB it becomes a page that says how large the view would be and how to narrow it. [Untrusted input](Untrusted-input) describes how the page keeps a hostile file's values from running as markup or script.

## Recipes

```bash
mzdiff --view --severity major trfp.mzML tool.mzML                 # what matters, as a diff (refuses when too large)
mzdiff --view --side-by-side --record ID trfp.mzML tool.mzML       # one spectrum, A and B in two columns
mzdiff --view --html --severity major trfp.mzML tool.mzML > d.html # the same as a page to open and share
mzdiff --list --severity major trfp.mzML tool.mzML                 # everything that matters, spectrum by spectrum
mzdiff --list --key MS:1000512 trfp.mzML tool.mzML                 # how each filter string differs
mzdiff --list --record "controllerType=0 controllerNumber=1 scan=5" trfp.mzML tool.mzML
mzdiff --list --json trfp.mzML tool.mzML | jq -r 'select(.type == "difference") | .key' | sort | uniq -c
mzdiff -q trfp.mzML tool.mzML && echo "nothing that matters differs"
```
