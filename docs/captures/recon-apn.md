# Recon — QManager "Settings > APN Configuration" shows nothing

Read-only recon on the device (no writes, no restarts, 6 AT reads total, each under
`timeout 12`). Local tree: `/Users/emumba/Downloads/projects/greenpacket-o5a-qmanager`.

Both QManager files on the device are byte-identical to the source tree
(`/data/qmanager/lib/cgi_at.sh` = `scripts/usr/lib/qmanager/cgi_at.sh`,
`/data/qmanager/www/cgi-bin/quecmanager/cellular/apn.sh` =
`scripts/www/cgi-bin/quecmanager/cellular/apn.sh`), and the deployed Next.js build
**does** contain the current card (grep for the card's own copy key
`save_connection_notice` hits `_next/static/chunks/b625d92571457cf9.js`). So this is
not a stale-build problem.

---

## 1. Reproduced symptom

Endpoint is fine and authenticated fine; it returns `success: true` and full JSON.
The information is simply **empty / pointed at the wrong context**.

```sh
# on device
curl -s -c C -X POST -d '{"password":"<redacted-password>"}' http://127.0.0.1:8080/cgi-bin/quecmanager/auth/login.sh
# -> {"success": true}   login_http=200

curl -s -b C http://127.0.0.1:8080/cgi-bin/quecmanager/cellular/apn.sh
# -> apn_http=200, ~4 KB JSON, success:true
```

Fast path (no auth) returns the same body:

```sh
cd /data/qmanager/www/cgi-bin/quecmanager/cellular && \
  _SKIP_AUTH=1 REQUEST_METHOD=GET QUERY_STRING= sh ./apn.sh
```

Captured body (relevant parts; full capture saved on device as `/tmp/apn.out`,
headers are `Content-Type: application/json` + `success/error` envelope):

```json
{ "success": true, "max_profiles": 6, "data_source": "at",
  "profiles": [ { "index": 1, "name": "", "apn": "", "pdp_type": "ipv4v6",
                  "auth_type": "none", "enabled": false,
                  "connect_progress": "disconnected", "ipv4_address": "",
                  "dns1": "", "dns2": "" }, ... ],
  "active": 0,
  "active_cid": 1,
  "internet_cid": 1,
  "apn": { "apn": "", "pdp_type": "ipv4v6", "cid": 1 },
  "cids": [
    { "cid": 1, "apn": "",  "apn_type": "", "is_internet": true  },
    { "cid": 2, "apn": "ims", "apn_type": "ims", "is_internet": false },
    { "cid": 3, "apn": "sos", "apn_type": "emergency", "is_internet": false },
    { "cid": 4, "apn": "", "apn_type": "", "is_internet": false },
    { "cid": 5, "apn": "", "apn_type": "", "is_internet": false },
    { "cid": 6, "apn": "connect.mobilinkworld.com", "apn_type": "", "is_internet": false }
  ] }
```

Ground truth from the modem (`/data/qmanager/bin/qcmd`, one command at a time):

```
AT+CGDCONT?
+CGDCONT: 1,"IPV4V6","",...                      <- internet slot, BLANK APN
+CGDCONT: 2,"IPV4V6","ims",...
+CGDCONT: 3,"IPV4V6","sos",...
+CGDCONT: 6,"IP","connect.mobilinkworld.com",... <- the profile that is really dialled

AT+CGACT?
+CGACT: 1,0        <- CID 1 NOT active
+CGACT: 2,1
+CGACT: 3,0
+CGACT: 6,1        <- CID 6 IS active

AT+CGPADDR
+CGPADDR: 1,0.0.0.0,0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0
+CGPADDR: 2,253.0.0.4.128.23.30.4.0.1.0.0.241.125.40.37
+CGPADDR: 3,0.0.0.0,0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0
+CGPADDR: 6,10.123.14.113     <- the internet bearer

AT+CGCONTRDP=6
+CGCONTRDP: 6,5,"connect.mobilinkworld.com",10.123.14.113,,119.160.122.146,119.160.80.146
AT+CGCONTRDP=1
OK                            <- nothing (CID 1 is not active)
```

