# GAP-03 — QManager source-tree contract: how to add a feature

Scout 3 of 5. Scope: **what must change, in which files, to add a new page + CGI
backend to the QManager UI on `:8080`**, what already exists that a gap-filling
plan can reuse, and what the commit gate demands.

Sources read (all read in full unless noted):
`/tmp/qm` — `app/`, `components/`, `hooks/`, `lib/`, `scripts/`,
`public/locales/`, `docs/{FRONTEND,BACKEND}.md`, `docs/reference/{i18n,icon-system}.md`,
`AGENTS.md`;
this repo — `deploy-x16/{README.md,install.sh,start_qmanager,qm_pathfix_x16.sh}`,
`docs/09-features.md`, `tests/{run-all.sh,smoke_endpoints.sh,integration_payload.sh,unit_cgi_parsers.sh}`,
`.githooks/pre-commit`, `router-fix/voip-bridge/qmanager/` (the `calls` overlay).

---

## 0. Tree provenance — read this before trusting any path below

| Fact | Evidence |
|---|---|
| `/tmp/qm` **is not a git checkout** (`fatal: not a git repository`) | `git -C /tmp/qm log --oneline` |
| It is the *default* `QM_SRC` for both `deploy-x16/install.sh` and `tests/ts/run-ts-tests.sh` | `QM_SRC="${QM_SRC:-/tmp/qm}"` |
| It is a scratch copy, wiped on host reboot, and **predates this module's fixes** | `deploy-x16/README.md` "Install" warning; `install.sh:113-136` refuses only to *warn* |
| A page built from the wrong tree deploys the wrong payload and does not fail | `install.sh:118-120` ("it happily deploys the OLD behaviour") |

**Consequence for any gap-filling plan:** step 0 is `QM_SRC=<real checkout>`, and
the plan must name that checkout. Every path in this document was read from
`/tmp/qm`, so each one must be re-confirmed against the real checkout before it
is edited — the *structure* is stable, the *contents* are not.

The tree does carry **one** of our overlays already: `app/cellular/calls/page.tsx`
and `components/cellular/calls/` exist in `/tmp/qm`, and `public/locales/en/sidebar.json`
has `"calls": "Calls"`. Do not conclude from that the tree is current — the
voip-bridge overlay is 33 files and only some of them are present (see
`router-fix/voip-bridge/qmanager/apply.sh --check`).

---

## 1. To add a page + backend, touch these N places

Minimum viable feature (page + one CGI, no daemon, no new icon): **15 files across
11 artefacts**. The `calls` overlay is the real, complete precedent and cost
**33 payload files**; the `smartdns` feature cost **2** in the QM tree because its
page and four CGIs already shipped and only the engine was missing (see §3).

### A. Frontend — QManager tree

| # | Path | Change | Required? |
|---|---|---|---|
| 1 | `app/<group>/<feature>/page.tsx` | Thin **server** component whose whole body is `return <XComponent />`. No markup, no header. | **yes** |
| 2 | `components/<group>/<feature>/<feature>.tsx` | The `"use client"` shell. Owns the page header **and** the motion cascade. | **yes** |
| 3 | `components/<group>/<feature>/*-card.tsx` | One component per card, each self-contained (own fetch state). | 1..N |
| 4 | `hooks/use-<feature>.ts` | `"use client"`; owns fetch + mutate, returns `MutationResult`. | **yes** |
| 5 | `types/<feature>.ts` | Response/interface shapes. Not enforced, but every existing feature has one. | ~yes |
| 6 | `components/app-sidebar.tsx` | Add a `NavItem` to `navCellular` / `navLocalNetwork` / `navSystem` / `navMonitoring`. | **yes** |
| 7 | `hooks/use-breadcrumbs.ts` | Add `'<segment>': 'items.<t_key>'` to `routeKeyMap`. | **yes, easy to miss** |
| 8 | `public/locales/{en,zh-CN,zh-TW,it,id}/sidebar.json` | `items.<t_key>` × 5 files. | **yes** |
| 9 | `public/locales/{en,zh-CN,zh-TW,it,id}/common.json` | One new top-level object per feature × 5 files. | **yes** |
| 10 | `components/ui/material-symbol-names.ts` + `bun run icons:subset` | Only if the nav glyph is not already in the subset. | conditional |

