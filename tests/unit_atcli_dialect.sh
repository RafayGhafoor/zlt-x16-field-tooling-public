#!/bin/sh
# =============================================================================
# tests/unit_atcli_dialect.sh — what the shim SAYS (transport, cells, bands)
# =============================================================================
# The read/translate half of the shim suite. Paired with
# tests/unit_atcli_policy.sh, which covers what it REFUSES and how it behaves
# under load. Split only so the two halves run in parallel; see lib_atcli.sh.
# =============================================================================
set -u
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib_atcli.sh"

echo "== transport =="
# ===========================================================================
if want transport; then
    out=$(FAKE_BLANK=AT+CSQ run 'AT+CSQ')
    assert_contains "blank modem reply becomes ERROR" "ERROR" "$out"

    out=$(FAKE_FAIL=AT+CSQ run 'AT+CSQ')
    assert_contains "modem ERROR passes through" "ERROR" "$out"

    # atcmd echoes "atcmd_receive:" — it must never reach the caller
    out=$(run 'AT+CGSN')
    assert_not_contains "atcmd_receive echo is stripped" "atcmd_receive" "$out"
    assert_contains "passthrough returns payload" "<imei-redacted>" "$out"

    out=$(run 'AT+CMGS="+923001234567"')
    assert_eq "interactive CMGS is refused (no prompt on this bus)" "ERROR" "$(printf '%s' "$out" | head -1)"

    # exit code must always be 0: qcmd parses OK/ERROR from the text
    run 'AT+CSQ' >/dev/null 2>&1
    assert_eq "shim always exits 0" "0" "$?"
fi

# ===========================================================================
echo "== AT+QENG=servingcell  <-  AT+CPSI? =="
# ===========================================================================
if want qeng; then
    out=$(run 'AT+QENG="servingcell"')

    assert_eq "f1 servingcell"   '"servingcell"' "$(qeng_field "$out" 1)"
    assert_eq "f2 state CONNECT" '"CONNECT"'     "$(qeng_field "$out" 2)"
    assert_eq "f3 RAT LTE"       '"LTE"'         "$(qeng_field "$out" 3)"
    assert_eq "f4 duplex FDD"    '"FDD"'         "$(qeng_field "$out" 4)"
    assert_eq "f5 MCC"           '410'           "$(qeng_field "$out" 5)"
    assert_eq "f6 MNC"           '03'            "$(qeng_field "$out" 6)"
    # 212150373 decimal -> 0xCA52865; >>8 == 0xCA528 == the eNB ID +CNWINFO reports
    assert_eq "f7 cell id as hex" 'CA52865'      "$(qeng_field "$out" 7)"
    assert_eq "f8 PCI"           '256'           "$(qeng_field "$out" 8)"
    assert_eq "f9 EARFCN"        '1312'          "$(qeng_field "$out" 9)"
    assert_eq "f10 band"         '3'             "$(qeng_field "$out" 10)"
    assert_eq "f11 UL bandwidth" '5'             "$(qeng_field "$out" 11)"
    assert_eq "f12 DL bandwidth" '5'             "$(qeng_field "$out" 12)"
    assert_eq "f13 TAC as hex"   '29DD'          "$(qeng_field "$out" 13)"
    # scaling and field ORDER. CPSI fields 11-14 are RSRQ, RSRP, RSSI, SINR --
    # all three of the first are tenths of a dB, SINR is whole. Verified against
    # the vendor's devinfo dump at the same instant on 2026-10-26; the previous
    # shim read f11 as RSSI and f13 as RSRQ/100, which reported an RSSI of
    # -120 dBm and an RSRQ of -6 where the modem was at -58 and -12.
    assert_eq "f14 RSRP = f12/10 truncating (-947 -> -94)" '-94' "$(qeng_field "$out" 14)"
    assert_eq "f15 RSRQ = f11/10 (-80 -> -8)"             '-8'  "$(qeng_field "$out" 15)"
    assert_eq "f16 RSSI = f13/10 (-668 -> -66)"           '-66' "$(qeng_field "$out" 16)"
    assert_eq "f17 SINR passthrough (whole dB)"           '15'  "$(qeng_field "$out" 17)"

    # A real captured triplet, to pin the order itself: this exact CPSI line
    # was read in the same second as vendor RSRP -88 / RSRQ -11 / RSSI -58.
    out=$(FAKE_CPSI='+CPSI: LTE,Online,410-01,0xD857,48466199,104,EUTRAN-BAND1,250,3,3,-120,-884,-600,0' run 'AT+QENG="servingcell"')
    assert_eq "live capture RSRP" '-88' "$(qeng_field "$out" 14)"
    assert_eq "live capture RSRQ" '-12' "$(qeng_field "$out" 15)"
    assert_eq "live capture RSSI" '-60' "$(qeng_field "$out" 16)"
    assert_eq "live capture SINR" '0'   "$(qeng_field "$out" 17)"
    assert_eq "trailing OK present" "1" "$(printf '%s' "$out" | grep -c '^OK')"

    # state mapping
    out=$(FAKE_CPSI='+CPSI: LTE,Search,410-03,0x1,1,2,EUTRAN-BAND1,100,5,5,-90,-900,-600,3' run 'AT+QENG="servingcell"')
    assert_eq "stat Search -> SEARCH" '"SEARCH"' "$(qeng_field "$out" 2)"

    out=$(FAKE_CPSI='+CPSI: LTE,Limited service,410-03,0x1,1,2,EUTRAN-BAND1,100,5,5,-90,-900,-600,3' run 'AT+QENG="servingcell"')
    assert_eq "stat Limited -> LIMSRV" '"LIMSRV"' "$(qeng_field "$out" 2)"

    # TDD band
    out=$(FAKE_CPSI='+CPSI: LTE,Online,460-00,0x1,1,2,EUTRAN-BAND41,40000,20,20,-80,-880,-500,20' run 'AT+QENG="servingcell"')
    assert_eq "TDD band 41 -> TDD" '"TDD"' "$(qeng_field "$out" 4)"
    assert_eq "TDD band number"    '41'    "$(qeng_field "$out" 10)"

    # no LTE service at all
    out=$(FAKE_CPSI=EMPTY run 'AT+QENG="servingcell"')
    assert_contains "no LTE -> SEARCH sentinel" '+QENG: "servingcell","SEARCH"' "$out"

    # -----------------------------------------------------------------------
    # EN-DC / NR5G-NSA. SIMCom returns the 5G leg as a SECOND +CPSI record on
    # the same answer; the shim must synthesise Quectel's three-line shape or
    # parse_at.sh's EN-DC branch never fires and the UI reports LTE while the
    # box is on NR. Fixture is a verbatim live capture (2026-10-26).
    # -----------------------------------------------------------------------
    ENDC='+CPSI: LTE,Online,410-01,0xD857,48466199,104,EUTRAN-BAND1,250,3,3,-133,-898,-579,-9
