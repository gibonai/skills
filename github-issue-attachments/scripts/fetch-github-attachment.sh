#!/usr/bin/env bash
#
# fetch-github-attachment.sh — download image/file attachments from a GitHub
# issue or pull request, including private repositories.
#
# WHY THIS EXISTS
# ---------------
# GitHub does NOT provide an API for downloading issue/PR attachments. Support
# has confirmed this directly: attachment access is tied to a browser session,
# not to a PAT, OAuth app, or GitHub App installation token. Hitting the
# `github.com/user-attachments/assets/...` URL directly returns HTTP 404 even
# with a valid token.
#
# The working mechanism is a documented media type plus an undocumented URL
# rewrite:
#
#   1. Request the issue/PR with `Accept: application/vnd.github.html+json`.
#      This is a DOCUMENTED media type; the response includes `body_html`.
#   2. In `body_html`, GitHub rewrites each attachment URL to a short-lived,
#      pre-signed `private-user-images.githubusercontent.com/...?jwt=...` URL.
#      The JWT is in the query string, so the download needs NO auth header.
#   3. Download that signed URL immediately. The JWT expires in ~5 minutes.
#
# The raw `body` field still contains the un-signed `user-attachments` URL,
# which is why reading `body` alone never works.
#
# USAGE
#   scripts/fetch-github-attachment.sh <owner/repo> <number> [outdir]
#
# EXAMPLES
#   scripts/fetch-github-attachment.sh Eye-Appeal-Inc/eye-appeal-inc 924
#   scripts/fetch-github-attachment.sh Eye-Appeal-Inc/eye-appeal-inc 924 /tmp/shots
#
# Requires: curl, python3, and GH_TOKEN in the environment (or a `gh` login).
# Exits non-zero if no attachments were found or any download failed.

set -euo pipefail

REPO="${1:-}"
NUMBER="${2:-}"
OUTDIR="${3:-.}"

if [[ -z "$REPO" || -z "$NUMBER" ]]; then
  echo "usage: $0 <owner/repo> <number> [outdir]" >&2
  exit 2
fi

if [[ -z "${GH_TOKEN:-}" ]]; then
  # Fall back to the gh CLI's stored token if present.
  GH_TOKEN="$(gh auth token 2>/dev/null || true)"
fi
if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "error: no GH_TOKEN in environment and 'gh auth token' returned nothing" >&2
  exit 2
fi

mkdir -p "$OUTDIR"

API="https://api.github.com/repos/${REPO}"
ACCEPT="application/vnd.github.html+json"

# Fetch the issue/PR body and its comments, both as rendered HTML.
# `body_html` is where the signed URLs live.
fetch_html() {
  local url="$1"
  curl -sS -H "Authorization: Bearer ${GH_TOKEN}" \
       -H "Accept: ${ACCEPT}" \
       -H "X-GitHub-Api-Version: 2022-11-28" \
       "$url"
}

echo "Fetching ${REPO}#${NUMBER} ..." >&2
BODY_JSON="$(fetch_html "${API}/issues/${NUMBER}")"
COMMENTS_JSON="$(fetch_html "${API}/issues/${NUMBER}/comments")"

TMPDIR_ATT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ATT"' EXIT
printf '%s' "$BODY_JSON" > "$TMPDIR_ATT/body.json"
printf '%s' "$COMMENTS_JSON" > "$TMPDIR_ATT/comments.json"

# Extract every attachment URL from the rendered HTML. GitHub emits the signed
# URL in both `src="..."` (images) and `href="..."` (non-image files).
python3 - "$TMPDIR_ATT" > "$TMPDIR_ATT/urls.txt" <<'PY'
import json, re, sys, os

d = sys.argv[1]
html_parts = []

for name in ("body.json", "comments.json"):
    path = os.path.join(d, name)
    try:
        with open(path) as fh:
            doc = json.load(fh)
    except Exception:
        continue
    if isinstance(doc, dict) and "body_html" in doc:
        html_parts.append(doc["body_html"] or "")
    elif isinstance(doc, list):
        for item in doc:
            if isinstance(item, dict) and "body_html" in item:
                html_parts.append(item["body_html"] or "")

seen, out = set(), []
for html in html_parts:
    for m in re.finditer(r'(?:src|href)=["\']([^"\']+)["\']', html):
        u = m.group(1)
        if "private-user-images" in u or "user-attachments" in u:
            if u not in seen:
                seen.add(u)
                out.append(u)

sys.stdout.write("\n".join(out))
PY

mapfile -t URLS < "$TMPDIR_ATT/urls.txt"

if [[ ${#URLS[@]} -eq 0 ]]; then
  echo "No attachments found on ${REPO}#${NUMBER}." >&2
  exit 1
fi

echo "Found ${#URLS[@]} attachment(s). Downloading immediately (JWT expires in ~5 min) ..." >&2

FAILED=0
i=0
for url in "${URLS[@]}"; do
  i=$((i + 1))
  # Derive a filename from the path, ignoring the query string.
  base="$(printf '%s' "$url" | sed 's/?.*$//' | sed 's#.*/##')"
  [[ -z "$base" ]] && base="attachment-${i}"
  dest="${OUTDIR}/${base}"

  # No Authorization header: the JWT in the query string is the credential.
  # Adding a bearer token here can break the request.
  code="$(curl -sSL -o "$dest" -w '%{http_code}' "$url" || echo 000)"
  size="$(stat -c%s "$dest" 2>/dev/null || echo 0)"

  if [[ "$code" == "200" && "$size" -gt 0 ]]; then
    echo "  ok  ${dest} (${size} bytes)" >&2
  else
    echo "  FAIL ${dest} (HTTP ${code}, ${size} bytes)" >&2
    FAILED=1
  fi
done

if [[ "$FAILED" -ne 0 ]]; then
  echo "One or more downloads failed. Re-run to get a fresh signed URL." >&2
  exit 1
fi