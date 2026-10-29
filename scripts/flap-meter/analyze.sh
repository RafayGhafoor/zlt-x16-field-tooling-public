#!/bin/sh
# Turn a transition log (+ the vendor dialer log) into the answer to one
# question: do radio changes precede the WAN drops, or follow them?
#
# Pure awk with a hand-rolled epoch, because the device has no python and the
# host's awk has no mktime. Read-only; takes file paths, contacts nothing.
#
#   ./analyze.sh capture/transitions-<host>-<stamp>.log [capture/dialer-...log]
#
# With no dialer log given, it uses the newest capture/dialer-*.log beside it.
set -eu
tlog=${1:?usage: analyze.sh <transitions.log> [dialer.log]}
if [ $# -ge 2 ]; then
    dlog=$2
else
    dlog=$(ls -t "$(dirname "$tlog")"/dialer-* 2>/dev/null | head -1 || true)
fi

[ -r "$tlog" ] || { echo "analyze.sh: cannot read $tlog" >&2; exit 1; }

awk -v tlog="$tlog" ${dlog:+-v dlog="$dlog"} '
function leap(y) { return (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) }
function epoch(y, mo, d, h, mi, s,   mm, days, i, yy) {
    split("31 28 31 30 31 30 31 31 30 31 30 31", mm, " ")
    days = 0
    for (yy = 1970; yy < y; yy++) days += (leap(yy) ? 366 : 365)
    for (i = 1; i < mo; i++) days += mm[i] + (i == 2 && leap(y) ? 1 : 0)
    days += d - 1
    return days * 86400 + h * 3600 + mi * 60 + s
}
# "YYYY-MM-DD HH:MM:SS" (our log, and the dialer log) or "YYYY-MM-DD HH:MM:SS.ffffff"
function ts(line,   a, b) {
    if (line !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) return -1
    split(substr(line, 1, 19), a, "[-: ]")
    return epoch(a[1] + 0, a[2] + 0, a[3] + 0, a[4] + 0, a[5] + 0, a[6] + 0)
}
function dur(s,   h, m) { h = int(s / 3600); m = int((s % 3600) / 60); return sprintf("%dh%02dm%02ds", h, m, s % 60) }

BEGIN { ns = 0; nc = 0; npcc = 0; nscc = 0; nendc = 0; nnr = 0; ndrop = 0; nup = 0; nerr = 0; nbeat = 0; gapmax = 0 }

/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] / {
    t = ts($0)
    if (t < 0) next
    if (first == 0) firsts = substr($0, 1, 19)
    if (first == 0 || t < first) first = t
    lasts = substr($0, 1, 19)
    if (t > last) last = t
    if (prev_t > 0 && t - prev_t > gapmax && $0 ~ / (STATE|HEARTBEAT) /) gapmax = t - prev_t
    prev_t = t

    if ($0 ~ / ERROR /) { nerr++; errs[nerr] = $0; next }
    if ($0 ~ / SUMMARY /) { summary = $0; next }
    if ($0 ~ / HEARTBEAT /) { nbeat++; next }
    if ($0 ~ / STATE /) {
        ns++
        # Derive the transition from the STATE line itself rather than trusting
        # the CHANGE lines: this works for old logs (where every SCC event was
        # just "scc") and new ones, and it cannot disagree with the state it is
        # supposed to describe.
        pcc = fld($0, "pcc="); scc = fld($0, "scc="); endc = fld($0, "endc="); nr = fld($0, "nr=")
        # membership = the carriers, with no activation state
        set = scc; gsub(/:act|:deact/, "", set)
        # state = the a/d flags in the same order
        st = ""; n = split(scc, parts, ",")
        for (i = 1; i <= n; i++) {
            q = index(parts[i], ":")
            f = (q ? substr(parts[i], q + 1) : "?")
            st = st (i > 1 ? "," : "") (f == "act" ? "a" : (f == "deact" ? "d" : f))
        }
        if (ns > 1) {
            changed = 0
            if (pcc != p_pcc) { npcc++; why[nc] = "pcc " p_pcc " -> " pcc; changed = 1 }
            # RRC reconfiguration (SCell added or released, or the SCells PCI
            # re-pointed by A6) is the event that matters; MAC activation is the
            # power-saving toggle and is counted separately.
            if (set != p_set) {
                nsccset++
                if (!changed) why[nc] = "scc-set " (p_set == "" ? "-" : p_set) " -> " (set == "" ? "-" : set)
                changed = 1
            } else if (st != p_st) {
                nsccstate++
                if (!changed) why[nc] = "scc-state " p_st " -> " st
                changed = 1
            }
            if (endc != p_endc) { nendc++; if (!changed) why[nc] = "endc " p_endc " -> " endc; changed = 1 }
            if (nr != p_nr) { nnr++; if (!changed) why[nc] = "nr " p_nr " -> " nr; changed = 1 }
            if (changed) { sc[nc] = t; nc++ }
        }
        p_pcc = pcc; p_set = set; p_st = st; p_endc = endc; p_nr = nr
        state = $0
        next
    }
    if ($0 ~ / CHANGE /) next
}

