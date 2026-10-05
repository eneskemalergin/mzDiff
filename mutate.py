#!/usr/bin/env python3
"""Injects one defect at a time into a reference mzML and checks that mzdiff reports it.

usage: ./mutate.py MZDIFF REFERENCE.mzML [CASE...]

Each case names the key of the critical or major class it must raise, `exit 2` when the file must
fail to read, or nothing when B must compare the same (a non-defect, or a defect mzValidate owns).
An edit that shifts bytes also breaks the index offset; that `indexListOffset` class is ignored
unless the case is about the trailer. A case whose structure the reference lacks is skipped.
The PRM fixture (PXD006618/1fmol_HSP90_SILpepmix_PRM.mzML) has every single-precursor structure;
an MS3 reference with two precursors per spectrum (PXD070648) has the multi-precursor ones.

Exit status: 0 when every case that ran behaved as expected, 1 otherwise.
"""
import re, subprocess, sys, os, tempfile


class Skip(Exception):
    """The reference has no structure for this case."""


MZDIFF = sys.argv[1]
REF = sys.argv[2]
ONLY = sys.argv[3:]
text = open(REF, encoding="utf-8").read()
handle, out = tempfile.mkstemp(suffix=".mzML", dir="/var/tmp")
os.close(handle)

def spectrum_block(t, scan):
    at = t.find(f'<spectrum id="controllerType=0 controllerNumber=1 scan={scan}"')
    if at < 0:
        raise Skip(f"no scan {scan}")
    s = at
    s = t.rindex("\n", 0, s) + 1
    e = t.index("</spectrum>", s) + len("</spectrum>\n")
    return s, e

def swap_spectra(t):
    a0, a1 = spectrum_block(t, 10); b0, b1 = spectrum_block(t, 11)
    return t[:a0] + t[b0:b1] + t[a0:a1] + t[b1:]

def dup_spectrum(t):
    a0, a1 = spectrum_block(t, 10)
    return t[:a1] + t[a0:a1] + t[a1:]

def drop_spectrum(t):
    a0, a1 = spectrum_block(t, 10)
    return t[:a0] + t[a1:]

def truncate_mid(t):
    a0, _ = spectrum_block(t, 1000)
    return t[:a0 + 300]

def truncate_after_spectra(t):
    return t[:t.index("</spectrumList>") + len("</spectrumList>")]

def truncate_before_index(t):
    return t[:t.index("<indexList")]

def first_in_spectrum(t, scan, old, new):
    a0, a1 = spectrum_block(t, scan)
    blk = t[a0:a1]
    if old not in blk:
        raise Skip(f"scan {scan} has no {old!r}")
    return t[:a0] + blk.replace(old, new, 1) + t[a1:]

def chrom_time_unit(t):
    i = t.index("<chromatogram ")
    j = t.index('unitAccession="UO:0000031" unitName="minute"', i)
    return t[:j] + 'unitAccession="UO:0000010" unitName="second"' + t[j + len('unitAccession="UO:0000031" unitName="minute"'):]

def chrom_type_change(t):
    i = t.index("<chromatogram ")
    e = t.index("</chromatogram>", i)
    blk = t[i:e]
    blk2 = re.sub(r'accession="MS:\d+" value="" name="[^"]*chromatogram"', 'accession="MS:1000235" value="" name="total ion current chromatogram"', blk, count=1)
    return t[:i] + blk2 + t[e:]

def sst_unit_dropped(t):
    return first_in_spectrum(t, 5, ' unitAccession="UO:0000031" unitName="minute" unitCvRef="UO"', "")

def sst_coarse(t):
    a0, a1 = spectrum_block(t, 2000)
    blk = t[a0:a1]
    m = re.search(r'accession="MS:1000016" value="([^"]+)"', blk)
    v = float(m.group(1))
    new = f"{v + 0.09:.1f}"  # off by up to ~5 s, printed with one decimal
    blk = blk[:m.start(1)] + new + blk[m.end(1):]
    return t[:a0] + blk + t[a1:]

def ic_ref(t):
    return first_in_spectrum(t, 5, 'instrumentConfigurationRef="IC1"', 'instrumentConfigurationRef="IC2"')

def array_unit(t):
    a0, a1 = spectrum_block(t, 5)
    blk = t[a0:a1]
    blk2 = re.sub(r'(accession="MS:1000515"[^>]*?unitAccession=")MS:1000131(" unitName=")[^"]*', r'\1UO:0000269\2absorbance unit', blk, count=1)
    assert blk2 != blk
    return t[:a0] + blk2 + t[a1:]

def default_len(t):
    a0, a1 = spectrum_block(t, 5)
    blk = t[a0:a1]
    m = re.search(r'defaultArrayLength="(\d+)"', blk)
    blk = blk[:m.start(1)] + str(int(m.group(1)) + 1) + blk[m.end(1):]
    return t[:a0] + blk + t[a1:]

def scan_id_format(t):
    return first_in_spectrum(t, 5, 'id="controllerType=0 controllerNumber=1 scan=5"', 'id="controllerType=0 controllerNumber=2 scan=5"')

def serial_leading_zero(t):
    return t.replace('value="FSN10178"', 'value="FSN10178 "', 1)

def bad_index_offset(t):
    return t.replace('<offset idRef="controllerType=0 controllerNumber=1 scan=2">', '<offset idRef="controllerType=0 controllerNumber=1 scan=2">1', 1)