Why #1 must stay thin — the tree states it twice, in the pages themselves:

```tsx
// app/local-network/smartdns/page.tsx
// It cannot hold the header, because this file is a SERVER component and the
// page's motion cascade has to be rooted in a client one — a header written here
// snaps in while the cards below it fade, which is the defect that made the
// sibling routes move their headers into their shells.
const SmartDnsPage = () => { return <SmartDnsComponent />; };
```

Why #7 is a real trap: `use-breadcrumbs.ts` falls back to
`segment.charAt(0).toUpperCase() + segment.slice(1).replace(/-/g,' ')`. `smartdns`
is **not** in `routeKeyMap`, so its breadcrumb currently renders **"Smartdns"**,
not "SmartDNS". `calls` is also absent, but "Calls" happens to be the correct
capitalisation, which is why the `voip-bridge` overlay got away without touching
the file. A new route is not so lucky.

No routing config exists to update: `next.config.ts` is `output: "export"`,
`trailingSlash: true`, and `app/<group>/layout.tsx` (a 9-line `AppLayout` wrapper)
already covers everything nested under an existing group. A new **top-level**
group needs its own `app/<group>/layout.tsx`; a sub-page does not.

### B. Backend — QManager tree

| # | Path | Change | Required? |
|---|---|---|---|
| 11 | `scripts/www/cgi-bin/quecmanager/<area>/<feature>.sh` | `#!/bin/sh` + `. cgi_base.sh` + method routing. | **yes** |
| 12 | `scripts/usr/lib/qmanager/<x>.sh` | Shared helper, only when a second caller exists (see the `resolve_wan_interface` comment in `mtu.sh` on why not to pre-abstract). | conditional |
| 13 | `scripts/usr/bin/qmanager_<feature>` | Daemon / boot oneshot / privileged helper. | conditional |
| 14 | `scripts/etc/systemd/system/qmanager-<feature>.service` | Unit. **Useless at boot on the X16 without the hook (see C).** | conditional |
| 15 | `scripts/usr/lib/qmanager/config.sh` | Add a `DEFAULTS` section if the feature persists settings in `/etc/qmanager/qmanager.conf`. | conditional |
| 16 | `scripts/usr/bin/qmanager_poller` + `types/modem-status.ts` | Only for a *live* metric (see §1.D). | conditional |

Two conventions the CGIs are held to, from `docs/BACKEND.md` §2.1 and the code:

- **Never write to the rootfs.** The only writable paths are `/data` (the X16's
  `/usrdata`), `/etc`, `/etc/qmanager`, `/etc/systemd/system`, `/tmp`, `/run`.
- **Do not hardcode `/usrdata` or `/usr/lib/qmanager`** in a form the pathfixer
  will not reach. `deploy-x16/qm_pathfix_x16.sh` rewrites four prefixes
  (`/usr/lib/qmanager` → `$QM_ROOT/lib`, `/usrdata/qmanager` → `$QM_ROOT`,
  bare `/usrdata` → `/data`, `/usr/bin/qmanager_*` → `$QM_ROOT/bin/*`). The bare
  `/usrdata` rule exists because the Tailscale installer did `cd /usrdata` at
  four sites; a new CGI that writes `/usrdata/foo` gets rewritten correctly, one
  that writes some *fifth* absolute path does not.

### C. Device side — this repo (`deploy-x16/`)

| # | Path | Change | Required? |
|---|---|---|---|
| 17 | (nothing) | `install.sh --build` copies **whole directories**: `out/.` → `www/`, `cgi-bin/quecmanager` → `www/cgi-bin/`, `usr/lib/qmanager/.` → `lib/`, `usr/bin/.` → `bin/`. A new page and a new CGI are carried automatically. | — |
| 18 | `deploy-x16/start_qmanager` | **One line per new unit.** This is the only thing that starts a unit at boot. | if #14 |
| 19 | `deploy-x16/install.sh` | Add the unit to a `push` list + `--uninstall`, only if you added #13/#14 or a new **native binary**. | if #13/#14 |
| 20 | `<module>/install.sh` (`--install/--check/--uninstall`) | Only if the feature needs a device-side *engine* (the `smartdns/` precedent). | conditional |