+CPSI: NR5G_NSA,47,NR5G_BAND41,509070,-770,-110,21,1,9'
    out=$(FAKE_CPSI="$ENDC" run 'AT+QENG="servingcell"')

    assert_eq "EN-DC emits three QENG lines" '3' "$(qeng_lines "$out")"

    # line 1: servingcell + state only
    assert_eq "EN-DC L1 f1 servingcell" '"servingcell"' "$(qeng_line_field "$out" 1 1)"
    assert_eq "EN-DC L1 f2 state"       '"CONNECT"'     "$(qeng_line_field "$out" 1 2)"

    # line 2: the LTE anchor, WITHOUT the servingcell prefix - the parser
    # selects it with \"LTE\" present AND \"servingcell\" absent
    assert_eq "EN-DC L2 f1 LTE" '"LTE"' "$(qeng_line_field "$out" 2 1)"
    assert_eq "EN-DC L2 f2 FDD" '"FDD"' "$(qeng_line_field "$out" 2 2)"
    # L2 layout: f1 LTE, f2 duplex, f3 mcc, f4 mnc, f5 cellid(hex), f6 pci,
    # f7 earfcn, f8 band, f9 ul_bw, f10 dl_bw, f11 tac(hex), f12 rsrp, ...
    assert_eq "EN-DC L2 anchor band B1" '1'     "$(qeng_line_field "$out" 2 8)"
    assert_eq "EN-DC L2 anchor PCI"     '104'   "$(qeng_line_field "$out" 2 6)"
    assert_eq "EN-DC L2 anchor EARFCN"  '250'   "$(qeng_line_field "$out" 2 7)"
    assert_not_contains "EN-DC L2 has no servingcell tag" 'servingcell' "$(printf '%s\n' "$out" | grep '^+QENG:' | sed -n 2p)"

    # line 3: the NR leg - MCC MNC PCID RSRP SINR RSRQ ARFCN band
    assert_eq "EN-DC L3 f1 NR5G-NSA" '"NR5G-NSA"' "$(qeng_line_field "$out" 3 1)"
    assert_eq "EN-DC L3 NCC"        '410'   "$(qeng_line_field "$out" 3 2)"
    assert_eq "EN-DC L3 NCI"        '01'    "$(qeng_line_field "$out" 3 3)"
    assert_eq "EN-DC L3 NR PCI"     '47'    "$(qeng_line_field "$out" 3 4)"
    # -770 tenths -> -77 dBm, truncated
    assert_eq "EN-DC L3 NR RSRP"    '-77'   "$(qeng_line_field "$out" 3 5)"
    # 21 is WHOLE dB on this unit (matches +CSINR) - dividing by 10 gives 2
    assert_eq "EN-DC L3 NR SINR whole dB" '21' "$(qeng_line_field "$out" 3 6)"
    # -110 tenths -> -11 dB, rounded
    assert_eq "EN-DC L3 NR RSRQ"    '-11'   "$(qeng_line_field "$out" 3 7)"
    assert_eq "EN-DC L3 NR ARFCN"   '509070' "$(qeng_line_field "$out" 3 8)"
    assert_eq "EN-DC L3 NR band n41" '41'   "$(qeng_line_field "$out" 3 9)"
    assert_eq "EN-DC trailing OK"   '1'     "$(printf '%s' "$out" | grep -c '^OK')"

    # LTE-only must stay byte-identical: its branch indexes by position WITH
    # the servingcell prefix, so emitting the EN-DC shape there breaks it.
    out=$(FAKE_CPSI='+CPSI: LTE,Online,410-03,0x29DD,212150373,256,EUTRAN-BAND3,1312,5,5,-80,-947,-668,15' run 'AT+QENG="servingcell"')
    assert_eq "LTE-only still one QENG line" '1' "$(qeng_lines "$out")"
    assert_eq "LTE-only keeps servingcell prefix" '"servingcell"' "$(qeng_field "$out" 1)"
