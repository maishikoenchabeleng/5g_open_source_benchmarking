#!/bin/bash
# =============================================================================
# 5G TESTBED BENCHMARK SCRIPT
# =============================================================================
# Tests all 6 combinations of RAN + Core on two separate machines
#
# RAN Machine  : administrator@137.158.126.24
# Core Machine : bluelabuser@137.158.126.21
#
# Combinations:
#   1. OAI-RAN    + Open5GS
#   2. OAI-RAN    + Free5GC
#   3. srsRAN     + Open5GS
#   4. srsRAN     + Free5GC
#   5. UERANSIM   + Open5GS
#   6. UERANSIM   + Free5GC
#
# Run with sudo:
#   sudo ./5g_benchmark.sh                 # all 6 combinations, ROUNDS times
#   sudo ./5g_benchmark.sh open5gs oai     # a single combination, ROUNDS times
#                                          # (core: open5gs|free5gc, ran: oai|srsran|ueransim)
#
# Rounds: every round runs each combination once (round-robin: A B C D E F,
# A B C D E F, ...), so slow drifts affect all combinations equally. Set
# ROUNDS below. summary.txt / summary.csv give mean, std, min, max, 95% CI.
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

# srsUE only: Open5GS AMF config without the phone PLMN 001/02 (see start_open5gs)
AMF_SRSUE_CONF="/etc/open5gs/amf_srsue.yaml"

# Test parameters
PING_COUNT=100
IPERF_DURATION=30
IPERF_SERVER_PORT=5201

# Number of rounds (each round = every combination once)
ROUNDS=3

# Fixed-load test: UDP at FIXED_RATE_MBPS in BOTH directions at the same time,
# CPU/RAM/power measured only during it (same job for every combination)
FIXED_RATE_MBPS=5
FIXED_DURATION=60
FL_CLIENT_SIDE="ue"      # iperf3 client end: ue (simulated UE) or core (phone is the server)

# Timing (seconds to wait for each stage)
WAIT_CORE_START=15
WAIT_GNB_START=15
WAIT_UE_CONNECT=60

# Output directory
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BASE_DIR="/home/administrator/5g_benchmark_${TIMESTAMP}"

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

# Calculate power from two RAPL readings and duration
calc_power() {
    local e_start=$1
    local e_end=$2
    local duration=$3
    # Returns: joules watts (space separated)
    local joules=$(( ($e_end - $e_start) / 1000000 ))
    local watts=$(( ($e_end - $e_start) / ($duration * 1000000) ))
    echo "$joules $watts"
}

# Detect tunnel interface
get_tunnel() {
    local ran=$1
    case $ran in
        oai)      echo "oaitun_ue1" ;;
        srsran)   echo "tun_srsue" ;;
        ueransim) echo "uesimtun0" ;;
    esac
}

# Process names used for CPU/RAM lookups
gnb_proc() {
    case $1 in
        oai)      echo "nr-softmodem" ;;
        srsran)   echo "gnb" ;;
        ueransim) echo "nr-gnb" ;;
    esac
}

ue_proc() {
    case $1 in
        oai)      echo "nr-uesoftmodem" ;;
        srsran)   echo "srsue" ;;
        ueransim) echo "nr-ue" ;;
    esac
}

# Force traffic sourced from the UE IP out through the UE tunnel.
# Without this, iperf3 -B <ue_ip> only sets the source address and the
# packets can leave via eno1, bypassing the RAN/GTP path entirely.
UE_RT_TABLE=5000
setup_ue_routing() {
    local tun=$1
    local ue_ip=$2
    sudo ip rule del from "$ue_ip" table $UE_RT_TABLE 2>/dev/null
    sudo ip rule add from "$ue_ip" table $UE_RT_TABLE
    sudo ip route replace default dev "$tun" table $UE_RT_TABLE
}

clear_ue_routing() {
    while sudo ip rule del table $UE_RT_TABLE 2>/dev/null; do :; done
    sudo ip route flush table $UE_RT_TABLE 2>/dev/null
}