**Do not rely on `systemctl enable`.** `/etc` is a separate ubi volume mounted
~10 s into boot, after systemd has loaded its unit files, so everything under
`/etc/systemd/system` is invisible for that boot. Verified twice in
`deploy-x16/README.md` ("Why a boot hook") and in `docs/09-features.md`
("Boot persistence: `enabled` was not enough").

### D. Adding one live metric (the poller chain)

`qmanager_poller` (3326 lines) is the single writer of
`/tmp/qmanager_status.json`. Fields are added, not discovered:

1. **Collect** — a `update_*` / `poll_tier*` function sets a shell variable.
   Cadence is chosen by tier: `poll_cycle` body (Tier 1, ~3.7–4.0 s measured),
   `% TIER1_5_EVERY` (5 → ~10 s), `% TIER2_EVERY` (15 → ~30 s),
   `% TIER3_EVERY` (15 → ~60 s, runs *after* the budget timer).
2. **Publish** — add a `--argjson <var>` to the `jq -n` in `write_cache()`
   (`qmanager_poller:2716`) and the key inside the JSON object literal. The
   optional-block idiom is `--argjson phy "${phy_json:-null}"` with the key
   omitted from the object while empty, so a fresh boot has the old cache shape.
3. **Type** — add the field to `types/modem-status.ts` (`ModemStatus`).
4. **Read** — the page consumes it through `useModemStatus()`
   (`hooks/use-modem-status.ts`, 2 s poll, 10 s staleness threshold) or through a
   thin CGI that just reads the cache.

There is **no poller config file** for metrics. The only tunables are the unit's
`Environment=` (`POLL_PERIOD`, `QM_AT_MIN_INTERVAL=3`) and
`scripts/etc/qmanager/environment` (which holds only `QLOG_LEVEL=INFO`).
Feature settings persist via `config.sh`'s `qm_config_get` / `qm_config_set` into
`/etc/qmanager/qmanager.conf`.

The durable metric archive is separate: `lib/qmanager/phy_metrics.sh` appends one
CSV row per Tier-3 pass to `QM_PHY_ARCHIVE_DIR` (default
`/usrdata/qmanager/metrics`, i.e. `/data/qmanager/metrics` after pathfix),
`YYYY-MM-DD.csv`, with `qm_phy_archive_row`.

---

## 2. Annotated minimal CGI + its page

### 2a. The smallest real CGI — `public/hostname.sh` (44 lines, complete)

This is the whole file. It is the best template because it is short enough to
hold in mind and it shows every required element.

```sh
#!/bin/sh
# hostname.sh — Public, unauthenticated device-identity endpoint.
# ...
# Endpoint: GET /cgi-bin/quecmanager/public/hostname.sh
# Response: application/json  ->  { "hostname": "<string>" }
# Install location: /usrdata/qmanager/www/cgi-bin/quecmanager/public/hostname.sh

_SKIP_AUTH=1                          # ← MUST be set BEFORE the source line;
. /usr/lib/qmanager/cgi_base.sh       #   cgi_base.sh calls require_auth at LOAD time
qlog_init "cgi_public_hostname"       # ← log tag; every line goes to /data/log/
cgi_headers                           # ← Content-Type + no-cache + CORS + blank line
cgi_handle_options                    # ← answers OPTIONS and exits

if [ "$REQUEST_METHOD" != "GET" ]; then
    cgi_method_not_allowed            # ← {"success":false,"error":"method_not_allowed"}
    exit 0
fi

HN=""
if [ -r /proc/sys/kernel/hostname ]; then
    HN=$(cat /proc/sys/kernel/hostname 2>/dev/null)
fi
HN=$(printf '%s' "$HN" | tr -d '\r\n' | cut -c1-63)

jq -n --arg hostname "$HN" '{hostname:$hostname}'   # ← jq builds the response
```

What each element is *for*, and what breaks without it:

