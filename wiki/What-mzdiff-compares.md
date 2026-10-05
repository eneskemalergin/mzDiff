# What mzdiff compares

mzdiff judges B against A. What B adds that A lacks is a difference only where it loses or changes meaning, and every difference it finds is reported at a [severity](Severity), never dropped. What a file must be on its own (index offsets, checksum, schema) is left to [mzValidate](https://github.com/eneskemalergin/mzValidate).

## Records and pairing

- **Spectra** pair by their native id in any vendor's format (Thermo, Waters, Sciex, Bruker, or a mix); by the scan number when the two files write different id formats; or by position when neither works. Pairing assumes no order: a spectrum on one side only is reported once (`record missing in B`, `record only in B`), a spectrum in another place pairs anyway and is reported as `records out of order`, and the pairs around both stay correct.
- **Chromatograms** pair by id through the same join, so thousands of SRM traces pair by id rather than by position. Those left without a partner then pair by type, so a TIC with another id still pairs with the TIC.
- **Bounded memory.** A record waits for its partner in a window of 1,024 records or 64 MiB per side; beyond it, the oldest is reported missing. However different the files, memory stays bounded.

## Compared

- **The header**: file content, source file checksum, instrument configurations (model, serial, source, analyzer, detector), and the run's start time. Header facts compare as a set.
- **Every attribute, cvParam, and userParam** of each record, per element path, with its unit. Parameters taken through a parameter group compare as if written inline.
- **Units.** A unit B drops is a difference of at most major, since the value is intact, except a time's: without its unit a time could be seconds or minutes, so it keeps its key's severity. A unit B adds is minor; whether the term allows it is mzValidate's check.
- **Terms of the same kind.** When A and B each have a term the other lacks, at the same element and of the same kind in the PSI-MS vocabulary (two analyzers, two polarities, two dissociation methods), they are one difference: `another term`, at the severity of that kind. When B's term descends from A's (supplemental beam-type collision-induced dissociation for beam-type collision-induced dissociation), it is `a more specific term`, minor.
- **Repeated elements as wholes.** When an element repeats in a record (two precursors of an MS3 spectrum, several scan windows), each one of A, with everything under it, must match a distinct one of B. Charge 2 and charge 3 trading places between two precursors is `values regrouped`.
- **Precursor order.** A spectrum's precursors are the one repeated element whose order counts: they run from the nearest stage back, and readers take the first as the spectrum's precursor. The same precursors in another order are `precursorOrder`.
- **Each scan's instrument configuration**: the source, analyzer, and detector of the configuration the scan names (or the run's default), so a spectrum filed under the ion trap instead of the orbitrap differs even when both configurations exist in the header.
- **Arrays** as decoded values, matched by role (m/z, intensity, time, others) and unit. Time arrays in seconds and in minutes compare as the same values. The same peaks in another order are a difference (`array:peaks`): readers that deisotope or search the peaks assume rising m/z.
- **The index trailer.** An indexed file must end with `indexListOffset`, `fileChecksum`, and `</indexedmzML>`, the offset pointing at the index. B losing the index A has is a difference. A file cut short anywhere else fails to read (exit 2).

## Ignored

Bookkeeping that differs between tools and carries no meaning:

- Tool names and versions, cvList versions and URIs, dataProcessing, file locations, ids, index offsets, list counts, zlib or no compression, and encoded lengths.
- Parameter order, attribute order, whitespace, number spelling (`50` and `50.000`), the order of repeated elements other than precursors, seconds against minutes, and `.63Z` against `.630Z`.

Each of these is ignored by a rule, not by skipping code, so [`--set`](Severity#overrides) can turn any of them back on.

## Tolerances

Differences that remain but cannot change meaning are reported as minor:

- The last printed digit (`79.106` and `79.107`), or a shorter spelling that is the longer one rounded (`1.6` and `1.59`, not `1.5`). A value printed as an integer never counts as rounded (`26` against `26.112` is a value difference), and the precision of seconds carries into minutes.
- Values equal at 32-bit precision: one side stored a 32-bit float, the other the 64-bit value.
- m/z within `--ppm` (default 1 ppm), for m/z parameters and m/z arrays.
- Array precision: 32-bit against 64-bit storage.

## Form

Some differences leave every value the same but change how B wrote the data, in ways readers fail on. mzdiff reports these itself, under keys that start with `form:`, and only where B does it and A does not:

- `form:integer` (critical): a value the PSI-MS vocabulary types as an integer (`charge state`, `ms level`) written otherwise, such as `2.0`. It is outside the standard, and a reader that parses the declared type refuses it; Sage refuses the whole file.
- `form:paramGroup` (major): a spectrum or chromatogram that takes parameters through a `referenceableParamGroup`. It is valid mzML, but readers that do not resolve groups miss what the group holds; Sage then never sees the ms level and searches none of those spectra. Groups in the header are not reported.
- `form:numpress` (major): arrays in MS-Numpress. Valid, and the values match within its precision, but readers without Numpress cannot decode them; Sage drops those spectra.

A form outside the standard is critical; a form inside it that known readers cannot handle is major. Base64 broken by whitespace is valid too and makes Sage refuse the file, but the reader mzdiff is built on decodes the text as it streams and keeps none of it, so mzdiff cannot see it yet.