Sidecars: **neither exists on the device**

```
cat: can't open '/etc/qmanager/apn_setting.json': No such file or directory
cat: can't open '/etc/qmanager/apn_names.json': No such file or directory
```

### What the user therefore sees

The page (`app/cellular/settings/apn-management/page.tsx` →
`components/cellular/settings/apn-management/apn-settings.tsx`, which uses
`hooks/use-apn-settings.ts`, **not** the 6-slot `useWanProfiles` hook) is a
single-APN write card. With the response above it renders:

* APN field: **empty** (`apn.apn === ""`, there is no fallback),
* PDP type: `ipv4v6`, CID select: `1` — the sidecar's defensive defaults, which
  look like real values,
* "Data context" chip: **"CID 1 in use for Internet"**
  (`apn-settings-card.tsx:503-515` renders `cid_in_use` with `activeCid`), while
  CID 1 is the *inactive, blank* context and the real internet APN
  (`connect.mobilinkworld.com`, CID 6) is listed as `is_internet: false` and is
  never shown as the APN.

So it is **not** an error/empty-array/shape problem: the CGI succeeds, but every
value on the card is either blank or attributed to the wrong PDP context.

---

## 2. Root cause (file:line)

### R1 — `active_cid` is always resolved as 1 (the real bug in the CID resolver)

`scripts/usr/lib/qmanager/cgi_at.sh:70-96` (same lines in
`/data/qmanager/lib/cgi_at.sh`), `detect_active_cid()`:

```sh
78:    cgpaddr_cids=$(printf '%s\n' "$raw" | awk -F'[,"]' '
79:        /\+CGPADDR:/ {
80:            cid = $1; gsub(/[^0-9]/, "", cid)
81:            ip = $3                       # <-- WRONG FIELD
...
94:    [ -n "$cgpaddr_cids" ] && active_cid=$(printf '%s\n' "$cgpaddr_cids" | head -1)
95:    [ -n "$active_cid" ] || active_cid="1"
```

With `-F'[,"]'` the line `+CGPADDR: 6,10.123.14.113` splits into
`$1="+CGPADDR: 6"`, `$2="10.123.14.113"`, `$3=""`. Every `+CGPADDR` line on this
firmware carries **one** address, so `$3` is *always* empty → each octet test
(`length(octets)==4 && octets[1]+0 > 0`) fails → `cgpaddr_cids` stays empty →
line 95 defaults `active_cid="1"`. The function can never return anything but 1
on this device.

Consumers: `scripts/www/cgi-bin/quecmanager/cellular/apn.sh:404-405`
(`detect_active_cid; internet_cid="$active_cid"`), which feeds
`cids[].is_internet` (apn.sh:407-415) and the frontend chip. `mtu.sh:40`
mentions the function only to say it cannot be used there; `apn.sh` is the only
caller.

### R2 — the stored-APN sidecar is never seeded, so `apn.apn` is always ""

`apn.sh:114` `SETTING_FILE="/etc/qmanager/apn_setting.json"` and
`apn.sh:217-224` `read_setting_json()` return `{"active":0}` when the file is
absent; `apn.sh:419-433` turns that into `apn_obj = {"apn":"", "pdp_type":"ipv4v6", "cid":1}`.
Nothing but a POST `save` ever creates the file, so on any device that has never
had an APN saved through QManager the card's APN field is permanently empty.
`apn_names.json` (apn.sh:113/186-193) is absent for the same reason — all six
`profiles[].name` are "".

### R3 — the granted APN is already in hand and thrown away

For each defined+enabled CID the GET issues `AT+CGCONTRDP=<cid>` (apn.sh:~300) and
runs `parse_cgcontrdp`, but `cgi_at.sh:160-190` only emits
`v4addr, gateway, dns1, dns2, v6addr`. `+CGCONTRDP`'s **field 3 is the negotiated
APN** (`"connect.mobilinkworld.com"` above) and `f[3]` is parsed then discarded.
That single field is the only reliable APN source on this device, because CID 1's
`AT+CGDCONT` APN is legitimately blank (the vendor dialer dials CID 6 and the
default/blank CGDCONT is never written).