# Wait for tunnel interface to appear with IP
wait_for_tunnel() {
    local tun=$1
    local max_wait=$2
    local ran=$3
    local elapsed=0

    while [ $elapsed -lt $max_wait ]; do
        UE_IP=$(ip addr show "$tun" 2>/dev/null \
            | grep "inet " | awk '{print $2}' | cut -d/ -f1)

        if [ -n "$UE_IP" ]; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

# Stop all RAN processes cleanly
stop_ran_processes() {
    log "Stopping RAN processes..."
    clear_ue_routing
    # Match exact process names only (-x), so unrelated processes whose
    # command line merely contains "gnb" (editors, logs...) are left alone.
    local procs="nr-softmodem nr-uesoftmodem srsue gnb nr-gnb nr-ue odu"
    local p
    for p in $procs; do sudo pkill -INT -x "$p" 2>/dev/null; done
    sleep 3
    for p in $procs; do sudo pkill -9 -x "$p" 2>/dev/null; done
    # Stop any UERANSIM left on core machine from the old setup
    ssh_core "sudo pkill -9 -x nr-gnb 2>/dev/null; \
              sudo pkill -9 -x nr-ue 2>/dev/null; \
              echo done" > /dev/null 2>&1
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
            ssh_core "sudo pkill -9 -f '[f]ree5gc' 2>/dev/null; sudo ip link delete upfgtp 2>/dev/null; echo stopped"
            ;;
    esac
    sleep 5
}

# =============================================================================
# CORE START FUNCTIONS
# =============================================================================

start_open5gs() {
    local log_dir=$1
    local amf_conf=$2   # optional: run the AMF with this config instead of amf.yaml
    local amf_unit="open5gs-amfd"
    log "Starting Open5GS on core machine..."
    ssh_core "sudo systemctl start open5gs-nrfd open5gs-scpd \
        $([ -z "$amf_conf" ] && echo open5gs-amfd) \
        open5gs-smfd open5gs-upfd open5gs-ausfd open5gs-udmd open5gs-udrd \
        open5gs-pcfd open5gs-nssfd open5gs-bsfd open5gs-seppd 2>/dev/null" > /dev/null

    # srsUE can't decode the Registration Accept of the dual-PLMN amf.yaml
    # (001/01 + phone 001/02), so its AMF runs as a transient unit with its own
    # config. amf.yaml is untouched; "systemctl stop open5gs-*" stops it too.
    if [ -n "$amf_conf" ]; then
        amf_unit="open5gs-amfd-srsue"
        log "AMF config for srsUE: ${amf_conf}"
        ssh_core "sudo systemctl reset-failed ${amf_unit} 2>/dev/null; \
            sudo systemd-run --unit=${amf_unit} -p User=open5gs -p Group=open5gs \
            /usr/bin/open5gs-amfd -c ${amf_conf}" > /dev/null 2>&1
    fi
    ssh_core "sleep ${WAIT_CORE_START}" > /dev/null

    sleep ${WAIT_CORE_START}

    # Verify: count exact "active" lines ("inactive" also contains "active")
    local n_active=$(ssh_core "sudo systemctl is-active ${amf_unit} open5gs-smfd open5gs-upfd" | grep -c "^active$")
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
    log "Starting Free5GC on core machine..."
    ssh_core "sudo pkill -9 -f '[f]ree5gc' 2>/dev/null; sudo ip link delete upfgtp 2>/dev/null; true"
    ssh_core "cd /home/bluelabuser/free5gc; nohup ./run.sh > /tmp/free5gc.log 2>&1 < /dev/null &"

    # Poll AMF's N2 SCTP listener (ss -t misses SCTP sockets, so no -t here)
    local elapsed=0
    while [ $elapsed -lt ${WAIT_CORE_START} ]; do
        if ssh_core "ss -lnp 2>/dev/null | grep -q ':38412'; echo \$?" | grep -q "^0$"; then
            log_ok "Free5GC AMF is listening on SCTP 38412 (${elapsed}s)"
            # The UPF can exit on its own (e.g. leftover upfgtp: "open Gtp5g:
            # open link: create: file exists") while the other NFs keep running
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

    ssh_core "cat /tmp/free5gc.log" > "${log_dir}/free5gc.log" 2>&1 &
    log_err "Free5GC AMF did not come up within ${WAIT_CORE_START}s"
    return 1
}

# =============================================================================
# RAN START FUNCTIONS
# =============================================================================

start_gnb_oai() {
    local log_dir=$1
    log "Starting OAI gNB..."
    cd /home/administrator/openairinterface5g/cmake_targets/ran_build/build

    sudo ./nr-softmodem \
        -O /home/administrator/openairinterface5g/targets/PROJECTS/GENERIC-NR-5GC/CONF/my.gnb.sa.band78.usrpb210.conf \
        --rfsim --gNBs.[0].min_rxtxtime 6 \
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

start_ue_oai() {
    local log_dir=$1
    log "Starting OAI UE..."
    cd /home/administrator/openairinterface5g/cmake_targets/ran_build/build

    sudo ./nr-uesoftmodem \
        --band 78 -r 106 --numerology 1 \
        -C 3619200000 --ssb 516 \
        --rfsim \
        -O /home/administrator/openairinterface5g/targets/PROJECTS/GENERIC-NR-5GC/CONF/ue-sim.conf \
        > "${log_dir}/ue.log" 2>&1 &

    UE_PID=$!
    log_ok "OAI UE started (PID: $UE_PID)"
}

start_gnb_srsran() {
    local log_dir=$1
    log "Starting srsRAN gNB..."

    sudo gnb -c /home/administrator/ocudu/configs/my_gnb_srsue.yml \
        > "${log_dir}/gnb.log" 2>&1 &

    GNB_PID=$!
    sleep ${WAIT_GNB_START}

    if ps -p $GNB_PID > /dev/null 2>&1; then
        log_ok "srsRAN gNB started (PID: $GNB_PID)"
        return 0
    else
        log_err "srsRAN gNB failed to start"
        return 1
    fi
}

start_ue_srsran() {
    local log_dir=$1
    log "Starting srsUE..."
    cd /home/administrator/srsRAN_4G/srsue

    sudo /home/administrator/srsRAN_4G/build/srsue/src/srsue ue.conf \
        > "${log_dir}/ue.log" 2>&1 &

    UE_PID=$!
    log_ok "srsUE started (PID: $UE_PID)"
}

start_gnb_ueransim() {
    local core=$1
    local log_dir=$2
    log "Starting UERANSIM gNB..."
    cd /home/administrator/UERANSIM/build

    sudo ./nr-gnb -c ../config/${core}-gnb.yaml \
        > "${log_dir}/gnb.log" 2>&1 &

    GNB_PID=$!
    sleep ${WAIT_GNB_START}

    if ps -p $GNB_PID > /dev/null 2>&1 && grep -q "NG Setup procedure is successful" "${log_dir}/gnb.log"; then
        log_ok "UERANSIM gNB started (PID: $GNB_PID)"
        return 0
    else
        log_err "UERANSIM gNB failed to start (see gnb.log)"
        return 1
    fi
}

start_ue_ueransim() {
    local core=$1
    local log_dir=$2
    log "Starting UERANSIM UE..."
    cd /home/administrator/UERANSIM/build

    sudo ./nr-ue -c ../config/${core}-ue.yaml \
        > "${log_dir}/ue.log" 2>&1 &

    UE_PID=$!
    log_ok "UERANSIM UE started (PID: $UE_PID)"
}


# =============================================================================
# METRICS COLLECTION
# =============================================================================

collect_cpu_ram() {
    local log_dir=$1
    local gnb_name=$2
    local ue_name=$3

    # -u and -r share one file: both must append (>>) and write whole lines
    # (--line-buffered), otherwise the -u writer overwrites the -r lines.
    : > "${log_dir}/cpu_ran.txt"
    : > "${log_dir}/cpu_core.txt"

    log "Collecting CPU/RAM on RAN machine..."
    LC_ALL=C pidstat -u -p ALL 1 180 \
        | grep --line-buffered -E "${gnb_name}|${ue_name}" \
        >> "${log_dir}/cpu_ran.txt" 2>&1 &
    CPU_RAN_PID=$!

    LC_ALL=C pidstat -r -p ALL 1 180 \
        | grep --line-buffered -E "${gnb_name}|${ue_name}" \
        >> "${log_dir}/cpu_ran.txt" 2>&1 &

    log "Collecting CPU/RAM on core machine..."
    ssh_core "LC_ALL=C pidstat -u -p ALL 1 180 \
        | grep --line-buffered -E 'open5gs|free5gc|upf|amf|smf'" \
        >> "${log_dir}/cpu_core.txt" 2>&1 &
    CPU_CORE_PID=$!

    ssh_core "LC_ALL=C pidstat -r -p ALL 1 180 \
        | grep --line-buffered -E 'open5gs|free5gc|upf|amf|smf'" \
        >> "${log_dir}/cpu_core.txt" 2>&1 &
}

run_iperf_tests() {
    local log_dir=$1
    local tun=$2
    local ue_ip=$3
    local ran=$4
    # A stuck iperf3 (e.g. dead tunnel) must not hang the whole run
    local iperf_timeout=$(( IPERF_DURATION + 30 ))

    # UDP first (tunnel freshest)
    log "Running UDP test for jitter (${IPERF_DURATION}s)..."
    ssh_core "pkill -x iperf3 2>/dev/null; sleep 2; nohup iperf3 -s -B ${CORE_IP} --port ${IPERF_SERVER_PORT} > /tmp/iperf_server.log 2>&1 & disown"
    sleep 5
    timeout ${iperf_timeout} iperf3 -c ${CORE_IP} -B ${ue_ip} -u -b 2M -l 1200 -t ${IPERF_DURATION} -p ${IPERF_SERVER_PORT} \
        > "${log_dir}/iperf_udp.txt" 2>&1

    # Then TCP DL
    log "Running TCP downlink test (${IPERF_DURATION}s)..."
    ssh_core "pkill -x iperf3 2>/dev/null; sleep 2; nohup iperf3 -s -B ${CORE_IP} --port ${IPERF_SERVER_PORT} > /tmp/iperf_server.log 2>&1 & disown"
    sleep 5
    # -R: server (core) sends, UE receives = downlink
    timeout ${iperf_timeout} iperf3 -c ${CORE_IP} -B ${ue_ip} -R -t ${IPERF_DURATION} -p ${IPERF_SERVER_PORT} \
        > "${log_dir}/iperf_tcp_dl.txt" 2>&1

    # Then TCP UL
    log "Running TCP uplink test (${IPERF_DURATION}s)..."
    ssh_core "pkill -x iperf3 2>/dev/null; sleep 2; nohup iperf3 -s -B ${CORE_IP} --port ${IPERF_SERVER_PORT} > /tmp/iperf_server.log 2>&1 & disown"
    sleep 5
    # No -R: client (UE) sends = uplink
    timeout ${iperf_timeout} iperf3 -c ${CORE_IP} -B ${ue_ip} -t ${IPERF_DURATION} -p ${IPERF_SERVER_PORT} \
        > "${log_dir}/iperf_tcp_ul.txt" 2>&1

    ssh_core "pkill -x iperf3 2>/dev/null"
}


run_ping_test() {
    local log_dir=$1
    local tun=$2
    local ran=$3

    log "Running ping test to core machine via ${tun} (10 packets)..."
    ping -I ${tun} ${CORE_IP} -c 10 -i 0.5 \
        > "${log_dir}/ping_core.txt" 2>&1

    log "Running ping test (${PING_COUNT} packets)..."
    ping -I ${tun} 8.8.8.8 -c ${PING_COUNT} -i 0.5 \
        > "${log_dir}/ping_100.txt" 2>&1
}

measure_power() {
    local log_dir=$1
    local duration=$2

    log "Measuring power via RAPL (${duration}s)..."

    # Read start values
    RAPL_RAN_START=$(read_rapl_ran)
    RAPL_CORE_START=$(read_rapl_core)
    POWER_START_TIME=$(date +%s)

    # Wait for duration (iperf runs during this)
    sleep ${duration}

    # Read end values
    RAPL_RAN_END=$(read_rapl_ran)
    RAPL_CORE_END=$(read_rapl_core)
    POWER_END_TIME=$(date +%s)
    ACTUAL_DURATION=$(( POWER_END_TIME - POWER_START_TIME ))

    # Calculate
    RAN_JOULES=$(( (RAPL_RAN_END - RAPL_RAN_START) / 1000000 ))
    RAN_WATTS=$(( (RAPL_RAN_END - RAPL_RAN_START) / (ACTUAL_DURATION * 1000000) ))
    CORE_JOULES=$(( (RAPL_CORE_END - RAPL_CORE_START) / 1000000 ))
    CORE_WATTS=$(( (RAPL_CORE_END - RAPL_CORE_START) / (ACTUAL_DURATION * 1000000) ))

    # Save raw readings
    cat > "${log_dir}/power_ran.txt" << EOF
RAPL Power Measurement - RAN Machine
=====================================
Start energy (uJ) : ${RAPL_RAN_START}
End energy   (uJ) : ${RAPL_RAN_END}
Duration      (s) : ${ACTUAL_DURATION}
Total energy  (J) : ${RAN_JOULES}
Average power (W) : ${RAN_WATTS}
Timestamp         : $(date)
EOF

    cat > "${log_dir}/power_core.txt" << EOF
RAPL Power Measurement - Core Machine
======================================
Start energy (uJ) : ${RAPL_CORE_START}
End energy   (uJ) : ${RAPL_CORE_END}
Duration      (s) : ${ACTUAL_DURATION}
Total energy  (J) : ${CORE_JOULES}
Average power (W) : ${CORE_WATTS}
Timestamp         : $(date)
EOF
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

# TCP throughput from the receiver line (what was actually delivered).
# With rfsim/ZMQ the sender can report more than arrived (data queued in
# the UE and drained after the 30s). Converted to Mbps.
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
# For RSS, pidstat's own end-of-run "Average:" lines are used when present
# (runs before 2026-09-29 lost most per-second -r lines, see collect_cpu_ram).
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
# Works for Open5GS (journalctl) and Free5GC log formats. Prints "reg pdu".
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
    !done && /Registration request|Handle Registration Request/ { req = t_ms($0); have_req = (req >= 0) }
    !done && have_req && /Registration complete|Handle Registration Complete/ { comp = t_ms($0); done = (comp >= 0); next }
    done && !have_ip && /IPv4\[|Allocated UE IP address/ { ip = t_ms($0); have_ip = (ip >= 0) }
    END {
        if (!done) { print "N/A N/A"; exit }
        r = comp - req; if (r < 0) r += 86400000
        if (have_ip) { p = ip - comp; if (p < 0) p += 86400000 } else p = "N/A"
        print r, p
    }' "$file"
}

# Core log saved for this combination
core_log_file() {
    case $1 in
        open5gs) echo "$2/amf.log" ;;
        free5gc) echo "$2/free5gc.log" ;;
    esac
}

# =============================================================================
# PERFORMANCE MODE, TEMPERATURE LOGGING, ROUNDS SUMMARY
# =============================================================================

# CPU governor "performance" on the RAN machine for the whole run (full clock
# speed instead of load-dependent scaling). The original governor is restored
# on exit (see the EXIT trap in main). The core machine is left unchanged: with
# the core in "performance", free5gc + srsRAN downlink collapsed to ~2-8 Mbit/s
# (tested 2026-09-29; ~52 Mbit/s in powersave), and its light load does not
# benefit from it.
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
    ssh_core "pkill -x iperf3 2>/dev/null; sleep 2; nohup iperf3 -s -B ${CORE_IP} --port ${IPERF_SERVER_PORT} > /tmp/iperf_server.log 2>&1 & disown"
    sleep 5
    collect_cpu_ram "$d" "$(gnb_proc $ran)" "$(ue_proc $ran)"
    # Whole-machine CPU on both machines (mpstat, every second)
    LC_ALL=C mpstat 1 $(( FIXED_DURATION + 60 )) > "${d}/mpstat_ran.txt" 2>&1 &
    local mp_ran_pid=$!
    ssh_core "LC_ALL=C mpstat 1 $(( FIXED_DURATION + 60 ))" > "${d}/mpstat_core.txt" 2>&1 &
    local mp_core_pid=$!
    local s_ran=$(read_rapl_ran) s_core=$(read_rapl_core) t0=$(date +%s)
    timeout $(( FIXED_DURATION + 30 )) iperf3 -c ${CORE_IP} -B ${UE_IP} -p ${IPERF_SERVER_PORT} \
        -u -b ${FIXED_RATE_MBPS}M -l 1200 -t ${FIXED_DURATION} --bidir > "${d}/iperf_fixed.txt" 2>&1
    local e_ran=$(read_rapl_ran) e_core=$(read_rapl_core) t1=$(date +%s)
    kill $mp_ran_pid 2>/dev/null
    ssh_core "pkill -x mpstat 2>/dev/null; true"
    wait $mp_ran_pid $mp_core_pid 2>/dev/null
    pkill -x pidstat 2>/dev/null
    ssh_core "pkill -x pidstat 2>/dev/null; pkill -x iperf3 2>/dev/null; true"
    wait $CPU_RAN_PID $CPU_CORE_PID 2>/dev/null
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
    local tun=$5

    # Parse all metrics
    local ping_results=$(parse_ping "${raw_dir}/ping_100.txt")
    local ping_loss=$(echo $ping_results | awk '{print $1}')
    local rtt_min=$(echo $ping_results | awk '{print $2}')
    local rtt_avg=$(echo $ping_results | awk '{print $3}')
    local rtt_max=$(echo $ping_results | awk '{print $4}')
    local rtt_mdev=$(echo $ping_results | awk '{print $5}')

    local tcp_dl=$(parse_iperf_tcp "${raw_dir}/iperf_tcp_dl.txt")
    local tcp_ul=$(parse_iperf_tcp "${raw_dir}/iperf_tcp_ul.txt")

    local udp_results=$(parse_iperf_udp "${raw_dir}/iperf_udp.txt")
    local udp_mbps=$(echo $udp_results | awk '{print $1}')
    local jitter=$(echo $udp_results | awk '{print $2}')
    local udp_loss=$(echo $udp_results | awk '{print $3}')

    # CPU/RAM
    local gnb_cpu gnb_cpu_peak ue_cpu ue_cpu_peak
    case $ran in
        oai)
            read gnb_cpu gnb_cpu_peak <<< $(parse_cpu "${raw_dir}/cpu_ran.txt" "nr-softmodem")
            read ue_cpu ue_cpu_peak   <<< $(parse_cpu "${raw_dir}/cpu_ran.txt" "nr-uesoftmodem")
            ;;
        srsran)
            read gnb_cpu gnb_cpu_peak <<< $(parse_cpu "${raw_dir}/cpu_ran.txt" "gnb")
            read ue_cpu ue_cpu_peak   <<< $(parse_cpu "${raw_dir}/cpu_ran.txt" "srsue")
            ;;
        ueransim)
            read gnb_cpu gnb_cpu_peak <<< $(parse_cpu "${raw_dir}/cpu_ran.txt" "nr-gnb")
            read ue_cpu ue_cpu_peak   <<< $(parse_cpu "${raw_dir}/cpu_ran.txt" "nr-ue")
            ;;
    esac

    local amf_cpu smf_cpu upf_cpu
    read amf_cpu _ <<< $(parse_cpu "${raw_dir}/cpu_core.txt" "amf")
    read smf_cpu _ <<< $(parse_cpu "${raw_dir}/cpu_core.txt" "smf")
    read upf_cpu _ <<< $(parse_cpu "${raw_dir}/cpu_core.txt" "upf")

    # Power
    local ran_watts ran_joules core_watts core_joules
    ran_joules=${RAN_JOULES:-N/A}
    ran_watts=${RAN_WATTS:-N/A}
    core_joules=${CORE_JOULES:-N/A}
    core_watts=${CORE_WATTS:-N/A}

    # Registration / PDU session setup times from the core log
    local reg_ms pdu_ms
    read reg_ms pdu_ms <<< $(parse_reg_times "$(core_log_file $core "$raw_dir")")

    # Temperature / CPU frequency during the tests
    local rta rtm rf rth cta ctm cf cth
    read rta rtm rf rth <<< $(parse_thermal "${raw_dir}/thermal_ran.txt")
    read cta ctm cf cth <<< $(parse_thermal "${raw_dir}/thermal_core.txt")

    # Connectivity check
    local conn_status="PASS"
    local ping_status="PASS"
    local gw_status="PASS"
    [ "$ping_loss" = "100" ] && ping_status="FAIL"
    [ -z "$UE_IP" ] && conn_status="FAIL"
    local gw_loss=$(parse_ping "${raw_dir}/ping_core.txt" | awk '{print $1}')
    { [ "$gw_loss" = "100" ] || [ "$gw_loss" = "N/A" ]; } && gw_status="FAIL"

    local path_line=$(grep "^Route for UE traffic" "${raw_dir}/tunnel_proof.txt" 2>/dev/null | cut -d: -f2-)
    local tun_rx=$(grep "^rx (downlink)" "${raw_dir}/tunnel_proof.txt" 2>/dev/null | awk '{print $NF}')
    local tun_tx=$(grep "^tx (uplink)" "${raw_dir}/tunnel_proof.txt" 2>/dev/null | awk '{print $NF}')

    # Write report
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
    local fl_ue_cpu fl_ue_pk
    read fl_ue_cpu fl_ue_pk <<< $(parse_cpu "${raw_dir}/fixed_load/cpu_ran.txt" "$(ue_proc $ran)")
    local fl_amf_cpu; read fl_amf_cpu _ <<< $(parse_cpu "${raw_dir}/fixed_load/cpu_core.txt" "amf")
    local fl_smf_cpu; read fl_smf_cpu _ <<< $(parse_cpu "${raw_dir}/fixed_load/cpu_core.txt" "smf")
    local fl_upf_cpu; read fl_upf_cpu _ <<< $(parse_cpu "${raw_dir}/fixed_load/cpu_core.txt" "upf")

    cat > "$report_file" << EOF
