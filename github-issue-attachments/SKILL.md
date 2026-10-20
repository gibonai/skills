---
name: github-issue-attachments
description: Download image and file attachments from GitHub issues, pull requests, and comments, including private repositories, where the raw user-attachments URL returns HTTP 404 even with a valid token. Use when an issue or PR specifies the work only as a screenshot, when you need to read an attached image, or when a github.com/user-attachments/assets/... URL fails with 404.
compatibility: Requires curl, python3, and network access to api.github.com and private-user-images.githubusercontent.com. Needs a GitHub token with read access to the repo (GH_TOKEN env var, or a gh CLI login).
license: MIT
---

# Fetching GitHub issue and PR attachments

## When to use this

Use this whenever you need the bytes of a file someone drag-and-dropped into a
GitHub issue, PR, or comment. The common case: an issue whose entire
specification is a screenshot.

**The critical rule:** a raw `github.com/user-attachments/assets/...` URL
returning `HTTP 404` does **not** mean the attachment is unreachable. That 404
is expected and proves nothing. Always run the procedure below before concluding
an image cannot be read.

## The core fact

GitHub has **no API** for downloading issue/PR attachments. GitHub Support
states this directly: attachment access is tied to a **browser session**, so it
does not work with Personal Access Tokens, OAuth Apps, or GitHub App
installation tokens. There are no plans to add one.

The working method is a documented media type plus an undocumented URL rewrite:

1. Request the issue/PR with `Accept: application/vnd.github.html+json`. This is
   a documented custom media type; the response includes `body_html`.
2. Inside `body_html`, GitHub has rewritten each attachment into a short-lived,
   pre-signed `private-user-images.githubusercontent.com/...?jwt=...` URL.
3. Download that URL **immediately**, with **no** `Authorization` header. The
   JWT in the query string is the credential.

## Procedure

### Step 1 — fetch the rendered HTML

```bash
source /workspace/.lemur-gh-token.env   # or export GH_TOKEN=...

curl -sS \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H "Accept: application/vnd.github.html+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/OWNER/REPO/issues/NUMBER" \
  -o /tmp/issue.json
```

### Step 2 — extract the signed URL

```bash
python3 - <<'PY'
import json, re
d = json.load(open('/tmp/issue.json'))
html = d.get('body_html', '')
urls = re.findall(r'(?:src|href)=["\']([^"\']+)["\']', html)
for u in urls:
    if 'private-user-images' in u or 'user-attachments' in u:
        print(u)
PY
```

GitHub emits the signed URL in `src="..."` for images and `href="..."` for
other files. Match on `private-user-images` or `user-attachments`.

### Step 3 — download it now

```bash
curl -sSL -o /tmp/shot.png "$SIGNED_URL"
```

Do **not** add an `Authorization` header. The credential is already in the URL,
and adding a bearer token can break the request.

## Use the bundled script instead

`scripts/fetch-github-attachment.sh` does all three steps for the issue body
**and** every comment, and verifies each download:

```bash
source /workspace/.lemur-gh-token.env
scripts/fetch-github-attachment.sh OWNER/REPO NUMBER [outdir]
```

Example:

```bash
scripts/fetch-github-attachment.sh Eye-Appeal-Inc/eye-appeal-inc 924 /tmp/shots
```

Output:

```
Fetching Eye-Appeal-Inc/eye-appeal-inc#924 ...
Found 1 attachment(s). Downloading immediately (JWT expires in ~5 min) ...
  ok  /tmp/shots/679268981-f7071360-....png (219996 bytes)
Done. Files in /tmp/shots
```

Exit codes: `0` success, `1` no attachments found or a download failed, `2` bad
usage or no token.

## What does not work

Every one of these returns `HTTP 404` with a 9-byte `Not Found` body, even with
a token that can read the private repo:

| Attempt | Result |
| --- | --- |
| `curl` the raw `user-attachments` URL, no auth | `HTTP 404` |
| `curl` the same URL with `Authorization: Bearer $GH_TOKEN` | `HTTP 404` |
| `gh api <raw user-attachments URL>` | `gh: HTTP 404` |
| Reading the issue's `body` field and extracting the URL from it | dead un-signed URL, `HTTP 404` |

The last row is the trap. `body` and `body_html` look similar, but only
`body_html` carries the signed URL. Reading `body` alone never works.

## The 5-minute expiry

The JWT is short-lived. Measured on a live fetch, `exp - now` was **291
seconds** (~5 minutes). Consequences:

- Fetch the HTML and download the file **in the same run**. Never cache the
  signed URL for later.
- If a download fails, re-run the whole procedure to mint a fresh URL.
  Retrying the same stale URL will keep failing.
- This is why the script does both steps back to back.

## Attachments in comments

The same rewrite applies to comments. Fetch
`/repos/{owner}/{repo}/issues/{number}/comments` with the same `html+json`
accept header and read `body_html` on each comment. The bundled script covers
the issue body and all comments in one pass.

## Verify you got the real file

A 9-byte file is the `Not Found` error page, not an image. Check the magic
bytes, and when the issue body declares dimensions, check those too:

```bash
head -c 8 /tmp/shot.png | od -An -c   # expect: 211 P N G \r \n 032 \n
```

```bash
python3 -c "
import struct
f = open('/tmp/shot.png','rb').read()
assert f[:8] == b'\x89PNG\r\n\x1a\n', 'not a PNG'
print('dimensions:', struct.unpack('>II', f[16:24]))
"
```

A real fetch of issue #924 produced a valid PNG, 219996 bytes, 2055×835 —
matching the `width="2055" height="835"` the issue body declared.

## Rules

1. **Always try `html+json` before concluding an attachment is unreachable.**
   The raw URL 404ing is expected and proves nothing.
2. **Never fabricate the change if the image is genuinely unreadable.** Ask for
   the screenshot to be re-attached or for a written description. Guessing at a
   screenshot-only requirement is worse than asking.
3. **Do not add an auth header to the signed-URL download.** The JWT is the
   credential.
4. **Do not cache signed URLs.** They expire in about 5 minutes.

## References

- REST docs, custom media types: <https://docs.github.com/en/rest/issues/issues>
- Media types overview: <https://docs.github.com/en/rest/guides/getting-started-with-the-rest-api>
- Changelog, private attachments: <https://github.blog/changelog/2023-05-08-more-secure-private-attachments>
- Community discussion #162417 (no API for private attachments)
- cli/cli discussion #11832 (no stable API for CI)