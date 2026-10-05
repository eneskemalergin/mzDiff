#!/usr/bin/env python3
"""Injects one defect at a time into a reference mzML and checks whether mzdiff flags it.

usage: ./mutate.py MZDIFF REFERENCE.mzML [CASE...]

Written for the PRM fixture (PXD006618/1fmol_HSP90_SILpepmix_PRM.mzML, TRFP output: scans 1..2103,
one base peak chromatogram). Expected misses: bad_index_offset, bad_checksum, index_attr (mzValidate
checks those), text_tab (XML turns a tab in an attribute into a space). serial_space shows only through the
shifted index offset, since values are trimmed. Every other case must be CAUGHT.
"""
import re, subprocess, sys, os, tempfile

MZDIFF = sys.argv[1]
REF = sys.argv[2]
ONLY = sys.argv[3:]
text = open(REF, encoding="utf-8").read()
handle, out = tempfile.mkstemp(suffix=".mzML", dir="/var/tmp")
os.close(handle)

def spectrum_block(t, scan):
    s = t.index(f'<spectrum id="controllerType=0 controllerNumber=1 scan={scan}"')
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
    assert old in blk, old
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

def charge_partial(t):  # 2 -> 2.4 would parse as number; use spelled
    return t

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

def empty_spectra(t):
    s = t.index("<spectrum ")
    s = t.rindex("\n", 0, s) + 1
    e = t.index("</spectrumList>")
    return t[:s] + t[e:]

CASES = {
    "swap_spectra": swap_spectra, "dup_spectrum": dup_spectrum, "drop_spectrum": drop_spectrum,
    "truncate_mid": truncate_mid, "truncate_after_spectra": truncate_after_spectra,
    "truncate_before_index": truncate_before_index, "chrom_time_unit": chrom_time_unit,
    "chrom_type_change": chrom_type_change, "sst_unit_dropped": sst_unit_dropped,
    "sst_coarse": sst_coarse, "ic_ref": ic_ref, "array_unit": array_unit, "default_len": default_len,
    "scan_id_format": scan_id_format, "bad_index_offset": bad_index_offset,
    "bad_checksum": bad_checksum, "index_attr": index_attr, "unit_only_b": unit_only_b,
    "text_tab": text_tab, "value_case": value_case, "empty_spectra": empty_spectra,
    "serial_space": serial_leading_zero,
}

for name, fn in CASES.items():
    if ONLY and name not in ONLY:
        continue
    try:
        m = fn(text)
    except Exception as e:
        print(f"{name:24} SETUP FAILED {e!r}")
        continue
    open(out, "w", encoding="utf-8").write(m)
    p = subprocess.run([MZDIFF, "--tsv", REF, out], capture_output=True, text=True)
    rows = [r.split("\t") for r in p.stdout.splitlines()[1:]]
    serious = [r for r in rows if r[0] in ("critical", "major")]
    flag = "CAUGHT" if p.returncode != 0 else "MISSED"
    print(f"{name:24} exit={p.returncode} {flag}  " + "; ".join(f"{r[0]}:{r[1]}:{r[4]}" for r in serious[:6])
          + (f"  stderr={p.stderr.strip()[:150]!r}" if p.stderr.strip() else "")
          + (f"  minor={len(rows) - len(serious)}" if rows else ""))
os.remove(out)