| Element | Contract |
|---|---|
| `_SKIP_AUTH=1` | Only for `public/`. Otherwise authentication is **automatic**: `cgi_base.sh:217` runs `require_auth` at source time, which 401s unless a valid session cookie exists. A new endpoint that forgets nothing gets auth for free. |
| `cgi_headers` | Must be called before any body. Defines `must`-set CORS + `no-store`. |
| `qlog_init` | Sourced from `qlog.sh`; the `|| { no-ops }` fallback in `cgi_base.sh:64` means a missing logger never breaks a request. |
| `jq -n …` | **Every** response is built by jq. `jq` is not on the device: it is staged by `install.sh --build` as a static ARMv7 binary into `/data/qmanager/bin/jq`, and `cgi_base.sh:18` puts `/data/qmanager/bin` on `PATH`. |
| `exit 0` | A CGI that falls off the end has already emitted its body; the exit code is not the HTTP status. |

**Response envelopes** (from `cgi_base.sh`):

```jsonc
// success, resource-shaped   → free-form object, success implicit
{"hostname":"x16"}

// success, mutation          → cgi_success():            {"success":true}
// success with payload       → jq -n '{success:true, …}'
{"success":true,"is_enabled":true,"current_value":1500}

// error                      → cgi_error <code> <detail>
{"success":false,"error":"invalid_mtu","detail":"MTU must be between 576 and 9000"}
```

`cgi_error` has a jq-free fallback (`_cgi_json_escape`) that is **byte-identical**
to jq's output, so `cgi_error` is safe even on a device whose `jq` is missing —
this is a behaviour probe, not a `command -v` check (`cgi_base.sh:151-193`).

### 2b. GET + POST with validation — `network/mtu.sh` (condensed, real)

The structure every mutating endpoint follows. Line numbers refer to the real
192-line file.

```sh
#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh                # (2)
qlog_init "cgi_mtu"; cgi_headers; cgi_handle_options   # (24-26)

# ---- GET: read state ------------------------------------------------ (93-115)
if [ "$REQUEST_METHOD" = "GET" ]; then
    current_mtu=$(get_current_mtu); current_mtu=${current_mtu:-1500}   # default, never null
    is_enabled="false"; [ -f "$MTU_FIREWALL_FILE" ] && is_enabled="true"
    jq -n --argjson is_enabled "$is_enabled" \
          --argjson current_value "$current_mtu" \
          '{success:true, is_enabled:$is_enabled, current_value:$current_value}'
    exit 0
fi

# ---- POST: validate, persist atomically, apply ---------------------- (120-189)
if [ "$REQUEST_METHOD" = "POST" ]; then
    cgi_read_post                                        # uses CONTENT_LENGTH
    mtu_value=$(printf '%s' "$POST_DATA" | jq -r '(.mtu) | if . == null then empty else tostring end')

    [ -z "$mtu_value" ] && { cgi_error "missing_field" "mtu field is required"; exit 0; }

    case "$mtu_value" in ''|*[!0-9]*)                   # no regex on the device
        cgi_error "invalid_mtu" "MTU must be a number"; exit 0 ;; esac
    [ "$mtu_value" -lt 576 ] || [ "$mtu_value" -gt 9000 ] && {
        cgi_error "invalid_mtu" "MTU must be between 576 and 9000"; exit 0; }

    MTU_TMP="${MTU_FIREWALL_FILE}.tmp"                   # atomic: temp + mv
    ... > "$MTU_TMP"; mv "$MTU_TMP" "$MTU_FIREWALL_FILE"
    ...                                                  # then apply live
    jq -n --argjson current_value "$mtu_value" \
          '{success:true, message:"MTU configuration updated", current_value:$current_value}'
    exit 0
fi

cgi_method_not_allowed                                                        # (192)
```

Three rules visible here that a new endpoint must copy:

1. **Validate with `case`, not regex.** The device's busybox/jq have no regex
   engine in the places you would expect; `case "$x" in ''|*[!0-9]*)` is the idiom.
