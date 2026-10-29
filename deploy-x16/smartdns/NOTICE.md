# smartdns (smartdns-rs) — attribution, for the copy this module deploys

**This module does not vendor the binary.** `install.sh` takes it from the QManager
tree (`$QM_SRC/dependencies/smartdns/smartdns`, default `/tmp/qm`) and refuses a hash
that is not the release asset every QManager install runs:

```
file    smartdns — ELF 32-bit LSB, ARM, EABI5, statically linked, stripped
size    7,029,804 bytes
sha256  2caca59f6c9a68a09de10c32414693b3eae3cc4ab6a42166343f8589070cb291
version smartdns-rs 0.13.1   (`smartdns --version`)
```

**Upstream:** <https://github.com/mokeyish/smartdns-rs> — tag **v0.13.1**.
**Licence:** GNU GPL v3 (`smartdns-rs`); the hickory-dns code inside it is
Apache-2.0/MIT by upstream's own statement.

The authoritative notice — licence text, the written offer of corresponding source,
and why the binary is committed to the QManager tree rather than fetched at deploy
time — lives beside the file it describes:

- `$QM_SRC/dependencies/smartdns/NOTICE.md`
- `$QM_SRC/dependencies/smartdns/LICENSE.GPL-3.0`

No local patches are applied to the resolver. It runs as a separate process
(`qmanager-dns.service`), so QManager's own licensing is unaffected.

**Runtime facts worth having next to the licence** (details in `README.md`):

- the daemon is **not** the LAN-facing resolver — dnsmasq owns `192.168.3.1:53` and
  `strict-order`-forwards to `127.0.0.1:5353`, so stopping it degrades rather than
  breaks LAN DNS, which is what makes the page's toggle safe;
- `smartdns test -c` **validates nothing** on 0.13.1 (unknown directives are silently
  ignored). Never gate a config deploy on it: `qmanager_dns_apply` runs the candidate
  on a throwaway port and requires it to bind and answer before swapping.

**Written offer of corresponding source:** contact the owner of the QManager project
(`RafayGhafoor/QManager-RM520N`) for a source archive of this exact build.
