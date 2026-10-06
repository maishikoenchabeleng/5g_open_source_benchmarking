#!/bin/bash
# =============================================================================
# 5G TESTBED - REAL PHONE BENCHMARK (monolithic gNB on the USRP B210)
# =============================================================================
# Benchmarks a real COTS phone (OnePlus, SIM IMSI 001020000049862, PLMN 001/02)
# through a monolithic gNB on the B210, with Open5GS or free5gc as the core.
#
# RAN Machine  : administrator@137.158.126.24   (gNB + B210)
# Core Machine : bluelabuser@137.158.126.21
#   open5gs : amf.yaml with 001/01 + 001/02
#   free5gc : AMF_CFG=amfcfg_phone.yaml ./run.sh (001/02 listed first - free5gc
#             uses its first PLMN for auth, SM data and SM policy)
#
# gNBs (both broadcast 001/02):
#   ocudu : gnb -c ~/ocudu/configs/my_gnb_rf_b200_78.yml   (20 MHz, 3450 MHz)
#   oai   : nr-softmodem -O .../my.gnb.sa.band78.usrpb210_phone.conf -E
#           (40 MHz, SSB 3619.2 MHz)
#
# Run with sudo:
#   sudo ./5g_phone_mono.sh                 # all 4 combinations, ROUNDS times (round-robin)
#   sudo ./5g_phone_mono.sh free5gc ocudu   # one combination, ROUNDS times
#                                           # (core: open5gs|free5gc, ran: ocudu|oai)
#
# On the phone: preferred network type NR only (5G switch); once per session
# in Termux:  termux-wake-lock ; iperf3 -s
#
# The phone attaches by itself when the gNB comes up. The script checks the
# core's SMF log every 5s for the phone's IP (max WAIT_UE_CONNECT s), then asks
# you to toggle airplane mode while it keeps checking (s + Enter = skip).
#
# Tests run from the core machine to the phone's IP (the phone has no tunnel on
# the RAN machine): ping, UDP jitter (downlink), TCP downlink and uplink.
# Radio metrics (CQI, MCS, BLER, SNR, RSRP) are logged every second during the
# tests: OCUDU's stdout metrics table (autostart_stdout_metrics in the yml),
# OAI's nrMAC_stats.log / nrRRC_stats.log.
# =============================================================================

# =============================================================================
# CONFIGURATION
# =============================================================================
RAN_USER="administrator"
RAN_IP="137.158.126.24"
CORE_USER="bluelabuser"
CORE_IP="137.158.126.21"

HOME_DIR="/home/administrator"
CORE_HOME="/home/bluelabuser"

# The phone's SIM
PHONE_IMSI="001020000049862"

# gNB configs
OCUDU_CONF="${HOME_DIR}/ocudu/configs/my_gnb_rf_b200_78.yml"
OCUDU_LOG_LEVEL="warning"      # yml stays at info for manual runs
OAI_BUILD_DIR="${HOME_DIR}/openairinterface5g/cmake_targets/ran_build/build"
OAI_CONF="${HOME_DIR}/openairinterface5g/targets/PROJECTS/GENERIC-NR-5GC/CONF/my.gnb.sa.band78.usrpb210_phone.conf"

# free5gc AMF config for the phone (see header)
FREE5GC_DIR="${CORE_HOME}/free5gc"
FREE5GC_AMF_CFG="amfcfg_phone.yaml"

# Test parameters
PING_COUNT=100
IPERF_DURATION=30
IPERF_SERVER_PORT=5201         # iperf3 -s in Termux listens here

# Number of rounds (each round = every gNB once)
ROUNDS=3

# Fixed-load test: UDP at FIXED_RATE_MBPS in BOTH directions at the same time,
# CPU/RAM/power measured only during it (same job for every combination)
FIXED_RATE_MBPS=5
FIXED_DURATION=60
FL_CLIENT_SIDE="core"      # iperf3 client end: ue (simulated UE) or core (phone is the server)

# Timing (seconds)
WAIT_CORE_START=15
WAIT_GNB_START=20              # B210 init + NG Setup
WAIT_UE_CONNECT=90             # phone attach (checked every UE_POLL_INTERVAL)
WAIT_UE_EXTRA=60               # reminder interval while the airplane-mode prompt waits
UE_POLL_INTERVAL=5

# Output directory
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BASE_DIR="/home/administrator/5g_phone_mono_${TIMESTAMP}"

# RAPL power measurement
RAPL_PATH="/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"
}

log_ok() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] ✔ $1${NC}"
}

log_err() {
    echo -e "${RED}[$(date '+%H:%M:%S')] ✘ $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $1${NC}"
}

ssh_core() {
    ssh -n ${CORE_USER}@${CORE_IP} "$1"
}

# Same, with the remote command's stdin taken from this script
ssh_core_stdin() {
    ssh ${CORE_USER}@${CORE_IP} "$1"
}

# Read RAPL energy in microjoules
read_rapl_ran() {
    cat ${RAPL_PATH} 2>/dev/null || echo "0"
}

read_rapl_core() {
    ssh_core "sudo cat ${RAPL_PATH} 2>/dev/null || echo 0"
}

# RAPL max counter value (the energy counter wraps back to 0 after this)
RAPL_MAX_PATH="/sys/class/powercap/intel-rapl/intel-rapl:0/max_energy_range_uj"
read_rapl_max_ran() {
    cat ${RAPL_MAX_PATH} 2>/dev/null || echo 0
}

read_rapl_max_core() {
    ssh_core "sudo cat ${RAPL_MAX_PATH} 2>/dev/null || echo 0"
}

# Energy used between two RAPL readings (uJ), handling one counter wrap.
# Prints nothing if a reading is missing (0), so the result shows as N/A.
rapl_delta() {
    local start=$1 end=$2 max=$3
    [ "${start:-0}" -gt 0 ] 2>/dev/null && [ "${end:-0}" -gt 0 ] 2>/dev/null || return
    if [ "$end" -ge "$start" ]; then
        echo $(( end - start ))
    elif [ "${max:-0}" -gt 0 ] 2>/dev/null; then
        echo $(( max - start + end ))
    fi
}

# Process name used for CPU/RAM lookups
gnb_proc() {
    case $1 in
        oai)   echo "nr-softmodem" ;;
        ocudu) echo "gnb" ;;
    esac
}

ran_label() {
    case $1 in
        oai)   echo "OAI (B210)" ;;
        ocudu) echo "OCUDU (B210)" ;;
    esac
}

# Stop the gNBs cleanly (SIGINT first, so OCUDU writes /tmp/gnb.log)
stop_ran_processes() {
    log "Stopping RAN processes..."
    # Match exact process names only (-x), so unrelated processes whose
    # command line merely contains "gnb" (editors, logs...) are left alone.
    local procs="nr-softmodem nr-uesoftmodem srsue gnb nr-gnb nr-ue odu"
    local p
    for p in $procs; do sudo pkill -INT -x "$p" 2>/dev/null; done
    sleep 3
    for p in $procs; do sudo pkill -9 -x "$p" 2>/dev/null; done
    sleep 2
}

# Stop core network
stop_core() {
    local core=$1
    log "Stopping core ($core)..."
    case $core in
        open5gs)
            ssh_core "sudo systemctl stop open5gs-*" 2>/dev/null
            ;;
        free5gc)
            ssh_core "sudo pkill -9 -f '[f]ree5gc' 2>/dev/null; sudo ip link delete upfgtp 2>/dev/null; echo stopped" > /dev/null
            ;;
    esac
    sleep 5
}

# =============================================================================
# CORE / gNB START
# =============================================================================

start_open5gs() {
    log "Starting Open5GS on core machine..."
    ssh_core "sudo systemctl start open5gs-nrfd open5gs-scpd open5gs-amfd \
        open5gs-smfd open5gs-upfd open5gs-ausfd open5gs-udmd open5gs-udrd \
        open5gs-pcfd open5gs-nssfd open5gs-bsfd open5gs-seppd 2>/dev/null"

    sleep ${WAIT_CORE_START}

    # Verify: count exact "active" lines ("inactive" also contains "active")
    local n_active=$(ssh_core "sudo systemctl is-active open5gs-amfd open5gs-smfd open5gs-upfd" | grep -c "^active$")
    if [ "$n_active" -eq 3 ]; then
        log_ok "Open5GS is running (AMF, SMF, UPF active)"
        return 0
    else
        log_err "Open5GS failed to start (${n_active}/3 of AMF/SMF/UPF active)"
        return 1
    fi
}

start_free5gc() {
    local log_dir=$1
    log "Starting Free5GC on core machine (AMF config ${FREE5GC_AMF_CFG})..."
    # A leftover upfgtp makes the UPF exit ("open Gtp5g: open link: create: file exists")
    ssh_core "sudo pkill -9 -f '[f]ree5gc' 2>/dev/null; sudo ip link delete upfgtp 2>/dev/null; true"
    ssh_core "cd ${FREE5GC_DIR}; AMF_CFG=${FREE5GC_AMF_CFG} nohup ./run.sh > /tmp/free5gc.log 2>&1 < /dev/null &"

    # Poll AMF's N2 SCTP listener (ss -t misses SCTP sockets, so no -t here)
    local elapsed=0
    while [ $elapsed -lt ${WAIT_CORE_START} ]; do
        if ssh_core "ss -lnp 2>/dev/null | grep -q ':38412'; echo \$?" | grep -q "^0$"; then
            log_ok "Free5GC AMF is listening on SCTP 38412 (${elapsed}s)"
            # The AMF must run with the phone config, or the phone fails authentication
            if ! ssh_core "pgrep -af '[b]in/amf' | grep -q '${FREE5GC_AMF_CFG}' && echo ok" | grep -q "^ok$"; then
                log_err "Free5GC AMF is not using ${FREE5GC_AMF_CFG} (does run.sh support AMF_CFG?)"
                return 1
            fi
            # The UPF can exit on its own while the other NFs keep running
            sleep 5
            if ! ssh_core "pgrep -f '[b]in/upf' > /dev/null && echo up" | grep -q "^up$"; then
                ssh_core "cat /tmp/free5gc.log" > "${log_dir}/free5gc.log" 2>&1
                log_err "Free5GC UPF is not running (see free5gc.log)"
                return 1
            fi
            log_ok "Free5GC UPF is running"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    ssh_core "cat /tmp/free5gc.log" > "${log_dir}/free5gc.log" 2>&1
    log_err "Free5GC AMF did not come up within ${WAIT_CORE_START}s"
    return 1
}

