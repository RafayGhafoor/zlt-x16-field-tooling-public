# 48 — Publishing this repository (and what the public mirror leaves out)

**Date:** 2026-10-30 · **Status:** done — the public mirror exists, this repo stays
private.

- **Public mirror:** <https://github.com/RafayGhafoor/zlt-x16-field-tooling-public>
- **Unlock tool (public):** <https://github.com/RafayGhafoor/zlt-x16-toolkit>
- **This repository:** stays **private** — it is the field record, not the shop window.

---

## Why a mirror instead of flipping this repo

`AGENTS.md` §7 already said it: *"keep this repository local; treat a scrub before any
push as mandatory, not precautionary."* On 2026-10-30 that stopped being advice and
became a measurement. `scripts/prepublish/audit.sh` on this repo reports:

| Class | Finding |
|---|---|
| Credentials | the fleet-wide WLAN PSK in **8 files and 3 commits**; the super-admin password in 7 files / 2 commits; the root/UI password in 19 files / 9 commits; `admin:<pw>` in 1 file |
| Device identity | IMSI-like numbers in 6 files, the module serial in 5 |
| Whole directories | `device-etc/` (184 files of vendor `/etc`, including `mdlcfg` dumps), `firmware-analysis/` (37 files, decompiled vendor code) |

Publishing it as-is would have handed out a working root password, a WLAN key that is
identical on every radio of the model, the customer's device identity, and the vendor's
decompiled IP. Deleting the files would not have been enough: **the values are in
history**, and a public repo publishes all of it.

Two ways out were considered:

1. **Rewrite this repo's history** (`git filter-repo` over ~2000 commits). Rejected: it
   destroys the rollback record and the capture evidence that `AGENTS.md` §5 depends
   on, in the repository whose whole job is being that record.
2. **Publish a sanitised mirror, keep this repo private** ← what we did.

The mirror has **one commit**, so there is no history to leak, and it contains only what
someone needs to *deploy and understand* the fixes.

## How the mirror was built

```sh
# 1. export the tree WITHOUT history, minus what must not publish
git archive HEAD | tar -x -C /tmp/mirror-a
cd /tmp/mirror-a && rm -rf device-etc firmware-analysis qmanager

# 2. redact credentials and identity in every text file (42 files changed)
python3 /tmp/redact.py .        # <wlan-psk-redacted>, <super-admin-pw-redacted>, <redacted-password>, admin:<pw>,
                               # IMSI / IMEI / module SN / MAC patterns

# 3. fix what the deletions broke (README image paths -> docs/screenshots/,
#    drop links to the private repo, licence note, "about this mirror")

# 4. fresh history, one commit
git init -b main && git add -A && git commit -m "ZLT X16 field tooling — public mirror"

# 5. THE GATE — must print "no blockers"
scripts/prepublish/audit.sh /tmp/mirror-a

# 6. push to a new repo, re-verify from a fresh clone, then flip visibility
git clone … /tmp/verify-a && scripts/prepublish/audit.sh /tmp/verify-a
```

Redaction keeps the *finding* and drops the *value*: the docs still say "the WLAN PSK is
stored in clear and is identical on every radio" — they no longer print it. That is the
difference between a security write-up and a leak.

## What the mirror does not contain

| Omitted | Why | Where it still lives |
|---|---|---|
| `device-etc/` | vendor `/etc` snapshots with credentials and auth server blocks | this private repo |
| `firmware-analysis/` | extracted and decompiled vendor binaries (the vendor's IP) | this private repo |
| `qmanager/` | the QManager source tree — a separate private repository with its own history | that repository |
| raw captures with device identity | IMSI / IMEI / serials | this private repo, redacted in the mirror |

`deploy-x16/install.sh --build` therefore needs a QManager tree from elsewhere; the
mirror's README says so.

## Verifying it, any time

```sh
scripts/prepublish/audit.sh .                                  # this repo: 11 blockers, by design
scripts/prepublish/audit.sh /path/to/mirror-clone              # mirror: must be 0
```

Anonymous checks that actually prove publication state (no login, no token):

```sh
curl -s -o /dev/null -w '%{http_code}\n' https://github.com/RafayGhafoor/zlt-x16-field-tooling-public
curl -s https://api.github.com/repos/RafayGhafoor/zlt-x16-toolkit/releases/latest   # assets
curl -s -o /dev/null -w '%{http_code}\n' \
  https://raw.githubusercontent.com/RafayGhafoor/zlt-x16-field-tooling-public/main/device-etc/README.md
#   ^ must be 404
```

## Two traps found while doing this

- **`\b` does not work in a POSIX ERE.** The first version of the audit used
  `git grep -E '\b(410|460)[0-9]{12,13}\b'` and reported "no IMSI" — on Apple grep a
  `\b` pattern matches nothing, so the check passed by failing. It uses explicit
  `(^|[^0-9])…([^0-9]|$)` classes now. An audit that cannot fail is worse than none.
- **`gh` pushes cannot touch `.github/workflows/`** without the `workflow` scope
  (`refusing to allow an OAuth App to create or update workflow`). Push workflow files
  over SSH (`git@github.com:…`), or `gh auth refresh -s workflow`.

## If you ever need to redo the mirror

Same six steps. The only judgement calls are the redaction list in
`scripts/prepublish/audit.sh` (keep it in sync with `redact.py`) and what to keep from
`docs/captures/` — screenshots are fine if they carry no identity, text captures are
not.
