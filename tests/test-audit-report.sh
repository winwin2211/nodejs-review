#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
S="$REPO_ROOT/skill/scripts"
d=$(tmpdir)

# npm v7+ audit JSON: lodash downgraded into a vulnerable range by this change, minimist already vulnerable at base
cat > "$d/audit.json" <<'EOF'
{ "auditReportVersion": 2, "vulnerabilities": {
  "lodash": { "name": "lodash", "severity": "high", "isDirect": true,
    "via": [ { "source": 1096302, "name": "lodash", "title": "Prototype Pollution in lodash", "url": "https://github.com/advisories/GHSA-p6mc-m468-83gw", "severity": "high", "range": "<4.17.21" } ],
    "range": "<4.17.21", "nodes": ["node_modules/lodash"], "fixAvailable": true },
  "minimist": { "name": "minimist", "severity": "moderate", "isDirect": false,
    "via": [ { "source": 1, "name": "minimist", "title": "Prototype Pollution", "url": "https://github.com/advisories/GHSA-xvch-5gv4-984h", "severity": "moderate", "range": "<1.2.6" } ],
    "range": "<1.2.6", "nodes": ["node_modules/minimist"], "fixAvailable": true },
  "left-pad": { "name": "left-pad", "severity": "low", "isDirect": false,
    "via": [ "minimist" ], "range": "*", "nodes": ["node_modules/left-pad"], "fixAvailable": true }
}, "metadata": { "vulnerabilities": { "high": 1, "moderate": 1, "low": 1 } } }
EOF
cat > "$d/head-lock.json" <<'EOF'
{ "lockfileVersion": 3, "packages": { "": {}, "node_modules/lodash": { "version": "4.17.20" }, "node_modules/minimist": { "version": "1.2.5" }, "node_modules/left-pad": { "version": "1.3.0" } } }
EOF
cat > "$d/base-lock.json" <<'EOF'
{ "lockfileVersion": 3, "packages": { "": {}, "node_modules/lodash": { "version": "4.17.21" }, "node_modules/minimist": { "version": "1.2.5" }, "node_modules/left-pad": { "version": "1.3.0" } } }
EOF

line=$(bash "$S/audit-report.sh" npm "$d/audit.json" "$d/head-lock.json" "$d/base-lock.json" "$d/out.tsv")
assert_eq "1 introduced (1 high/critical), 2 pre-existing" "$line" "npm: summary separates introduced from pre-existing"
assert_contains "$(cat "$d/out.tsv")" $'lodash\t4.17.20\thigh\tGHSA-p6mc-m468-83gw\tintroduced' "npm: lodash row with the GHSA id, introduced"
assert_contains "$(cat "$d/out.tsv")" $'minimist\t1.2.5\tmoderate\tGHSA-xvch-5gv4-984h\tpreexisting' "npm: minimist unchanged -> pre-existing"
assert_contains "$(cat "$d/out.tsv")" $'left-pad\t1.3.0\tlow\tvia minimist\tpreexisting' "npm: a transitive via-only entry names its parent advisory"

# collect.sh saves the merge-base lockfile without an extension (tools/lock-base):
# the format comes from the content, so the npm lockfile is still read as JSON
cp "$d/base-lock.json" "$d/lock-base"
line=$(bash "$S/audit-report.sh" npm "$d/audit.json" "$d/head-lock.json" "$d/lock-base" "$d/out1b.tsv")
assert_eq "1 introduced (1 high/critical), 2 pre-existing" "$line" "npm: a base lockfile saved without .json is still parsed as JSON"

# no base lockfile (the change added it): everything is introduced
line=$(bash "$S/audit-report.sh" npm "$d/audit.json" "$d/head-lock.json" - "$d/out2.tsv")
assert_eq "3 introduced (1 high/critical), 0 pre-existing" "$line" "npm: without a base lockfile every advisory is introduced"

# pnpm (npm v6-style) audit JSON with a pnpm-lock.yaml v9 head/base
cat > "$d/pnpm-audit.json" <<'EOF'
{ "advisories": { "1096302": { "module_name": "lodash", "severity": "critical", "title": "Prototype Pollution in lodash",
  "url": "https://github.com/advisories/GHSA-p6mc-m468-83gw", "findings": [ { "version": "4.17.20", "paths": ["lodash"] } ] } },
  "metadata": { "vulnerabilities": { "critical": 1 } } }
EOF
printf "lockfileVersion: '9.0'\n\npackages:\n\n  lodash@4.17.20:\n    resolution: {integrity: sha512-x}\n" > "$d/head-pnpm.yaml"
printf "lockfileVersion: '9.0'\n\npackages:\n\n  lodash@4.17.21:\n    resolution: {integrity: sha512-y}\n" > "$d/base-pnpm.yaml"
line=$(bash "$S/audit-report.sh" pnpm "$d/pnpm-audit.json" "$d/head-pnpm.yaml" "$d/base-pnpm.yaml" "$d/out3.tsv")
assert_eq "1 introduced (1 high/critical), 0 pre-existing" "$line" "pnpm: critical lodash introduced"
assert_contains "$(cat "$d/out3.tsv")" $'lodash\t4.17.20\tcritical\tGHSA-p6mc-m468-83gw\tintroduced' "pnpm: row from the advisories format"
printf "lockfileVersion: '9.0'\n\npackages:\n\n  lodash@4.17.20:\n    resolution: {integrity: sha512-x}\n" > "$d/base-pnpm-same.yaml"
line=$(bash "$S/audit-report.sh" pnpm "$d/pnpm-audit.json" "$d/head-pnpm.yaml" "$d/base-pnpm-same.yaml" "$d/out4.tsv")
assert_eq "0 introduced (0 high/critical), 1 pre-existing" "$line" "pnpm: same version at base -> pre-existing"
cp "$d/base-pnpm-same.yaml" "$d/lock-base-pnpm"
line=$(bash "$S/audit-report.sh" pnpm "$d/pnpm-audit.json" "$d/head-pnpm.yaml" "$d/lock-base-pnpm" "$d/out4b.tsv")
assert_eq "0 introduced (0 high/critical), 1 pre-existing" "$line" "pnpm: a base lockfile saved without .yaml is still parsed as YAML"

# clean audit, unsupported manager, invalid json
echo '{ "auditReportVersion": 2, "vulnerabilities": {}, "metadata": {} }' > "$d/clean.json"
assert_eq "0 introduced (0 high/critical), 0 pre-existing" "$(bash "$S/audit-report.sh" npm "$d/clean.json" "$d/head-lock.json" "$d/base-lock.json" "$d/out5.tsv")" "no vulnerabilities"
assert_exit 1 bash "$S/audit-report.sh" yarn "$d/audit.json" "$d/head-lock.json" - "$d/out6.tsv"
echo 'npm ERR! network request failed' > "$d/bad.json"
assert_exit 1 bash "$S/audit-report.sh" npm "$d/bad.json" "$d/head-lock.json" - "$d/out7.tsv"

finish