def bad_checksum(t):
    return re.sub(r"<fileChecksum>[0-9a-f]+", "<fileChecksum>" + "0" * 40, t)

def index_attr(t):
    return first_in_spectrum(t, 5, 'index="4"', 'index="7"')

def unit_only_b(t):
    return first_in_spectrum(t, 5, 'name="ms level"', 'name="ms level" unitAccession="UO:0000010" unitName="second" unitCvRef="UO"')

def text_tab(t):
    return first_in_spectrum(t, 5, 'name="filter string"', 'name="filter string"').replace(
        'FTMS + c NSI Full ms2', 'FTMS + c NSI\tFull ms2', 1)

def value_case(t):
    return first_in_spectrum(t, 5, 'FTMS + c NSI Full ms2', 'ftms + c NSI Full ms2')

def two_precursors(t):
    i = t.find('<precursorList count="2">')
    if i < 0:
        raise Skip("no spectrum with two precursors")
    return i, t.index("</precursorList>", i)

def swap_values(t, accession):
    i, e = two_precursors(t)
    blk = t[i:e]
    values = re.findall(rf'accession="{accession}" value="([^"]+)"', blk)
    if len(values) != 2 or values[0] == values[1]:
        raise Skip(f"the precursors do not hold two different {accession} values")
    swapped = iter(values[::-1])
    blk = re.sub(rf'(accession="{accession}" value=")([^"]+)', lambda m: m.group(1) + next(swapped), blk)
    return t[:i] + blk + t[e:]

def swap_precursor_charge(t):
    return swap_values(t, "MS:1000041")

def swap_precursor_energy(t):
    return swap_values(t, "MS:1000045")

def reorder_precursors(t):
    i, e = two_precursors(t)
    blk = t[i:e]
    starts = [m.start() for m in re.finditer(r"[ \t]*<precursor[ >]", blk)]
    end = blk.rindex("</precursor>") + len("</precursor>")
    first, second = blk[starts[0]:starts[1]], blk[starts[1]:end]
    return t[:i] + blk[:starts[0]] + second.rstrip() + "\n" + first.rstrip() + blk[end:] + t[e:]

def empty_spectra(t):
    s = t.index("<spectrum ")
    s = t.rindex("\n", 0, s) + 1
    e = t.index("</spectrumList>")
    return t[:s] + t[e:]

EXIT2 = "exit 2"

# Case name, edit, and what mzdiff must report: a class key, EXIT2, or None for the same.
CASES = [
    ("swap_spectra", swap_spectra, "scan"),
    ("dup_spectrum", dup_spectrum, "scan"),
    ("drop_spectrum", drop_spectrum, "@id"),
    ("empty_spectra", empty_spectra, "@id"),
    ("truncate_mid", truncate_mid, EXIT2),
    ("truncate_after_spectra", truncate_after_spectra, EXIT2),
    ("truncate_before_index", truncate_before_index, "indexListOffset"),
    ("default_len", default_len, EXIT2),
    ("chrom_time_unit", chrom_time_unit, "array:MS:1000595"),
    ("chrom_type_change", chrom_type_change, "MS:1000628"),
    ("sst_unit_dropped", sst_unit_dropped, "MS:1000016"),
    ("sst_coarse", sst_coarse, "MS:1000016"),
    ("value_case", value_case, "MS:1000512"),
    ("ic_ref", ic_ref, "instrumentConfiguration"),
    ("array_unit", array_unit, "array:MS:1000515"),
    ("scan_id_format", scan_id_format, "id"),
    ("swap_precursor_charge", swap_precursor_charge, "MS:1000041"),
    ("swap_precursor_energy", swap_precursor_energy, "MS:1000045"),
    ("reorder_precursors", reorder_precursors, None),
    # mzValidate checks these (a unit the term does not allow, the index, the checksum); mzdiff
    # must stay quiet about them, or file them as minor.
    ("unit_only_b", unit_only_b, None),
    ("bad_index_offset", bad_index_offset, None),
    ("bad_checksum", bad_checksum, None),
    ("index_attr", index_attr, None),
    # Not defects: XML turns a tab in an attribute into a space, and values are trimmed.
    ("text_tab", text_tab, None),
    ("serial_space", serial_leading_zero, None),
]

failed = 0
for name, edit, expect in CASES:
    if ONLY and name not in ONLY:
        continue
    try:
        mutated = edit(text)
    except Skip as reason:
        print(f"{name:24} skip   {reason}")
        continue
    if mutated == text:
        print(f"{name:24} skip   the edit found nothing to change")
        continue
    open(out, "w", encoding="utf-8").write(mutated)
    run = subprocess.run([MZDIFF, "--tsv", REF, out], capture_output=True, text=True)
    rows = [r.split("\t") for r in run.stdout.splitlines()[1:]]
    serious = {r[4] for r in rows if r[0] in ("critical", "major")}
    if expect != "indexListOffset":
        serious.discard("indexListOffset")
    if expect == EXIT2:
        ok = run.returncode == 2
    elif expect is None:
        ok = run.returncode in (0, 1) and not serious
    else:
        ok = expect in serious
    failed += not ok
    got = f"exit {run.returncode}" if run.returncode == 2 else (", ".join(sorted(serious)) or "same")
    print(f"{name:24} {'ok    ' if ok else 'FAIL  '} expected {expect or 'same'}; got {got}")
os.remove(out)
sys.exit(1 if failed else 0)