2. **Persist atomically** — write `.tmp`, then `mv`.
3. **Never emit a default as if it were a reading** without `qlog` noting it; and
   when a value is genuinely unavailable, emit `null` (the frontend's
   `null`-handling is the "no reading" state, per `types/modem-status.ts`).

### 2c. The frontend half — `hooks/use-mtu-settings.ts` (complete pattern)

```ts
"use client";
import { authFetch } from "@/lib/auth-fetch";          // 401 → /login/, keeps cookies
import type { MutationResult } from "@/types/mutation-result";   // {ok, error}

const CGI_ENDPOINT = "/cgi-bin/quecmanager/network/mtu.sh";

export interface MtuSettingsData { isEnabled: boolean; currentValue: number; }

export function useMtuSettings() {
  const [data, setData]       = useState<MtuSettingsData | null>(null);
  const [isLoading, setL]     = useState(true);
  const [isSaving, setS]      = useState(false);
  const [error, setError]     = useState<string | null>(null);
  const mountedRef            = useRef(true);          // no setState after unmount

  const fetchMtu = useCallback(async (silent = false) => {
    if (!silent) setL(true); setError(null);
    const resp = await authFetch(CGI_ENDPOINT);
    const json = await resp.json();
    if (!json.success) { setError(json.error || "Failed…"); return; }   // ← check .success
    setData({ isEnabled: json.is_enabled, currentValue: json.current_value }); // snake→camel here
  }, []);

  useEffect(() => { fetchMtu(); }, [fetchMtu]);        // fetch on mount

  const saveMtu = useCallback(async (mtu: number): Promise<MutationResult> => {
    const resp = await authFetch(CGI_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },  // ← required; CGI reads only this
      body: JSON.stringify({ mtu }),
    });
    const json = await resp.json();
    if (!json.success) {
      const message = json.detail || json.error || "Failed to apply MTU"; // detail wins
      setError(message);
      return { ok: false, error: message };            // ← never read hook state after await
    }
    await fetchMtu(true);                              // silent refresh, no loading flash
    return { ok: true, error: null };
  }, [fetchMtu]);

  return { data, isLoading, isSaving, error, saveMtu, disableMtu, refresh: fetchMtu };
}
```

And the page is 10 lines (`app/local-network/ttl-settings/page.tsx`):

```tsx
const TTLandMTUSettingsPage = () => { return <TTLandMTUSettingsComponent />; };
export default TTLandMTUSettingsPage;
```

**The whole contract in one line:** `web page → hook → authFetch(GET/POST) →
CGI (sh) → jq → /tmp or /etc` — with the CGI's `success:false` +
`detail`/`error` pair surfaced verbatim in the card's error state.

---

## 3. Inventory — already built, not yet used on this device

The single most important finding for a gap-filling plan: **most gaps are not
missing UI, they are missing engines, or a page nobody linked.**

### 3.1 Fully implemented in the QM tree — verify deployment before planning

| Capability | Code that exists | State on X16 | Notes |
|---|---|---|---|
| **Tailscale VPN** | `app/monitoring/tailscale/page.tsx`; `components/monitoring/tailscale/` (5 files: `tailscale.tsx`, `status-band`, `connection-card`, `peers-card`, `install-card`, `danger-card`); `hooks/use-tailscale.ts` (474 L); `scripts/www/cgi-bin/quecmanager/vpn/tailscale.sh` (**612 L**); `scripts/usr/bin/qmanager_tailscale_mgr` (**421 L**); `scripts/etc/systemd/system/tailscaled.{service,defaults}` | **Not deployed and not documented.** No mention in `docs/09-features.md`; not in `deploy-x16/install.sh`'s unit lists; needs a native `tailscale`/`tailscaled` ARM binary at `/usrdata/tailscale/` (pathfixed by `qm_pathfix_x16.sh`, whose header specifically records fixing its `cd /usrdata` sites). | The **only** real VPN. `qmanager_firewall` already whitelists `tailscale0` if the binary is present, and the sudoers file pre-authorises `systemctl … tailscaled`. This is the cheapest large win: page + CGI + manager all exist. |
| **SmartDNS** | page, 4 CGIs, `smartdns_stats.sh` | **Deployed** via `deploy-x16/smartdns/` | The precedent for "page shipped, engine missing": only 2 files changed in the QM tree. |
| **Traffic Engine (DPI)** | page + `video_optimizer.sh` | **Deployed** (`qmanager-dpi{, -ensure}`) | Same shape; units were the only missing piece. |
| **Calls** | full overlay in `router-fix/voip-bridge/qmanager/` (33 files) | Deployed | See §1 for the file list this cost. |
| **Web console (ttyd)** | `app/system-settings/web-console/`; `qmanager_console_mgr` (downloads ttyd) | **Not installed.** Not in any unit list; and it would need a binary download, which the read-only-rootfs/no-Entware model does not do at boot. | Exposes a root shell → covers `route`/`arp`/`traceroute`/`tcpdump` manually, not as features. |
| **AT Terminal** (`at_cmd/send_command.sh`) | raw AT passthrough, blocks `QSCAN*` | Deployed | The **only** path to commands absent from the allowlist — including `AT+CUSD` (USSD), `AT+CGLA`/`AT+CRSM` beyond the wasted-CRSM probe. Not a feature. |