================================================================================
                        5G TESTBED BENCHMARK REPORT
================================================================================
  Generated  : $(date '+%Y-%m-%d %H:%M:%S')
  Report for : $(echo $core | tr '[:lower:]' '[:upper:]') + $(echo $ran | tr '[:lower:]' '[:upper:]')
  Round      : ${CURRENT_ROUND} of ${ROUNDS}
================================================================================

────────────────────────────────────────────────────────────────────────────────
 TEST CONFIGURATION
────────────────────────────────────────────────────────────────────────────────
  Core Network      : $(echo $core | tr '[:lower:]' '[:upper:]')
  RAN Stack         : $(echo $ran | tr '[:lower:]' '[:upper:]')
  RAN Machine IP    : ${RAN_IP}
  Core Machine IP   : ${CORE_IP}
  Tunnel Interface  : ${tun}
  UE IP Assigned    : ${UE_IP:-N/A}
  Ping Count        : ${PING_COUNT} packets
  Iperf Duration    : ${IPERF_DURATION} seconds
  Test Timestamp    : $(date '+%Y-%m-%d %H:%M:%S')

────────────────────────────────────────────────────────────────────────────────
 CONNECTIVITY
────────────────────────────────────────────────────────────────────────────────
  UE Registration         : ${conn_status}
  UE IP Assigned          : ${UE_IP:-N/A}
  Tunnel Interface Up     : ${tun}
  UE traffic route        :${path_line:- N/A}
  Core Reachable (tunnel) : ${gw_status}  (10 pings to ${CORE_IP} via ${tun}, loss ${gw_loss} %)
  Internet Reachable      : ${ping_status}

