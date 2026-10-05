#!/usr/bin/env python3
"""Injects one defect at a time into spectra a search engine identifies, then runs both mzdiff
and the engine (Sage) on the result, to set mzdiff's severity beside what a real consumer does.

usage: tools/consumer.py [-o OUT] [-n SCANS] [--sage P] [--validate P] --fasta P MZDIFF REFERENCE.mzML [CASE...]
       tools/consumer.py --compare [-o OUT] [--sage P] [--validate P] --fasta P MZDIFF REFERENCE.mzML B.mzML...

Each case edits the same SCANS spectra (default 200): rank-1 target matches at 1% FDR in the
reference, spread over the run. The engine's result for those spectra is then one of:

  fatal    the run fails, or reads no spectra
  lost     some edited spectra vanish from the results (dropped, not searched, or no candidate)
  wrong    some edited spectra change peptide or charge, lose their 1% FDR match, or are
           reported more than once
  shifted  the same matches, with other scores, retention times, or masses
  none     the edited spectra's results are unchanged

and mzdiff's verdict is its most severe class (`indexListOffset` ignored: every edit shifts bytes).
mzValidate's error rules are listed beside it (the `mzml.index.` rules ignored, for the same
reason), since `corpus.sh` folds both into one status. A case is flagged MISSED when the engine is
hurt (fatal, lost, wrong) and neither tool says major or an error, UNDER when the engine fails or
loses spectra and mzdiff says major, STRICT when mzdiff says critical and the engine is unaffected
(other consumers may still be). `--compare` runs the engine
on converter outputs instead and compares every spectrum with the reference's results.

Sage and mzValidate come from the mzBridge checkout (MZBRIDGE, default ../mzBridge beside this
repository), as for corpus.sh. The FASTA (--fasta, or MZDIFF_FASTA) must match the reference's
organism; the engine settings suit Orbitrap HCD runs.
Writes OUT/consumer.tsv; the edited files are removed as soon as each case is done.
"""
import argparse, base64, csv, json, math, os, re, shutil, struct, subprocess, sys, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.environ.get("MZBRIDGE") or os.path.join(HERE, "..", "..", "mzBridge")
SAGE = os.path.join(BRIDGE, "tools", "bin", "sage")
VALIDATE = os.path.join(BRIDGE, "tools", "bin", "mzValidate")
FASTA = os.environ.get("MZDIFF_FASTA")

SETTINGS = {
    "database": {
        "bucket_size": 32768,
        "enzyme": {"missed_cleavages": 2, "min_len": 7, "max_len": 50, "cleave_at": "KR", "restrict": "P"},
        "fragment_min_mz": 150.0, "fragment_max_mz": 2000.0,
        "peptide_min_mass": 500.0, "peptide_max_mass": 5000.0,
        "ion_kinds": ["b", "y"], "min_ion_index": 2,
        "static_mods": {"C": 57.0215}, "variable_mods": {"M": [15.9949]}, "max_variable_mods": 2,
        "decoy_tag": "rev_", "generate_decoys": True,
    },
    "precursor_tol": {"ppm": [-10, 10]}, "fragment_tol": {"ppm": [-20, 20]},
    "isotope_errors": [0, 2], "deisotope": True, "chimera": False, "predict_rt": True,
    "min_peaks": 15, "max_peaks": 150, "min_matched_peaks": 4, "report_psms": 1,
    "quant": {"lfq": True},
}


class Skip(Exception):
    """The reference has no structure for this case."""


# Edits of one spectrum's XML. Each returns the new block, or the same block when it does not apply.

def param_line(block, accession):
    return re.search(rf'[ \t]*<cvParam [^>]*accession="{accession}"[^>]*/>\n', block)

def drop_param(accession):
    def edit(block):
        m = param_line(block, accession)
        return block[:m.start()] + block[m.end():] if m else block
    return edit

def set_value(accession, change):
    def edit(block):
        m = re.search(rf'(accession="{accession}" value=")([^"]*)', block)
        return block[:m.start(2)] + change(m.group(2)) + block[m.end(2):] if m else block
    return edit

def replace(old, new):
    return lambda block: block.replace(old, new, 1)

def chain(*edits):
    def edit(block):
        for e in edits:
            block = e(block)
        return block
    return edit

