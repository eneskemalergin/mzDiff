#!/usr/bin/env bash
# Converts Thermo .raw files with one tool, compares each output with the ThermoRawFileParser
# mzML beside the .raw using mzdiff, and runs mzValidate on each output.
#
# usage: tools/corpus.sh [-t mzbridge|opentfraw|mzdata] [-o OUT] [-c DIR] [-b BASELINE] [RAW...]
#
# Needs an mzBridge checkout (MZBRIDGE, default ../mzBridge) with its peers and mzValidate built.
# Writes summary.tsv, classes.tsv, run.txt, and files/ to OUT; with -b, also changes.tsv, and
# exits 1 when a critical or major class is new or grown. The Development wiki page has details.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
repo=${MZBRIDGE:-$root/../mzBridge}
[ -d "$repo" ] || { echo "mzBridge checkout not found: $repo (set MZBRIDGE)" >&2; exit 2; }
repo=$(cd "$repo" && pwd)
tool=mzbridge
out=""
corpus=${MZDIFF_CORPUS:-}
baseline=""
while getopts "t:o:c:b:h" flag; do
  case $flag in
    t) tool=$OPTARG ;;
    o) out=$OPTARG ;;
    c) corpus=$OPTARG ;;
    b) baseline=$OPTARG ;;
    *) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 2 ;;
  esac
done
if [ -n "$baseline" ] && [ ! -f "$baseline/summary.tsv" ]; then
  echo "baseline has no summary.tsv: $baseline" >&2
  exit 2
fi
shift $((OPTIND - 1))
if [ $# -eq 0 ] && [ -z "$corpus" ]; then
  echo "no RAW files given: name them, or give -c DIR (or set MZDIFF_CORPUS)" >&2
  exit 2
fi
case $tool in mzbridge | opentfraw | mzdata) ;; *) echo "unknown tool: $tool" >&2; exit 2 ;; esac

(cd "$root" && zig build -Doptimize=ReleaseFast)
mzdiff="$root/zig-out/bin/mzdiff"
if [ "$tool" = mzbridge ]; then (cd "$repo" && zig build -Doptimize=ReleaseFast); fi
validate="$repo/tools/bin/mzValidate"
if [ ! -x "$validate" ]; then
  echo "warning: $validate not found; outputs are not validated (tools/install.sh mzvalidate)" >&2
fi

