#!/usr/bin/env bash
# Stores your GitHub fine-grained PAT in the Salesforce "GitHub" External Credential
# (principal GitHubPrincipal, parameter "token") of the watchitbuild org.
# The token is read from the environment and never written to disk or echoed.
#
#   export GITHUB_PAT=github_pat_xxx
#   ./scripts/setup-github-credential.sh
set -euo pipefail
ORG="${ORG:-watchitbuild}"
: "${GITHUB_PAT:?Set GITHUB_PAT first (fine-grained PAT for agent-forge + profile repo)}"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
python3 - "$TMP" <<'PY'
import json, os, sys
json.dump({
  "externalCredential": "GitHub",
  "principalName": "GitHubPrincipal",
  "principalType": "NamedPrincipal",
  "credentials": {"token": {"value": os.environ["GITHUB_PAT"], "encrypted": True}}
}, open(sys.argv[1], "w"))
PY
EP="/services/data/v64.0/named-credentials/credential"
if sf api request rest "$EP" --method POST --body "@$TMP" -o "$ORG" >/dev/null 2>&1; then
  echo "✅ Credential created in $ORG"
else
  sf api request rest "$EP" --method PUT --body "@$TMP" -o "$ORG" >/dev/null && echo "✅ Credential updated in $ORG"
fi