def arrays(block):
    return list(re.finditer(r"<binaryDataArray .*?</binaryDataArray>", block, re.S))

def decode(xml):
    bits = 64 if "MS:1000523" in xml else 32
    payload = re.search(r"<binary>(.*?)</binary>", xml, re.S).group(1)
    raw = base64.b64decode(payload)
    raw = zlib.decompress(raw) if "MS:1000574" in xml else raw
    return list(struct.unpack(f"<{len(raw) // (bits // 8)}{'d' if bits == 64 else 'f'}", raw))

def encode(xml, values, bits=None, compressed=None):
    bits = bits or (64 if "MS:1000523" in xml else 32)
    compressed = ("MS:1000574" in xml) if compressed is None else compressed
    raw = struct.pack(f"<{len(values)}{'d' if bits == 64 else 'f'}", *values)
    text = base64.b64encode(zlib.compress(raw) if compressed else raw).decode()
    xml = re.sub(r"<binary>.*?</binary>", f"<binary>{text}</binary>", xml, flags=re.S)
    xml = re.sub(r'encodedLength="\d+"', f'encodedLength="{len(text)}"', xml)
    name = {64: "64-bit float", 32: "32-bit float"}[bits]
    xml = re.sub(r'accession="MS:100052[13]" value="" name="[^"]*"', f'accession="MS:10005{23 if bits == 64 else 21}" value="" name="{name}"', xml)
    if not compressed:
        xml = xml.replace('accession="MS:1000574" value="" name="zlib compression"', 'accession="MS:1000576" value="" name="no compression"')
    return xml

def with_arrays(change, bits=None, compressed=None, which=None):
    """Decodes the m/z and intensity arrays, applies `change(mz, intensity)`, and encodes the
    arrays named in `which` (all by default) again."""
    def edit(block):
        found = {("mz" if 'accession="MS:1000514"' in m.group(0) else "i"): m for m in arrays(block)
                 if 'accession="MS:1000514"' in m.group(0) or 'accession="MS:1000515"' in m.group(0)}
        if len(found) != 2:
            return block
        mz, inten = change(decode(found["mz"].group(0)), decode(found["i"].group(0)))
        new = {"mz": mz, "i": inten}
        length = len(decode(found["mz"].group(0)))
        for key in sorted(found, key=lambda k: -found[k].start()):
            if which and key not in which:
                continue
            m = found[key]
            block = block[:m.start()] + encode(m.group(0), new[key], bits, compressed) + block[m.end():]
        if len(mz) != length:
            block = re.sub(r'defaultArrayLength="\d+"', f'defaultArrayLength="{len(mz)}"', block, count=1)
        return block
    return edit

def drop_array(accession):
    def edit(block):
        for m in arrays(block):
            if f'accession="{accession}"' in m.group(0):
                start = block.rindex("\n", 0, m.start()) + 1
                end = block.index("\n", m.end()) + 1
                block = block[:start] + block[end:]
                return re.sub(r'<binaryDataArrayList count="(\d+)"', lambda c: f'<binaryDataArrayList count="{int(c.group(1)) - 1}"', block, count=1)
        return block
    return edit

def wrap_base64(block):
    def wrap(m):
        text = m.group(1)
        return "<binary>" + "\n".join(text[i:i + 76] for i in range(0, len(text), 76)) + "</binary>"
    return re.sub(r"<binary>(.*?)</binary>", wrap, block, count=1, flags=re.S)

def numpress_nibbles(x):
    """One residual in MS-Numpress's half-byte integer code."""
    x &= 0xFFFFFFFF
    mask = 0xF0000000
    head = x & mask
    if head == 0:
        skip = next((i for i in range(8) if x & (mask >> (4 * i))), 8)
        return [skip] + [(x >> (4 * j)) & 0xF for j in range(8 - skip)]
    if head == mask:
        skip = next((i for i in range(8) if x & (mask >> (4 * i)) != mask >> (4 * i)), 7)
        return [skip + 8] + [(x >> (4 * j)) & 0xF for j in range(8 - skip)]
    return [0] + [(x >> (4 * j)) & 0xF for j in range(8)]