if [ -z "$out" ]; then out=$(mktemp -d /var/tmp/mzdiff-corpus.XXXXXX); fi
mkdir -p "$out/files"
scratch=$(mktemp -d /var/tmp/mzdiff-scratch.XXXXXX)
cleanup() {
  rm -f "$scratch/out.mzML" "$scratch/err" "$scratch"/mzdata/*.mzML
  rmdir "$scratch/mzdata" 2> /dev/null || true
  rmdir "$scratch" 2> /dev/null || true
}
trap cleanup EXIT

convert() {
  case $tool in
    mzbridge) "$repo/zig-out/bin/mzBridge" convert "$1" "$2" ;;
    opentfraw) "$repo/tools/bin/to_mzml" --indexed "$1" "$2" > /dev/null ;;
    mzdata)
      "$repo/tools/bin/mzdata-converter" -o "$scratch/mzdata" "$1" > /dev/null &&
        mv "$scratch/mzdata/$(basename "${1%.*}").mzML" "$2" &&
        rmdir "$scratch/mzdata" ;;
  esac
}

if [ $# -eq 0 ]; then
  files=()
  unreferenced=0
  while IFS= read -r raw; do
    if [ -f "${raw%.*}.mzML" ]; then files+=("$raw"); else unreferenced=$((unreferenced + 1)); fi
  done < <(find "$corpus" -iname '*.raw' -type f | sort)
  if [ "$unreferenced" -gt 0 ]; then echo "note: $unreferenced .raw files have no reference .mzML and are skipped" >&2; fi
else
  files=("$@")
fi

revision() {
  if git -C "$1" rev-parse --short HEAD 2> /dev/null; then
    git -C "$1" diff --quiet HEAD 2> /dev/null || echo "(modified)"
  else
    echo "not a git repo"
  fi | paste -sd' '
}

{
  echo "tool: $tool"
  echo "date: $(date -Iseconds)"
  echo "mzdiff: $(revision "$root")"
  echo "mzBridge: $(revision "$repo")"
  if [ -x "$validate" ]; then echo "mzValidate: $("$validate" --version 2>&1 | head -1)"; fi
} > "$out/run.txt"

summary="$out/summary.tsv"
printf 'file\tstatus\tcritical\tmajor\tminor\tpaired\tseconds\tvalidate\n' > "$summary"
row() {
  python3 - "$@" << 'PYTHON'
import json, sys
name, override, seconds, check, path = sys.argv[1:]
report = json.load(open(path))
status = override or report["status"]
if report["a"]["spectra"] and not report["paired"]["spectra"]:
    status = "nothing paired"
if report["completion"] != "complete":
    status += " (incomplete)"
totals = report["totals"]
print("\t".join([name, status, str(totals["critical"]), str(totals["major"]), str(totals["minor"]),
                 str(report["paired"]["spectra"]), f"{float(seconds):.1f}", check]))
PYTHON
}
for raw in "${files[@]}"; do
  ref="${raw%.*}.mzML"
  name=$(echo "${raw#"$corpus"/}" | sed 's|/|__|g')
  json="$out/files/$name.json"
  mzml="$scratch/out.mzML"
  if [ ! -f "$ref" ]; then
    printf '%s\tno reference: %s\t\t\t\t\t\t\n' "$name" "$ref" >> "$summary"
    continue
  fi
  start=$(date +%s.%N)
  if ! convert "$raw" "$mzml" 2> "$scratch/err"; then
    reason=$(grep -v -e 'panicked at' -e '^Found [0-9]* file' -e '^note: run with' -e '^[[:space:]]*$' "$scratch/err" | head -1 || true)
    [ -n "$reason" ] || reason=$(tr '\n\t' '  ' < "$scratch/err")
    printf '%s\tconvert failed: %s\t\t\t\t\t\t\n' "$name" "$(printf '%s' "$reason" | tr '\t' ' ' | cut -c1-160)" >> "$summary"
    rm -f "$mzml" "$scratch/err"
    continue
  fi
  code=0
  "$mzdiff" --json "$ref" "$mzml" > "$json" 2> "$out/files/$name.err" || code=$?
  [ -s "$out/files/$name.err" ] || rm -f "$out/files/$name.err"
  seconds=$(echo "$(date +%s.%N) - $start" | bc)
  if [ "$code" -ge 2 ]; then
    printf '%s\tmzdiff failed: %s\t\t\t\t\t%.1f\t\n' "$name" "$(head -1 "$out/files/$name.err" | tr '\t' ' ' | cut -c1-120)" "$seconds" >> "$summary"
    rm -f "$mzml" "$json"
    continue
  fi
  check="not run"
  override=""
  if [ -x "$validate" ]; then
    check=$( { "$validate" check "$mzml" --summary 2>&1 || true; } | tail -1 | tr '\t' ' ')
    case $check in
      "complete: errors"*) override="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$json")+invalid" ;;
      complete:*) ;;
      *) check="mzValidate did not complete: $check" ;;
    esac
  fi
  row "$name" "$override" "$seconds" "$check" "$json" >> "$summary"
  rm -f "$mzml" "$scratch/err"
done

python3 - "$out" << 'PYTHON' | sort -t$'\t' -k3,3 -k1,1nr > "$out/classes.tsv"
import glob, json, os, sys
files, records = {}, {}
for path in glob.glob(os.path.join(sys.argv[1], "files", "*.json")):
    for c in json.load(open(path))["classes"]:
        key = (c["severity"], c["kind"], c["path"], c["key"], c["name"])
        files[key] = files.get(key, 0) + 1
        records[key] = records.get(key, 0) + c["records"]
for key in files:
    print("\t".join([str(files[key]), str(records[key]), *key]))
PYTHON
awk -F'\t' 'NR > 1 { split($2, s, ":"); n[s[1]]++ } END { for (k in n) printf "  %-16s %d\n", k, n[k] }' "$summary" | sort
echo "results: $out (summary.tsv, classes.tsv, run.txt, files/ with one JSON report per file)"
[ -n "$baseline" ] || exit 0

python3 - "$baseline" "$out" << 'PYTHON'
import glob, json, os, sys
before_dir, after_dir = sys.argv[1:]

def statuses(run):
    rows = [line.rstrip("\n").split("\t") for line in open(os.path.join(run, "summary.tsv"))][1:]
    return {row[0]: row[1] for row in rows}

def classes(run):
    found = {}
    for path in glob.glob(os.path.join(run, "files", "*.json")):
        name = os.path.basename(path)[: -len(".json")]
        found[name] = {(c["severity"], c["kind"], c["path"], c["key"]): c["records"] for c in json.load(open(path))["classes"]}
    return found

status_before, status_after = statuses(before_dir), statuses(after_dir)
classes_before, classes_after = classes(before_dir), classes(after_dir)
rows, regressions, improvements = [], 0, 0
for name in sorted(set(status_before) | set(status_after)):
    s0, s1 = status_before.get(name, "-"), status_after.get(name, "-")
    if s0 != s1:
        rows.append([name, "status", "", "", "", "", s0, s1])
    c0, c1 = classes_before.get(name, {}), classes_after.get(name, {})
    if name not in classes_before or name not in classes_after:
        continue
    for key in sorted(set(c0) | set(c1)):
        r0, r1 = c0.get(key, 0), c1.get(key, 0)
        if r0 == r1:
            continue
        change = "new" if r0 == 0 else "gone" if r1 == 0 else "more" if r1 > r0 else "fewer"
        serious = key[0] in ("critical", "major")
        if serious and change in ("new", "more"):
            regressions += 1
        elif change in ("gone", "fewer"):
            improvements += 1
        rows.append([name, change, *key, str(r0), str(r1)])
with open(os.path.join(after_dir, "changes.tsv"), "w") as out:
    out.write("file\tchange\tseverity\tkind\tpath\tkey\tbefore\tafter\n")
    for row in rows:
        out.write("\t".join(row) + "\n")
print(f"against {before_dir}: {regressions} regressions (critical or major classes new or grown), "
      f"{improvements} improvements, {sum(1 for r in rows if r[1] == 'status')} status changes; see changes.tsv")
sys.exit(1 if regressions else 0)
PYTHON
