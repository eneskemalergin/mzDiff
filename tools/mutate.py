#!/usr/bin/env python3
"""Injects one defect at a time into a reference mzML and checks that mzdiff reports it.

usage: tools/mutate.py MZDIFF REFERENCE.mzML [CASE...]

Each case names the class it must raise, `exit 3`, `minor:KIND`, or nothing for the same result;
a case whose structure the reference lacks is skipped. The Development wiki page lists the
notation and the references that cover every case.

Exit status: 0 when every case that ran behaved as expected, 1 otherwise.
"""
import base64, re, struct, subprocess, sys, os, tempfile, zlib

import consumer


class Skip(Exception):
    pass


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

def drop_many(t):
    a0, _ = spectrum_block(t, 100)
    _, b1 = spectrum_block(t, 1699)
    return t[:a0] + t[b1:]

def truncate_mid(t):
    a0, _ = spectrum_block(t, 1000)
    return t[:a0 + 300]

def truncate_after_spectra(t):
    return t[:t.index("</spectrumList>") + len("</spectrumList>")]

def truncate_before_index(t):
    if "<indexList" not in t:
        raise Skip("the reference has no index")
    return t[:t.index("<indexList")]

def first_in_spectrum(t, scan, old, new):
    a0, a1 = spectrum_block(t, scan)
    blk = t[a0:a1]
    if old not in blk:
        raise Skip(f"scan {scan} has no {old!r}")
    return t[:a0] + blk.replace(old, new, 1) + t[a1:]

def first_chromatogram(t):
    i = t.find("<chromatogram ")
    if i < 0:
        raise Skip("the reference has no chromatogram")
    return i

def chrom_time_unit(t):
    i = first_chromatogram(t)
    j = t.index('unitAccession="UO:0000031" unitName="minute"', i)
    return t[:j] + 'unitAccession="UO:0000010" unitName="second"' + t[j + len('unitAccession="UO:0000031" unitName="minute"'):]

def chrom_type_change(t):
    i = first_chromatogram(t)
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
    if not m:
        raise Skip("scan 2000 has no scan start time")
    v = float(m.group(1))
    new = f"{round(v, 1) + 0.2:.1f}"
    blk = blk[:m.start(1)] + new + blk[m.end(1):]
    return t[:a0] + blk + t[a1:]

def ic_ref(t):
    return first_in_spectrum(t, 5, 'instrumentConfigurationRef="IC1"', 'instrumentConfigurationRef="IC99"')

def ic_other(t):
    if 'instrumentConfiguration id="IC2"' not in t:
        raise Skip("the reference has one instrument configuration")
    return first_in_spectrum(t, 5, 'instrumentConfigurationRef="IC1"', 'instrumentConfigurationRef="IC2"')

def array_unit(t):
    a0, a1 = spectrum_block(t, 5)
    blk = t[a0:a1]
    blk2 = re.sub(r'(accession="MS:1000515"[^>]*?unitAccession=")MS:1000131(" unitName=")[^"]*', r'\1UO:0000269\2absorbance unit', blk, count=1)
    assert blk2 != blk
    return t[:a0] + blk2 + t[a1:]

def mz_unit_dropped(t):
    return first_in_spectrum(t, 5, 'name="m/z array" unitAccession="MS:1000040" unitName="m/z" unitCvRef="MS"', 'name="m/z array"')

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

def array_in(t, scan, accession):
    a0, a1 = spectrum_block(t, scan)
    for m in re.finditer(r"<binaryDataArray .*?</binaryDataArray>", t[a0:a1], re.S):
        if f'accession="{accession}"' in m.group(0):
            return a0 + m.start(), a0 + m.end(), m.group(0)
    raise Skip(f"scan {scan} has no {accession} array")