def numpress_linear(values):
    """MS-Numpress linear prediction, as the reference implementation writes it."""
    top = max(values[:2])
    for i in range(2, len(values)):
        guess = values[i - 1] + (values[i - 1] - values[i - 2])
        top = max(top, math.ceil(abs(values[i] - guess) + 1))
    fixed = math.floor(0x7FFFFFFF / top)
    out = bytearray(struct.pack(">d", fixed))
    ints = [int(v * fixed + 0.5) for v in values]
    for v in ints[:2]:
        out += struct.pack("<I", v)
    nibbles = []
    for i in range(2, len(ints)):
        nibbles += numpress_nibbles(ints[i] - (2 * ints[i - 1] - ints[i - 2]))
    if len(nibbles) % 2:
        nibbles.append(0)
    out += bytes((nibbles[i] << 4) | nibbles[i + 1] for i in range(0, len(nibbles), 2))
    return bytes(out)

def numpress_array(xml):
    """The m/z array re-encoded in MS-Numpress linear (no zlib), its other parameters kept."""
    values = decode(xml)
    if len(values) < 3:
        return xml
    text = base64.b64encode(numpress_linear(values)).decode()
    xml = re.sub(r"<binary>.*?</binary>", f"<binary>{text}</binary>", xml, flags=re.S)
    xml = re.sub(r'encodedLength="\d+"', f'encodedLength="{len(text)}"', xml)
    return re.sub(r'accession="MS:100057[46]" value="" name="[^"]*"', 'accession="MS:1002312" value="" name="MS-Numpress linear prediction compression"', xml)

def numpress_mz(block):
    for m in arrays(block):
        if 'accession="MS:1000514"' in m.group(0):
            return block[:m.start()] + numpress_array(m.group(0)) + block[m.end():]
    return block

def drop_top_peak(mz, inten):
    top = max(range(len(inten)), key=inten.__getitem__)
    return mz[:top] + mz[top + 1:], inten[:top] + inten[top + 1:]

def shift_ppm(ppm):
    return lambda v: repr(float(v) * (1 + ppm * 1e-6))

def add(delta):
    return lambda v: repr(float(v) + delta)

def times(factor):
    return lambda v: repr(float(v) * factor)

def rt_to_seconds(block):
    m = re.search(r'accession="MS:1000016" value="([^"]+)" name="scan start time" unitAccession="UO:0000031" unitName="minute"', block)
    if not m:
        return block
    new = f'accession="MS:1000016" value="{float(m.group(1)) * 60!r}" name="scan start time" unitAccession="UO:0000010" unitName="second"'
    return block[:m.start()] + new + block[m.end():]

GROUP = ('      <referenceableParamGroup id="mzdiffMs2">\n'
         '        <cvParam cvRef="MS" accession="MS:1000511" value="2" name="ms level" />\n'
         '        <cvParam cvRef="MS" accession="MS:1000127" value="" name="centroid spectrum" />\n'
         '      </referenceableParamGroup>\n')

def group_header(text):
    """Adds a parameter group holding ms level 2 and centroid to the header."""
    m = re.search(r'<referenceableParamGroupList count="(\d+)">\n', text)
    if m:
        return text[:m.start()] + f'<referenceableParamGroupList count="{int(m.group(1)) + 1}">\n' + GROUP + text[m.end():]
    at = text.index("<softwareList")
    at = text.rindex("\n", 0, at) + 1
    return text[:at] + '    <referenceableParamGroupList count="1">\n' + GROUP + "    </referenceableParamGroupList>\n" + text[at:]

def group_ref(block):
    if not param_line(block, "MS:1000511") or not param_line(block, "MS:1000127"):
        return block
    block = drop_param("MS:1000127")(drop_param("MS:1000511")(block))
    first = block.index("\n") + 1
    return block[:first] + '          <referenceableParamGroupRef ref="mzdiffMs2" />\n' + block[first:]

def strip_index(text):
    """The mzML without its indexedmzML wrapper, keeping the namespace the wrapper declared."""
    start = text.index("<mzML")
    end = text.index("</mzML>") + len("</mzML>")
    body = text[start:end]
    if ' xmlns="' not in body[:body.index(">")]:
        body = '<mzML xmlns="http://psi.hupo.org/ms/mzml"' + body[len("<mzML"):]
    return '<?xml version="1.0" encoding="utf-8"?>\n' + body + "\n"

