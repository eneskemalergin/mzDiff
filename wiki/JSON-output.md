# JSON output

There is no library API: the JSON is the machine interface. Keys and kinds are the stable contract; labels and names may improve.

## Report and summary

`--json` with the report or `--summary` prints one document (schema 1) with:

- `schema_version`, and `tool` (`name`, `version`): which mzdiff wrote it
- both sides: `path`, `software`, `spectra`, `chromatograms`
- `paired`, `completion`, `status`, `fail_on`
- `totals`: classes per severity

The report adds `classes`, each with `severity`, `kind`, `label`, `path`, `key`, `name`, `records`, and `examples`.

## List

`--list --json` prints JSON Lines: one line per difference, then a summary line. A difference line has `type`, `record`, `severity`, `kind`, `path`, `key`, `name`, `a`, and `b`, and for arrays `values`, `differing`, and `largest`.

A run that fails part way (an unreadable record, say) ends the stream with the error object below instead of the summary line, so a reader can tell a cut stream from a complete one.

```bash
mzdiff --list --json A.mzML B.mzML | jq -r 'select(.type == "difference") | .key' | sort | uniq -c
```

## Errors

A run that cannot complete (exit 3) prints one error object: the whole output for the report and the summary, the last line for the list.

```json
{"type": "error", "schema_version": 1, "tool": {"name": "mzdiff", "version": "0.1.0"}, "error": "FileNotFound", "side": "b", "path": "tool.mzML", "message": "no such file"}
```

- `error`: the error's name, stable for scripts (`FileNotFound`, `IsDir`, `InvalidXml`, `DecodedSizeMismatch`, ...).
- `side` and `path`: which file, or `null` when the failure is not one file's (out of memory, an output that cannot be written).
- `message`: a sentence for people; for a malformed file, the reader's diagnostic with its code and position.

A usage error (exit 2) prints no JSON: the command itself is wrong, and stderr says how.

## Kinds

The `kind` of a class or a difference is one of: `missing` and `extra` (a parameter or term on one side only), `value`, `unit`, `count` (how many of an element or parameter), `rounding`, `narrow` (equal at 32-bit precision), and `ppm` (the three tolerances, always minor), `record_missing` and `record_extra`, `order` (records out of their files' order), `element_order` (precursors in another order), `term` (B names another term of the same kind, such as another analyzer), `specific` (B names a more specific term, always minor), `regrouped` (values moved between repeated elements), `id_mismatch`, `peak_count`, `peak_values`, `peak_order`, `precision`, `array_missing`, and `array_extra`.

JSON carries the exact values from the files, escaped as JSON. The text, TSV, and HTML outputs show control characters as visible escapes instead ([Untrusted input](Untrusted-input)).