fi

# ===========================================================================
echo "== AT+QNWPREFCFG: capability vs policy must not be conflated =="
# ===========================================================================
if want qnwprefcfg; then
    # The band picker's catalogue comes from ue_capability_band; the "enabled"
    # checkboxes come from policy_band. Emitting the policy under the same
    # lte_band/nsa_nr5g_band/nr5g_band keys in BOTH answers made the picker offer
    # only the already-enabled bands (LTE 1:3:5:41 instead of the modem's 19).
    out=$(run 'AT+QNWPREFCFG="ue_capability_band"')
    cap=$(printf '%s\n' "$out" | grep '"lte_band"' | head -1)
    assert_contains "capability carries the full LTE set" '1:3:5:7:8:<mac-redacted>:<mac-redacted>:46:48' "$cap"
    assert_contains "capability line still present" 'ue_capability_band' "$out"
    nsacap=$(printf '%s\n' "$out" | grep '"nsa_nr5g_band"' | head -1)
    assert_contains "capability carries the full NSA NR set" '77:78:79' "$nsacap"
    # nr5g_band must not be read out of the nsa_nr5g_band/nrdc_nr5g_band lines
    sacap=$(printf '%s\n' "$out" | grep '"nr5g_band"' | grep -v nsa_ | grep -v nrdc_ | head -1)
    assert_contains "capability carries the SA NR set" '77:78:79' "$sacap"

    out=$(run 'AT+QNWPREFCFG="policy_band"')
    pol=$(printf '%s\n' "$out" | grep '"lte_band"' | head -1)
    assert_contains "policy still carries the ENABLED set" '1:3:5:41' "$pol"
    assert_not_contains "policy is not the capability list" '18:19:20' "$pol"
fi