### 3.2 Present but partial / unsupported by design

| Area | What exists | Reality |
|---|---|---|
| Firewall | `scripts/usr/bin/qmanager_firewall` + `qmanager-firewall.service`, chain `QMANAGER_FW`, ports 80/443, trusted `lo bridge0 eth0 [tailscale0]` | A **port gate for the UI itself**, not a firewall manager. No page, no rule CRUD, no port-forwarding/NAT UI. |
| DHCP | none | `dnsmasq.leases` is *read* by `ippt.sh` (IP-passthrough); the leases file is a dependency, not a feature. No DHCP server page, no lease table, no reservation CRUD. |
| Cell locking / frequency locking | `tower/lock.sh`, `frequency/lock.sh`, `bands/lock.sh` | LTE `AT+CCELLCFG` only, one EARFCN+PCI; NR-SA unsupported; write not yet applied live (`docs/09`, `docs/23`). |
| IP passthrough | `network/ip_passthrough.sh`, `ippt.sh` | Upstream drives Quectel `ql_qmap`, absent here. |
| FPLMN / MBN | `cellular/fplmn.sh`, `cellular/mbn.sh` | Answer an explicit `unsupported:*` error; never fake data. The smoke suite asserts exactly that. |

### 3.3 Absent — no code at all (grep across `app/ components/ hooks/ scripts/ lib/`)

| Gap | Grep result |
|---|---|
| **QoS / SQM / traffic shaping** | 0 hits |
| **UPnP / IGD** | 0 hits |
| **USSD** | 0 hits, including `AT+CUSD` in the allowlist and in `atcli_smd11` |
| **SNMP** | 0 hits |
| **DDNS** | 0 hits (`ddns` matched only a scenario card, unrelated) |
| **Traceroute / ping-to-host UI** | 0 hits (`qmanager_ping` pings *its own* probe targets only; `monitoring/sites.sh` is a fixed-domain latency sweep) |
| **tcpdump / packet capture UI** | 0 hits |
| **Static routes / routing table UI** | 0 hits |
| **ARP table UI** | 0 hits (`arp` matched `shapes`, `avatar`, `sidebar` — substring noise) |
| **Parental controls** | 0 hits (`parent` = React prop) |
| **Port forwarding** | 0 hits (`port forward` matched only SMS forwarding) |
| **WireGuard / OpenVPN** | 0 hits; Tailscale only |

---

## 4. Test & gate requirements

### 4.1 What actually gates a commit

| Gate | Command | Wired in? |
|---|---|---|
| Host suite | `sh tests/run-all.sh` | **yes** — `.githooks/pre-commit`, bypass `git commit --no-verify` or `QM_TEST_SKIP=1` |
| Device leg | `sh tests/run-all.sh --device` | **no** — deliberately excluded (needs the box + 2–3 min) |
| `bun run i18n:check` | strict: missing/empty/extra key = **error** | **no** — not called by `run-all.sh`; `scripts/test/` was deleted 2026-09-03 |
| `bun run icons:check` | font/manifest parity | **no** — runs only via `bun run package` |
| `bun run lint` | eslint | **no** |