def with_array(t, scan, accession, change, bits=None, compressed=None):
    start, end, xml = array_in(t, scan, accession)
    old_bits = 64 if "MS:1000523" in xml else 32 if "MS:1000521" in xml else None
    if old_bits is None:
        raise Skip(f"{accession} array is not 32- or 64-bit float")
    old_zlib = "MS:1000574" in xml
    payload = re.search(r"<binary>(.*?)</binary>", xml, re.S).group(1)
    raw = base64.b64decode(payload)
    raw = zlib.decompress(raw) if old_zlib else raw
    values = list(struct.unpack(f"<{len(raw) // (old_bits // 8)}{'d' if old_bits == 64 else 'f'}", raw))
    values = change(values)
    bits = bits or old_bits
    compressed = old_zlib if compressed is None else compressed
    raw = struct.pack(f"<{len(values)}{'d' if bits == 64 else 'f'}", *values)
    encoded = base64.b64encode(zlib.compress(raw) if compressed else raw).decode()
    xml = re.sub(r"<binary>.*?</binary>", f"<binary>{encoded}</binary>", xml, flags=re.S)
    xml = re.sub(r'encodedLength="\d+"', f'encodedLength="{len(encoded)}"', xml)
    precision = {64: ('MS:1000523', '64-bit float'), 32: ('MS:1000521', '32-bit float')}
    xml = re.sub(r'accession="MS:100052[13]" value="" name="[^"]*"', 'accession="%s" value="" name="%s"' % precision[bits], xml)
    if old_zlib and not compressed:
        xml = xml.replace('accession="MS:1000574" value="" name="zlib compression"', 'accession="MS:1000576" value="" name="no compression"')
    return t[:start] + xml + t[end:]

def scale_at(values, at, factor):
    values[at] *= factor
    return values

def param_value(t, scan, accession, change):
    a0, a1 = spectrum_block(t, scan)
    blk = t[a0:a1]
    m = re.search(rf'accession="{accession}" value="([^"]*)"', blk)
    if not m:
        raise Skip(f"scan {scan} has no {accession}")
    return t[:a0] + blk[:m.start(1)] + change(m.group(1)) + blk[m.end(1):] + t[a1:]

def tic_zero(t):
    return param_value(t, 5, "MS:1000285", lambda v: "0")

def ms_level_in_group(t):
    m = re.search(r'<referenceableParamGroupList count="(\d+)">\n', t)
    if not m:
        raise Skip("the reference has no parameter group list")
    group = ('      <referenceableParamGroup id="mutateMsLevel">\n'
             '        <cvParam cvRef="MS" accession="MS:1000511" value="2" name="ms level" />\n'
             '      </referenceableParamGroup>\n')
    t = t[:m.start()] + f'<referenceableParamGroupList count="{int(m.group(1)) + 1}">\n' + group + t[m.end():]
    a0, a1 = spectrum_block(t, 5)
    blk = t[a0:a1]
    line = re.search(r'[ \t]*<cvParam [^>]*accession="MS:1000511" value="2"[^>]*/>\n', blk)
    if not line:
        raise Skip("scan 5 is not ms level 2")
    blk = blk[:line.start()] + '          <referenceableParamGroupRef ref="mutateMsLevel" />\n' + blk[line.end():]
    return t[:a0] + blk + t[a1:]


def analyzer_swapped(t):
    old = '<cvParam cvRef="MS" accession="MS:1000484" value="" name="orbitrap" />'
    if old not in t:
        raise Skip("the header's analyzer is not orbitrap")
    return t.replace(old, '<cvParam cvRef="MS" accession="MS:1000079" value="" name="fourier transform ion cyclotron resonance mass spectrometer" />', 1)

HCD = 'accession="MS:1000422" value="" name="beam-type collision-induced dissociation"'

def single_precursor(t, scan):
    a0, a1 = spectrum_block(t, scan)
    if '<precursorList count="1">' not in t[a0:a1]:
        raise Skip(f"scan {scan} has not exactly one precursor")

def activation_swapped(t):
    single_precursor(t, 5)
    return first_in_spectrum(t, 5, HCD, 'accession="MS:1000598" value="" name="electron transfer dissociation"')

def activation_narrowed(t):
    single_precursor(t, 5)
    return first_in_spectrum(t, 5, HCD, 'accession="MS:1002678" value="" name="supplemental beam-type collision-induced dissociation"')


def in_spectrum(t, scan, edit, what):
    a0, a1 = spectrum_block(t, scan)
    blk = edit(t[a0:a1])
    if blk == t[a0:a1]:
        raise Skip(f"scan {scan} has no {what}")
    return t[:a0] + blk + t[a1:]