────────────────────────────────────────────────────────────────────────────────
 REGISTRATION  (from core network logs)
────────────────────────────────────────────────────────────────────────────────
  Registration Time       : ${reg_ms} ms   (AMF: Registration Request -> Registration Complete)
  PDU Session Setup Time  : ${pdu_ms} ms   (Registration Complete -> UE IP allocated by SMF)

────────────────────────────────────────────────────────────────────────────────
 LATENCY  (${PING_COUNT} ICMP packets via ${tun} to 8.8.8.8)
────────────────────────────────────────────────────────────────────────────────
  Packets Sent            : ${PING_COUNT}
  Packet Loss             : ${ping_loss} %
  RTT Minimum             : ${rtt_min} ms
  RTT Average             : ${rtt_avg} ms
  RTT Maximum             : ${rtt_max} ms
  RTT Std Deviation       : ${rtt_mdev} ms

────────────────────────────────────────────────────────────────────────────────
 JITTER  (UDP iperf3, ${IPERF_DURATION}s via ${tun})
────────────────────────────────────────────────────────────────────────────────
  UDP Throughput          : ${udp_mbps} Mbps
  Jitter                  : ${jitter} ms
  UDP Packet Loss         : ${udp_loss}

────────────────────────────────────────────────────────────────────────────────
 THROUGHPUT  (TCP iperf3, ${IPERF_DURATION}s via ${tun}, receiver side)