So the enforced gate is this repo's `tests/run-all.sh` (12 `run_unit` suites + 2
static checks + the bun TS leg, ~6 s, parallel,
`QM_TESTS_SEQ=1` to serialise). Everything else is a convention you must choose to
run — but `i18n:check` is a *hard error* gate the moment anyone runs it, and a
missing locale key is exactly what a new page introduces.

### 4.2 What a new feature must add to `run-all.sh`

`run-all.sh` declares suites with `run_unit "<label>" "$HERE/<file>.sh"`. A new
suite is a `sh` file printing `ok`/`bad` lines. **Two traps the runner already
guards against**, both of which a new suite must respect:

1. `_scan_log` fails a suite that printed `command not found` — "an assertion that
   did not run is not a passing assertion".
2. The runner replays per-suite logs in declaration order, so output is
   deterministic regardless of parallelism.

Minimum expected additions for a page + CGI:

| File | Why |
|---|---|
| `tests/smoke_endpoints.sh` | One row in the `ENDPOINTS="…"` block: `endpoint\|key\|expectation`. The 3rd column is an **expectation**, not a key name — `ok`, `unsupported:<reason>`, `true:<key>`, `false:<key>`, `nonempty:<key>`, `nonnull:<key>`. Shape-only checks once reported "46 ok, 0 failures" while three features were broken. |
| `tests/unit_<feature>.sh` | Only if the CGI parses something. The house pattern (`unit_cgi_parsers.sh`) copies the parsing code **verbatim** from the QM tree with a `MAINTENANCE POINTS` block naming file:line, so an upstream change is visibly a test change; `QM_SRC=<tree>` additionally asserts the copies still match. |
| `tests/check_boot_wiring.sh` | Only if a new unit is added — it asserts `ActiveEnterTimestampMonotonic` is inside the current `/proc/uptime`, i.e. started **by this boot**, not by hand. |
| `tests/integration_payload.sh` | Only if `install.sh` gains a push step; it already catches "a file pushed by install.sh that no longer exists in the tree", "a unit enabled but not removed by `--uninstall`", and "a path `qm_pathfix_x16.sh` no longer rewrites". |

### 4.3 Documentation obligation

`AGENTS.md` §7: one commit per finished feature, `Verified:` line for on-device
work, cross-referenced when the change spans this repo and the QM tree. A `docs/`
page describing the fix lands in the same commit.

---

## 5. The gap-filling plan this implies

Ordered by cost/benefit as the tree actually stands:

1. **Tailscale** — 0 new frontend or CGI code; verify `tailscaled` can run on this
   ARMv7/glibc-2.31 unit, then deploy the binary + unit + boot-hook line. Add
   `tailscale` to `smoke_endpoints.sh` (currently absent from the 48 rows).
2. **Breadcrumb + nav fixes** — `smartdns` and `calls` are both missing from
   `hooks/use-breadcrumbs.ts`'s `routeKeyMap`; a 2-line fix.
3. **Firewall/DHCP/port-forward/QoS/UPnP/USSD/SNMP/DDNS** — genuinely greenfield.
   Each is the full 15-file checklist (§1A + §1B), plus a device-side engine if it
   needs one (the `smartdns/` module shape).
4. **Do not build a Shell page for `route`/`arp`/`traceroute`/`tcpdump`** — those
   are already reachable over SSH and, if ttyd were deployed, via the Web Console.
   They are a diagnostic surface, not a feature gap.

---

## Provenance / what was *not* verified

- Every file path and code excerpt above was read from `/tmp/qm`, which is **not a
  git checkout** and predates this module's QM-side fixes. Paths are stable;
  contents must be re-confirmed against the real checkout.
- Device-side state (whether a `tailscale` binary exists at `/usrdata/tailscale/`,
  whether `ttyd` is installed) was **not** probed — no device session was opened
  in this scout. The claims here are "no code path deploys it", which is provable
  from this repo alone.
- The `run-all.sh` suite was not executed; its contents and the pre-commit hook
  were read.