start_gnb_ocudu() {
    local log_dir=$1
    log "Starting OCUDU gNB on the B210 (log level ${OCUDU_LOG_LEVEL})..."
    cd "$(dirname "$OCUDU_CONF")"
    # Line-buffered, so the per-second metrics table reaches gnb.log right away
    stdbuf -oL gnb -c "$OCUDU_CONF" log --all_level ${OCUDU_LOG_LEVEL} \
        > "${log_dir}/gnb.log" 2>&1 &
    GNB_PID=$!
    sleep ${WAIT_GNB_START}

    if ps -p $GNB_PID > /dev/null 2>&1; then
        log_ok "OCUDU gNB started (PID: $GNB_PID)"
        return 0
    else
        log_err "OCUDU gNB failed to start"
        return 1
    fi
}

start_gnb_oai() {
    local log_dir=$1
    log "Starting OAI gNB on the B210..."
    # nrMAC_stats.log / nrRRC_stats.log are written to the working directory
    cd "$OAI_BUILD_DIR"
    rm -f nrMAC_stats.log nrRRC_stats.log nrL1_stats.log
    ./nr-softmodem -O "$OAI_CONF" -E \
        > "${log_dir}/gnb.log" 2>&1 &
    GNB_PID=$!
    sleep ${WAIT_GNB_START}

    if ps -p $GNB_PID > /dev/null 2>&1; then
        log_ok "OAI gNB started (PID: $GNB_PID)"
        return 0
    else
        log_err "OAI gNB failed to start"
        return 1
    fi
}

# Cell settings for the report
cell_info() {
    local ran=$1
    local raw_dir=$2
    case $ran in
        ocudu)
            # e.g. "Cell pci=0, bw=20 MHz, 1T1R, dl_arfcn=630000 (n78), dl_freq=3450 MHz, ..."
            grep -m1 "^Cell pci=" "${raw_dir}/gnb.log" 2>/dev/null || echo "N/A"
            ;;
        oai)
            awk -F'[=;]' '
                /absoluteFrequencySSB/      { gsub(/ /, "", $2); ssb = $2 }
                /dl_carrierBandwidth/       { gsub(/ /, "", $2); prb = $2 }
                END {
                    split("51:20 106:40 133:50 162:60 217:80 273:100", m, " ")
                    for (i in m) { split(m[i], kv, ":"); if (kv[1] == prb) bw = kv[2] }
                    printf "SSB ARFCN %s, %s PRB (%s MHz at 30 kHz SCS)\n", ssb, prb, (bw ? bw : "?")
                }' "$OAI_CONF"
            ;;
    esac
}

# =============================================================================
# PHONE ATTACH
# =============================================================================

# The phone's current IP from the SMF log of this run. Empty if it has no
# session right now (a later release of that IP clears it).
#   Open5GS : "UE SUPI[imsi-..] DNN[..] IPv4[x]"  /  "Removed Session: UE IMSI:[imsi-..] .. IPv4:[x]"
#   free5gc : "[supi:imsi-..] Allocated PDUAdress[x]"  /  "UE[imsi-..] PDUSessionID[n] Release IP[x]"
get_phone_ip() {
    local src
    case $CORE in
        open5gs) src="sudo journalctl -u open5gs-smfd --since '${COMBO_START}' --no-pager -o cat 2>/dev/null" ;;
        free5gc) src="sed 's/\x1b\[[0-9;]*m//g' /tmp/free5gc.log 2>/dev/null" ;;
    esac
    ssh_core "$src" \
        | awk -v imsi="imsi-${PHONE_IMSI}" '
            index($0, "UE SUPI[" imsi "]") && match($0, /IPv4\[[0-9.]+\]/) {
                ip = substr($0, RSTART + 5, RLENGTH - 6)
            }
            index($0, imsi) && match($0, /Allocated PDUAdress\[[0-9.]+\]/) {
                ip = substr($0, RSTART + 20, RLENGTH - 21)
            }
            /Removed Session/ && index($0, imsi) && ip != "" && index($0, "IPv4:[" ip "]") { ip = "" }
            /Release IP\[/ && index($0, imsi) && ip != "" && index($0, "Release IP[" ip "]") { ip = "" }
            END { print ip }'
}

# Check every UE_POLL_INTERVAL s for up to $1 s. Sets UE_IP on success.
poll_phone_ip() {
    local max_wait=$1
    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        UE_IP=$(get_phone_ip)
        [ -n "$UE_IP" ] && return 0
        sleep ${UE_POLL_INTERVAL}
        elapsed=$(( elapsed + UE_POLL_INTERVAL ))
        ATTACH_WAIT=$(( ATTACH_WAIT + UE_POLL_INTERVAL ))
    done
    return 1
}

# Wait for the phone; after WAIT_UE_CONNECT s ask for an airplane-mode toggle.
# The phone is still checked every UE_POLL_INTERVAL s while the prompt is
# shown, so the run continues by itself as soon as it attaches.
# Returns 1 if the user skips the run (s + Enter).
wait_for_phone() {
    ATTACH_WAIT=0
    poll_phone_ip ${WAIT_UE_CONNECT} && return 0
    log_warn "Phone has not attached after ${ATTACH_WAIT}s."
    log_warn "Toggle airplane mode on the phone. The script keeps checking and continues"
    log_warn "by itself as soon as the phone attaches.   (s + Enter = skip this round)"
    local ans rc since=0
    while :; do
        ans=""
        read -r -t ${UE_POLL_INTERVAL} ans < /dev/tty 2>/dev/null
        rc=$?
        if [ $rc -eq 0 ]; then
            [ "$ans" = "s" ] && return 1
        elif [ $rc -le 128 ]; then
            # no terminal to read from: just wait
            sleep ${UE_POLL_INTERVAL}
        fi
        UE_IP=$(get_phone_ip)
        [ -n "$UE_IP" ] && return 0
        ATTACH_WAIT=$(( ATTACH_WAIT + UE_POLL_INTERVAL ))
        since=$(( since + UE_POLL_INTERVAL ))
        if [ $since -ge ${WAIT_UE_EXTRA} ]; then
            log_warn "Still waiting for the phone (${ATTACH_WAIT}s)...   (s + Enter = skip this round)"
            since=0
        fi
    done
}

# Before each test: use the newest IP (the phone can re-register and get a new one)
refresh_phone_ip() {
    local ip=$(get_phone_ip)
    if [ -z "$ip" ]; then
        log_warn "Phone has no session right now - keeping ${UE_IP}"
    elif [ "$ip" != "$UE_IP" ]; then
        log_warn "Phone IP changed ${UE_IP} -> ${ip} (re-registered); using the new IP"
        echo "$(date +%T) IP changed ${UE_IP} -> ${ip}" >> "${RAW_DIR}/phone_ip.txt"
        UE_IP=$ip
    fi
}

# =============================================================================
# METRICS COLLECTION
# =============================================================================

collect_cpu_ram() {
    local log_dir=$1
    local gnb_name=$2
    local secs=$3

    # -u and -r share one file: both must append (>>) and write whole lines
    # (--line-buffered), otherwise the -u writer overwrites the -r lines.
    : > "${log_dir}/cpu_ran.txt"
    : > "${log_dir}/cpu_core.txt"

    log "Collecting CPU/RAM on RAN machine..."
    LC_ALL=C pidstat -u -p ALL 1 ${secs} \
        | grep --line-buffered -w "${gnb_name}" \
        >> "${log_dir}/cpu_ran.txt" 2>&1 &
    CPU_RAN_PID=$!

    LC_ALL=C pidstat -r -p ALL 1 ${secs} \
        | grep --line-buffered -w "${gnb_name}" \
        >> "${log_dir}/cpu_ran.txt" 2>&1 &
    CPU_RAN_PID2=$!

    log "Collecting CPU/RAM on core machine..."
    ssh_core "LC_ALL=C pidstat -u -p ALL 1 ${secs} \
        | grep --line-buffered -E 'open5gs|upf|amf|smf'" \
        >> "${log_dir}/cpu_core.txt" 2>&1 &
    CPU_CORE_PID=$!

    ssh_core "LC_ALL=C pidstat -r -p ALL 1 ${secs} \
        | grep --line-buffered -E 'open5gs|upf|amf|smf'" \
        >> "${log_dir}/cpu_core.txt" 2>&1 &
    CPU_CORE_PID2=$!
}

stop_cpu_ram() {
    kill $CPU_RAN_PID $CPU_RAN_PID2 2>/dev/null
    ssh_core "pkill -x pidstat 2>/dev/null; true"
    pkill -x pidstat 2>/dev/null
    wait $CPU_RAN_PID $CPU_RAN_PID2 $CPU_CORE_PID $CPU_CORE_PID2 2>/dev/null
}

# Radio metrics, one row per second during the tests:
#   time,cqi,dl_mcs,dl_bler_pct,ul_mcs,ul_bler_pct,ul_snr_db,dl_rsrp_dbm,dl_sinr_db,ul_rsrp_db
RADIO_HEADER="time,cqi,dl_mcs,dl_bler_pct,ul_mcs,ul_bler_pct,ul_snr_db,dl_rsrp_dbm,dl_sinr_db,ul_rsrp_db"