────────────────────────────────────────────────────────────────────────────────
  Downlink                : ${tcp_dl} Mbps
  Uplink                  : ${tcp_ul} Mbps

  Bytes through ${tun} during all tests (proof traffic used the 5G path):
  Received (downlink)     : ${tun_rx:-N/A} bytes
  Sent     (uplink)       : ${tun_tx:-N/A} bytes

────────────────────────────────────────────────────────────────────────────────
 CPU USAGE  (pidstat, sampled every 1s during the performance tests; 100% = one core)
────────────────────────────────────────────────────────────────────────────────
  [ RAN Machine : ${RAN_IP} ]
  gNB Process             : avg ${gnb_cpu} %   peak ${gnb_cpu_peak} %
  UE  Process             : avg ${ue_cpu} %    peak ${ue_cpu_peak} %

  [ Core Machine : ${CORE_IP} ]
  AMF                     : avg ${amf_cpu} %
  SMF                     : avg ${smf_cpu} %
  UPF                     : avg ${upf_cpu} %

────────────────────────────────────────────────────────────────────────────────
 MEMORY USAGE  (pidstat RSS, during the performance tests)
────────────────────────────────────────────────────────────────────────────────
  [ RAN Machine ]
  gNB RSS                 : $(parse_ram "${raw_dir}/cpu_ran.txt" "$(gnb_proc $ran)") KB
  UE  RSS                 : $(parse_ram "${raw_dir}/cpu_ran.txt" "$(ue_proc $ran)") KB

  [ Core Machine ]
  AMF RSS                 : $(parse_ram "${raw_dir}/cpu_core.txt" "amf") KB
  SMF RSS                 : $(parse_ram "${raw_dir}/cpu_core.txt" "smf") KB
  UPF RSS                 : $(parse_ram "${raw_dir}/cpu_core.txt" "upf") KB

────────────────────────────────────────────────────────────────────────────────
 POWER CONSUMPTION  (Intel RAPL, measured during the performance tests)
────────────────────────────────────────────────────────────────────────────────
  [ RAN Machine : ${RAN_IP} ]
  Average Power           : ${ran_watts} W
  Total Energy            : ${ran_joules} J

  [ Core Machine : ${CORE_IP} ]
  Average Power           : ${core_watts} W
  Total Energy            : ${core_joules} J

────────────────────────────────────────────────────────────────────────────────
 FIXED-LOAD RESOURCES  (UDP ${FIXED_RATE_MBPS} Mbit/s DL + ${FIXED_RATE_MBPS} Mbit/s UL at once, ${FIXED_DURATION}s)