# ===========================================================================
echo "== AT+QCAINFO  <-  AT+CCAINFO? =="
# ===========================================================================
if want ca; then
    out=$(run 'AT+QCAINFO')
    pcc=$(printf '%s\n' "$out" | grep '"PCC"')
    scc1=$(printf '%s\n' "$out" | grep '"SCC"' | sed -n '1p')
    scc2=$(printf '%s\n' "$out" | grep '"SCC"' | sed -n '2p')

    # parser reads: f1 label f2 earfcn f3 bw-code f4 "LTE BAND n" f6 PCI
    #               f7 RSRP f8 RSRQ f9 RSSI
    assert_eq "PCC earfcn"   '1312' "$(printf '%s' "$pcc" | awk -F',' '{print $2}')"
    assert_eq "PCC bandwidth code" '100' "$(printf '%s' "$pcc" | awk -F',' '{print $3}')"
    assert_contains "PCC band text" 'LTE BAND 3' "$pcc"
    assert_eq "PCC PCI"  '256'  "$(printf '%s' "$pcc" | awk -F',' '{print $6}')"
    assert_eq "PCC RSRP" '-94'  "$(printf '%s' "$pcc" | awk -F',' '{print $7}')"
    assert_eq "PCC RSRQ" '-8'   "$(printf '%s' "$pcc" | awk -F',' '{print $8}')"
    assert_eq "PCC RSSI" '-66'  "$(printf '%s' "$pcc" | awk -F',' '{print $9}')"
    # Field 9 of +CCAINFO is SINR in 0.1 dB (measured 2026-10-26 against a
    # simultaneous +CSINR). The shim used to hardcode '-' here, so LTE SINR was
    # null on every cycle and the Spectrum-in-use card never showed one.
    assert_eq "PCC SINR from CCAINFO field 9 (200 -> 20)" '20' \
        "$(printf '%s' "$pcc" | awk -F',' '{print $10}')"

    # Wideband RSSI on this modem is -32..-39 dBm. The old guard rejected
    # anything above -40 and blanked RSRP/RSRQ/RSSI together, which is exactly
    # the "Spectrum in use: every metric not reported" symptom. A healthy row
    # must survive; a row whose RSSI is BELOW its RSRP must still be rejected.
    out=$(FAKE_CCA='+CCAINFO: "PCC",EUTRAN_BAND3,1850,100,227,-73,-14,-39,137' run 'AT+QCAINFO')
    pcc=$(printf '%s\n' "$out" | grep '"PCC"')
    assert_eq "wideband RSSI (-39) is not blanked" '-39' "$(printf '%s' "$pcc" | awk -F',' '{print $9}')"
    assert_eq "  ... and RSRP survives with it"    '-73' "$(printf '%s' "$pcc" | awk -F',' '{print $7}')"
    assert_eq "  ... and SINR is 13, not a dash"   '13'  "$(printf '%s' "$pcc" | awk -F',' '{print $10}')"

    out=$(FAKE_CCA='+CCAINFO: "PCC",EUTRAN_BAND3,1850,100,227,-73,-14,-95,137' run 'AT+QCAINFO')
    pcc=$(printf '%s\n' "$out" | grep '"PCC"')
    assert_eq "RSSI below RSRP is still rejected" '-' "$(printf '%s' "$pcc" | awk -F',' '{print $9}')"

    # SCC rows carry one extra field after PCI — the offset shift that produced
    # a bogus "B1 rsrp -44" before it was handled explicitly.
    assert_eq "SCC band"  'LTE BAND 1' "$(printf '%s' "$scc1" | awk -F',' '{print $4}')"
    assert_eq "SCC PCI"   '502'  "$(printf '%s' "$scc1" | awk -F',' '{print $6}')"
    assert_eq "SCC RSRP"  '-108' "$(printf '%s' "$scc1" | awk -F',' '{print $7}')"
    assert_eq "SCC RSRQ"  '-9'   "$(printf '%s' "$scc1" | awk -F',' '{print $8}')"
    assert_eq "SCC RSSI"  '-82'  "$(printf '%s' "$scc1" | awk -F',' '{print $9}')"
    assert_eq "second SCC band" 'LTE BAND 5' "$(printf '%s' "$scc2" | awk -F',' '{print $4}')"

    # validation: RSRP cannot exceed RSSI; a misaligned row must emit blanks
    out=$(FAKE_CCA='+CCAINFO: "SCC",EUTRAN_BAND1,150,50,502,2,-44,-3,-82,134,2,3,9' run 'AT+QCAINFO')
    assert_eq "implausible metrics are dropped, not plotted" '-,-,-' "$(printf '%s' "$out" | grep '"SCC"' | awk -F',' '{print $7","$8","$9}')"

    # no CA at all
    out=$(FAKE_CCA=EMPTY run 'AT+QCAINFO')
    assert_contains "no CA -> PCC-only sentinel" '+QCAINFO: "PCC"' "$out"

    # enable/disable are no-ops that must still answer OK
    out=$(run 'AT+QCAINFO=1')
    assert_eq "QCAINFO=1 answers OK" "OK" "$(printf '%s' "$out" | grep -m1 OK)"