# Each case: name, the edit of every chosen spectrum, and an optional edit of the whole file.
CASES = [
    # Anchors: what every consumer must see.
    ("drop_spectrum", lambda b: "", None),
    ("duplicate_spectrum", lambda b: b + b, None),
    # Precursor.
    ("charge_changed", set_value("MS:1000041", lambda v: str(int(v) + 1)), None),
    ("charge_removed", drop_param("MS:1000041"), None),
    ("charge_spelled_2.0", set_value("MS:1000041", lambda v: v + ".0"), None),
    ("selected_mz_isotope", set_value("MS:1000744", add(1.003355)), None),
    ("selected_mz_10ppm", set_value("MS:1000744", shift_ppm(10)), None),
    ("selected_mz_0.5ppm", set_value("MS:1000744", shift_ppm(0.5)), None),
    ("selected_mz_removed", drop_param("MS:1000744"), None),
    ("isolation_target_1da", set_value("MS:1000827", add(1.0)), None),
    ("isolation_offsets_x2", chain(set_value("MS:1000828", times(2)), set_value("MS:1000829", times(2))), None),
    ("selected_intensity_removed", drop_param("MS:1000042"), None),
    ("spectrum_ref_removed", lambda b: re.sub(r' spectrumRef="[^"]*"', "", b, count=1), None),
    ("collision_energy_changed", set_value("MS:1000045", add(10)), None),
    # Spectrum description.
    ("ms_level_1", set_value("MS:1000511", lambda v: "1"), None),
    ("ms_level_spelled_2.0", set_value("MS:1000511", lambda v: v + ".0"), None),
    ("centroid_removed", drop_param("MS:1000127"), None),
    ("centroid_to_profile", replace('accession="MS:1000127" value="" name="centroid spectrum"', 'accession="MS:1000128" value="" name="profile spectrum"'), None),
    ("tic_zero", set_value("MS:1000285", lambda v: "0"), None),
    ("tic_x2", set_value("MS:1000285", times(2)), None),
    ("filter_string_changed", set_value("MS:1000512", lambda v: v.replace("Full ms2", "Full msx")), None),
    ("injection_time_x2", set_value("MS:1000927", times(2)), None),
    ("ms_level_in_group", group_ref, group_header),
    # Retention time.
    ("rt_unit_dropped", replace(' unitAccession="UO:0000031" unitName="minute" unitCvRef="UO"', ""), None),
    ("rt_minutes_labeled_seconds", replace('unitAccession="UO:0000031" unitName="minute"', 'unitAccession="UO:0000010" unitName="second"'), None),
    ("rt_in_seconds", rt_to_seconds, None),
    ("rt_plus_1min", set_value("MS:1000016", add(1.0)), None),
    ("rt_removed", drop_param("MS:1000016"), None),
    # Peaks.
    ("intensity_array_removed", drop_array("MS:1000515"), None),
    ("top_peak_removed", with_arrays(drop_top_peak), None),
    ("peaks_descending", with_arrays(lambda mz, i: (mz[::-1], i[::-1])), None),
    ("intensity_32bit", with_arrays(lambda mz, i: (mz, i), bits=32, which={"i"}), None),
    ("mz_32bit", with_arrays(lambda mz, i: (mz, i), bits=32, which={"mz"}), None),
    ("arrays_uncompressed", with_arrays(lambda mz, i: (mz, i), compressed=False), None),
    ("base64_wrapped", wrap_base64, None),
    ("mz_numpress", numpress_mz, None),
    ("default_length_off", lambda b: re.sub(r'defaultArrayLength="(\d+)"', lambda m: f'defaultArrayLength="{int(m.group(1)) + 1}"', b, count=1), None),
    # Identity and container.
    ("native_id_scan_only", lambda b: re.sub(r'id="controllerType=0 controllerNumber=1 (scan=\d+)"', r'id="\1"', b, count=1), None),
    ("index_removed", lambda b: b, strip_index),
]


def native_ids(path):
    ids = []
    with open(path, newline="") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            ids.append(row["scannr"])
    return ids