────────────────────────────────────────────────────────────────────────────────
  Same traffic for every combination: compare these values to see which
  combination needs fewer resources for the same job.
  Machine CPU = all cores incl. kernel work (e.g. free5gc gtp5g); use it,
  not the UPF process CPU, to compare the cores. 100 % = whole machine.
  FL Load Delivered       : DL ${fl_dl} Mbps (loss ${fl_dl_loss} %), UL ${fl_ul} Mbps (loss ${fl_ul_loss} %)
  FL Load Check           : ${fl_valid}   (VALID = both directions >= 95% of target, loss <= 5%)

  [ RAN Machine : ${RAN_IP} ]
  FL gNB CPU              : avg ${fl_gnb_cpu} %   peak ${fl_gnb_pk} %
  FL gNB RSS              : $(parse_ram "${raw_dir}/fixed_load/cpu_ran.txt" "$(gnb_proc $ran)") KB
  FL UE  CPU              : avg ${fl_ue_cpu} %   peak ${fl_ue_pk} %
  FL UE  RSS              : $(parse_ram "${raw_dir}/fixed_load/cpu_ran.txt" "$(ue_proc $ran)") KB
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
  raw/gnb.log             : gNB full terminal output with timestamps
  raw/ue.log              : UE full terminal output with timestamps
  raw/amf.log             : AMF/core journal logs
  raw/tunnel_proof.txt    : UE IP, route check, tunnel byte counters
  raw/ping_core.txt       : Ping to core machine via tunnel (10 packets)
  raw/ping_100.txt        : Full ping output (${PING_COUNT} packets)
  raw/iperf_tcp_dl.txt    : TCP downlink iperf3 full output
  raw/iperf_tcp_ul.txt    : TCP uplink iperf3 full output
  raw/iperf_udp.txt       : UDP jitter iperf3 full output
  raw/FAILED.txt          : Only present if the combination failed (reason)
  raw/cpu_ran.txt         : pidstat output - RAN machine
  raw/cpu_core.txt        : pidstat output - core machine
  raw/power_ran.txt       : RAPL power log - RAN machine
  raw/power_core.txt      : RAPL power log - core machine
  raw/fixed_load/         : Fixed-load test: iperf_fixed.txt, CPU/RAM, power
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

append_csv() {
    local csv_file=$1
    local core=$2
    local ran=$3
    local raw_dir=$4
    local status=${5:-PASS}

    local ping_results=$(parse_ping "${raw_dir}/ping_100.txt")
    local ping_loss=$(echo $ping_results | awk '{print $1}')
    local rtt_avg=$(echo $ping_results | awk '{print $3}')
    local rtt_mdev=$(echo $ping_results | awk '{print $5}')
    local tcp_dl=$(parse_iperf_tcp "${raw_dir}/iperf_tcp_dl.txt")
    local tcp_ul=$(parse_iperf_tcp "${raw_dir}/iperf_tcp_ul.txt")
    local udp_results=$(parse_iperf_udp "${raw_dir}/iperf_udp.txt")
    local jitter=$(echo $udp_results | awk '{print $2}')
    local udp_loss=$(echo $udp_results | awk '{print $3}')
    local reg_ms pdu_ms
    read reg_ms pdu_ms <<< $(parse_reg_times "$(core_log_file $core "$raw_dir")")
    local gnb_cpu ue_cpu
    read gnb_cpu _ <<< $(parse_cpu "${raw_dir}/cpu_ran.txt" "$(gnb_proc $ran)")
    read ue_cpu _ <<< $(parse_cpu "${raw_dir}/cpu_ran.txt" "$(ue_proc $ran)")
    local ran_th core_th
    ran_th=$(parse_thermal "${raw_dir}/thermal_ran.txt" | tr ' ' ',')
    core_th=$(parse_thermal "${raw_dir}/thermal_core.txt" | tr ' ' ',')

    # Fixed-load test; resource values only if the load was fully delivered
    local fl_dl fl_dl_loss fl_ul fl_ul_loss fl_valid fl_rw fl_rj fl_cw fl_cj fl_res
    read fl_dl fl_dl_loss fl_ul fl_ul_loss <<< $(fixed_load_rates "${raw_dir}/fixed_load/iperf_fixed.txt")
    fl_valid=$(fixed_load_check $fl_dl $fl_dl_loss $fl_ul $fl_ul_loss)
    read fl_rw fl_rj fl_cw fl_cj <<< $(fixed_load_power "${raw_dir}/fixed_load")
    fl_res="$(parse_cpu "${raw_dir}/fixed_load/cpu_ran.txt" "$(gnb_proc $ran)" | cut -d" " -f1),$(parse_cpu "${raw_dir}/fixed_load/cpu_ran.txt" "$(ue_proc $ran)" | cut -d" " -f1),$(parse_ram "${raw_dir}/fixed_load/cpu_ran.txt" "$(gnb_proc $ran)"),$(parse_ram "${raw_dir}/fixed_load/cpu_ran.txt" "$(ue_proc $ran)"),$(parse_cpu "${raw_dir}/fixed_load/cpu_core.txt" "upf" | cut -d" " -f1),${fl_rw},${fl_rj},${fl_cw},${fl_cj},$(parse_mpstat "${raw_dir}/fixed_load/mpstat_ran.txt" | cut -d" " -f1),$(parse_mpstat "${raw_dir}/fixed_load/mpstat_ran.txt" | cut -d" " -f5),$(parse_mpstat "${raw_dir}/fixed_load/mpstat_core.txt" | cut -d" " -f1),$(parse_mpstat "${raw_dir}/fixed_load/mpstat_core.txt" | cut -d" " -f5)"
    [ "$fl_valid" = "VALID" ] || fl_res=$(printf "N/A%.0s," $(seq 1 13) | sed "s/,$//")

    echo "${TIMESTAMP},${core},${ran},${status},${UE_IP:-N/A},${ping_loss},${rtt_avg},${rtt_mdev},${tcp_dl},${tcp_ul},${jitter},${udp_loss},${RAN_WATTS:-N/A},${RAN_JOULES:-N/A},${CORE_WATTS:-N/A},${CORE_JOULES:-N/A},${reg_ms},${pdu_ms},${gnb_cpu},${ue_cpu},${ran_th},${core_th},${CURRENT_ROUND},${fl_dl},${fl_ul},${fl_dl_loss},${fl_ul_loss},${fl_valid},${fl_res}" \
        >> "$csv_file"
}