fi

# ===========================================================================
echo "== identity / misc translations =="
# ===========================================================================
if want identity; then
    out=$(run 'AT+QCCID')
    assert_contains "QCCID answer carries the +QCCID prefix" '+QCCID: 89410037251217291419' "$out"
    assert_not_contains "no raw +ICCID prefix leaks" '+ICCID:' "$out"

    out=$(run 'AT+CVERSION')
    first_body=$(printf '%s\n' "$out" | grep -v '^+CVERSION:' | grep -v '^$' | head -1)
    assert_eq "model line comes first (poller takes first bare line)" 'SIMCOM_SIM8260E' "$first_body"
    assert_contains "Authors line present" 'Authors: SIMCOM INCORPORATED' "$out"
    assert_contains "VERSION line present" 'VERSION: V1.0.01' "$out"

    out=$(run 'AT+QUIMSLOT?')
    assert_contains "single SIM slot" '+QUIMSLOT: 1' "$out"
    out=$(run 'AT+QSIMSTAT?')
    assert_contains "SIM inserted" '+QSIMSTAT: 1,1' "$out"
    out=$(run 'AT+QSIMDET?')
    assert_contains "SIM detect answered" '+QSIMDET: 0,1' "$out"

    # Per-antenna: the modem does expose four chains per RAT, via SIMCom's own
    # AT+CRSRP?/AT+CSINR?. The shim re-emits them in Quectel's shape (values
    # first, RAT token last) so parse_at.sh's positional parser reads them.
    out=$(run 'AT+QRSRP')
    assert_contains "QRSRP LTE line comes from AT+CRSRP?" '+QRSRP: -97,-98,-90,-89,LTE' "$out"
    assert_contains "QRSRP NR5G line is carried too" '+QRSRP: -74,-76,-83,-75,NR5G' "$out"
    assert_eq "QRSRP issues exactly one modem query" "AT+CRSRP?" \
        "$(FAKE_CALL_LOG=/tmp/qmtest-rsrp.$$ QM_CPSI_CACHE=/tmp/qmtest-c.$$ \
           QM_AT_CACHE_DIR=/tmp/qmtest-ac.$$ \
           QM_AT_BLACKLIST=/tmp/qmtest-b.$$ ATC="$FAKE" sh "$SHIM" 'AT+QRSRP' >/dev/null 2>&1; \
           cat /tmp/qmtest-rsrp.$$ 2>/dev/null; rm -rf /tmp/qmtest-rsrp.$$ /tmp/qmtest-ac.$$)"

    out=$(run 'AT+QSINR')
    assert_contains "QSINR LTE line comes from AT+CSINR?" '+QSINR: 8,0,8,8,LTE' "$out"
    assert_contains "QSINR NR5G line is carried too" '+QSINR: 22,20,13,20,NR5G' "$out"

    # RSRQ has no per-chain source on this modem (AT+CRSRQ? answers ERROR), so
    # all four ports are the parser's -32768 "unavailable" sentinel. Repeating
    # the serving-cell aggregate in port 0 is the lie this replaced.
    out=$(run 'AT+QRSRQ')
    assert_contains "QRSRQ reports four unavailable ports" '-32768,-32768,-32768,-32768,LTE' "$out"
    assert_not_contains "QRSRQ does not fake a Main reading" '+QRSRQ: -7,' "$out"

    # A modem that refuses the per-chain query must surface as ERROR, never as
    # four invented values.
    out=$(FAKE_CRSRP=EMPTY run 'AT+QRSRP')
    assert_eq "QRSRP without per-chain support answers ERROR" "ERROR" "$(printf '%s' "$out" | head -1)"

    out=$(run 'AT+QNWCFG="lte_mimo_layers"')
    assert_eq "QNWCFG unsupported -> OK" "OK" "$(printf '%s' "$out" | grep -m1 OK)"
fi

