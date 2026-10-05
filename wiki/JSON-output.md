# JSON output

There is no library API: the JSON is the machine interface. Keys and kinds are the stable contract; labels and names may improve.

## Report and summary

`--json` with the report or `--summary` prints one document (schema 1) with:

- `schema_version`
- both sides: `path`, `software`, `spectra`, `chromatograms`
- `paired`, `completion`, `status`, `fail_on`
- `totals`: classes per severity

The report adds `classes`, each with `severity`, `kind`, `label`, `path`, `key`, `name`, `records`, and `examples`.

## List

`--list --json` prints JSON Lines: one line per difference, then a summary line. A difference line has `type`, `record`, `severity`, `kind`, `path`, `key`, `name`, `a`, and `b`, and for arrays `values`, `differing`, and `largest`.

A run that fails part way (an unreadable record, say) ends the stream with `{"type": "error", "error": NAME}` instead of the summary line, so a reader can tell a cut stream from a complete one.

```bash
mzdiff --list --json A.mzML B.mzML | jq -r 'select(.type == "difference") | .key' | sort | uniq -c
```

## Kinds

The `kind` of a class or a difference is one of: `missing` and `extra` (a parameter or term on one side only), `value`, `unit`, `count` (how many of an element or parameter), `rounding`, `narrow` (equal at 32-bit precision), and `ppm` (the three tolerances, always minor), `record_missing` and `record_extra`, `order` (records out of their files' order), `element_order` (precursors in another order), `term` (B names another term of the same kind, such as another analyzer), `specific` (B names a more specific term, always minor), `regrouped` (values moved between repeated elements), `id_mismatch`, `peak_count`, `peak_values`, `peak_order`, `precision`, `array_missing`, and `array_extra`.

JSON carries the exact values from the files, escaped as JSON. The text, TSV, and HTML outputs show control characters as visible escapes instead ([Untrusted input](Untrusted-input)).