def charge_spelled(t):
    return param_value(t, 5, "MS:1000041", lambda v: v + ".0")

def mz_numpress(t):
    return in_spectrum(t, 5, consumer.numpress_mz, "m/z array")


def same_param_order(t):
    a0, a1 = spectrum_block(t, 5)
    lines = t[a0:a1].split("\n")
    top = [i for i, l in enumerate(lines) if re.match(r"^ {10}<cvParam ", l)]
    if len(top) < 2:
        raise Skip("scan 5 has fewer than two spectrum-level parameters")
    params = [lines[i] for i in top][::-1]
    for i, line in zip(top, params):
        lines[i] = line
    return t[:a0] + "\n".join(lines) + t[a1:]

def same_attribute_order(t):
    a0, a1 = spectrum_block(t, 5)
    blk = t[a0:a1]
    m = re.match(r'(\s*)<spectrum (id="[^"]*") (index="[^"]*") (defaultArrayLength="[^"]*")>', blk)
    if not m:
        raise Skip("scan 5's spectrum tag is not id, index, defaultArrayLength")
    return t[:a0] + f"{m.group(1)}<spectrum {m.group(4)} {m.group(3)} {m.group(2)}>" + blk[m.end():] + t[a1:]

def same_number_spelling(t):
    t = param_value(t, 5, "MS:1000927", lambda v: v + ".000" if "." not in v else v + "000")
    return param_value(t, 5, "MS:1000285", lambda v: f"{float(v):e}" if float(v) == float(f"{float(v):e}") else repr(float(v) / 10) + "e1")

def same_value_whitespace(t):
    return param_value(t, 5, "MS:1000927", lambda v: f" {v} ")

def same_seconds(t):
    t = param_value(t, 5, "MS:1000016", lambda v: repr(float(v) * 60))
    a0, a1 = spectrum_block(t, 5)
    blk = t[a0:a1]
    old = 'name="scan start time" unitAccession="UO:0000031" unitName="minute"'
    if old not in blk:
        raise Skip("scan 5's start time is not in minutes")
    return t[:a0] + blk.replace(old, 'name="scan start time" unitAccession="UO:0000010" unitName="second"') + t[a1:]

def same_uncompressed(t):
    return with_array(t, 5, "MS:1000514", lambda v: v, compressed=False)

def same_float32(t):
    return with_array(t, 5, "MS:1000515", lambda v: v, bits=32)

def same_peak_order(t):
    return with_array(with_array(t, 5, "MS:1000514", lambda v: v[::-1]), 5, "MS:1000515", lambda v: v[::-1])


def mz_param_inside(t):
    return param_value(t, 5, "MS:1000504", lambda v: repr(float(v) * (1 + 0.9e-6)))

def mz_param_outside(t):
    return param_value(t, 5, "MS:1000504", lambda v: repr(float(v) * (1 + 1.5e-6)))

def mz_array_inside(t):
    return with_array(t, 5, "MS:1000514", lambda v: scale_at(v, 3, 1 + 0.9e-6))

def mz_array_outside(t):
    return with_array(t, 5, "MS:1000514", lambda v: scale_at(v, 3, 1 + 1.5e-6))

def intensity_inside(t):
    return with_array(t, 5, "MS:1000515", lambda v: scale_at(v, 3, 1 + 5e-8))

def intensity_outside(t):
    return with_array(t, 5, "MS:1000515", lambda v: scale_at(v, 3, 1 + 1e-6))

def rounding_inside(t):
    return param_value(t, 5, "MS:1000016", lambda v: f"{float(v):.3f}")

def rounding_outside(t):
    return param_value(t, 5, "MS:1000016", lambda v: f"{round(float(v), 3) + 0.002:.3f}")

def empty_spectra(t):
    s = t.index("<spectrum ")
    s = t.rindex("\n", 0, s) + 1
    e = t.index("</spectrumList>")
    return t[:s] + t[e:]

UNREADABLE = "exit 3"