# ===========================================================================
echo "== AT+QTEMP (thermal fallback) =="
# ===========================================================================
if want qtemp; then
    T=$(mktemp -d)
    mkdir -p "$T/thermal_zone0" "$T/thermal_zone1" "$T/thermal_zone2"
    printf 'modem-lte-sub6\n' > "$T/thermal_zone0/type"; printf '38500\n' > "$T/thermal_zone0/temp"
    printf 'cpuss-0-usr\n'    > "$T/thermal_zone1/type"; printf '99999\n' > "$T/thermal_zone1/temp"
    printf 'modem-ambient\n'  > "$T/thermal_zone2/type"; printf '0\n'     > "$T/thermal_zone2/temp"
    out=$(QM_THERMAL_DIR="$T" run 'AT+QTEMP')
    assert_contains "QTEMP falls back to the modem thermal zone" '+QTEMP: "modem-0",39' "$out"
    assert_not_contains "non-modem zones are ignored" '100' "$out"
    rm -rf "$T"

    # a firmware that does answer AT+QTEMP must be passed through untouched
    out=$(FAKE_QTEMP_OK=1 run 'AT+QTEMP')
    assert_contains "modem QTEMP passthrough (ERROR path not taken)" 'ERROR' "$out"
fi

# ===========================================================================
echo "== AT+CGCONTRDP (WAN context selection) =="
# ===========================================================================
if want apn; then
    out=$(QM_WAN_IP=10.220.84.156 run 'AT+CGCONTRDP')
    assert_contains "active WAN context is selected" 'Ufone.internet' "$out"
    assert_not_contains "dormant profile is filtered out" 'SWISSCOM' "$out"

    # no matching address -> every row passes through unchanged
    out=$(QM_WAN_IP=10.9.9.9 run 'AT+CGCONTRDP')
    assert_contains "unmatched WAN keeps all rows (fallback)" 'SWISSCOM' "$out"

    # no route yet -> fallback, never an empty answer
    out=$(QM_WAN_IP= run 'AT+CGCONTRDP')
    assert_contains "no WAN address still answers rows" '+CGCONTRDP:' "$out"
fi