def load(path):
    """Rank-1 results by scan number: peptide, charge, label, q, hyperscore, rt, expmass, and how
    many rank-1 rows the scan has (more than one when a spectrum is written twice)."""
    rows = {}
    with open(path, newline="") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            if row["rank"] != "1":
                continue
            m = re.search(r"scan=(\d+)", row["scannr"])
            key = m.group(1) if m else row["scannr"]
            row["times"] = rows[key]["times"] + 1 if key in rows else 1
            rows[key] = row
    return rows

def sage(args, mzml, out):
    os.makedirs(out, exist_ok=True)
    config = dict(SETTINGS)
    config["database"] = dict(SETTINGS["database"], fasta=args.fasta)
    path = os.path.join(out, "sage.json")
    with open(path, "w") as f:
        json.dump(config, f)
    run = subprocess.run([args.sage, path, "-o", out, mzml], capture_output=True, text=True)
    log = run.stderr
    psms = re.search(r"discovered (\d+) target peptide-spectrum matches", log)
    note = ""
    if run.returncode != 0 or "panicked" in log or "ERROR" in log:
        lines = [l for l in log.splitlines() if "panicked" in l or "ERROR" in l or "rror" in l]
        note = (lines[-1] if lines else f"exit {run.returncode}")[-160:]
    result = os.path.join(out, "results.sage.tsv")
    ok = run.returncode == 0 and os.path.exists(result) and not note
    return ok, (int(psms.group(1)) if psms else 0), note, result

def confident(row):
    return row["label"] == "1" and float(row["spectrum_q"]) <= 0.01

def effect(ref, test, scans):
    """Counts what happened to `scans` between two result sets."""
    lost = wrong = shifted = 0
    for s in scans:
        a, b = ref.get(s), test.get(s)
        if b is None:
            lost += 1
            continue
        moved = any(abs(float(a[k]) - float(b[k])) > 1e-4 for k in ("hyperscore", "rt", "expmass"))
        # A match that falls below 1% FDR counts only when its own numbers moved: the engine's FDR
        # step is not deterministic, and a few borderline matches cross the line between runs.
        if a["peptide"] != b["peptide"] or a["charge"] != b["charge"] or b["times"] != a["times"] or (moved and confident(a) and not confident(b)):
            wrong += 1
        elif moved:
            shifted += 1
    return lost, wrong, shifted

def impact(ok, lost, wrong, shifted):
    if not ok:
        return "fatal"
    return "lost" if lost else "wrong" if wrong else "shifted" if shifted else "none"

def mzdiff(args, ref, mzml):
    run = subprocess.run([args.mzdiff, "--json", ref, mzml], capture_output=True, text=True)
    if run.returncode == 2:
        return "exit 2", run.stderr.strip().splitlines()[-1][:80] if run.stderr.strip() else ""
    report = json.loads(run.stdout)
    order = {"critical": 0, "major": 1, "minor": 2}
    classes = [c for c in report["classes"] if c["key"] != "indexListOffset"]
    if not classes:
        return "same", ""
    worst = min(classes, key=lambda c: order[c["severity"]])["severity"]
    keys = sorted({c["key"] if c["severity"] != "minor" else f"minor:{c['kind']}" for c in classes if c["severity"] == worst})
    return worst, ",".join(keys)[:80]

def validate(args, mzml):
    """mzValidate's error rules, apart from the index ones every edit breaks."""
    if not os.path.exists(args.validate):
        return "not run"
    run = subprocess.run([args.validate, "check", mzml], capture_output=True, text=True)
    rules = sorted({m for m in re.findall(r"ERROR .*\[([^\]]+)\]", run.stdout + run.stderr) if not m.startswith("mzml.index.")})
    return ",".join(rules) or "valid"

def flag(engine, verdict, valid):
    if engine in ("fatal", "lost", "wrong") and verdict in ("same", "minor") and valid in ("valid", "not run"):
        return "MISSED"
    if engine in ("fatal", "lost") and verdict == "major":
        return "UNDER"
    if engine == "none" and verdict == "critical":
        return "STRICT"
    return ""