# OAI: sample nrMAC_stats.log / nrRRC_stats.log (rewritten by the gNB, so a
# copy is taken every second). DL RSRP/SINR are measured by the phone.
# The files can list several UEs (stale out-of-sync contexts from earlier
# attach attempts), so the phone is the UE with the most data-bearer bytes
# (LCID 4); if none has data yet, the last in-sync UE. Its RSRP/SINR in the
# RRC file is found by the same RNTI.
oai_radio_sample() {
    local mac="${OAI_BUILD_DIR}/nrMAC_stats.log"
    local rrc="${OAI_BUILD_DIR}/nrRRC_stats.log"
    [ -s "$mac" ] || return
    awk -v t="$(date +%T)" '
        FILENAME ~ /MAC/ && /^UE RNTI / {
            u = $3; ue[++nu] = u; data[u] = 0
            if (/ in-sync/) insync = u
            for (i = 1; i <= NF; i++) if ($i == "RSRP" && $(i+2) != "(0") rsrp[u] = $(i+1)
            next
        }
        FILENAME ~ /MAC/ && /^UE [0-9a-f]+: / {
            u = $2; sub(/:$/, "", u)
            if (/ CQI /) for (i = 1; i <= NF; i++) if ($i == "CQI") cqi[u] = $(i+1) + 0
            if (/dlsch_rounds/) for (i = 1; i <= NF; i++) { if ($i == "BLER") dbler[u] = $(i+1) * 100; if ($i == "MCS") dmcs[u] = $(i+2) }
            if (/ulsch_rounds/) for (i = 1; i <= NF; i++) { if ($i == "BLER") ubler[u] = $(i+1) * 100; if ($i == "MCS") umcs[u] = $(i+2); if ($i == "SNR") usnr[u] = $(i+1) }
            if (/LCID 4:/) for (i = 1; i <= NF; i++) if ($i == "TX" || $i == "RX") data[u] += $(i+1)
            next
        }
        FILENAME ~ /RRC/ && /RNTI/ {
            for (i = 1; i <= NF; i++) if ($i == "RNTI") r = $(i+1)
        }
        FILENAME ~ /RRC/ && /resultSSB/ && r != "" {
            for (i = 1; i <= NF; i++) { if ($i == "RSRP") rrsrp[r] = $(i+1); if ($i == "SINR") sinr[r] = $(i+1) }
        }
        END {
            if (!nu) exit
            best = insync; max = 0
            for (k = 1; k <= nu; k++) if (data[ue[k]] > max) { max = data[ue[k]]; best = ue[k] }
            if (best == "") best = ue[nu]
            p = (best in rsrp) ? rsrp[best] : rrsrp[best]
            printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,\n", t, cqi[best], dmcs[best], dbler[best],
                umcs[best], ubler[best], usnr[best], p, sinr[best]
        }' "$mac" "$rrc" 2>/dev/null
}

start_radio_log() {
    local ran=$1
    local log_dir=$2
    echo "$RADIO_HEADER" > "${log_dir}/radio_metrics.csv"
    case $ran in
        oai)
            ( while :; do
                oai_radio_sample >> "${log_dir}/radio_metrics.csv"
                cp "${OAI_BUILD_DIR}/nrMAC_stats.log" "${log_dir}/nrMAC_stats_last.log" 2>/dev/null
                cp "${OAI_BUILD_DIR}/nrRRC_stats.log" "${log_dir}/nrRRC_stats_last.log" 2>/dev/null
                sleep 1
              done ) &
            RADIO_PID=$!
            ;;
        ocudu)
            # The table rows go to gnb.log; remember where the tests start
            RADIO_START_LINE=$(wc -l < "${log_dir}/gnb.log")
            ;;
    esac
}

# OCUDU stdout metrics rows (see scheduler_metrics_consumers.cpp):
#  pci rnti | cqi ri mcs brate ok nok (%) dl_bs | pusch rsrp ri mcs brate ok nok (%) bsr ta phr
# pusch = UL SNR, rsrp = UL RSRP measured by the gNB. The per-second ok/nok
# counts are kept per row so the BLER over the window can be computed from them.
ocudu_radio_rows() {
    local gnb_log=$1 from=$2 to=$3
    sed -n "$((from + 1)),${to}p" "$gnb_log" \
        | awk -F'|' '
            $1 ~ /^ *[0-9]+ +[0-9a-f]+ *$/ && NF >= 3 {
                n++
                split($2, d, " "); split($3, u, " ")
                # dl: cqi ri mcs brate ok nok pct dl_bs   ul: snr rsrp ri mcs brate ok nok pct bsr ...
                dbl = (d[5] + d[6] > 0) ? sprintf("%.2f", 100 * d[6] / (d[5] + d[6])) : ""
                ubl = (u[6] + u[7] > 0) ? sprintf("%.2f", 100 * u[7] / (u[6] + u[7])) : ""
                printf "%d,%s,%s,%s,%s,%s,%s,,,%s,%d,%d,%d,%d\n", n,
                    (d[1] == "n/a" ? "" : d[1]), d[3], dbl, u[4], ubl,
                    (u[1] == "n/a" ? "" : u[1]), (u[2] ~ /^-?[0-9.]+$/ ? u[2] : ""),
                    d[5], d[6], u[6], u[7]
            }'
}

stop_radio_log() {
    local ran=$1
    local log_dir=$2
    case $ran in
        oai)
            kill $RADIO_PID 2>/dev/null
            wait $RADIO_PID 2>/dev/null
            ;;
        ocudu)
            local end_line=$(wc -l < "${log_dir}/gnb.log")
            # Rows have no clock time: "time" is the sample number (1 per second)
            echo "${RADIO_HEADER},dl_ok,dl_nok,ul_ok,ul_nok" > "${log_dir}/radio_metrics.csv"
            ocudu_radio_rows "${log_dir}/gnb.log" "$RADIO_START_LINE" "$end_line" \
                >> "${log_dir}/radio_metrics.csv"
            ;;
    esac
}

# Averages over the test window. Prints:
#   cqi dl_mcs dl_bler_pct ul_mcs ul_bler_pct ul_snr_db dl_rsrp_dbm dl_sinr_db ul_rsrp_db samples
# BLER for OCUDU = total nok / total (ok + nok) over the window; for OAI the
# average of the gNB's BLER values (OAI only reports BLER, not the counts).
parse_radio() {
    local file=$1
    if [ ! -s "$file" ]; then echo "N/A N/A N/A N/A N/A N/A N/A N/A N/A 0"; return; fi
    awk -F, '
        NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
        {
            rows++
            for (k = 2; k <= 10; k++) if ($k ~ /^-?[0-9.]+$/) { s[k] += $k; n[k]++ }
            if (col["dl_ok"]) { dok += $(col["dl_ok"]); dnok += $(col["dl_nok"]); uok += $(col["ul_ok"]); unok += $(col["ul_nok"]); counts = 1 }
        }
        END {
            for (k = 2; k <= 10; k++) v[k] = n[k] ? sprintf("%.2f", s[k] / n[k]) : "N/A"
            if (counts) {
                v[4] = (dok + dnok) ? sprintf("%.2f", 100 * dnok / (dok + dnok)) : "N/A"
                v[6] = (uok + unok) ? sprintf("%.2f", 100 * unok / (uok + unok)) : "N/A"
            }
            print v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10], rows + 0
        }' "$file"
}

# =============================================================================
# TESTS (run from the core machine to the phone)
# =============================================================================