### R4 — there is no QManager equivalent of the vendor's profile list

The vendor APN page is a list of up to **4 named profiles** stored in its own
config store; QManager models one APN + six CGDCONT contexts. Nothing in the
QManager tree reads the vendor store, so even a working APN read can only show
the one context's APN — the "profiles" the customer compares against are a
different data model (see §3).

---

## 3. How the stock (vendor) UI does it

Web root `/tzwww`; page `/tzwww/html/config/setting_apn.html`, logic
`/tzwww/js/config/setting_apn.js` (minified, one line). It is a Vue app that
POSTs JSON to `/tzwww/cgi-bin/http.cgi` (`Page.postJSON`):

| call | purpose | response fields used |
|---|---|---|
| `{json:{cmd:RequestCmd.APN_INFO_PROCESS, method:JSONMethod.GET}}` | **the APN list** | `apn_list[]` — `name` (label), `apnName`, `selectAuthtication` ("0"=NONE,"1"=PAP,"2"=CHAP,"3"=PAP&CHAP), `apnUserName`, `apnUserPassword`, `edit_flag`, `default_flag` |
| `{cmd:RequestCmd.APN_CONFIG, methods:GET, subcmd:3}` | global APN settings | `apnNatName`, `apnMTU`, `selectType` (IP / IPV6 / IPV4V6) |
| `{cmd:RequestCmd.MULTI_APN_INFO, methods:GET}` | multi-APN names | `multiApnNum`, `apnName1..N` |
| POST same cmd with `apn_list` | save the whole list | `success` |
| POST `apn_reset:"1"` | reset to defaults | `success` |

Hard cap: `if(this.editNum>=4) alert(fullAPN)` — the vendor list holds at most 4
profiles, one of which can be `default_flag="1"`. This is a vendor config store,
**not** `AT+CGDCONT`; that is why the stock page still shows profiles while the
modem's internet slot (CID 1) has a blank APN and the real APN sits on CID 6.

---

## 4. Fix plan (no device writes in this phase)

Files (source tree, then redeploy with `deploy-x16/install.sh`):

1. **`scripts/usr/lib/qmanager/cgi_at.sh:81`** — `ip = $3` → `ip = $2`.
   (Optionally also accept `$2` when it contains a space-separated mask, and skip
   CIDs 2/3 reserved for IMS/SOS.) This alone makes `detect_active_cid` return 6.
   *Expect `active_cid`/`internet_cid` = 6, `cids[5].is_internet = true`, chip
   "CID 6 in use for Internet".*
2. **`scripts/usr/lib/qmanager/cgi_at.sh:160-190`** (`parse_cgcontrdp`) — append
   the negotiated APN as a **6th** tab field (`f[3]`), keeping fields 1-5 in
   place so `cut -f1..5` callers (apn.sh ~300, and any other caller) are
   unchanged. Add `apn` to the documented contract.
3. **`scripts/www/cgi-bin/quecmanager/cellular/apn.sh`** —
   * capture the 6th field in the profile loop (alongside `v4addr`/`dns1`),
   * after `read_setting_json` (apn.sh:217-224 / 419-433): if the sidecar was
     absent (or `.apn` empty) **seed the display values from the modem** —
     `setting_apn` = negotiated APN of `active_cid` (fall back to that CID's
     `AT+CGDCONT` APN), `setting_pdp` = the CX's PDP type mapped through
     `pdp_to_frontend`, `setting_cid` = `active_cid`, `active` stays `0`
     (nothing has been *saved* through QManager). No write, no sidecar creation:
     keep `read_setting_json`'s `{"active":0}` file semantics untouched so the
     POST path is unchanged.
   * do **not** change the POST/save/deactivate paths in the same commit.