def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("mzdiff"); p.add_argument("reference"); p.add_argument("rest", nargs="*")
    p.add_argument("-o", "--out", default="consumer-out"); p.add_argument("-n", "--scans", type=int, default=200)
    p.add_argument("--sage", default=SAGE); p.add_argument("--fasta", default=FASTA)
    p.add_argument("--validate", default=VALIDATE)
    p.add_argument("--compare", action="store_true")
    args = p.parse_args()
    if not args.fasta:
        p.error("give --fasta (or set MZDIFF_FASTA) for the reference's organism")
    os.makedirs(args.out, exist_ok=True)

    ok, psms, note, result = sage(args, args.reference, os.path.join(args.out, "reference"))
    if not ok:
        sys.exit(f"the engine failed on the reference: {note}")
    ref = load(result)
    print(f"reference: {psms} target PSMs at 1% FDR")
    table = open(os.path.join(args.out, "consumer.tsv"), "w")

    if args.compare:
        table.write("file\tpsms\tmzdiff\tkeys\tvalidate\tengine\tlost\twrong\tshifted\tgained\tnote\n")
        scans = sorted(ref)
        for path in args.rest:
            name = os.path.basename(path)
            ok, n, note, result = sage(args, path, os.path.join(args.out, name))
            test = load(result) if ok else {}
            lost, wrong, shifted = effect(ref, test, scans) if ok else (0, 0, 0)
            gained = len(set(test) - set(ref))
            verdict, keys = mzdiff(args, args.reference, path)
            valid = validate(args, path)
            row = [name, n, verdict, keys, valid, impact(ok, lost, wrong, shifted), lost, wrong, shifted, gained, note]
            table.write("\t".join(map(str, row)) + "\n")
            print(f"{name:40} {n:6} PSMs  mzdiff {verdict:8} validate {valid}  engine {row[5]:7} lost {lost} wrong {wrong} shifted {shifted} gained {gained} {note}")
        return

    chosen = [row for row in (r for r in ref.values()) if confident(row)]
    chosen.sort(key=lambda r: float(r["rt"]))
    step = max(1, len(chosen) // args.scans)
    chosen = chosen[::step][:args.scans]
    scans = [re.search(r"scan=(\d+)", r["scannr"]).group(1) if "scan=" in r["scannr"] else r["scannr"] for r in chosen]
    ids = [r["scannr"] for r in chosen]
    text = open(args.reference, encoding="utf-8").read()
    blocks = []
    for native in ids:
        at = text.find(f'<spectrum id="{native}"')
        start = text.rindex("\n", 0, at) + 1
        end = text.index("</spectrum>", at) + len("</spectrum>\n")
        blocks.append((start, end))
    blocks.sort()

    table.write("case\tmzdiff\tkeys\tvalidate\tengine\tlost\twrong\tshifted\tcollateral\tflag\tnote\n")
    print(f"{'case':28} {'mzdiff':8} {'engine':8} lost wrong shifted collateral  flag")
    others = [s for s in ref if s not in set(scans)]
    for name, edit, whole in CASES:
        if args.rest and name not in args.rest:
            continue
        pieces, at, changed = [], 0, 0
        for start, end in blocks:
            old = text[start:end]
            new = edit(old)
            changed += new != old
            pieces += [text[at:start], new]
            at = end
        pieces.append(text[at:])
        out_text = "".join(pieces)
        if whole:
            out_text = whole(out_text)
            changed = changed or 1
        if not changed:
            print(f"{name:28} skipped: no chosen spectrum has the structure")
            continue
        path = os.path.join(args.out, f"{name}.mzML")
        with open(path, "w", encoding="utf-8") as f:
            f.write(out_text)
        del out_text, pieces
        verdict, keys = mzdiff(args, args.reference, path)
        valid = validate(args, path)
        case_dir = os.path.join(args.out, name)
        ok, n, note, result = sage(args, path, case_dir)
        os.remove(path)
        test = load(result) if ok else {}
        lost, wrong, shifted = effect(ref, test, scans) if ok else (0, 0, 0)
        collateral = sum(effect(ref, test, others)[:2]) if ok else 0
        engine = impact(ok, lost, wrong, shifted)
        mark = flag(engine, verdict, valid)
        row = [name, verdict, keys, valid, engine, lost, wrong, shifted, collateral, mark, note]
        table.write("\t".join(map(str, row)) + "\n"); table.flush()
        print(f"{name:28} {verdict:8} {engine:8} {lost:4} {wrong:5} {shifted:7} {collateral:10}  {mark:6} {keys} | {valid} {note}", flush=True)


if __name__ == "__main__":
    main()
