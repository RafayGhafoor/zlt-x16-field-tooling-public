# 21 — FOTA / Update Channels: what actually exists

Question: *can this unit pull the latest firmware itself?*

**Answer: no. Every update channel on this device is either disabled,
unconfigured, or pointed at an address unreachable from the deployment network.**
The 2.0.0.5 build (`X16-OMN247_4.0.04`, see [11](11-device-and-firmware.md)) will
have to come from the operator/vendor.

Measured 2026-10-26 on the live unit.

---

## 1. FOTA — client present, no server

The client exists and is not running:

```
-rwxrwxr-x 1 system system 292664 Jan  5  2024 /bin/fota
$ pidof fota   -> (nothing)
```

Every relevant config value is empty or disabled:

```
USR_FOTA_SWITCH            = 0          <- master switch OFF
USR_FOTA_URL               = ""
USR_FOTA1_URL              = ""
USR_FOTA1_URL_2            = ""
USR_FOTA_DOWNLOAD_FILEPATH = ""
USR_FOTA_USERNAME          = ""
USR_FOTA_PASSWD            = ""
USR_FOTA_PORT              = ""
```

What *is* configured is only the shape of the protocol, not a destination:

```
USR_FOTA_SERVER_RULE   = tozed        <- Tozed/ZLT OTA protocol
USR_FOTA_CONFIGNAME    = version.zip  <- fetches <url>/version.zip
USR_FOTA_CHECK_TIME    = 86400
USR_FOTA_TIMEOUT       = 2000
USR_FOTA_SPEEDLIMIT    = 1024
USR_FOTA_AUTO_UPGRADE_SWITCH = 1      <- auto-upgrade ON, but no URL to check
```

`/bin/fota` contains **no hardcoded URL**. Its strings are config-driven:
`E_CONF_ID_FOTA_SWITCH`, `E_CONF_ID_URL`, `RedirectPKGURL`, `ServerVersion`,
`TZ_FOTA_ON_BOOT`, `TZ_FOTA_STATUS`. So there is nothing to fall back to — with
`USR_FOTA_URL` empty the client has nowhere to look.

Note `USR_FOTA_AUTO_UPGRADE_SWITCH=1` sitting on top of an empty URL: if anyone
later fills in a URL, auto-upgrade is already armed.

## 2. TR-069 — three different failure modes, all fatal

| Target | Source | Result |
|---|---|---|
| `http://acs.isp.nawras.om:7547/` | factory `main_config` | DNS resolves to **10.215.235.20** — a *private* address on Ooredoo Oman's internal network. Unreachable from Pakistan (`http=000`). |
| `183.6.18.43:12345` | live `USR_TR069_SERVER_IP` / `_PORT` | unreachable (`http=000`) |
| `netcwmpd` | `start_netcwmpd` | **never starts** — syntax bug at line 38 (`[ -z "\`pidof netcwmpd\`"];then`, missing space before `]`) |

So even if an ACS were reachable, no CWMP client is running. See
[19](19-vulnerability-assessment.md) §V11 — do **not** "fix" that bug without
first clearing the ACS fields, because `USR_TR069_UPGRADE_AUTO_SW=1` would
re-arm vendor remote management with automatic firmware upgrade.

## 3. Version-check endpoint — live but empty

```
USR_TR069_CHECK_VERSION_ADDR = http://cn.tr069.cwmpd.com:8666/version/
$ curl http://cn.tr069.cwmpd.com:8666/version/
{}
[http=200 size=2]
```

A Chinese CWMP demo server answering `{}`. It is reachable but publishes no
version information. Not an update source.

## 4. Web UI "online upgrade" — no endpoint found

The command enum exposes the surface — `ONLINE_UPGRADE_AUTO` (196),
`REMOTE_UPGRADE` (198), `UPGRADE_IMMEDIATELY` (239), `SYS_AUTO_UPGRADE` (240),
`DETECTION_VERSION_INFO` (238) — but:

- `strings /tzwww/cgi-bin/http.cgi` contains **no OTA URL** (only a libc
  launchpad reference);
- the CGI returned an empty 200 body to every request shape tried (POST+query,
  plain GET, form-encoded, with and without a `login.html` cookie jar), including
  `INIT_PAGE` (cmd 80) which the login page is known to call unauthenticated.

That last point matters: **an empty 200 is not evidence that the handler rejected
the request.** It is the CGI refusing to emit output for our request shape. The
real handler behaviour still needs to be observed in a browser (see §6).

---

## 5. What this means

The device cannot self-update. To move to `2.0.0.5` / `X16-OMN247_4.0.04`:

1. **Ask the operator/vendor** (Ooredoo Oman for the OMN247 SKU) for the package,
   or the ODM (Tozed/ZLT) for a `X16-OMN247` build. This is the only realistic
   route — the package is not reachable from the device's configured channels.
2. If a package is obtained, it installs via the local upgrade path
   (`SYS_UPDATE` / `CONFIG_UPDATE` / the `update_ota.bin` flow in
   `/data/logs_backup/SYSUPGRADE.log`), **not** FOTA.
3. Do **not** point `USR_FOTA_URL` at an arbitrary host to "try it": the client
   accepts a package and auto-upgrade is already enabled. An untrusted package is
   a root compromise vector.

## 6. To settle the web-UI question

Browser-based, not curl:

1. Log into `http://192.168.3.1/` as admin.
2. Open the upgrade / system page and press "check for updates".
3. Watch with DevTools → Network, or on the device:
   ```sh
   ssh zlt-x16-root 'strings /bin/fota | head -1; tcpdump -ni any -A tcp port 80 or 443 2>/dev/null | grep -aiE "GET|Host:" | head -40'
   ```
   (`tcpdump` may not be installed — DevTools is simpler.)
4. If a vendor URL appears, it is the real OTA endpoint and can be tested
   directly with `curl`.

---

## 7. Incidental finding while investigating this

`/tzwww/cgi-bin/http.cgi` is **`-rwxrwxrwx root root`** and is executed **as root**
by `mini_httpd` (`user=root`, `cgipat=cgi-bin/*`).

```
-rwxrwxrwx 1 root   root     468680 Jul 19  2025 /tzwww/cgi-bin/http.cgi
-rwxrwxrwx 1 system system  2188384 Jul 10  2025 /tzwww/cgi-bin/http.cgi.bak
```

Any local process can overwrite that file and obtain code execution as **root** on
the next web request. It is also the single point of failure for the entire admin
UI — replacing it is both an escalation and a total DoS of the management
interface. `/tzwww` is on the read-only `ubi0:rootfs`, yet the CGI is 0777, which
means the vendor explicitly widened it; the `.bak` (2.1 MB vs the live 468 KB) is
a *different, larger* build of the same CGI.

Recorded as **V20** in [19](19-vulnerability-assessment.md).