4. *(Second, separate feature — optional)* reproduce the "profiles" view the
   customer expects: render `cids[]`/`profiles[]` (CID, APN, PDP type, IMS/SOS
   tagging) as a read-only list above the write card. Do **not** scrape
   `/tzwww/cgi-bin/http.cgi` from QManager (coupled to vendor auth/session and
   the vendor config store; documented in §3 only as the explanation of the
   difference).

Deployed targets after a build: `/data/qmanager/lib/cgi_at.sh` and
`/data/qmanager/www/cgi-bin/quecmanager/cellular/apn.sh`.

---

## 5. How to verify

```sh
# 1. active CID resolver, cheap and offline of the UI
ssh zlt-root 'timeout 12 /data/qmanager/bin/qcmd "AT+CGPADDR"'   # expect +CGPADDR: 6,10.123.14.113
ssh zlt-root 'cd /data/qmanager/www/cgi-bin/quecmanager/cellular && \
  _SKIP_AUTH=1 REQUEST_METHOD=GET QUERY_STRING= timeout 40 sh ./apn.sh'
```

Expected after the fix:

* `"active_cid": 6`, `"internet_cid": 6`,
* `"apn": {"apn":"connect.mobilinkworld.com","pdp_type":"ipv4","cid":6}`
  (CID 6's CGDCONT PDP type is `IP` → `ipv4`),
* `"cids":[ … {"cid":6,"apn":"connect.mobilinkworld.com","is_internet":true} ]`,
* `profiles[0].enabled` stays `false` (CID 1 really is inactive: `+CGACT: 1,0`),
  so no regression there.

```sh
# 2. through the real HTTP path (auth) — must stay 200 + success:true
curl -s -c /tmp/C -X POST -d '{"password":"<redacted-password>"}' \
  http://127.0.0.1:8080/cgi-bin/quecmanager/auth/login.sh
curl -s -b /tmp/C http://127.0.0.1:8080/cgi-bin/quecmanager/cellular/apn.sh | head -60
```

3. In the browser at `http://127.0.0.1:8080/cellular/settings/apn-management/`:
   the APN field is pre-filled with `connect.mobilinkworld.com`, the chip reads
   "CID 6 in use for Internet", the card is no longer blank. Do **not** press
   Save to verify (it runs `AT+COPS=2/0` and drops the WAN for a moment).

---

## 6. Risks / do-not-touch

* `detect_active_cid` is shared; today its only caller is `apn.sh`. Changing
  `$3`→`$2` alters which CID the UI labels as internet, and — through
  `apn.cid` — the **default CID a subsequent Save would target**. Writes must
  keep using an explicitly supplied `cid`; do not let a display-side seed turn
  into a silent write to CID 6.
* CID 6 is the context the **vendor dialer/QCMAP owns**. Never restart
  QCMAP/dialer/services that own the PDP context, never send `AT+CGACT=0/1` or
  `AT+COPS=2/0` during verification (this is what the Save path does).
* `AT+CGCONTRDP=<cid>` answers a bare `OK` for inactive CIDs (measured on 1) and
  real data on 6 — any new parse must keep treating "no `+CGCONTRDP:` line" as
  "no runtime data", not as a failure.
* Do not reintroduce a file write on GET: `/etc/qmanager/` is root:root on this
  device (the sidecars would have to be created `www-data`-owned), and a GET that
  creates state is how the earlier "silently no-oped sidecar" bug happened.
* Do not touch `/tzwww`, `http.cgi`, `TzConfig.ini`/`SMGConfig.ini`, modem
  firmware, MBN/PDC profiles, or `/bin/dialer`.

## 7. Unknown / would resolve

* Where exactly the vendor persists `apn_list` (not in `/etc/TzConfig.ini`,
  `/etc/SMGConfig.ini`, `/etc/config/*`, and not in `AT+CGDCONT`). Resolving it
  would need a stock-UI session against `/tzwww/cgi-bin/http.cgi` and a
  filesystem watch — not needed for the fix above.
* Whether the vendor's `default_flag` profile is what its dialer writes to CID 6
  at boot — same answer requires the vendor cfg store. The observable fact is
  CID 6 = `connect.mobilinkworld.com`, active, with 10.123.14.113.