# =============================================================================
# RUN ONE COMBINATION
# =============================================================================

# Core logs for this combination only (COMBO_START is the core machine's
# clock at the start of the combination, so logs never overlap)
collect_core_logs() {
    local core=$1
    local raw_dir=$2
    case $core in
        open5gs)
            ssh_core "sudo journalctl -u open5gs-amfd -u open5gs-amfd-srsue -u open5gs-smfd \
                -u open5gs-upfd -u open5gs-pcfd -u open5gs-bsfd \
                --since '${COMBO_START}' --no-pager" \
                > "${raw_dir}/amf.log" 2>&1
            ;;
        free5gc)
            ssh_core "cat /tmp/free5gc.log" > "${raw_dir}/free5gc.log" 2>&1
            ;;
    esac
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
    stop_core $core
    return 1
}

run_combination() {
    local core=$1
    local ran=$2

    local combo_name="${core}_${ran}"
    local combo_dir="${BASE_DIR}/round${CURRENT_ROUND}/${combo_name}"
    local raw_dir="${combo_dir}/raw"

    mkdir -p "${raw_dir}"
    UE_IP=""
    RAN_WATTS=""; RAN_JOULES=""; CORE_WATTS=""; CORE_JOULES=""
    COMBO_START=$(ssh_core "date '+%Y-%m-%d %H:%M:%S'")
    [ -z "$COMBO_START" ] && COMBO_START="15 minutes ago"

    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  TESTING: $(echo $core | tr '[:lower:]' '[:upper:]') + $(echo $ran | tr '[:lower:]' '[:upper:]')   [round ${CURRENT_ROUND}/${ROUNDS}]${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"

    local tun=$(get_tunnel $ran)

    # ── STEP 1: Start core ────────────────────────────────────────────────────
    log "STEP 1: Starting core network ($core)..."
    case $core in
        open5gs)
            start_open5gs "$raw_dir" "$([ "$ran" = srsran ] && echo "$AMF_SRSUE_CONF")" || { fail_combination $core $ran "$raw_dir" "Core failed to start"; return 1; }
            ;;
        free5gc)
            start_free5gc "$raw_dir" || { fail_combination $core $ran "$raw_dir" "Core failed to start"; return 1; }
            ;;
    esac

    # ── STEP 2: Start gNB ────────────────────────────────────────────────────
    log "STEP 2: Starting gNB ($ran)..."
    case $ran in
        oai)      start_gnb_oai "$raw_dir" || { fail_combination $core $ran "$raw_dir" "gNB failed to start"; return 1; } ;;
        srsran)   start_gnb_srsran "$raw_dir" || { fail_combination $core $ran "$raw_dir" "gNB failed to start"; return 1; } ;;
        ueransim) start_gnb_ueransim "$core" "$raw_dir" || { fail_combination $core $ran "$raw_dir" "gNB failed to start"; return 1; } ;;
    esac

    # ── STEP 3: Start UE ─────────────────────────────────────────────────────
    log "STEP 3: Starting UE ($ran)..."
    case $ran in
        oai)      start_ue_oai "$raw_dir" ;;
        srsran)   start_ue_srsran "$raw_dir" ;;
        ueransim) start_ue_ueransim "$core" "$raw_dir" ;;
    esac

    # ── STEP 4: Wait for tunnel ───────────────────────────────────────────────
    log "STEP 4: Waiting for UE to connect (max ${WAIT_UE_CONNECT}s)..."
    if wait_for_tunnel "$tun" "$WAIT_UE_CONNECT" "$ran"; then
        log_ok "UE connected: IP=${UE_IP} on ${tun}"
        setup_ue_routing "$tun" "$UE_IP"

        # Check that UE-sourced traffic really goes through the tunnel
        # (otherwise iperf3 -B <ue_ip> measures eno1 at ~900 Mbit/s)
        local route=$(ip route get ${CORE_IP} from ${UE_IP} 2>/dev/null | head -1)

        # Save proof of tunnel being up
        {
            echo "=== Tunnel Interface State ==="
            echo "Timestamp: $(date)"
            ip addr show "$tun"
            echo ""
            echo "Route for UE traffic: ${route}"
            echo ""
            echo "=== Policy rules ==="
            ip rule show
            echo ""
            echo "=== Routing Table ==="
            ip route show
        } > "${raw_dir}/tunnel_proof.txt"

        if echo "$route" | grep -q "dev ${tun}"; then
            log_ok "UE traffic routed via ${tun}"
        else
            fail_combination $core $ran "$raw_dir" "UE traffic would bypass ${tun} (${route})"
            return 1
        fi
    else
        UE_IP=""
        fail_combination $core $ran "$raw_dir" "UE did not connect within ${WAIT_UE_CONNECT}s"
        return 1
    fi

    # ── STEP 5: NAT on core ───────────────────────────────────────────────────
    log "STEP 5: Ensuring NAT is configured on core..."
    # 10.45.0.0/16 = Open5GS UE pool, 10.60.0.0/16 = Free5GC UE pool
    ssh_core "sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1; \
        for net in 10.45.0.0/16 10.60.0.0/16; do \
          sudo iptables -t nat -C POSTROUTING -s \$net -o eno1 -j MASQUERADE > /dev/null 2>&1 \
          || sudo iptables -t nat -A POSTROUTING -s \$net -o eno1 -j MASQUERADE; \
        done"

    # ── STEP 6: Run tests with power + CPU measurement ────────────────────────
    log "STEP 6: Running benchmark tests..."

    # Start CPU/RAM collection in background
    collect_cpu_ram "$raw_dir" \
        "$(gnb_proc $ran)" "$(ue_proc $ran)"
    start_thermal_log "$raw_dir"

    # Start RAPL power measurement in background
    RAPL_RAN_START=$(read_rapl_ran)
    RAPL_CORE_START=$(read_rapl_core)
    POWER_START_TIME=$(date +%s)

    local tun_rx0=$(cat /sys/class/net/$tun/statistics/rx_bytes 2>/dev/null || echo 0)
    local tun_tx0=$(cat /sys/class/net/$tun/statistics/tx_bytes 2>/dev/null || echo 0)

    # Run ping test
    run_ping_test "$raw_dir" "$tun" "$ran"

    # Run iperf tests
    run_iperf_tests "$raw_dir" "$tun" "$UE_IP" "$ran"

    {
        echo ""
        echo "=== Bytes through ${tun} during tests ==="
        echo "rx (downlink): $(( $(cat /sys/class/net/$tun/statistics/rx_bytes 2>/dev/null || echo 0) - tun_rx0 ))"
        echo "tx (uplink)  : $(( $(cat /sys/class/net/$tun/statistics/tx_bytes 2>/dev/null || echo 0) - tun_tx0 ))"
    } >> "${raw_dir}/tunnel_proof.txt"

    # Read end power values
    RAPL_RAN_END=$(read_rapl_ran)
    RAPL_CORE_END=$(read_rapl_core)
    POWER_END_TIME=$(date +%s)
    stop_thermal_log
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

    # Save power logs
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

    # Wait for CPU collection to finish
    wait $CPU_RAN_PID 2>/dev/null
    wait $CPU_CORE_PID 2>/dev/null

    # ── Fixed-load test (resources for the same job) ──────────────────────────
    run_fixed_load_test "$raw_dir" "$ran"

    # ── STEP 7: Collect core logs ─────────────────────────────────────────────
    log "STEP 7: Collecting logs..."
    collect_core_logs "$core" "$raw_dir"

    # ── STEP 8: Generate report ───────────────────────────────────────────────
    log "STEP 8: Generating report..."
    generate_report "${combo_dir}/report.txt" "$raw_dir" "$core" "$ran" "$tun"

    # Append to CSV
    append_csv "${BASE_DIR}/all_results.csv" "$core" "$ran" "$raw_dir" "PASS"

    # ── STEP 9: Cleanup ───────────────────────────────────────────────────────
    log "STEP 9: Cleaning up..."
    stop_ran_processes
    stop_core $core

    log_ok "Combination ${combo_name} complete. Results in: ${combo_dir}"
    echo ""
}