# ===========================================================================
echo "== AT+QNWPREFCFG reads/writes =="
# ===========================================================================
if want bands; then
    out=$(run 'AT+QNWPREFCFG="policy_band"')
    # The fixture now carries the live ZLT X16 policy capture (1:3:5:41); the
    # previous 1:3:5:8 was an invented value from the original GreenPacket box.
    assert_contains "lte_band key"      '+QNWPREFCFG: "lte_band",1:3:5:41' "$out"
    assert_contains "nsa_nr5g_band key" '+QNWPREFCFG: "nsa_nr5g_band",1:8:40:41:78' "$out"
    assert_contains "nr5g_band key"     '+QNWPREFCFG: "nr5g_band",1:8:40:41:78' "$out"

    out=$(run 'AT+QNWPREFCFG="mode_pref"')
    assert_contains "mode_pref AUTO from CNMP=2" '"mode_pref",AUTO' "$out"

    out=$(run 'AT+QNWPREFCFG="nr5g_disable_mode"')
    assert_contains "nr5g_disable_mode" '"nr5g_disable_mode",0' "$out"

    out=$(run 'AT+QNWPREFCFG="roam_pref"')
    assert_contains "roam_pref" '"roam_pref",1' "$out"

    # bands/current.sh greps the three band keys out of ue_capability_band
    out=$(run 'AT+QNWPREFCFG="ue_capability_band"')
    assert_contains "capability line" '+QNWPREFCFG: "ue_capability_band"' "$out"
    assert_contains "capability also carries lte_band"      '"lte_band",' "$out"
    assert_contains "capability also carries nsa_nr5g_band" '"nsa_nr5g_band",' "$out"
    assert_contains "capability also carries nr5g_band"     '"nr5g_band",' "$out"

    # cellular/network_priority.sh reads this key and errors out without it
    out=$(run 'AT+QNWPREFCFG="rat_acq_order"')
    assert_contains "rat_acq_order answered" '"rat_acq_order",LTE:NR5G:WCDMA' "$out"
    out=$(run 'AT+QNWPREFCFG="rat_acq_order",LTE')
    assert_eq "rat_acq_order write is accepted" "OK" "$(printf '%s' "$out" | tr -d '\r' | grep -m1 -E 'OK|ERROR')"

    # an unmodelled key must still answer so the panel renders "unknown"
    out=$(run 'AT+QNWPREFCFG="some_future_key"')
    assert_contains "unknown read key answered, page cannot fail" '"some_future_key",' "$out"

    # writes: mode_pref maps to CNMP; the band keys map to AT+CSYSSEL.
    out=$(run 'AT+QNWPREFCFG="mode_pref",LTE')
    assert_eq "mode_pref write maps to CNMP" "OK" "$(printf '%s' "$out" | tr -d '\r' | grep -m1 OK)"

    # Regression (2026-10-27): a QNWPREFCFG write answered "OK" and then a
    # second, phantom "ERROR". set_qnwprefcfg stored this command's remainder in
    # `_rest`, which is the compound-chain loop's GLOBAL, so the loop ran one
    # extra iteration over the leftover text, matched nothing, and fell through
    # to at_raw. qcmd classifies *any* *ERROR* as command_failed -- so every
    # band/mode write was reported to the UI as a failure while the modem had
    # already applied it.
    #
    # The `grep -m1 OK` above cannot catch that: it looks for the OK and never
    # notices what follows. These assert on the whole output instead.
    out=$(run 'AT+QNWPREFCFG="mode_pref",LTE')
    assert_eq "mode_pref write emits no phantom ERROR" "0" \
      "$(printf '%s' "$out" | grep -c ERROR || true)"
    out=$(run 'AT+QNWPREFCFG="lte_band",3')
    assert_eq "band write emits no phantom ERROR" "0" \
      "$(printf '%s' "$out" | grep -c ERROR || true)"
    out=$(run 'AT+QNWPREFCFG="rat_acq_order",LTE')
    assert_eq "rat_acq_order write emits no phantom ERROR" "0" \
      "$(printf '%s' "$out" | grep -c ERROR || true)"

    # THE BAND LOCK. The cell-locking page's Apply button called
    # AT+QNWPREFCFG="lte_band",<list>, which used to land in the `*) ERROR`
    # arm of set_qnwprefcfg -- so every band lock failed with "Failed to send
    # band lock command" while the same page read the current bands fine.
    for _k in lte_band nsa_nr5g_band nr5g_band; do
        out=$(run "AT+QNWPREFCFG=\"$_k\",1:3")
        assert_eq "$_k band write accepted" "OK" \
            "$(printf '%s' "$out" | tr -d '\r' | grep -m1 -E 'OK|ERROR')"
        assert_contains "$_k write reaches the modem as CSYSSEL" \
            "AT+CSYSSEL=\"$_k\",1:3" "$out"
    done

    # A bitmask is a DIFFERENT set on each side; it must not be reinterpreted.
    out=$(run 'AT+QNWPREFCFG="lte_band",0x1a8000a')
    assert_eq "bitmask band value refused (encoding differs)" "ERROR" \
        "$(printf '%s' "$out" | tr -d '\r' | grep -m1 -E 'OK|ERROR')"
    out=$(run 'AT+QNWPREFCFG="lte_band",')
    assert_eq "empty band list refused" "ERROR" \
        "$(printf '%s' "$out" | tr -d '\r' | grep -m1 -E 'OK|ERROR')"
    out=$(run 'AT+QNWPREFCFG="lte_band",1::3')
    assert_eq "empty band element refused" "ERROR" \
        "$(printf '%s' "$out" | tr -d '\r' | grep -m1 -E 'OK|ERROR')"
    # band 99 is not in this modem's capability answer: OK-then-no-service is
    # the failure mode being prevented, so it must be an error up front.
    out=$(run 'AT+QNWPREFCFG="lte_band",3:99')
    assert_eq "unsupported band refused" "ERROR" \
        "$(printf '%s' "$out" | tr -d '\r' | grep -m1 -E 'OK|ERROR')"
    assert_contains "refusal names the band" "band 99" "$out"

    # The answers are not settings.
    out=$(run 'AT+QNWPREFCFG="ue_capability_band",1:3')
    assert_eq "writing a read-only key refused" "ERROR" \
        "$(printf '%s' "$out" | tr -d '\r' | grep -m1 -E 'OK|ERROR')"

    # Single-key read: must answer the real list, never an empty value (an empty
    # list renders as "no bands selected" in the picker).
    out=$(run 'AT+QNWPREFCFG="lte_band"')
    assert_contains "single-key read answers the list" '+QNWPREFCFG: "lte_band",1:3:5:41' "$out"
fi

# ===========================================================================
echo
if [ "$FAIL" -eq 0 ]; then
    printf 'PASS  %d assertions\n' "$PASS"
    exit 0
fi
printf 'FAIL  %d passed, %d failed%s\n' "$PASS" "$FAIL" "$FAILED_NAMES"
exit 1