# A clear message when the iperf3 server on the phone cannot be reached
check_iperf_result() {
    local file=$1
    local err=$(grep -m1 -aiE "iperf3: error|unable to connect|server is busy" "$file" 2>/dev/null)
    err=${err#*error - }
    if grep -qiE "unable to connect|connection refused|no route to host|server is busy|control socket has closed|bad file descriptor|unable to send control message" "$file" 2>/dev/null; then
        log_warn "iperf3 failed: ${err}"
        log_warn "Is 'iperf3 -s' still running in Termux on the phone? (restart it there: Ctrl+C, then iperf3 -s)"
    elif ! grep -q "receiver" "$file" 2>/dev/null; then
        log_warn "iperf3 gave no result: ${err:-see $(basename "$file")}"
    fi
}

run_ping_test() {
    local log_dir=$1
    refresh_phone_ip
    log "Running ping test: core -> phone ${UE_IP} (${PING_COUNT} packets)..."
    ssh_core "ping -c ${PING_COUNT} -i 0.5 ${UE_IP}" > "${log_dir}/ping_phone.txt" 2>&1
}

run_iperf_tests() {
    local log_dir=$1
    # A stuck iperf3 (e.g. phone gone) must not hang the whole run
    local iperf_timeout=$(( IPERF_DURATION + 30 ))
    local opts="-p ${IPERF_SERVER_PORT} -t ${IPERF_DURATION} --connect-timeout 10000"

    # Client on the core machine, server on the phone:
    #   no -R : core sends, phone receives = downlink
    #   -R    : phone sends, core receives = uplink
    refresh_phone_ip
    log "Running UDP test for jitter, downlink 2 Mbit/s (${IPERF_DURATION}s)..."
    ssh_core "timeout ${iperf_timeout} iperf3 -c ${UE_IP} ${opts} -u -b 2M -l 1200" \
        > "${log_dir}/iperf_udp.txt" 2>&1
    check_iperf_result "${log_dir}/iperf_udp.txt"
    sleep 3

    refresh_phone_ip
    log "Running TCP downlink test (${IPERF_DURATION}s)..."
    ssh_core "timeout ${iperf_timeout} iperf3 -c ${UE_IP} ${opts}" \
        > "${log_dir}/iperf_tcp_dl.txt" 2>&1
    check_iperf_result "${log_dir}/iperf_tcp_dl.txt"
    sleep 3

    refresh_phone_ip
    log "Running TCP uplink test (${IPERF_DURATION}s)..."
    ssh_core "timeout ${iperf_timeout} iperf3 -c ${UE_IP} ${opts} -R" \
        > "${log_dir}/iperf_tcp_ul.txt" 2>&1
    check_iperf_result "${log_dir}/iperf_tcp_ul.txt"
}

# =============================================================================
# PARSE RESULTS
# =============================================================================

parse_ping() {
    local file=$1
    if [ ! -f "$file" ]; then echo "N/A N/A N/A N/A N/A"; return; fi

    local loss=$(grep "packet loss" "$file" | awk '{print $6}' | tr -d '%')
    local rtt=$(grep "rtt min/avg/max/mdev" "$file" | awk -F'=' '{print $2}' | tr -d ' ms')
    local min=$(echo $rtt | cut -d'/' -f1)
    local avg=$(echo $rtt | cut -d'/' -f2)
    local max=$(echo $rtt | cut -d'/' -f3)
    local mdev=$(echo $rtt | cut -d'/' -f4)

    echo "${loss:-N/A} ${min:-N/A} ${avg:-N/A} ${max:-N/A} ${mdev:-N/A}"
}

# TCP throughput from the receiver line (what was actually delivered), Mbps
parse_iperf_tcp() {
    local file=$1
    if [ ! -f "$file" ]; then echo "N/A"; return; fi
    local mbps=$(grep "receiver" "$file" | tail -1 \
        | awk '{for (i=1; i<=NF; i++) if ($i ~ /bits\/sec$/) { v=$(i-1); u=$i } }
               END { if (u ~ /^Gbits/) v*=1000; else if (u ~ /^Kbits/) v/=1000; if (v!="") print v }')
    echo "${mbps:-N/A}"
}

parse_iperf_udp() {
    local file=$1
    if [ ! -f "$file" ]; then echo "N/A N/A N/A"; return; fi
    # Get the receiver summary line
    local receiver_line=$(grep "receiver" "$file" | tail -1)
    local mbps=$(echo "$receiver_line" | awk '{print $7}')
    local jitter=$(echo "$receiver_line" | awk '{print $9}')
    local loss=$(echo "$receiver_line" | awk '{print $12}' | tr -d '()')
    echo "${mbps:-N/A} ${jitter:-N/A} ${loss:-N/A}"
}

# pidstat lines, time is 1 column (24h) or 2 columns (12h "02:03:59 PM"):
#   -u : [time] UID PID %usr %system %guest %wait %CPU CPU Command  -> 10 (+1) fields
#   -r : [time] UID PID minflt/s majflt/s VSZ RSS %MEM Command      ->  9 (+1) fields
# In both, the wanted value (%CPU or RSS) is the 3rd field from the end.
# The process name must match exactly ("amf" also matches Open5GS "open5gs-amfd").
# Same-named PIDs/threads are summed per sample, then averaged over samples.
# Prints "avg peak" (%CPU, 100% = one core) or "avg" (RSS KB).
pidstat_stat() {
    local file=$1
    local process=$2
    local kind=$3    # cpu | ram
    awk -v p="$process" -v kind="$kind" '
        ($NF==p || $NF=="open5gs-" p "d") && $1=="Average:" && NF==9 {
            avg_rss += $(NF-2); have_avg = 1    # pidstat full-run average (-r)
        }
        ($NF==p || $NF=="open5gs-" p "d") && $1!="Average:" {
            ampm = ($2=="AM" || $2=="PM")
            want = (kind=="cpu" ? 10 : 9) + ampm
            if (NF != want) next
            key = ampm ? $1" "$2 : $1
            s[key] += $(NF-2)
        }
        END {
            n=0; t=0; pk=0
            for (k in s) { n++; t+=s[k]; if (s[k]>pk) pk=s[k] }
            if (kind=="ram" && have_avg) { printf "%.0f\n", avg_rss; exit }
            if (n==0)          print (kind=="cpu" ? "N/A N/A" : "N/A")
            else if (kind=="cpu") printf "%.2f %.2f\n", t/n, pk
            else               printf "%.0f\n", t/n
        }' "$file"
}

parse_cpu() {
    local file=$1
    local process=$2
    if [ ! -f "$file" ]; then echo "N/A N/A"; return; fi
    pidstat_stat "$file" "$process" cpu
}

parse_ram() {
    local file=$1
    local process=$2
    if [ ! -f "$file" ]; then echo "N/A"; return; fi
    pidstat_stat "$file" "$process" ram
}

# Registration and PDU session setup times (ms) from the core network log.
#   Registration : AMF "Registration request"  -> "Registration complete"
#   PDU session  : AMF "Registration complete" -> SMF UE IP allocated
# The registration right before the first IP allocation is used: the phone can
# register without asking for a data session and register again later (e.g.
# after an airplane-mode toggle), which would otherwise inflate the PDU time.
# Prints "reg pdu".
parse_reg_times() {
    local file=$1
    if [ ! -s "$file" ]; then echo "N/A N/A"; return; fi
    awk '
    function t_ms(line,   a, h, m, s, f) {
        if (!match(line, /[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9]+/)) return -1
        a = substr(line, RSTART, RLENGTH)
        h = substr(a, 1, 2) + 0; m = substr(a, 4, 2) + 0; s = substr(a, 7, 2) + 0
        f = substr(substr(a, 10) "000", 1, 3) + 0
        return ((h * 60 + m) * 60 + s) * 1000 + f
    }
    have_ip { next }
    /Registration request|Handle Registration Request/ { req = t_ms($0); have_req = (req >= 0); done = 0 }
    have_req && /Registration complete|Handle Registration Complete/ { comp = t_ms($0); done = (comp >= 0); next }
    done && /IPv4\[|Allocated UE IP address/ { ip = t_ms($0); have_ip = (ip >= 0) }
    END {
        if (!done) { print "N/A N/A"; exit }
        r = comp - req; if (r < 0) r += 86400000
        if (have_ip) { p = ip - comp; if (p < 0) p += 86400000 } else p = "N/A"
        print r, p
    }' "$file"
}

# =============================================================================
# PERFORMANCE MODE, TEMPERATURE LOGGING, ROUNDS SUMMARY
# =============================================================================

# CPU governor "performance" on the RAN machine for the whole run; restored on
# exit (see the EXIT trap in main). The core machine is left unchanged (same
# as 5g_benchmark.sh).
ORIG_GOV_RAN=""
set_performance_mode() {
    ORIG_GOV_RAN=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$g" 2>/dev/null
    done
    GOV_RAN=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
    GOV_CORE=$(ssh_core "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null")
    log "CPU governor: RAN ${ORIG_GOV_RAN:-?} -> ${GOV_RAN:-?}, core ${GOV_CORE:-?} (unchanged)"
    [ "$GOV_RAN" = "performance" ] || log_warn "Performance mode not active on the RAN machine"
}

restore_cpu_mode() {
    if [ -n "$ORIG_GOV_RAN" ]; then
        for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo "$ORIG_GOV_RAN" > "$g" 2>/dev/null
        done
    fi
}

# Temperature logger, run on each machine during the tests. Every 2s:
#   time  package_temp_C  avg_cpu_freq_MHz  thermal_throttle_events_total
# $1 = maximum run time in seconds (it is also stopped when the tests end).
THERMAL_LOGGER='
end=$(( $(date +%s) + ${1:-600} ))
echo "# time temp_c freq_mhz throttle_total"
while [ $(date +%s) -lt $end ]; do
    t=0
    for z in /sys/class/thermal/thermal_zone*; do
        if [ "$(cat $z/type 2>/dev/null)" = "x86_pkg_temp" ]; then t=$(cat $z/temp); break; fi
    done
    f=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null \
        | awk "{ s += \$1; n++ } END { if (n) printf \"%.0f\", s / n / 1000; else print 0 }")
    th=$(cat /sys/devices/system/cpu/cpu*/thermal_throttle/*_throttle_count 2>/dev/null \
        | awk "{ s += \$1 } END { print s + 0 }")
    echo "$(date +%T) $(( t / 1000 )) $f $th"
    sleep 2
done'

start_thermal_log() {
    local log_dir=$1
    bash -c "$THERMAL_LOGGER" thermal 600 > "${log_dir}/thermal_ran.txt" 2>&1 &
    THERMAL_RAN_PID=$!
    ssh_core_stdin "bash -s 600" <<< "$THERMAL_LOGGER" > "${log_dir}/thermal_core.txt" 2>&1 &
    THERMAL_CORE_PID=$!
}

stop_thermal_log() {
    kill $THERMAL_RAN_PID 2>/dev/null
    # Killing the local ssh does not stop the remote loop: stop it there
    ssh_core "pkill -f '^bash -s 600\$' 2>/dev/null; true"
    kill $THERMAL_CORE_PID 2>/dev/null
    wait $THERMAL_RAN_PID $THERMAL_CORE_PID 2>/dev/null
}

# Prints "temp_avg temp_max freq_avg throttle_events" (events = increase
# of the throttle counters during the tests; 0 means no thermal slowdown)
parse_thermal() {
    local file=$1
    if [ ! -s "$file" ]; then echo "N/A N/A N/A N/A"; return; fi
    awk '$1 !~ /^#/ && NF == 4 {
            n++; t += $2; f += $3; if ($2 > tm) tm = $2
            if (n == 1) th0 = $4; th1 = $4 }
         END { if (n) printf "%.1f %d %.0f %d\n", t / n, tm, f / n, th1 - th0
               else print "N/A N/A N/A N/A" }' "$file"
}

# Statistics over all rounds, per combination, from all_results.csv.
# Only PASS rows are used; n = number of PASS rows with a numeric value.
# 95% CI = mean +/- t(n-1) * std / sqrt(n)  (Student t, two-sided).
generate_summary() {
    local metrics=$1
    local csv="${BASE_DIR}/all_results.csv"
    local txt="${BASE_DIR}/summary.txt"
    local scsv="${BASE_DIR}/summary.csv"
    {
        echo "================================================================================"
        echo "              STATISTICS OVER ${ROUNDS} ROUND(S) - PER COMBINATION"
        echo "================================================================================"
        echo "  Generated : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "  Run ID    : ${TIMESTAMP}"
        echo "  Source    : all_results.csv (PASS rows only)"
        echo "  std = sample standard deviation; 95% CI = +/- t(n-1) * std / sqrt(n)"
        echo "  Radio metrics are averages over each run's test window."
        echo "  dl_rsrp/dl_sinr: measured by the phone (OAI only)."
        echo "  ul_rsrp: measured by the gNB (OCUDU only) - not comparable with dl_rsrp."
        echo "================================================================================"
    } > "$txt"
    awk -F, -v metrics="$metrics" -v txt="$txt" -v scsv="$scsv" '
        BEGIN {
            split("12.706 4.303 3.182 2.776 2.571 2.447 2.365 2.306 2.262 2.228 2.201 2.179 2.160 2.145 2.131 2.120 2.110 2.101 2.093 2.086 2.080 2.074 2.069 2.064 2.060 2.056 2.052 2.048 2.045 2.042", T, " ")
            nm = split(metrics, M, " ")
        }
        NR == 1 { for (i = 1; i <= NF; i++) col[$i] = i; next }
        {
            key = $(col["core"]) " + " $(col["ran"])
            if (!(key in total)) order[++nk] = key
            total[key]++
            if ($(col["status"]) != "PASS") next
            passed[key]++
            for (j = 1; j <= nm; j++) {
                c = col[M[j]]; if (!c) continue
                v = $c
                if (v !~ /^-?[0-9]+(\.[0-9]+)?$/) continue
                v += 0; n[key, j]++; s[key, j] += v; ss[key, j] += v * v
                if (n[key, j] == 1 || v < mn[key, j]) mn[key, j] = v
                if (n[key, j] == 1 || v > mx[key, j]) mx[key, j] = v
            }
        }
        END {
            print "core,ran,metric,n,mean,std,min,max,ci95_halfwidth" > scsv
            for (k = 1; k <= nk; k++) {
                key = order[k]
                printf "\n── %s ──  rounds passed: %d of %d\n", key, passed[key] + 0, total[key] >> txt
                printf "  %-20s %3s %11s %10s %10s %10s %11s\n", "metric", "n", "mean", "std", "min", "max", "95% CI +/-" >> txt
                split(key, KR, " \\+ ")
                for (j = 1; j <= nm; j++) {
                    cnt = n[key, j] + 0
                    if (cnt == 0) { printf "  %-20s %3d %11s\n", M[j], 0, "N/A" >> txt; continue }
                    mean = s[key, j] / cnt
                    if (cnt > 1) {
                        var = (ss[key, j] - s[key, j] * s[key, j] / cnt) / (cnt - 1); if (var < 0) var = 0
                        sd = sqrt(var); tv = (cnt - 1 <= 30) ? T[cnt - 1] : 1.96; ci = tv * sd / sqrt(cnt)
                        sds = sprintf("%.3f", sd); cis = sprintf("%.3f", ci)
                    } else { sds = "N/A"; cis = "N/A" }
                    printf "  %-20s %3d %11.3f %10s %10.3f %10.3f %11s\n", M[j], cnt, mean, sds, mn[key, j], mx[key, j], cis >> txt
                    printf "%s,%s,%s,%d,%.3f,%s,%.3f,%.3f,%s\n", KR[1], KR[2], M[j], cnt, mean, sds, mn[key, j], mx[key, j], cis >> scsv
                }
            }
        }' "$csv"
    log_ok "Statistics summary saved: $txt (and summary.csv)"
}

# =============================================================================
# REPORT GENERATION
# =============================================================================

# =============================================================================
# FIXED-LOAD TEST (resources for the same job)
# =============================================================================
# The same UDP load in both directions at the same time (iperf3 --bidir) for
# every combination. CPU/RAM/power are measured only during this test, so the
# combinations can be compared for the same amount of work.

# iperf3 --bidir summary, client view: "[TX-C] ... receiver" = data the client
# sent, "[RX-C] ... receiver" = data the client received.
# Prints "tx_mbps tx_loss_pct rx_mbps rx_loss_pct".
parse_iperf_bidir() {
    local file=$1
    if [ ! -f "$file" ]; then echo "N/A N/A N/A N/A"; return; fi
    awk '
        /receiver/ && /\[(TX|RX)-C\]/ {
            role = (/\[TX-C\]/) ? "tx" : "rx"
            for (i = 1; i <= NF; i++) {
                if ($i ~ /bits\/sec$/) {
                    v = $(i-1)
                    if ($i ~ /^Gbits/) v *= 1000; else if ($i ~ /^Kbits/) v /= 1000
                    rate[role] = v
                }
                if ($i ~ /^\(.*%\)$/) { l = $i; gsub(/[()%]/, "", l); loss[role] = l }
            }
        }
        END {
            printf "%s %s %s %s\n", (("tx" in rate) ? rate["tx"] : "N/A"), (("tx" in loss) ? loss["tx"] : "N/A"),
                                    (("rx" in rate) ? rate["rx"] : "N/A"), (("rx" in loss) ? loss["rx"] : "N/A")
        }' "$file"
}

# Prints "dl_mbps dl_loss_pct ul_mbps ul_loss_pct" (FL_CLIENT_SIDE tells which
# end runs the iperf3 client)
fixed_load_rates() {
    local tx_r tx_l rx_r rx_l
    read tx_r tx_l rx_r rx_l <<< $(parse_iperf_bidir "$1")
    if [ "$FL_CLIENT_SIDE" = "ue" ]; then
        echo "$rx_r $rx_l $tx_r $tx_l"
    else
        echo "$tx_r $tx_l $rx_r $rx_l"
    fi
}

# VALID if both directions carried >= 95% of the target rate with <= 5% loss
fixed_load_check() {
    awk -v t="$FIXED_RATE_MBPS" -v a="$1" -v b="$2" -v c="$3" -v d="$4" 'BEGIN {
        ok = (a ~ /^[0-9.]+$/ && c ~ /^[0-9.]+$/ && a >= 0.95 * t && c >= 0.95 * t \
              && b ~ /^[0-9.]+$/ && d ~ /^[0-9.]+$/ && b <= 5 && d <= 5)
        print (ok ? "VALID" : "CHECK") }'
}

# Power over the fixed-load window -> <dir>/power.txt
write_fixed_power() {
    local d=$1 s_ran=$2 e_ran=$3 s_core=$4 e_core=$5 dur=$6
    [ "$dur" -lt 1 ] && dur=1
    local dr=$(rapl_delta "$s_ran" "$e_ran" "$(read_rapl_max_ran)")
    local dc=$(rapl_delta "$s_core" "$e_core" "$(read_rapl_max_core)")
    {
        echo "duration_s=${dur}"
        echo "ran_watts=${dr:+$(( dr / (dur * 1000000) ))}"
        echo "ran_joules=${dr:+$(( dr / 1000000 ))}"
        echo "core_watts=${dc:+$(( dc / (dur * 1000000) ))}"
        echo "core_joules=${dc:+$(( dc / 1000000 ))}"
    } > "${d}/power.txt"
}

# Prints "ran_watts ran_joules core_watts core_joules" for the fixed-load window
fixed_load_power() {
    local f="$1/power.txt"
    if [ ! -f "$f" ]; then echo "N/A N/A N/A N/A"; return; fi
    awk -F= '{ v[$1] = $2 }
        END { split("ran_watts ran_joules core_watts core_joules", K, " ")
              for (i = 1; i <= 4; i++) printf "%s%s", (v[K[i]] == "" ? "N/A" : v[K[i]]), (i < 4 ? " " : "\n") }' "$f"
}

# Whole-machine CPU from mpstat (all cores, incl. kernel work such as free5gc's
# gtp5g forwarding in softirq, which per-process pidstat cannot see).
# Prints "busy_pct cores usr_pct sys_pct soft_pct" (averages over the samples;
# busy = 100 - idle; cores = busy * number_of_CPUs / 100).
parse_mpstat() {
    local file=$1
    if [ ! -s "$file" ]; then echo "N/A N/A N/A N/A N/A"; return; fi
    awk '
        /\([0-9]+ CPU\)/ { if (match($0, /\([0-9]+ CPU\)/)) ncpu = substr($0, RSTART + 1, RLENGTH - 6) + 0 }
        $1 != "Average:" && $2 == "all" && NF >= 12 {
            n++; usr += $3; sys += $5; soft += $8; idle += $NF
        }
        END {
            if (!n) { print "N/A N/A N/A N/A N/A"; exit }
            busy = 100 - idle / n
            printf "%.2f %.2f %.2f %.2f %.2f\n", busy, (ncpu ? busy * ncpu / 100 : 0), usr / n, sys / n, soft / n
        }' "$file"
}

run_fixed_load_test() {
    local raw_dir=$1
    local ran=$2
    local d="${raw_dir}/fixed_load"
    mkdir -p "$d"
    log "FIXED-LOAD TEST: UDP ${FIXED_RATE_MBPS} Mbit/s downlink + ${FIXED_RATE_MBPS} Mbit/s uplink at the same time (${FIXED_DURATION}s)..."
    refresh_phone_ip
    collect_cpu_ram "$d" "$(gnb_proc $ran)" "$(( FIXED_DURATION + 60 ))"
    # Radio metrics for this window only (OCUDU reads its table from gnb.log)
    ln -sf ../gnb.log "${d}/gnb.log"
    start_radio_log "$ran" "$d"
    # Whole-machine CPU on both machines (mpstat, every second)
    LC_ALL=C mpstat 1 $(( FIXED_DURATION + 60 )) > "${d}/mpstat_ran.txt" 2>&1 &
    local mp_ran_pid=$!
    ssh_core "LC_ALL=C mpstat 1 $(( FIXED_DURATION + 60 ))" > "${d}/mpstat_core.txt" 2>&1 &
    local mp_core_pid=$!
    local s_ran=$(read_rapl_ran) s_core=$(read_rapl_core) t0=$(date +%s)
    ssh_core "timeout $(( FIXED_DURATION + 30 )) iperf3 -c ${UE_IP} -p ${IPERF_SERVER_PORT} -t ${FIXED_DURATION} \
        -u -b ${FIXED_RATE_MBPS}M -l 1200 --bidir --connect-timeout 10000" > "${d}/iperf_fixed.txt" 2>&1
    local e_ran=$(read_rapl_ran) e_core=$(read_rapl_core) t1=$(date +%s)
    kill $mp_ran_pid 2>/dev/null
    ssh_core "pkill -x mpstat 2>/dev/null; true"
    wait $mp_ran_pid $mp_core_pid 2>/dev/null
    stop_radio_log "$ran" "$d"
    stop_cpu_ram
    check_iperf_result "${d}/iperf_fixed.txt"
    write_fixed_power "$d" "$s_ran" "$e_ran" "$s_core" "$e_core" $(( t1 - t0 ))
    local fl=$(fixed_load_rates "${d}/iperf_fixed.txt")
    read fl_dl fl_dll fl_ul fl_ull <<< "$fl"
    local chk=$(fixed_load_check $fl)
    if [ "$chk" = "VALID" ]; then
        log_ok "Fixed load delivered: DL ${fl_dl} Mbps, UL ${fl_ul} Mbps"
    else
        log_warn "Fixed load NOT fully delivered (DL ${fl_dl} Mbps loss ${fl_dll}%, UL ${fl_ul} Mbps loss ${fl_ull}%) - resources marked N/A in the CSV"
    fi
}

generate_report() {
    local report_file=$1
    local raw_dir=$2
    local core=$3
    local ran=$4

    local ping_loss rtt_min rtt_avg rtt_max rtt_mdev
    read ping_loss rtt_min rtt_avg rtt_max rtt_mdev <<< $(parse_ping "${raw_dir}/ping_phone.txt")

    local tcp_dl=$(parse_iperf_tcp "${raw_dir}/iperf_tcp_dl.txt")
    local tcp_ul=$(parse_iperf_tcp "${raw_dir}/iperf_tcp_ul.txt")

    local udp_mbps jitter udp_loss
    read udp_mbps jitter udp_loss <<< $(parse_iperf_udp "${raw_dir}/iperf_udp.txt")

    local gnb_cpu gnb_cpu_peak
    read gnb_cpu gnb_cpu_peak <<< $(parse_cpu "${raw_dir}/cpu_ran.txt" "$(gnb_proc $ran)")
    local amf_cpu smf_cpu upf_cpu
    read amf_cpu _ <<< $(parse_cpu "${raw_dir}/cpu_core.txt" "amf")
    read smf_cpu _ <<< $(parse_cpu "${raw_dir}/cpu_core.txt" "smf")
    read upf_cpu _ <<< $(parse_cpu "${raw_dir}/cpu_core.txt" "upf")

    local reg_ms pdu_ms
    read reg_ms pdu_ms <<< $(parse_reg_times "$(core_log_file $core "$raw_dir")")

    local cqi dmcs dbler umcs ubler usnr drsrp dsinr ursrp nsamp
    read cqi dmcs dbler umcs ubler usnr drsrp dsinr ursrp nsamp <<< $(parse_radio "${raw_dir}/radio_metrics.csv")

    local rta rtm rf rth cta ctm cf cth
    read rta rtm rf rth <<< $(parse_thermal "${raw_dir}/thermal_ran.txt")
    read cta ctm cf cth <<< $(parse_thermal "${raw_dir}/thermal_core.txt")

    local ip_changes=$(grep -c "IP changed" "${raw_dir}/phone_ip.txt" 2>/dev/null)

    # Fixed-load test (same job for every combination)
    local fl_rb fl_rcores fl_rusr fl_rsys fl_rsoft fl_cb fl_ccores fl_cusr fl_csys fl_csoft
    read fl_rb fl_rcores fl_rusr fl_rsys fl_rsoft <<< $(parse_mpstat "${raw_dir}/fixed_load/mpstat_ran.txt")
    read fl_cb fl_ccores fl_cusr fl_csys fl_csoft <<< $(parse_mpstat "${raw_dir}/fixed_load/mpstat_core.txt")
    local fl_dl fl_dl_loss fl_ul fl_ul_loss fl_valid fl_rw fl_rj fl_cw fl_cj
    read fl_dl fl_dl_loss fl_ul fl_ul_loss <<< $(fixed_load_rates "${raw_dir}/fixed_load/iperf_fixed.txt")
    fl_valid=$(fixed_load_check $fl_dl $fl_dl_loss $fl_ul $fl_ul_loss)
    read fl_rw fl_rj fl_cw fl_cj <<< $(fixed_load_power "${raw_dir}/fixed_load")
    local fl_gnb_cpu fl_gnb_pk
    read fl_gnb_cpu fl_gnb_pk <<< $(parse_cpu "${raw_dir}/fixed_load/cpu_ran.txt" "$(gnb_proc $ran)")
    local fl_amf_cpu; read fl_amf_cpu _ <<< $(parse_cpu "${raw_dir}/fixed_load/cpu_core.txt" "amf")
    local fl_smf_cpu; read fl_smf_cpu _ <<< $(parse_cpu "${raw_dir}/fixed_load/cpu_core.txt" "smf")
    local fl_upf_cpu; read fl_upf_cpu _ <<< $(parse_cpu "${raw_dir}/fixed_load/cpu_core.txt" "upf")
    local fl_cqi fl_dmcs fl_dbler fl_umcs fl_ubler fl_usnr fl_drsrp fl_dsinr fl_ursrp fl_nsamp
    read fl_cqi fl_dmcs fl_dbler fl_umcs fl_ubler fl_usnr fl_drsrp fl_dsinr fl_ursrp fl_nsamp <<< $(parse_radio "${raw_dir}/fixed_load/radio_metrics.csv")

    cat > "$report_file" << EOF
================================================================================
                   5G TESTBED - REAL PHONE BENCHMARK REPORT
================================================================================
  Generated  : $(date '+%Y-%m-%d %H:%M:%S')
  Report for : $(echo $core | tr '[:lower:]' '[:upper:]') + $(ran_label $ran)
  Round      : ${CURRENT_ROUND} of ${ROUNDS}
================================================================================

────────────────────────────────────────────────────────────────────────────────
 TEST CONFIGURATION
────────────────────────────────────────────────────────────────────────────────
  Core Network      : $(echo $core | tr '[:lower:]' '[:upper:]')
  gNB               : $(ran_label $ran)
  Cell              : $(cell_info $ran "$raw_dir")
  RAN Machine IP    : ${RAN_IP}
  Core Machine IP   : ${CORE_IP}
  Phone IMSI        : ${PHONE_IMSI}
  Phone IP          : ${UE_IP:-N/A}   (IP changes during the tests: ${ip_changes:-0})
  Phone attached    : after ~${ATTACH_WAIT}s (checked every ${UE_POLL_INTERVAL}s)
  Ping Count        : ${PING_COUNT} packets
  Iperf Duration    : ${IPERF_DURATION} seconds
  Test Timestamp    : $(date '+%Y-%m-%d %H:%M:%S')

────────────────────────────────────────────────────────────────────────────────
 REGISTRATION  (from core network logs)
────────────────────────────────────────────────────────────────────────────────
  Registration Time       : ${reg_ms} ms   (AMF: Registration Request -> Registration Complete)
  PDU Session Setup Time  : ${pdu_ms} ms   (Registration Complete -> UE IP allocated by SMF)

────────────────────────────────────────────────────────────────────────────────
 LATENCY  (${PING_COUNT} ICMP packets, core machine -> phone)
────────────────────────────────────────────────────────────────────────────────
  Packets Sent            : ${PING_COUNT}
  Packet Loss             : ${ping_loss} %
  RTT Minimum             : ${rtt_min} ms
  RTT Average             : ${rtt_avg} ms
  RTT Maximum             : ${rtt_max} ms
  RTT Std Deviation       : ${rtt_mdev} ms

────────────────────────────────────────────────────────────────────────────────
 JITTER  (UDP iperf3 2 Mbit/s, ${IPERF_DURATION}s, core -> phone = downlink)
────────────────────────────────────────────────────────────────────────────────
  UDP Throughput          : ${udp_mbps} Mbps
  Jitter                  : ${jitter} ms
  UDP Packet Loss         : ${udp_loss}

────────────────────────────────────────────────────────────────────────────────
 THROUGHPUT  (TCP iperf3, ${IPERF_DURATION}s, receiver side)
────────────────────────────────────────────────────────────────────────────────
  Downlink                : ${tcp_dl} Mbps   (core -> phone)
  Uplink                  : ${tcp_ul} Mbps   (phone -> core)

────────────────────────────────────────────────────────────────────────────────
 RADIO  (averages over the test window, ${nsamp} one-second samples)
────────────────────────────────────────────────────────────────────────────────
  CQI                     : ${cqi}   (0-15, channel quality reported by the phone)
  DL MCS                  : ${dmcs}   (0-27/28, higher = faster but more fragile)
  DL BLER                 : ${dbler} %
  UL MCS                  : ${umcs}
  UL BLER                 : ${ubler} %
  UL SNR                  : ${usnr} dB   (measured by the gNB)
  DL RSRP                 : ${drsrp} dBm   (measured by the phone; OAI only)
  DL SINR                 : ${dsinr} dB   (measured by the phone; OAI only)
  UL RSRP                 : ${ursrp} dB   (measured by the gNB; OCUDU only)

────────────────────────────────────────────────────────────────────────────────
 CPU USAGE  (pidstat, sampled every 1s during the performance tests; 100% = one core)
────────────────────────────────────────────────────────────────────────────────
  [ RAN Machine : ${RAN_IP} ]
  gNB Process             : avg ${gnb_cpu} %   peak ${gnb_cpu_peak} %

  [ Core Machine : ${CORE_IP} ]
  AMF                     : avg ${amf_cpu} %
  SMF                     : avg ${smf_cpu} %
  UPF                     : avg ${upf_cpu} %

────────────────────────────────────────────────────────────────────────────────
 MEMORY USAGE  (pidstat RSS, during the performance tests)
────────────────────────────────────────────────────────────────────────────────
  [ RAN Machine ]
  gNB RSS                 : $(parse_ram "${raw_dir}/cpu_ran.txt" "$(gnb_proc $ran)") KB

  [ Core Machine ]
  AMF RSS                 : $(parse_ram "${raw_dir}/cpu_core.txt" "amf") KB
  SMF RSS                 : $(parse_ram "${raw_dir}/cpu_core.txt" "smf") KB
  UPF RSS                 : $(parse_ram "${raw_dir}/cpu_core.txt" "upf") KB

────────────────────────────────────────────────────────────────────────────────
 POWER CONSUMPTION  (Intel RAPL, measured during the performance tests)
────────────────────────────────────────────────────────────────────────────────
  [ RAN Machine : ${RAN_IP} ]
  Average Power           : ${RAN_WATTS:-N/A} W
  Total Energy            : ${RAN_JOULES:-N/A} J

  [ Core Machine : ${CORE_IP} ]
  Average Power           : ${CORE_WATTS:-N/A} W
  Total Energy            : ${CORE_JOULES:-N/A} J

────────────────────────────────────────────────────────────────────────────────
 FIXED-LOAD RESOURCES  (UDP ${FIXED_RATE_MBPS} Mbit/s DL + ${FIXED_RATE_MBPS} Mbit/s UL at once, ${FIXED_DURATION}s)
────────────────────────────────────────────────────────────────────────────────
  Same traffic for every combination: compare these values to see which
  combination needs fewer resources for the same job.
  Machine CPU = all cores incl. kernel work (e.g. free5gc gtp5g); use it,
  not the UPF process CPU, to compare the cores. 100 % = whole machine.
  FL Load Delivered       : DL ${fl_dl} Mbps (loss ${fl_dl_loss} %), UL ${fl_ul} Mbps (loss ${fl_ul_loss} %)
  FL Load Check           : ${fl_valid}   (VALID = both directions >= 95% of target, loss <= 5%)
  FL Radio (avg)          : CQI ${fl_cqi}, DL MCS ${fl_dmcs}, UL MCS ${fl_umcs}, UL SNR ${fl_usnr} dB, DL BLER ${fl_dbler} %, UL BLER ${fl_ubler} %

  [ RAN Machine : ${RAN_IP} ]
  FL gNB CPU              : avg ${fl_gnb_cpu} %   peak ${fl_gnb_pk} %
  FL gNB RSS              : $(parse_ram "${raw_dir}/fixed_load/cpu_ran.txt" "$(gnb_proc $ran)") KB
  FL RAN Power            : ${fl_rw} W   (${fl_rj} J)
  FL Machine CPU (all)    : ${fl_rb} % busy = ${fl_rcores} cores   (usr ${fl_rusr} %, sys ${fl_rsys} %, soft ${fl_rsoft} %)

  [ Core Machine : ${CORE_IP} ]
  FL AMF / SMF / UPF CPU  : avg ${fl_amf_cpu} % / ${fl_smf_cpu} % / ${fl_upf_cpu} %
  FL Core Power           : ${fl_cw} W   (${fl_cj} J)
  FL Machine CPU (all)    : ${fl_cb} % busy = ${fl_ccores} cores   (usr ${fl_cusr} %, sys ${fl_csys} %, soft ${fl_csoft} %)

────────────────────────────────────────────────────────────────────────────────
 TEMPERATURE & CPU FREQUENCY  (sampled every 2s during tests)
────────────────────────────────────────────────────────────────────────────────
  CPU Governor            : RAN ${GOV_RAN:-N/A}, core ${GOV_CORE:-N/A}

  [ RAN Machine : ${RAN_IP} ]
  Package Temperature     : avg ${rta} °C   max ${rtm} °C
  Average CPU Frequency   : ${rf} MHz
  Thermal Throttle Events : ${rth}   (0 = no slowdown from heat)

  [ Core Machine : ${CORE_IP} ]
  Package Temperature     : avg ${cta} °C   max ${ctm} °C
  Average CPU Frequency   : ${cf} MHz
  Thermal Throttle Events : ${cth}   (0 = no slowdown from heat)

────────────────────────────────────────────────────────────────────────────────
 EVIDENCE FILES
────────────────────────────────────────────────────────────────────────────────
  raw/gnb.log             : gNB terminal output (OCUDU: incl. per-second metrics table)
  raw/gnb_internal.log    : OCUDU /tmp/gnb.log (${OCUDU_LOG_LEVEL} level) - OCUDU only
  raw/radio_metrics.csv   : Per-second radio metrics during the tests
  raw/nrMAC_stats_last.log: Last OAI MAC stats snapshot - OAI only
  raw/nrRRC_stats_last.log: Last OAI RRC stats snapshot - OAI only
  raw/amf.log             : Open5GS AMF/SMF/UPF journal logs (Open5GS runs)
  raw/free5gc.log         : free5gc log (free5gc runs)
  raw/phone_ip.txt        : Phone IP and any changes during the tests
  raw/ping_phone.txt      : Full ping output (${PING_COUNT} packets)
  raw/iperf_tcp_dl.txt    : TCP downlink iperf3 full output
  raw/iperf_tcp_ul.txt    : TCP uplink iperf3 full output
  raw/iperf_udp.txt       : UDP jitter iperf3 full output
  raw/FAILED.txt          : Only present if the run failed (reason)
  raw/cpu_ran.txt         : pidstat output - RAN machine
  raw/cpu_core.txt        : pidstat output - core machine
  raw/power_ran.txt       : RAPL power log - RAN machine
  raw/power_core.txt      : RAPL power log - core machine
  raw/fixed_load/         : Fixed-load test: iperf_fixed.txt, CPU/RAM, power, radio
  raw/thermal_ran.txt     : Temperature/frequency log - RAN machine
  raw/thermal_core.txt    : Temperature/frequency log - core machine
  ../../terminal_session.txt : Full terminal output of the whole run

================================================================================
EOF

    log_ok "Report saved: $report_file"
}

# =============================================================================
# CSV EXPORT
# =============================================================================

CSV_HEADER="timestamp,core,ran,status,ue_ip,ping_loss_pct,rtt_avg_ms,rtt_mdev_ms,tcp_dl_mbps,tcp_ul_mbps,jitter_ms,udp_loss,ran_watts,ran_joules,core_watts,core_joules,reg_ms,pdu_setup_ms,gnb_cpu_pct,cqi,dl_mcs,dl_bler_pct,ul_mcs,ul_bler_pct,ul_snr_db,dl_rsrp_dbm,dl_sinr_db,ul_rsrp_db,ran_temp_avg_c,ran_temp_max_c,ran_freq_avg_mhz,ran_throttle_events,core_temp_avg_c,core_temp_max_c,core_freq_avg_mhz,core_throttle_events,round,fl_dl_mbps,fl_ul_mbps,fl_dl_loss_pct,fl_ul_loss_pct,fl_valid,fl_gnb_cpu_pct,fl_gnb_rss_kb,fl_upf_cpu_pct,fl_ran_watts,fl_ran_joules,fl_core_watts,fl_core_joules,fl_ran_machine_cpu_pct,fl_ran_softirq_pct,fl_core_machine_cpu_pct,fl_core_softirq_pct"

SUMMARY_METRICS="ping_loss_pct rtt_avg_ms rtt_mdev_ms tcp_dl_mbps tcp_ul_mbps jitter_ms gnb_cpu_pct ran_watts core_watts reg_ms pdu_setup_ms cqi dl_mcs dl_bler_pct ul_mcs ul_bler_pct ul_snr_db dl_rsrp_dbm dl_sinr_db ul_rsrp_db ran_temp_max_c core_temp_max_c ran_freq_avg_mhz core_freq_avg_mhz ran_throttle_events core_throttle_events fl_dl_mbps fl_ul_mbps fl_gnb_cpu_pct fl_gnb_rss_kb fl_upf_cpu_pct fl_ran_watts fl_ran_joules fl_core_watts fl_core_joules fl_ran_machine_cpu_pct fl_ran_softirq_pct fl_core_machine_cpu_pct fl_core_softirq_pct"

append_csv() {
    local csv_file=$1
    local core=$2
    local ran=$3
    local raw_dir=$4
    local status=${5:-PASS}

    local ping_loss rtt_avg rtt_mdev
    read ping_loss _ rtt_avg _ rtt_mdev <<< $(parse_ping "${raw_dir}/ping_phone.txt")
    local tcp_dl=$(parse_iperf_tcp "${raw_dir}/iperf_tcp_dl.txt")
    local tcp_ul=$(parse_iperf_tcp "${raw_dir}/iperf_tcp_ul.txt")
    local jitter udp_loss
    read _ jitter udp_loss <<< $(parse_iperf_udp "${raw_dir}/iperf_udp.txt")
    local reg_ms pdu_ms
    read reg_ms pdu_ms <<< $(parse_reg_times "$(core_log_file $core "$raw_dir")")
    local gnb_cpu
    read gnb_cpu _ <<< $(parse_cpu "${raw_dir}/cpu_ran.txt" "$(gnb_proc $ran)")
    local radio=$(parse_radio "${raw_dir}/radio_metrics.csv" | awk '{ NF = 9; print }' | tr ' ' ',')
    local ran_th core_th
    ran_th=$(parse_thermal "${raw_dir}/thermal_ran.txt" | tr ' ' ',')
    core_th=$(parse_thermal "${raw_dir}/thermal_core.txt" | tr ' ' ',')

    # Fixed-load test; resource values only if the load was fully delivered
    local fl_dl fl_dl_loss fl_ul fl_ul_loss fl_valid fl_rw fl_rj fl_cw fl_cj fl_res
    read fl_dl fl_dl_loss fl_ul fl_ul_loss <<< $(fixed_load_rates "${raw_dir}/fixed_load/iperf_fixed.txt")
    fl_valid=$(fixed_load_check $fl_dl $fl_dl_loss $fl_ul $fl_ul_loss)
    read fl_rw fl_rj fl_cw fl_cj <<< $(fixed_load_power "${raw_dir}/fixed_load")
    fl_res="$(parse_cpu "${raw_dir}/fixed_load/cpu_ran.txt" "$(gnb_proc $ran)" | cut -d" " -f1),$(parse_ram "${raw_dir}/fixed_load/cpu_ran.txt" "$(gnb_proc $ran)"),$(parse_cpu "${raw_dir}/fixed_load/cpu_core.txt" "upf" | cut -d" " -f1),${fl_rw},${fl_rj},${fl_cw},${fl_cj},$(parse_mpstat "${raw_dir}/fixed_load/mpstat_ran.txt" | cut -d" " -f1),$(parse_mpstat "${raw_dir}/fixed_load/mpstat_ran.txt" | cut -d" " -f5),$(parse_mpstat "${raw_dir}/fixed_load/mpstat_core.txt" | cut -d" " -f1),$(parse_mpstat "${raw_dir}/fixed_load/mpstat_core.txt" | cut -d" " -f5)"
    [ "$fl_valid" = "VALID" ] || fl_res=$(printf "N/A%.0s," $(seq 1 11) | sed "s/,$//")

    echo "${TIMESTAMP},${core},${ran},${status},${UE_IP:-N/A},${ping_loss},${rtt_avg},${rtt_mdev},${tcp_dl},${tcp_ul},${jitter},${udp_loss},${RAN_WATTS:-N/A},${RAN_JOULES:-N/A},${CORE_WATTS:-N/A},${CORE_JOULES:-N/A},${reg_ms},${pdu_ms},${gnb_cpu},${radio},${ran_th},${core_th},${CURRENT_ROUND},${fl_dl},${fl_ul},${fl_dl_loss},${fl_ul_loss},${fl_valid},${fl_res}" \
        >> "$csv_file"
}

# =============================================================================
# RUN ONE COMBINATION
# =============================================================================

# Core log saved for this run
core_log_file() {
    case $1 in
        open5gs) echo "$2/amf.log" ;;
        free5gc) echo "$2/free5gc.log" ;;
    esac
}

# Core logs for this run only (COMBO_START is the core machine's clock at the
# start of the run, so logs never overlap; free5gc's log is new each start)
collect_core_logs() {
    local core=$1
    local raw_dir=$2
    case $core in
        open5gs)
            ssh_core "sudo journalctl -u open5gs-amfd -u open5gs-smfd \
                -u open5gs-upfd -u open5gs-pcfd -u open5gs-bsfd \
                --since '${COMBO_START}' --no-pager" \
                > "${raw_dir}/amf.log" 2>&1
            ;;
        free5gc)
            ssh_core "sed 's/\x1b\[[0-9;]*m//g' /tmp/free5gc.log" > "${raw_dir}/free5gc.log" 2>&1
            ;;
    esac
}

# OCUDU writes its internal log (/tmp/gnb.log) when it exits
collect_gnb_logs() {
    local ran=$1
    local raw_dir=$2
    [ "$ran" = "ocudu" ] && cp /tmp/gnb.log "${raw_dir}/gnb_internal.log" 2>/dev/null
}

# On failure: record the reason, keep the logs, add a FAIL row to the CSV
# (so repeated runs never silently lose samples), then clean up.
fail_combination() {
    local core=$1
    local ran=$2
    local raw_dir=$3
    local reason=$4
    log_err "$reason"
    echo "FAILED: ${reason} ($(date))" > "${raw_dir}/FAILED.txt"
    collect_core_logs "$core" "$raw_dir"
    append_csv "${BASE_DIR}/all_results.csv" "$core" "$ran" "$raw_dir" "FAIL"
    stop_ran_processes
    collect_gnb_logs "$ran" "$raw_dir"
    stop_core $core
    return 1
}

run_combination() {
    local core=$1
    local ran=$2

    CORE=$core
    local combo_name="${core}_${ran}_phone"
    local combo_dir="${BASE_DIR}/round${CURRENT_ROUND}/${combo_name}"
    local raw_dir="${combo_dir}/raw"
    RAW_DIR="$raw_dir"

    mkdir -p "${raw_dir}"
    UE_IP=""
    ATTACH_WAIT=0
    RAN_WATTS=""; RAN_JOULES=""; CORE_WATTS=""; CORE_JOULES=""
    COMBO_START=$(ssh_core "date '+%Y-%m-%d %H:%M:%S'")
    [ -z "$COMBO_START" ] && COMBO_START="15 minutes ago"

    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  TESTING: $(echo $core | tr '[:lower:]' '[:upper:]') + $(ran_label $ran) + PHONE   [round ${CURRENT_ROUND}/${ROUNDS}]${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"

    # ── STEP 1: Start core ────────────────────────────────────────────────────
    log "STEP 1: Starting core network ($core)..."
    case $core in
        open5gs) start_open5gs ;;
        free5gc) start_free5gc "$raw_dir" ;;
    esac || { fail_combination $core $ran "$raw_dir" "Core failed to start"; return 1; }

    # ── STEP 2: Start gNB ────────────────────────────────────────────────────
    log "STEP 2: Starting gNB ($(ran_label $ran))..."
    case $ran in
        oai)   start_gnb_oai "$raw_dir" ;;
        ocudu) start_gnb_ocudu "$raw_dir" ;;
    esac || { fail_combination $core $ran "$raw_dir" "gNB failed to start"; return 1; }

    # ── STEP 3: Wait for the phone ───────────────────────────────────────────
    log "STEP 3: Waiting for the phone to attach (checking every ${UE_POLL_INTERVAL}s, max ${WAIT_UE_CONNECT}s)..."
    if wait_for_phone; then
        log_ok "Phone attached: IP=${UE_IP} (after ~${ATTACH_WAIT}s)"
        echo "$(date +%T) attached, IP ${UE_IP} (after ~${ATTACH_WAIT}s)" > "${raw_dir}/phone_ip.txt"
    else
        UE_IP=""
        fail_combination $core $ran "$raw_dir" "Phone did not attach (run skipped)"
        return 1
    fi

    # ── STEP 4: NAT on core (internet for the phone) ──────────────────────────
    log "STEP 4: Ensuring NAT is configured on core..."
    # 10.45.0.0/16 = Open5GS UE pool, 10.60.0.0/16 = Free5GC UE pool
    ssh_core "sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1; \
        for net in 10.45.0.0/16 10.60.0.0/16; do \
          sudo iptables -t nat -C POSTROUTING -s \$net -o eno1 -j MASQUERADE > /dev/null 2>&1 \
          || sudo iptables -t nat -A POSTROUTING -s \$net -o eno1 -j MASQUERADE; \
        done"

    # ── STEP 5: Run tests with power, CPU and radio measurement ───────────────
    log "STEP 5: Running benchmark tests..."
    # Long enough for ping + 3 iperf runs; stopped when the tests end
    local secs=$(( PING_COUNT / 2 + 3 * (IPERF_DURATION + 40) + 30 ))
    collect_cpu_ram "$raw_dir" "$(gnb_proc $ran)" "$secs"
    start_thermal_log "$raw_dir"
    start_radio_log "$ran" "$raw_dir"

    RAPL_RAN_START=$(read_rapl_ran)
    RAPL_CORE_START=$(read_rapl_core)
    POWER_START_TIME=$(date +%s)

    run_ping_test "$raw_dir"
    run_iperf_tests "$raw_dir"

    RAPL_RAN_END=$(read_rapl_ran)
    RAPL_CORE_END=$(read_rapl_core)
    POWER_END_TIME=$(date +%s)
    stop_radio_log "$ran" "$raw_dir"
    stop_thermal_log
    stop_cpu_ram
    ACTUAL_DURATION=$(( POWER_END_TIME - POWER_START_TIME ))
    [ $ACTUAL_DURATION -lt 1 ] && ACTUAL_DURATION=1

    # The RAPL counter wraps around (max_energy_range_uj); rapl_delta handles it
    local e_ran=$(rapl_delta "$RAPL_RAN_START" "$RAPL_RAN_END" "$(read_rapl_max_ran)")
    local e_core=$(rapl_delta "$RAPL_CORE_START" "$RAPL_CORE_END" "$(read_rapl_max_core)")
    if [ -n "$e_ran" ]; then
        RAN_JOULES=$(( e_ran / 1000000 ))
        RAN_WATTS=$(( e_ran / (ACTUAL_DURATION * 1000000) ))
    fi
    if [ -n "$e_core" ]; then
        CORE_JOULES=$(( e_core / 1000000 ))
        CORE_WATTS=$(( e_core / (ACTUAL_DURATION * 1000000) ))
    fi

    cat > "${raw_dir}/power_ran.txt" << EOF
RAPL Power Measurement - RAN Machine (${RAN_IP})
=================================================
Start energy (uJ) : ${RAPL_RAN_START}
End energy   (uJ) : ${RAPL_RAN_END}
Duration      (s) : ${ACTUAL_DURATION}
Total energy  (J) : ${RAN_JOULES}
Average power (W) : ${RAN_WATTS}
Timestamp         : $(date)
EOF

    cat > "${raw_dir}/power_core.txt" << EOF
RAPL Power Measurement - Core Machine (${CORE_IP})
===================================================
Start energy (uJ) : ${RAPL_CORE_START}
End energy   (uJ) : ${RAPL_CORE_END}
Duration      (s) : ${ACTUAL_DURATION}
Total energy  (J) : ${CORE_JOULES}
Average power (W) : ${CORE_WATTS}
Timestamp         : $(date)
EOF

    # ── Fixed-load test (resources for the same job) ──────────────────────────
    run_fixed_load_test "$raw_dir" "$ran"

    # ── STEP 6: Stop gNB, collect logs ────────────────────────────────────────
    log "STEP 6: Stopping gNB and collecting logs..."
    stop_ran_processes
    collect_gnb_logs "$ran" "$raw_dir"
    collect_core_logs "$core" "$raw_dir"

    # ── STEP 7: Generate report ───────────────────────────────────────────────
    log "STEP 7: Generating report..."
    generate_report "${combo_dir}/report.txt" "$raw_dir" "$core" "$ran"
    append_csv "${BASE_DIR}/all_results.csv" "$core" "$ran" "$raw_dir" "PASS"

    # ── STEP 8: Cleanup ───────────────────────────────────────────────────────
    log "STEP 8: Cleaning up..."
    stop_core $core

    log_ok "Run ${combo_name} complete. Results in: ${combo_dir}"
    echo ""
}

# =============================================================================
# COMPARISON REPORT
# =============================================================================

generate_comparison() {
    local comp_file="${BASE_DIR}/comparison.txt"

    cat > "$comp_file" << EOF
================================================================================
                5G TESTBED - REAL PHONE - ALL RUNS COMPARISON
================================================================================
  Generated : $(date '+%Y-%m-%d %H:%M:%S')
  Run ID    : ${TIMESTAMP}
================================================================================

EOF

    for combo_dir in "${BASE_DIR}"/round*/*/; do
        if [ -f "${combo_dir}/report.txt" ]; then
            local name="$(basename "$(dirname "$combo_dir")")/$(basename "$combo_dir")"
            echo "── ${name} ──────────────────────────────────────────────────────" >> "$comp_file"
            # Extract key metrics from each report
            grep -E "^  (FL |Cell |Downlink|Uplink|RTT Average|Jitter|Packet Loss|UDP Packet Loss|Average Power|Phone IP |Registration Time|PDU Session Setup|CQI|DL MCS|DL BLER|UL MCS|UL BLER|UL SNR|DL RSRP|DL SINR|UL RSRP)" \
                "${combo_dir}/report.txt" >> "$comp_file"
            echo "" >> "$comp_file"
        elif [ -f "${combo_dir}/raw/FAILED.txt" ]; then
            echo "── $(basename "$(dirname "$combo_dir")")/$(basename "$combo_dir") ── $(cat "${combo_dir}/raw/FAILED.txt")" >> "$comp_file"
            echo "" >> "$comp_file"
        fi
    done

    log_ok "Comparison report saved: $comp_file"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Please run with sudo: sudo $0 [core ran]"
        exit 1
    fi

    # Reject unknown names before anything starts
    if [ $# -ne 0 ]; then
        if [ $# -ne 2 ] || ! [[ "$1" =~ ^(open5gs|free5gc)$ ]] || ! [[ "$2" =~ ^(ocudu|oai)$ ]]; then
            echo "Usage: sudo $0 [core ran]   (none = all 4 combinations)"
            echo "  core: open5gs | free5gc"
            echo "  ran : ocudu | oai"
            exit 1
        fi
    fi

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           5G TESTBED - REAL PHONE BENCHMARK                  ║${NC}"
    echo -e "${GREEN}║           $(date '+%Y-%m-%d %H:%M:%S')                                ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    mkdir -p "${BASE_DIR}"
    # On exit: restore the CPU governors and hand results back to the invoking user
    trap 'restore_cpu_mode; [ -n "${SUDO_USER}" ] && chown -R "${SUDO_USER}:$(id -gn "${SUDO_USER}")" "${BASE_DIR}"' EXIT
    # Record the whole terminal session
    exec > >(tee -a "${BASE_DIR}/terminal_session.txt") 2>&1

    echo "$CSV_HEADER" > "${BASE_DIR}/all_results.csv"

    log "Results will be saved to: ${BASE_DIR}"
    # A previous run that was interrupted can leave the core/RAN running
    # (e.g. an AMF still holding its ports), so start from a clean state
    log "Making sure nothing from a previous run is still running..."
    stop_ran_processes
    stop_core open5gs
    stop_core free5gc
    set_performance_mode

    local combos="open5gs:ocudu open5gs:oai free5gc:ocudu free5gc:oai"
    [ $# -eq 2 ] && combos="$1:$2"

    for CURRENT_ROUND in $(seq 1 ${ROUNDS}); do
        echo ""
        log "════════ ROUND ${CURRENT_ROUND} of ${ROUNDS} ════════"
        local c
        for c in $combos; do
            run_combination "${c%%:*}" "${c##*:}"
        done
    done

    generate_comparison
    generate_summary "$SUMMARY_METRICS"

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ALL TESTS COMPLETE                                          ║${NC}"
    echo -e "${GREEN}║  Results: ${BASE_DIR}${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo "Output structure:"
    find "${BASE_DIR}" -type f | sort
}

main "$@"