# =============================================================================
# COMPARISON REPORT
# =============================================================================

generate_comparison() {
    local comp_file="${BASE_DIR}/comparison.txt"

    cat > "$comp_file" << EOF
================================================================================
                    5G TESTBED - ALL COMBINATIONS COMPARISON
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
            grep -E "^  (FL |Downlink|Uplink|RTT Average|Jitter|Packet Loss|UDP Packet Loss|Average Power|UE IP Assigned    :|Registration Time|PDU Session Setup)" \
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

    # Reject unknown names before anything starts (e.g. "ocudu" belongs to 5g_split_ue.sh)
    if [ $# -ne 0 ]; then
        if [ $# -ne 2 ] || ! [[ "$1" =~ ^(open5gs|free5gc)$ ]] || ! [[ "$2" =~ ^(oai|srsran|ueransim)$ ]]; then
            echo "Usage: sudo $0 [core ran]"
            echo "  core: open5gs | free5gc"
            echo "  ran : oai | srsran | ueransim"
            exit 1
        fi
    fi

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           5G TESTBED BENCHMARK SCRIPT                        ║${NC}"
    echo -e "${GREEN}║           $(date '+%Y-%m-%d %H:%M:%S')                             ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Create output directory
    mkdir -p "${BASE_DIR}"
    # When run via sudo, hand results back to the invoking user on exit
    # On exit: restore the CPU governors and hand results back to the invoking user
    trap 'restore_cpu_mode; [ -n "${SUDO_USER}" ] && chown -R "${SUDO_USER}:$(id -gn "${SUDO_USER}")" "${BASE_DIR}"' EXIT
    # Record the whole terminal session
    exec > >(tee -a "${BASE_DIR}/terminal_session.txt") 2>&1

    # Write CSV header
    echo "timestamp,core,ran,status,ue_ip,ping_loss_pct,rtt_avg_ms,rtt_mdev_ms,tcp_dl_mbps,tcp_ul_mbps,jitter_ms,udp_loss,ran_watts,ran_joules,core_watts,core_joules,reg_ms,pdu_setup_ms,gnb_cpu_pct,ue_cpu_pct,ran_temp_avg_c,ran_temp_max_c,ran_freq_avg_mhz,ran_throttle_events,core_temp_avg_c,core_temp_max_c,core_freq_avg_mhz,core_throttle_events,round,fl_dl_mbps,fl_ul_mbps,fl_dl_loss_pct,fl_ul_loss_pct,fl_valid,fl_gnb_cpu_pct,fl_ue_cpu_pct,fl_gnb_rss_kb,fl_ue_rss_kb,fl_upf_cpu_pct,fl_ran_watts,fl_ran_joules,fl_core_watts,fl_core_joules,fl_ran_machine_cpu_pct,fl_ran_softirq_pct,fl_core_machine_cpu_pct,fl_core_softirq_pct" \
        > "${BASE_DIR}/all_results.csv"

    log "Results will be saved to: ${BASE_DIR}"
    # A previous run that was interrupted can leave the core/RAN running
    # (e.g. an AMF still holding its ports), so start from a clean state
    log "Making sure nothing from a previous run is still running..."
    stop_ran_processes
    stop_core open5gs
    stop_core free5gc
    set_performance_mode

    for CURRENT_ROUND in $(seq 1 ${ROUNDS}); do
        echo ""
        log "════════ ROUND ${CURRENT_ROUND} of ${ROUNDS} ════════"
        if [ $# -eq 2 ]; then
            # Single combination, e.g.: sudo ./5g_benchmark.sh open5gs oai
            log "Testing 1 combination: $1 + $2"
            run_combination "$1" "$2"
        else
            log "Testing 6 combinations..."

            # Run all combinations
            run_combination open5gs oai
            run_combination open5gs srsran
            run_combination open5gs ueransim
            run_combination free5gc oai
            run_combination free5gc srsran
            run_combination free5gc ueransim
        fi
    done

    # Generate comparison and statistics over rounds
    generate_comparison
    generate_summary "ping_loss_pct rtt_avg_ms rtt_mdev_ms tcp_dl_mbps tcp_ul_mbps jitter_ms gnb_cpu_pct ue_cpu_pct ran_watts core_watts reg_ms pdu_setup_ms ran_temp_max_c core_temp_max_c ran_freq_avg_mhz core_freq_avg_mhz ran_throttle_events core_throttle_events fl_dl_mbps fl_ul_mbps fl_gnb_cpu_pct fl_ue_cpu_pct fl_gnb_rss_kb fl_ue_rss_kb fl_upf_cpu_pct fl_ran_watts fl_ran_joules fl_core_watts fl_core_joules fl_ran_machine_cpu_pct fl_ran_softirq_pct fl_core_machine_cpu_pct fl_core_softirq_pct"

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
