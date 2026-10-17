# Untrusted input

mzdiff treats both input files as untrusted. Besides reading them through zmz's bounded parser:

- Text, TSV, and HTML output show control characters (C0, DEL, C1) and Unicode bidirectional overrides from the files as visible escapes (`\u{009b}`, `\u{202e}`), so a value cannot rewrite your terminal or make text display in another order than it reads. JSON carries the exact values, escaped as JSON.
- Pairing holds at most 1,024 waiting spectra or chromatograms, or 64 MiB, per side, whichever comes first; the strings a reader shares between records are capped at 8 MB; the report keeps at most 4,096 classes (further keys join one class per path, kind, and severity, and the list still shows each difference); the text view and the page refuse past their caps. However different or large two files are, memory stays bounded.
- A file that fails to read exits 3 with the reader's diagnostic. No partial report is printed as if it were complete.

## The HTML page

Every value from the files is escaped, so a hostile mzML cannot put markup or script into the page, and the page's script only hides and shows. A Content-Security-Policy, built from the SHA-256 digests of the page's own style and script, lets the browser run nothing else and fetch nothing at all, so even an edited copy of the page cannot run injected script.
