#!/usr/bin/env bash
# Which added lines did the tests execute?
#
#   coverage-changed.sh LCOV ADDED.tsv REPO [PKG_DIR]
#
# Prints one row per changed file, `file<TAB>covered<TAB>total<TAB>uncovered-ranges<TAB>uncovered-functions`,
# where total counts the added lines lcov knows as executable (DA records),
# ranges look like `42-47,51`, and functions lists `name:start-end` for every
# function whose added executable lines were all unexecuted (ranges come from
# consecutive FN records; the last function runs to the end of the file). A
# changed file with no SF record was loaded by no test: its row is `0 0
# <every added line> NO_RECORD` and it adds nothing to the final
# `TOTAL=covered/total` line, which counts measured lines only. SF paths may
# be absolute, repo-relative, or relative to PKG_DIR.
set -euo pipefail
LCOV=${1:?usage: coverage-changed.sh LCOV ADDED.tsv REPO [PKG_DIR]}
ADDED=${2:?}; ROOT=${3:?}; PKG=${4:-.}
ROOT=$(cd "$ROOT" && pwd -P)
[[ -f "$LCOV" ]] || LCOV=/dev/null
awk -F'\t' -v root="$ROOT/" -v pkg="$PKG" -v addedf="$ADDED" '
  function norm(p) {
    if (index(p, root) == 1) return substr(p, length(root) + 1)
    if (p ~ /^\// || pkg == ".") return p
    if (index(p, pkg "/") == 1) return p
    return pkg "/" p
  }
  function sortnum(arr, n,   i, j, t) { for (i = 2; i <= n; i++) { t = arr[i]; j = i - 1; while (j > 0 && arr[j] > t) { arr[j + 1] = arr[j]; j-- } arr[j + 1] = t } }
  function ranges(arr, n,   i, s, out) {
    out = ""; if (n == 0) return out
    s = arr[1]
    for (i = 2; i <= n + 1; i++) {
      if (i <= n && arr[i] == arr[i - 1] + 1) continue
      out = out (out == "" ? "" : ",") (s == arr[i - 1] ? s : s "-" arr[i - 1])
      if (i <= n) s = arr[i]
    }
    return out
  }
  FILENAME == addedf { if (NF >= 2) { f = $1; if (!(f in seen)) { seen[f] = 1; order[++nf] = f }; add[f, ++na[f]] = $2 + 0 }; next }
  /^SF:/ { cur = norm(substr($0, 4)); rec[cur] = 1; next }
  /^FN:/ { s = substr($0, 4); i = index(s, ","); fnline[cur, ++nfn[cur]] = substr(s, 1, i - 1) + 0; fnname[cur, nfn[cur]] = substr(s, i + 1); next }
  /^DA:/ { s = substr($0, 4); split(s, a, ","); da[cur, a[1] + 0] = a[2] + 0; hasda[cur, a[1] + 0] = 1; next }
  END {
    tc = 0; tt = 0
    for (k = 1; k <= nf; k++) {
      f = order[k]
      if (!(f in rec)) { nu = 0; delete unc; for (i = 1; i <= na[f]; i++) unc[++nu] = add[f, i]; sortnum(unc, nu); print f "\t0\t0\t" ranges(unc, nu) "\tNO_RECORD"; continue }
      cov = 0; tot = 0; nu = 0; delete unc
      for (i = 1; i <= na[f]; i++) { L = add[f, i]; if ((f SUBSEP L) in hasda) { tot++; if (da[f, L] > 0) cov++; else unc[++nu] = L } }
      sortnum(unc, nu)
      # functions whose added executable lines were all unexecuted
      m = nfn[f] + 0; delete fl; for (i = 1; i <= m; i++) fl[i] = fnline[f, i]
      sortnum(fl, m)
      funcs = ""
      for (i = 1; i <= m; i++) {
        start = fl[i]; end = (i < m) ? fl[i + 1] - 1 : 1000000000
        nm = ""; for (j = 1; j <= m; j++) if (fnline[f, j] == start) { nm = fnname[f, j]; break }
        anyexec = 0; anyunexec = 0
        for (q = 1; q <= na[f]; q++) { L = add[f, q]; if (L >= start && L <= end && ((f SUBSEP L) in hasda)) { if (da[f, L] > 0) anyexec = 1; else anyunexec = 1 } }
        if (anyunexec && !anyexec) funcs = funcs (funcs == "" ? "" : ";") nm ":" start "-" (end == 1000000000 ? "end" : end)
      }
      print f "\t" cov "\t" tot "\t" ranges(unc, nu) "\t" funcs
      tc += cov; tt += tot
    }
    print "TOTAL=" tc "/" tt
  }
' "$ADDED" "$LCOV"
