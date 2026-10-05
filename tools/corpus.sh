#!/usr/bin/env bash
# Converts corpus .raw files with one tool and compares each output with the TRFP reference
# mzML beside the .raw, using mzdiff; also runs mzValidate on each output.
#
# usage: tools/corpus.sh [-t TOOL] [-o OUT] [-c DIR] [RAW...]
#   -t TOOL  mzbridge (default), opentfraw, or mzdata
#   -o OUT   directory for the per-file mzdiff TSVs and summary.tsv (default: a new /var/tmp dir)
#   -c DIR   corpus root searched when no RAW is given (default: $MZDIFF_CORPUS)
#   RAW...   files to check; default every .raw with a .mzML reference beside it
#
# MZBRIDGE names the mzBridge checkout (default: ../mzBridge beside this repository); its zig-out holds
# mzBridge and its tools/bin the peers and mzValidate.
#
# One file at a time, so a run does not compete with itself for memory or disk. Converted output
# goes to a scratch directory under /var/tmp and is removed after each comparison. mzdiff (and
# mzBridge, for -t mzbridge) are rebuilt first, so a run never uses a stale binary.
#
# status in summary.tsv: mzdiff's status word (same, tolerated, differs), "+invalid" when
# mzValidate found errors, "nothing paired" when A held spectra and none paired, "(incomplete)"
# when the comparison stopped early, "convert failed: ...", or "mzdiff failed: ..." (an unreadable
# file; the first line of mzdiff's message follows). The paired column counts paired spectra.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
repo=${MZBRIDGE:-$root/../mzBridge}
[ -d "$repo" ] || { echo "mzBridge checkout not found: $repo (set MZBRIDGE)" >&2; exit 2; }
repo=$(cd "$repo" && pwd)
tool=mzbridge
out=""
corpus=${MZDIFF_CORPUS:-}
while getopts "t:o:c:h" flag; do
  case $flag in
    t) tool=$OPTARG ;;
    o) out=$OPTARG ;;
    c) corpus=$OPTARG ;;
    *) sed -n '2,20p' "$0"; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
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
# Removes only what this script puts in its scratch directory, even when it stops early.
cleanup() {
  rm -f "$scratch/out.mzML" "$scratch/err" "$scratch"/mzdata/*.mzML
  rmdir "$scratch/mzdata" 2> /dev/null || true
  rmdir "$scratch" 2> /dev/null || true
}
trap cleanup EXIT

convert() { # raw output.mzML
  case $tool in
    mzbridge) "$repo/zig-out/bin/mzBridge" convert "$1" "$2" ;;
    opentfraw) "$repo/tools/bin/to_mzml" --indexed "$1" "$2" > /dev/null ;;
    mzdata)
      "$repo/tools/bin/mzdata-converter" -o "$scratch/mzdata" "$1" > /dev/null
      mv "$scratch/mzdata/$(basename "${1%.*}").mzML" "$2"
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

revision() { # dir: its commit, marked when the work tree differs from it
  if git -C "$1" rev-parse --short HEAD 2> /dev/null; then
    git -C "$1" diff --quiet HEAD 2> /dev/null || echo "(modified)"
  else
    echo "not a git repo"
  fi | paste -sd' '
}

# What produced these results, for comparing runs later.
{
  echo "tool: $tool"
  echo "date: $(date -Iseconds)"
  echo "mzdiff: $(revision "$root")"
  echo "mzBridge: $(revision "$repo")"
  if [ -x "$validate" ]; then echo "mzValidate: $("$validate" --version 2>&1 | head -1)"; fi
} > "$out/run.txt"

summary="$out/summary.tsv"
printf 'file\tstatus\tcritical\tmajor\tminor\tpaired\tseconds\tvalidate\n' > "$summary"
# One summary row from mzdiff's JSON report: its status word (or "nothing paired" when A held
# spectra and none paired), class counts, and paired spectra.
row() { # name status-override seconds validate report.json
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
    printf '%s\tconvert failed: %s\t\t\t\t\t\t\n' "$name" "$(tr '\n\t' '  ' < "$scratch/err" | cut -c1-120)" >> "$summary"
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

# Classes across the run: how many files each (severity, kind, path, key) hit, and in how many
# records in total.
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