CASES = [
    ("swap_spectra", swap_spectra, "order"),
    ("dup_spectrum", dup_spectrum, "@id"),
    ("drop_spectrum", drop_spectrum, "@id"),
    ("drop_many", drop_many, "@id"),
    ("empty_spectra", empty_spectra, "@id"),
    ("truncate_mid", truncate_mid, UNREADABLE),
    ("truncate_after_spectra", truncate_after_spectra, UNREADABLE),
    ("truncate_before_index", truncate_before_index, "indexListOffset"),
    ("default_len", default_len, UNREADABLE),
    ("chrom_time_unit", chrom_time_unit, "array:MS:1000595"),
    ("chrom_type_change", chrom_type_change, "MS:1000628"),
    ("sst_unit_dropped", sst_unit_dropped, "MS:1000016"),
    ("tic_zero", tic_zero, "MS:1000285"),
    ("sst_coarse", sst_coarse, "MS:1000016"),
    ("value_case", value_case, "MS:1000512"),
    ("ic_ref", ic_ref, "instrumentConfiguration"),
    ("ic_other", ic_other, "MS:1000484"),
    ("array_unit", array_unit, "array:MS:1000515"),
    ("mz_unit_dropped", mz_unit_dropped, "array:MS:1000514"),
    ("scan_id_format", scan_id_format, "@id"),
    ("swap_precursor_charge", swap_precursor_charge, "MS:1000041"),
    ("swap_precursor_energy", swap_precursor_energy, "MS:1000045"),
    ("reorder_precursors", reorder_precursors, "precursorOrder"),
    ("same_param_order", same_param_order, None),
    ("same_attribute_order", same_attribute_order, None),
    ("same_number_spelling", same_number_spelling, None),
    ("same_value_whitespace", same_value_whitespace, None),
    ("same_seconds", same_seconds, None),
    ("ms_level_in_group", ms_level_in_group, "form:paramGroup"),
    ("charge_spelled", charge_spelled, "form:integer"),
    ("analyzer_swapped", analyzer_swapped, "MS:1000484 (term)"),
    ("activation_swapped", activation_swapped, "MS:1000422 (term)"),
    ("activation_narrowed", activation_narrowed, "minor:specific"),
    ("mz_numpress", mz_numpress, "form:numpress"),
    ("same_uncompressed", same_uncompressed, None),
    ("same_float32", same_float32, "minor:precision"),
    ("peaks_reversed", same_peak_order, "array:peaks"),
    ("mz_param_inside", mz_param_inside, "minor:ppm"),
    ("mz_param_outside", mz_param_outside, "MS:1000504"),
    ("mz_array_inside", mz_array_inside, "minor:ppm"),
    ("mz_array_outside", mz_array_outside, "array:MS:1000514"),
    ("intensity_inside", intensity_inside, "minor:narrow"),
    ("intensity_outside", intensity_outside, "array:MS:1000515"),
    ("rounding_inside", rounding_inside, "minor:rounding"),
    ("rounding_outside", rounding_outside, "MS:1000016"),
    ("unit_only_b", unit_only_b, "minor:unit"),
    ("bad_index_offset", bad_index_offset, None),
    ("bad_checksum", bad_checksum, None),
    ("index_attr", index_attr, None),
    ("text_tab", text_tab, None),
    ("serial_space", serial_leading_zero, None),
]

failed = 0
try:
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
        if expect != "indexListOffset":
            rows = [r for r in rows if r[4] != "indexListOffset"]
        serious = {r[4] for r in rows if r[0] in ("critical", "major")}
        kinded = {f"{r[4]} ({r[1]})" for r in rows if r[0] in ("critical", "major")}
        minor = {r[1] for r in rows if r[0] == "minor"}
        if expect == UNREADABLE:
            ok = run.returncode == 3
        elif expect is None:
            ok = run.returncode in (0, 1) and not rows
        elif expect.startswith("minor:"):
            ok = run.returncode in (0, 1) and not serious and expect[len("minor:"):] in minor
        elif expect.endswith(")"):
            ok = expect in kinded
        else:
            ok = expect in serious
        failed += not ok
        got = f"exit {run.returncode}" if run.returncode >= 2 else (", ".join(sorted(serious) + [f"minor:{k}" for k in sorted(minor)]) or "same")
        print(f"{name:24} {'ok    ' if ok else 'FAIL  '} expected {expect or 'same'}; got {got}")
finally:
    os.remove(out)
sys.exit(1 if failed else 0)