# value of "<key><value>" on a STATE line, up to the next space
function fld(line, key,   i, s) {
    i = index(line, key)
    if (i == 0) return ""
    s = substr(line, i + length(key))
    sub(/ .*$/, "", s)
    return s
}

END {
    span = (last > first) ? last - first : 0
    printf "== window\n"
    printf "  %s -> %s  (%s)\n", firsts, lasts, dur(span)
    printf "  state samples: %d   heartbeats: %d   changes: %d   errors: %d\n", ns, nbeat, nc, nerr
    if (span > 0 && nc > 0) printf "  mean time between changes: %s\n", dur(int(span / nc))
    if (gapmax > 0) printf "  largest gap between samples: %s (a sampler gap, not a quiet link)\n", dur(gapmax)
    if (summary != "") printf "  %s\n", summary
    for (i = 1; i <= nerr; i++) printf "  %s\n", errs[i]

    printf "\n== changes by type\n"
    printf "  serving cell / band (RRC reselection): %d\n", npcc
    printf "  SCell added or released   (RRC reconfig): %d   <- this is the churn worth chasing\n", nsccset
    printf "  SCell activated/deactivated (MAC CE)   : %d   <- normal: tracks data activity\n", nsccstate
    printf "  EN-DC available: %d    NR anchor: %d\n", nendc, nnr
    if (nsccstate > 0 && nsccset == 0)
        printf "  -> no SCell was added or released: the toggling is MAC-level power saving, not CA flapping\n"

    if (dlog == "") {
        printf "\n== drops\n  no dialer log given or found -- skipping the join\n"
        exit 0
    }

    # Pass 2: the dialer log.
    nd = 0; nu = 0
    while ((getline line < dlog) > 0) {
        tt = ts(line)
        if (tt < 0) continue
        if (line ~ /Datacall Disconnected/) { dt[nd] = tt; dstr[nd] = substr(line, 1, 19); nd++ }
        if (line ~ /dial successful/) { ut[nu] = tt; nu++ }
    }
    close(dlog)

    printf "\n== WAN drops (%s)\n", dlog
    printf "  disconnects: %d   re-dials: %d\n", nd, nu
    if (nd == 0) { printf "  none in this log -- nothing to correlate\n"; exit 0 }

    # recovery time per drop: first re-dial at or after it
    rec = 0; recsum = 0
    for (i = 0; i < nd; i++) {
        best = -1
        for (j = 0; j < nu; j++) if (ut[j] >= dt[i] && (best < 0 || ut[j] < best)) best = ut[j]
        if (best >= 0) { rec++; recsum += best - dt[i]; recv[i] = best - dt[i] } else recv[i] = -1
    }
    if (rec > 0) printf "  mean drop -> re-dial: %s (n=%d)\n", dur(int(recsum / rec)), rec
    printf "\n  direction per drop (window 60 s):\n"
    printf "  %-19s  %-8s  %-22s  %s\n", "drop", "recovery", "change in 60 s BEFORE", "change in 60 s AFTER"
    before = 0; after = 0; neither = 0; outside = 0
    for (i = 0; i < nd; i++) {
        # A drop outside the monitored window has NO data, which is not the same
        # as "no change happened". Reporting the two alike would invent evidence.
        if (dt[i] < first || dt[i] > last) { outside++; printf "  %-19s  %-8s  %-22s  %s\n", dstr[i], (recv[i] >= 0 ? recv[i] "s" : "-"), "no data (outside window)", "no data"; continue }
        b = "no"; a = "no"
        for (k = 0; k < nc + 1; k++) {
            if (sc[k] <= dt[i] && dt[i] - sc[k] <= 60) b = dur(dt[i] - sc[k]) " before"
            if (sc[k] > dt[i] && sc[k] - dt[i] <= 60) a = dur(sc[k] - dt[i]) " after"
        }
        if (b != "no") before++
        if (a != "no") after++
        if (b == "no" && a == "no") neither++
        printf "  %-19s  %-8s  %-22s  %s\n", dstr[i], (recv[i] >= 0 ? recv[i] "s" : "-"), b, a
    }
    inwin = nd - outside
    printf "\n== verdict\n"
    if (outside > 0) printf "  %d of %d drop(s) fall outside the monitored window -- not counted either way\n", outside, nd
    printf "  drops with a radio change in the preceding 60 s: %d/%d\n", before, inwin
    printf "  drops with a radio change in the following 60 s: %d/%d\n", after, inwin
    printf "  drops with neither:                              %d/%d\n", neither, inwin
    if (inwin == 0) {
        printf "  -> no drop landed inside this window: run the sampler across a drop before drawing a conclusion\n"
        exit 0
    }
    if (before > after * 2 && before >= 3) {
        printf "  -> churn LEADS the drops here: radio surgery is worth testing (docs/29 said the opposite on 2026-10-26)\n"
    } else if (after > before * 2 && after >= 3) {
        printf "  -> drops LEAD the churn: matches docs/29 -- fix the recovery path, not the radio\n"
    } else {
        printf "  -> no clear direction at these counts; a longer window is needed\n"
    }
}
' "$tlog"
