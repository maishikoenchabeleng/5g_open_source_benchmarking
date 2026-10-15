#!/bin/bash
# =============================================================================
# 5G CU/DU SPLIT BENCHMARK SCRIPT
# =============================================================================
# Tests the 4 CU/DU split combinations on two separate machines:
#   CU (+ core network) on the core machine, DU + UE on the RAN machine.
#
# RAN Machine  : administrator@137.158.126.24   (DU + UE)
# Core Machine : bluelabuser@137.158.126.21     (CU + core)
#
# Combinations:
#   1. OCUDU split (ocu/odu + srsUE, ZMQ)          + Open5GS
#   2. OAI split   (nr-softmodem F1 + OAI UE, rfsim) + Open5GS
#   3. OCUDU split                                 + Free5GC
#   4. OAI split                                   + Free5GC
#
# Same tests as 5g_benchmark.sh: 100-packet ping, UDP jitter, TCP DL/UL,
# CPU/RAM (pidstat) and RAPL power, plus per-combination report, CSV and
# comparison.
#
# Run with sudo (RAPL + UE routing need root):
#   sudo ./5g_split_ue.sh                 # all 4 combinations, ROUNDS times
#   sudo ./5g_split_ue.sh open5gs oai     # a single combination, ROUNDS times
#
# Rounds: every round runs each combination once (round-robin: A B C D,
# A B C D, ...), so slow drifts affect all combinations equally. Set ROUNDS
# below. summary.txt / summary.csv give mean, std, min, max, 95% CI.
#
# Port layout on the core machine (the UPF owns 137.158.126.21:2152):
#   CU N3   -> 127.0.0.20:2152      CU F1-U -> 137.158.126.21:2153
#   DU F1-U -> sends to CU on 2153  F1-C    -> SCTP 38472
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

# OCUDU split
OCUDU_CU_CONF="${CORE_HOME}/ocudu/configs/my_cu_srsue.yml"
OCUDU_DU_CONF="${HOME_DIR}/ocudu/configs/my_du_srsue.yml"
SRSUE_DIR="${HOME_DIR}/srsRAN_4G/srsue"
SRSUE_BIN="${HOME_DIR}/srsRAN_4G/build/srsue/src/srsue"

# OAI split
OAI_CU_BUILD="${CORE_HOME}/openairinterface5g/cmake_targets/ran_build/build"
OAI_CU_CONF="${CORE_HOME}/openairinterface5g/targets/PROJECTS/GENERIC-NR-5GC/CONF/my_cu_ue.conf"
OAI_BUILD="${HOME_DIR}/openairinterface5g/cmake_targets/ran_build/build"
OAI_CONF_DIR="${HOME_DIR}/openairinterface5g/targets/PROJECTS/GENERIC-NR-5GC/CONF"
OAI_DU_CONF="${OAI_CONF_DIR}/my_du_ue.conf"
OAI_UE_CONF="${OAI_CONF_DIR}/ue-sim.conf"

# CU log on the core machine (copied into raw/cu.log after each run)
CU_REMOTE_LOG="/tmp/split_cu.log"

# Test parameters
PING_COUNT=100
IPERF_DURATION=30
IPERF_SERVER_PORT=5201

# Timing (seconds to wait for each stage)
WAIT_CORE_START=15
WAIT_CU_START=30
WAIT_DU_START=30
WAIT_UE_CONNECT=60
PIDSTAT_SAMPLES=240

# Number of rounds (each round = every combination once)
ROUNDS=3

# Fixed-load test: UDP at FIXED_RATE_MBPS in BOTH directions at the same time,
# CPU/RAM/power measured only during it (same job for every combination)
FIXED_RATE_MBPS=5
FIXED_DURATION=60
FL_CLIENT_SIDE="ue"      # iperf3 client end: ue (simulated UE) or core (phone is the server)

# Output directory
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BASE_DIR="/home/administrator/5g_split_ue_${TIMESTAMP}"

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

# Under sudo, ssh as the invoking user so their ssh key is used
ssh_core() {
    if [ -n "${SUDO_USER}" ]; then
        runuser -u "${SUDO_USER}" -- ssh -n ${CORE_USER}@${CORE_IP} "$1"
    else
        ssh -n ${CORE_USER}@${CORE_IP} "$1"
    fi
}

# Same, with the remote command's stdin taken from this script
ssh_core_stdin() {
    if [ -n "${SUDO_USER}" ]; then
        runuser -u "${SUDO_USER}" -- ssh ${CORE_USER}@${CORE_IP} "$1"
    else
        ssh ${CORE_USER}@${CORE_IP} "$1"
    fi
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

ran_label() {
    case $1 in
        ocudu) echo "OCUDU CU/DU split (srsUE, ZMQ)" ;;
        oai)   echo "OAI CU/DU split (OAI UE, rfsim)" ;;
    esac
}

# Detect tunnel interface
get_tunnel() {
    case $1 in
        ocudu) echo "tun_srsue" ;;
        oai)   echo "oaitun_ue1" ;;
    esac
}

# UPF-side tunnel interface on the core machine
get_core_tunnel() {
    case $1 in
        open5gs) echo "ogstun" ;;
        free5gc) echo "upfgtp" ;;
    esac
}

# Process names (pidstat Command column) used for CPU/RAM lookups
du_proc() {
    case $1 in
        ocudu) echo "odu" ;;
        oai)   echo "nr-softmodem" ;;
    esac
}

ue_proc() {
    case $1 in
        ocudu) echo "srsue" ;;
        oai)   echo "nr-uesoftmodem" ;;
    esac
}

cu_proc() {
    case $1 in
        ocudu) echo "ocu" ;;
        oai)   echo "nr-softmodem" ;;
    esac
}

# Force traffic sourced from the UE IP out through the UE tunnel.
# Without this, iperf3 -B <ue_ip> only sets the source address and the
# packets can leave via eno1, bypassing the RAN/GTP path entirely.
# (srsUE needs this; the OAI UE adds its own rule, this one is harmless.)
UE_RT_TABLE=5000
setup_ue_routing() {
    local tun=$1
    local ue_ip=$2
    while ip rule del table $UE_RT_TABLE 2>/dev/null; do :; done
    ip rule add from "$ue_ip" table $UE_RT_TABLE
    ip route replace default dev "$tun" table $UE_RT_TABLE
}

clear_ue_routing() {
    while ip rule del table $UE_RT_TABLE 2>/dev/null; do :; done
    ip route flush table $UE_RT_TABLE 2>/dev/null
}

# Wait for tunnel interface to appear with IP
wait_for_tunnel() {
    local tun=$1
    local max_wait=$2
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

# Stop DU + UE on the RAN machine
stop_ran_processes() {
    log "Stopping RAN processes (DU + UE)..."
    clear_ue_routing
    pkill -INT -x srsue          2>/dev/null
    pkill -INT -x nr-uesoftmodem 2>/dev/null
    pkill -INT -x odu            2>/dev/null
    pkill -INT -x nr-softmodem   2>/dev/null
    sleep 3
    pkill -9 -x srsue            2>/dev/null
    pkill -9 -x nr-uesoftmodem   2>/dev/null
    pkill -9 -x odu              2>/dev/null
    pkill -9 -x nr-softmodem     2>/dev/null
    pkill -9 -x gnb              2>/dev/null
    sleep 2
}

# Stop the CU on the core machine
stop_cu() {
    log "Stopping CU on core machine..."
    ssh_core "sudo pkill -INT -x ocu 2>/dev/null; sudo pkill -INT -x nr-softmodem 2>/dev/null; \
              sleep 3; \
              sudo pkill -9 -x ocu 2>/dev/null; sudo pkill -9 -x nr-softmodem 2>/dev/null; \
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
            ssh_core "sudo pkill -9 -f '[f]ree5gc' 2>/dev/null; sudo ip link delete upfgtp 2>/dev/null; echo stopped" > /dev/null
            ;;
    esac
    sleep 5
}

stop_all() {
    stop_ran_processes
    stop_cu
    stop_core open5gs
    stop_core free5gc
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
        open5gs-pcfd open5gs-nssfd open5gs-bsfd open5gs-seppd 2>/dev/null"

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

    sleep ${WAIT_CORE_START}

    local n_active=$(ssh_core "sudo systemctl is-active ${amf_unit} open5gs-smfd open5gs-upfd" | grep -c "^active$")
    if [ "$n_active" -ne 3 ]; then
        log_err "Open5GS failed to start (AMF/SMF/UPF not all active)"
        return 1
    fi
    log_ok "Open5GS is running"
    return 0
}

start_free5gc() {
    local log_dir=$1
    log "Starting Free5GC on core machine..."
    # A leftover upfgtp makes the UPF exit ("open Gtp5g: open link: create: file exists")
    ssh_core "sudo pkill -9 -f '[f]ree5gc' 2>/dev/null; sudo ip link delete upfgtp 2>/dev/null; true"
    ssh_core "cd ${CORE_HOME}/free5gc; nohup ./run.sh > /tmp/free5gc.log 2>&1 < /dev/null &"

    # Poll AMF's N2 SCTP listener
    local elapsed=0
    while [ $elapsed -lt ${WAIT_CORE_START} ]; do
        if ssh_core "awk 'NR>1 && \$6==38412' /proc/net/sctp/eps | grep -q . ; echo \$?" | grep -q "^0$"; then
            log_ok "Free5GC AMF is listening on SCTP 38412 (${elapsed}s)"
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    if [ $elapsed -ge ${WAIT_CORE_START} ]; then
        log_err "Free5GC AMF did not come up within ${WAIT_CORE_START}s"
        return 1
    fi

    # The UPF can die on its own while the other NFs keep running
    sleep 5
    if ! ssh_core "pgrep -f '[b]in/upf' > /dev/null && echo up" | grep -q up; then
        log_err "Free5GC UPF is not running (see free5gc.log)"
        return 1
    fi
    log_ok "Free5GC UPF is running"
    return 0
}

# =============================================================================
# CU START FUNCTIONS (core machine)
# =============================================================================

# CU is ready when it has an N2 association to the AMF and listens for F1-C
wait_for_cu() {
    local elapsed=0
    while [ $elapsed -lt ${WAIT_CU_START} ]; do
        if ssh_core "awk 'NR>1 && \$13==38412' /proc/net/sctp/assocs | grep -q . && \
                     awk 'NR>1 && \$6==38472' /proc/net/sctp/eps | grep -q . && echo ready" \
                | grep -q ready; then
            log_ok "CU connected to AMF (NG Setup) and listening for F1-C (${elapsed}s)"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

start_cu() {
    local ran=$1
    log "Starting CU ($ran) on core machine..."
    case $ran in
        ocudu)
            ssh_core "sudo nohup ocu -c ${OCUDU_CU_CONF} > ${CU_REMOTE_LOG} 2>&1 < /dev/null &"
            ;;
        oai)
            ssh_core "cd ${OAI_CU_BUILD}; sudo nohup ./nr-softmodem -O ${OAI_CU_CONF} > ${CU_REMOTE_LOG} 2>&1 < /dev/null &"
            ;;
    esac

    if wait_for_cu; then
        return 0
    fi
    log_err "CU did not complete NG Setup within ${WAIT_CU_START}s (see cu.log)"
    return 1
}

# =============================================================================
# DU + UE START FUNCTIONS (RAN machine)
# =============================================================================

# DU is ready when its F1-C SCTP association to the CU is up
wait_for_du() {
    local pid=$1
    local elapsed=0
    while [ $elapsed -lt ${WAIT_DU_START} ]; do
        if ! ps -p $pid > /dev/null 2>&1; then
            return 1
        fi
        if awk 'NR>1 && $13==38472' /proc/net/sctp/assocs | grep -q .; then
            log_ok "DU connected to CU over F1-C (${elapsed}s)"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

start_du() {
    local ran=$1
    local log_dir=$2
    log "Starting DU ($ran)..."
    case $ran in
        ocudu)
            odu -c ${OCUDU_DU_CONF} > "${log_dir}/du.log" 2>&1 &
            ;;
        oai)
            cd ${OAI_BUILD}
            ./nr-softmodem -O ${OAI_DU_CONF} --rfsim > "${log_dir}/du.log" 2>&1 &
            ;;
    esac
    DU_PID=$!

    if wait_for_du $DU_PID; then
        # Give the DU a moment to activate the cell after F1 Setup
        sleep 5
        return 0
    fi
    log_err "DU failed to connect to CU (see du.log)"
    return 1
}

start_ue() {
    local ran=$1
    local log_dir=$2
    case $ran in
        ocudu)
            log "Starting srsUE..."
            cd ${SRSUE_DIR}
            ${SRSUE_BIN} ue.conf > "${log_dir}/ue.log" 2>&1 &
            ;;
        oai)
            log "Starting OAI UE..."
            cd ${OAI_BUILD}
            ./nr-uesoftmodem \
                --band 78 -r 106 --numerology 1 \
                -C 3619200000 --ssb 516 \
                --rfsim \
                -O ${OAI_UE_CONF} \
                > "${log_dir}/ue.log" 2>&1 &
            ;;
    esac
    UE_PID=$!
    log_ok "UE started (PID: $UE_PID)"
}

# =============================================================================
# METRICS COLLECTION
# =============================================================================

collect_cpu_ram() {
    local log_dir=$1
    local du_name=$2
    local ue_name=$3
    local cu_name=$4

    # LC_ALL=C: 24h timestamps, so the time is a single column
    log "Collecting CPU/RAM on RAN machine..."
    LC_ALL=C pidstat -u -p ALL 1 ${PIDSTAT_SAMPLES} \
        | grep --line-buffered -E " (${du_name}|${ue_name})$" \
        > "${log_dir}/cpu_ran.txt" 2>&1 &
    CPU_RAN_PID=$!

    LC_ALL=C pidstat -r -p ALL 1 ${PIDSTAT_SAMPLES} \
        | grep --line-buffered -E " (${du_name}|${ue_name})$" \
        > "${log_dir}/mem_ran.txt" 2>&1 &
    MEM_RAN_PID=$!

    log "Collecting CPU/RAM on core machine..."
    ssh_core "LC_ALL=C pidstat -u -p ALL 1 ${PIDSTAT_SAMPLES} \
        | grep --line-buffered -E ' (${cu_name}|open5gs-[a-z]+|amf|ausf|bsf|chf|n3iwf|nef|nrf|nssf|pcf|scp|smf|tngf|udm|udr|upf)$'" \
        > "${log_dir}/cpu_core.txt" 2>&1 &
    CPU_CORE_PID=$!

    ssh_core "LC_ALL=C pidstat -r -p ALL 1 ${PIDSTAT_SAMPLES} \
        | grep --line-buffered -E ' (${cu_name}|open5gs-[a-z]+|amf|ausf|bsf|chf|n3iwf|nef|nrf|nssf|pcf|scp|smf|tngf|udm|udr|upf)$'" \
        > "${log_dir}/mem_core.txt" 2>&1 &
    MEM_CORE_PID=$!
}

# Stop pidstat itself (not grep) so grep flushes everything and exits
stop_cpu_ram() {
    pkill -x pidstat 2>/dev/null
    ssh_core "pkill -x pidstat 2>/dev/null; true"
    local i
    for i in 1 2 3 4 5; do
        kill -0 $CPU_RAN_PID $MEM_RAN_PID $CPU_CORE_PID $MEM_CORE_PID 2>/dev/null || break
        sleep 1
    done
    kill $CPU_RAN_PID $MEM_RAN_PID $CPU_CORE_PID $MEM_CORE_PID 2>/dev/null
}

start_iperf_server() {
    ssh_core "pkill -x iperf3 2>/dev/null; sleep 2; nohup iperf3 -s -B ${CORE_IP} --port ${IPERF_SERVER_PORT} > /tmp/iperf_server.log 2>&1 < /dev/null &"
    sleep 5
}

run_iperf_tests() {
    local log_dir=$1
    local ue_ip=$2
    local iperf_timeout=$(( IPERF_DURATION + 30 ))

    # UDP first (tunnel freshest)
    log "Running UDP test for jitter (${IPERF_DURATION}s)..."
    start_iperf_server
    timeout ${iperf_timeout} iperf3 -c ${CORE_IP} -B ${ue_ip} -u -b 2M -l 1200 -t ${IPERF_DURATION} -p ${IPERF_SERVER_PORT} \
        > "${log_dir}/iperf_udp.txt" 2>&1

    # Then TCP DL
    log "Running TCP downlink test (${IPERF_DURATION}s)..."
    start_iperf_server
    # -R: server (core) sends, UE receives = downlink
    timeout ${iperf_timeout} iperf3 -c ${CORE_IP} -B ${ue_ip} -R -t ${IPERF_DURATION} -p ${IPERF_SERVER_PORT} \
        > "${log_dir}/iperf_tcp_dl.txt" 2>&1

    # Then TCP UL
    log "Running TCP uplink test (${IPERF_DURATION}s)..."
    start_iperf_server
    # No -R: client (UE) sends = uplink
    timeout ${iperf_timeout} iperf3 -c ${CORE_IP} -B ${ue_ip} -t ${IPERF_DURATION} -p ${IPERF_SERVER_PORT} \
        > "${log_dir}/iperf_tcp_ul.txt" 2>&1

    ssh_core "pkill -x iperf3 2>/dev/null"
}

run_ping_test() {
    local log_dir=$1
    local tun=$2

    log "Running ping test (${PING_COUNT} packets)..."
    ping -I ${tun} 8.8.8.8 -c ${PING_COUNT} -i 0.5 \
        > "${log_dir}/ping_100.txt" 2>&1
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

# TCP throughput from the receiver line: with rfsim/ZMQ the sender can report
# more than was actually delivered (data queued in the UE and drained later).
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

# pidstat -u line: ... %usr %system %guest %wait %CPU CPU Command
# %CPU is the 3rd field from the end. Threads/PIDs with the same name are
# summed per sample, then averaged over samples. Prints "avg peak".
parse_cpu() {
    local file=$1
    local process=$2
    if [ ! -s "$file" ]; then echo "N/A N/A"; return; fi
    awk -v p="$process" '$NF==p && $1!="Average:" { s[$1]+=$(NF-2) }
        END { n=0; t=0; pk=0
              for (k in s) { n++; t+=s[k]; if (s[k]>pk) pk=s[k] }
              if (n>0) printf "%.2f %.2f\n", t/n, pk; else print "N/A N/A" }' "$file"
}

# pidstat -r line: ... minflt/s majflt/s VSZ RSS %MEM Command
# RSS (KB) is the 3rd field from the end. Summed per sample, averaged.
parse_ram() {
    local file=$1
    local process=$2
    if [ ! -s "$file" ]; then echo "N/A"; return; fi
    awk -v p="$process" '$NF==p && $1!="Average:" { s[$1]+=$(NF-2) }
        END { n=0; t=0
              for (k in s) { n++; t+=s[k] }
              if (n>0) printf "%.0f\n", t/n; else print "N/A" }' "$file"
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

# Core NF names differ: Open5GS runs open5gs-amfd etc., Free5GC runs amf etc.
core_nf_proc() {
    local core=$1
    local nf=$2
    case $core in
        open5gs) echo "open5gs-${nf}d" ;;
        free5gc) echo "${nf}" ;;
    esac
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

# Core network functions: Open5GS (open5gs-*d) and free5gc (amf, smf, upf,
# nrf, ...). Used to sum the whole core's CPU/memory; the CU (split) and other
# programs (e.g. the MongoDB database) are not included.
CORE_NF_RE='^(open5gs-[a-z]+|amf|ausf|bsf|chf|n3iwf|nef|nrf|nssf|pcf|scp|smf|tngf|udm|udr|upf)$'

# Sum over ALL core network functions per sample, then averaged over samples.
# $2 = cpu (prints %CPU, 100% = one core) or ram (prints RSS in KB).
parse_core_total() {
    local file=$1
    local kind=$2
    if [ ! -s "$file" ]; then echo "N/A"; return; fi
    awk -v kind="$kind" -v re="$CORE_NF_RE" '
        $1 == "Average:" { next }
        $NF ~ re {
            ampm = ($2 == "AM" || $2 == "PM")
            want = (kind == "cpu" ? 10 : 9) + ampm
            if (NF != want) next
            key = ampm ? $1 " " $2 : $1
            s[key] += $(NF-2)
        }
        END {
            n = 0; t = 0
            for (k in s) { n++; t += s[k] }
            if (!n) print "N/A"
            else if (kind == "cpu") printf "%.2f\n", t / n
            else printf "%.0f\n", t / n
        }' "$file"
}

# Whole-machine CPU (mpstat) on both machines during the performance tests
start_mpstat_both() {
    local log_dir=$1
    LC_ALL=C mpstat 1 900 > "${log_dir}/mpstat_ran.txt" 2>&1 &
    MPSTAT_RAN_PID=$!
    ssh_core "LC_ALL=C mpstat 1 900" > "${log_dir}/mpstat_core.txt" 2>&1 &
    MPSTAT_CORE_PID=$!
}

stop_mpstat_both() {
    kill $MPSTAT_RAN_PID 2>/dev/null
    ssh_core "pkill -x mpstat 2>/dev/null; true"
    wait $MPSTAT_RAN_PID $MPSTAT_CORE_PID 2>/dev/null
}

run_fixed_load_test() {
    local raw_dir=$1
    local ran=$2
    local d="${raw_dir}/fixed_load"
    mkdir -p "$d"
    log "FIXED-LOAD TEST: UDP ${FIXED_RATE_MBPS} Mbit/s downlink + ${FIXED_RATE_MBPS} Mbit/s uplink at the same time (${FIXED_DURATION}s)..."
    start_iperf_server
    collect_cpu_ram "$d" "$(du_proc $ran)" "$(ue_proc $ran)" "$(cu_proc $ran)"
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
    stop_cpu_ram
    ssh_core "pkill -x iperf3 2>/dev/null; true"
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

    local CORE=$(echo $core | tr '[:lower:]' '[:upper:]')
    local RAN_LABEL=$(ran_label $ran)

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
    local du_cpu du_cpu_peak ue_cpu ue_cpu_peak cu_cpu cu_cpu_peak
    read du_cpu du_cpu_peak <<< $(parse_cpu "${raw_dir}/cpu_ran.txt" "$(du_proc $ran)")
    read ue_cpu ue_cpu_peak <<< $(parse_cpu "${raw_dir}/cpu_ran.txt" "$(ue_proc $ran)")
    read cu_cpu cu_cpu_peak <<< $(parse_cpu "${raw_dir}/cpu_core.txt" "$(cu_proc $ran)")

    local amf_cpu smf_cpu upf_cpu
    read amf_cpu _ <<< $(parse_cpu "${raw_dir}/cpu_core.txt" "$(core_nf_proc $core amf)")
    read smf_cpu _ <<< $(parse_cpu "${raw_dir}/cpu_core.txt" "$(core_nf_proc $core smf)")
    read upf_cpu _ <<< $(parse_cpu "${raw_dir}/cpu_core.txt" "$(core_nf_proc $core upf)")

    # Connectivity check
    local conn_status="PASS"
    local ping_status="PASS"
    [ "$ping_loss" = "100" ] && ping_status="FAIL"
    [ -z "$UE_IP" ] && conn_status="FAIL"

    # Registration / PDU session setup times from the core log
    local reg_ms pdu_ms
    read reg_ms pdu_ms <<< $(parse_reg_times "$(core_log_file $core "$raw_dir")")

    # Temperature / CPU frequency during the tests
    local rta rtm rf rth cta ctm cf cth
    read rta rtm rf rth <<< $(parse_thermal "${raw_dir}/thermal_ran.txt")
    read cta ctm cf cth <<< $(parse_thermal "${raw_dir}/thermal_core.txt")

    # Tunnel proof summary
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
    local fl_du_cpu fl_du_pk
    read fl_du_cpu fl_du_pk <<< $(parse_cpu "${raw_dir}/fixed_load/cpu_ran.txt" "$(du_proc $ran)")
    local fl_ue_cpu fl_ue_pk
    read fl_ue_cpu fl_ue_pk <<< $(parse_cpu "${raw_dir}/fixed_load/cpu_ran.txt" "$(ue_proc $ran)")
    local fl_cu_cpu fl_cu_pk
    read fl_cu_cpu fl_cu_pk <<< $(parse_cpu "${raw_dir}/fixed_load/cpu_core.txt" "$(cu_proc $ran)")
    local fl_amf_cpu; read fl_amf_cpu _ <<< $(parse_cpu "${raw_dir}/fixed_load/cpu_core.txt" "$(core_nf_proc $core amf)")
    local fl_smf_cpu; read fl_smf_cpu _ <<< $(parse_cpu "${raw_dir}/fixed_load/cpu_core.txt" "$(core_nf_proc $core smf)")
    local fl_upf_cpu; read fl_upf_cpu _ <<< $(parse_cpu "${raw_dir}/fixed_load/cpu_core.txt" "$(core_nf_proc $core upf)")

    # Whole core (all core network functions) and whole machines, performance tests
    local core_cpu=$(parse_core_total "${raw_dir}/cpu_core.txt" cpu)
    local core_rss=$(parse_core_total "${raw_dir}/mem_core.txt" ram)
    local m_rb m_rcores m_rusr m_rsys m_rsoft m_cb m_ccores m_cusr m_csys m_csoft
    read m_rb m_rcores m_rusr m_rsys m_rsoft <<< $(parse_mpstat "${raw_dir}/mpstat_ran.txt")
    read m_cb m_ccores m_cusr m_csys m_csoft <<< $(parse_mpstat "${raw_dir}/mpstat_core.txt")
    local fl_core_cpu=$(parse_core_total "${raw_dir}/fixed_load/cpu_core.txt" cpu)
    local fl_core_rss=$(parse_core_total "${raw_dir}/fixed_load/mem_core.txt" ram)

    cat > "$report_file" << EOF
================================================================================
                   5G CU/DU SPLIT BENCHMARK REPORT
================================================================================
  Generated  : $(date '+%Y-%m-%d %H:%M:%S')
  Report for : ${CORE} + ${RAN_LABEL}
  Round      : ${CURRENT_ROUND} of ${ROUNDS}
================================================================================

────────────────────────────────────────────────────────────────────────────────
 TEST CONFIGURATION
────────────────────────────────────────────────────────────────────────────────
  Core Network      : ${CORE}
  RAN Stack         : ${RAN_LABEL}
  CU Location       : Core machine ${CORE_IP}  ($(cu_proc $ran))
  DU + UE Location  : RAN machine ${RAN_IP}  ($(du_proc $ran) + $(ue_proc $ran))
  Tunnel Interface  : ${tun}
  UE IP Assigned    : ${UE_IP:-N/A}
  Ping Count        : ${PING_COUNT} packets
  Iperf Duration    : ${IPERF_DURATION} seconds
  Test Timestamp    : $(date '+%Y-%m-%d %H:%M:%S')

────────────────────────────────────────────────────────────────────────────────
 CONNECTIVITY
────────────────────────────────────────────────────────────────────────────────
  CU <-> AMF (NG Setup)   : PASS
  DU <-> CU  (F1 Setup)   : PASS
  UE Registration         : ${conn_status}
  UE IP Assigned          : ${UE_IP:-N/A}
  Tunnel Interface Up     : ${tun}
  UE traffic route        :${path_line:- N/A}
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
 JITTER  (UDP iperf3, 2 Mbps, ${IPERF_DURATION}s via ${tun})
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
  DU  Process             : avg ${du_cpu} %   peak ${du_cpu_peak} %
  UE  Process             : avg ${ue_cpu} %   peak ${ue_cpu_peak} %

  [ Core Machine : ${CORE_IP} ]
  CU  Process             : avg ${cu_cpu} %   peak ${cu_cpu_peak} %
  AMF                     : avg ${amf_cpu} %
  SMF                     : avg ${smf_cpu} %
  UPF                     : avg ${upf_cpu} %
  Core NFs (all)          : avg ${core_cpu} %   (all core network functions; CU not included)

  [ Whole machines (mpstat: all cores, incl. kernel work; 100 % = whole machine) ]
  RAN Machine CPU (all)   : ${m_rb} % busy = ${m_rcores} cores   (usr ${m_rusr} %, sys ${m_rsys} %, soft ${m_rsoft} %)
  Core Machine CPU (all)  : ${m_cb} % busy = ${m_ccores} cores   (usr ${m_cusr} %, sys ${m_csys} %, soft ${m_csoft} %)

────────────────────────────────────────────────────────────────────────────────
 MEMORY USAGE  (pidstat RSS, during the performance tests)
────────────────────────────────────────────────────────────────────────────────
  [ RAN Machine ]
  DU  RSS                 : $(parse_ram "${raw_dir}/mem_ran.txt" "$(du_proc $ran)") KB
  UE  RSS                 : $(parse_ram "${raw_dir}/mem_ran.txt" "$(ue_proc $ran)") KB

  [ Core Machine ]
  CU  RSS                 : $(parse_ram "${raw_dir}/mem_core.txt" "$(cu_proc $ran)") KB
  AMF RSS                 : $(parse_ram "${raw_dir}/mem_core.txt" "$(core_nf_proc $core amf)") KB
  SMF RSS                 : $(parse_ram "${raw_dir}/mem_core.txt" "$(core_nf_proc $core smf)") KB
  UPF RSS                 : $(parse_ram "${raw_dir}/mem_core.txt" "$(core_nf_proc $core upf)") KB
  Core NFs (all) RSS      : ${core_rss} KB   (all core network functions; CU not included)

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

  [ RAN Machine : ${RAN_IP} ]
  FL DU  CPU              : avg ${fl_du_cpu} %   peak ${fl_du_pk} %
  FL DU  RSS              : $(parse_ram "${raw_dir}/fixed_load/mem_ran.txt" "$(du_proc $ran)") KB
  FL UE  CPU              : avg ${fl_ue_cpu} %   peak ${fl_ue_pk} %
  FL UE  RSS              : $(parse_ram "${raw_dir}/fixed_load/mem_ran.txt" "$(ue_proc $ran)") KB
  FL RAN Power            : ${fl_rw} W   (${fl_rj} J)
  FL Machine CPU (all)    : ${fl_rb} % busy = ${fl_rcores} cores   (usr ${fl_rusr} %, sys ${fl_rsys} %, soft ${fl_rsoft} %)

  [ Core Machine : ${CORE_IP} ]
  FL CU  CPU              : avg ${fl_cu_cpu} %   peak ${fl_cu_pk} %
  FL CU  RSS              : $(parse_ram "${raw_dir}/fixed_load/mem_core.txt" "$(cu_proc $ran)") KB
  FL AMF / SMF / UPF CPU  : avg ${fl_amf_cpu} % / ${fl_smf_cpu} % / ${fl_upf_cpu} %
  FL Core NFs (all)       : CPU avg ${fl_core_cpu} %   RSS ${fl_core_rss} KB   (CU not included)
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
  raw/cu.log              : CU output (core machine)
  raw/du.log              : DU output (RAN machine)
  raw/ue.log              : UE output
  raw/amf.log|free5gc.log : Core network logs
  raw/tunnel_proof.txt    : UE IP, route check, tunnel byte counters (UE + UPF)
  raw/ping_100.txt        : Full ping output (${PING_COUNT} packets)
  raw/iperf_tcp_dl.txt    : TCP downlink iperf3 full output
  raw/iperf_tcp_ul.txt    : TCP uplink iperf3 full output
  raw/iperf_udp.txt       : UDP jitter iperf3 full output
  raw/cpu_ran.txt         : pidstat -u - RAN machine
  raw/mem_ran.txt         : pidstat -r - RAN machine
  raw/cpu_core.txt        : pidstat -u - core machine
  raw/mem_core.txt        : pidstat -r - core machine
  raw/power_ran.txt       : RAPL power log - RAN machine
  raw/power_core.txt      : RAPL power log - core machine
  raw/fixed_load/         : Fixed-load test: iperf_fixed.txt, CPU/RAM, power
  raw/mpstat_ran.txt      : Whole-machine CPU, RAN machine (performance tests)
  raw/mpstat_core.txt     : Whole-machine CPU, core machine (performance tests)
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
    local status=$5

    local ping_results=$(parse_ping "${raw_dir}/ping_100.txt")
    local ping_loss=$(echo $ping_results | awk '{print $1}')
    local rtt_avg=$(echo $ping_results | awk '{print $3}')
    local rtt_mdev=$(echo $ping_results | awk '{print $5}')
    local tcp_dl=$(parse_iperf_tcp "${raw_dir}/iperf_tcp_dl.txt")
    local tcp_ul=$(parse_iperf_tcp "${raw_dir}/iperf_tcp_ul.txt")
    local udp_results=$(parse_iperf_udp "${raw_dir}/iperf_udp.txt")
    local jitter=$(echo $udp_results | awk '{print $2}')
    local udp_loss=$(echo $udp_results | awk '{print $3}')
    local du_cpu ue_cpu cu_cpu
    read du_cpu _ <<< $(parse_cpu "${raw_dir}/cpu_ran.txt" "$(du_proc $ran)")
    read ue_cpu _ <<< $(parse_cpu "${raw_dir}/cpu_ran.txt" "$(ue_proc $ran)")
    read cu_cpu _ <<< $(parse_cpu "${raw_dir}/cpu_core.txt" "$(cu_proc $ran)")
    local reg_ms pdu_ms
    read reg_ms pdu_ms <<< $(parse_reg_times "$(core_log_file $core "$raw_dir")")
    local ran_th core_th
    ran_th=$(parse_thermal "${raw_dir}/thermal_ran.txt" | tr ' ' ',')
    core_th=$(parse_thermal "${raw_dir}/thermal_core.txt" | tr ' ' ',')

    # Fixed-load test; resource values only if the load was fully delivered
    local fl_dl fl_dl_loss fl_ul fl_ul_loss fl_valid fl_rw fl_rj fl_cw fl_cj fl_res
    read fl_dl fl_dl_loss fl_ul fl_ul_loss <<< $(fixed_load_rates "${raw_dir}/fixed_load/iperf_fixed.txt")
    fl_valid=$(fixed_load_check $fl_dl $fl_dl_loss $fl_ul $fl_ul_loss)
    read fl_rw fl_rj fl_cw fl_cj <<< $(fixed_load_power "${raw_dir}/fixed_load")
    fl_res="$(parse_cpu "${raw_dir}/fixed_load/cpu_ran.txt" "$(du_proc $ran)" | cut -d" " -f1),$(parse_cpu "${raw_dir}/fixed_load/cpu_ran.txt" "$(ue_proc $ran)" | cut -d" " -f1),$(parse_cpu "${raw_dir}/fixed_load/cpu_core.txt" "$(cu_proc $ran)" | cut -d" " -f1),$(parse_ram "${raw_dir}/fixed_load/mem_ran.txt" "$(du_proc $ran)"),$(parse_ram "${raw_dir}/fixed_load/mem_ran.txt" "$(ue_proc $ran)"),$(parse_ram "${raw_dir}/fixed_load/mem_core.txt" "$(cu_proc $ran)"),$(parse_cpu "${raw_dir}/fixed_load/cpu_core.txt" "$(core_nf_proc $core upf)" | cut -d" " -f1),${fl_rw},${fl_rj},${fl_cw},${fl_cj},$(parse_mpstat "${raw_dir}/fixed_load/mpstat_ran.txt" | cut -d" " -f1),$(parse_mpstat "${raw_dir}/fixed_load/mpstat_ran.txt" | cut -d" " -f5),$(parse_mpstat "${raw_dir}/fixed_load/mpstat_core.txt" | cut -d" " -f1),$(parse_mpstat "${raw_dir}/fixed_load/mpstat_core.txt" | cut -d" " -f5)"
    [ "$fl_valid" = "VALID" ] || fl_res=$(printf "N/A%.0s," $(seq 1 15) | sed "s/,$//")

    # Whole core, RAN/CU memory and whole machines (performance tests),
    # whole core at fixed load (N/A if the fixed load was not delivered)
    local core_cpu=$(parse_core_total "${raw_dir}/cpu_core.txt" cpu)
    local core_rss=$(parse_core_total "${raw_dir}/mem_core.txt" ram)
    local ran_rss=$(parse_ram "${raw_dir}/mem_ran.txt" "$(du_proc $ran)")
    local cu_rss=$(parse_ram "${raw_dir}/mem_core.txt" "$(cu_proc $ran)")
    local m_ran=$(parse_mpstat "${raw_dir}/mpstat_ran.txt" | awk '{print $1","$5}')
    local m_core=$(parse_mpstat "${raw_dir}/mpstat_core.txt" | awk '{print $1","$5}')
    local fl_core_cpu=$(parse_core_total "${raw_dir}/fixed_load/cpu_core.txt" cpu)
    local fl_core_rss=$(parse_core_total "${raw_dir}/fixed_load/mem_core.txt" ram)
    if [ "$(fixed_load_check $(fixed_load_rates "${raw_dir}/fixed_load/iperf_fixed.txt"))" != "VALID" ]; then
        fl_core_cpu="N/A"; fl_core_rss="N/A"
    fi

    echo "${TIMESTAMP},${core},${ran}_split,${status},${UE_IP:-N/A},${ping_loss},${rtt_avg},${rtt_mdev},${tcp_dl},${tcp_ul},${jitter},${udp_loss},${du_cpu},${ue_cpu},${cu_cpu},${RAN_WATTS:-N/A},${RAN_JOULES:-N/A},${CORE_WATTS:-N/A},${CORE_JOULES:-N/A},${reg_ms},${pdu_ms},${ran_th},${core_th},${CURRENT_ROUND},${fl_dl},${fl_ul},${fl_dl_loss},${fl_ul_loss},${fl_valid},${fl_res},${core_cpu},${core_rss},${ran_rss},${cu_rss},${m_ran},${m_core},${fl_core_cpu},${fl_core_rss}" \
        >> "$csv_file"
}

# =============================================================================
# RUN ONE COMBINATION
# =============================================================================

# On failure: save what we have, clean up, record FAIL in the CSV
fail_combination() {
    local core=$1
    local ran=$2
    local raw_dir=$3
    local reason=$4
    log_err "$reason"
    echo "FAILED: $reason ($(date))" > "${raw_dir}/FAILED.txt"
    collect_logs "$core" "$raw_dir"
    UE_IP=""
    append_csv "${BASE_DIR}/all_results.csv" "$core" "$ran" "$raw_dir" "FAIL"
    stop_ran_processes
    stop_cu
    stop_core $core
    return 1
}

collect_logs() {
    local core=$1
    local raw_dir=$2
    ssh_core "cat ${CU_REMOTE_LOG} 2>/dev/null" > "${raw_dir}/cu.log" 2>&1
    case $core in
        open5gs)
            ssh_core "sudo journalctl -u open5gs-amfd -u open5gs-amfd-srsue -u open5gs-smfd \
                -u open5gs-upfd --since '${COMBO_START}' --no-pager" \
                > "${raw_dir}/amf.log" 2>&1
            ;;
        free5gc)
            ssh_core "cat /tmp/free5gc.log" > "${raw_dir}/free5gc.log" 2>&1
            ;;
    esac
}

core_tun_bytes() {
    local ctun=$1
    ssh_core "cat /sys/class/net/${ctun}/statistics/rx_bytes /sys/class/net/${ctun}/statistics/tx_bytes 2>/dev/null" | tr '\n' ' '
}

run_combination() {
    local core=$1
    local ran=$2

    local combo_name="${core}_${ran}_split"
    local combo_dir="${BASE_DIR}/round${CURRENT_ROUND}/${combo_name}"
    local raw_dir="${combo_dir}/raw"

    mkdir -p "${raw_dir}"
    UE_IP=""
    RAN_WATTS=""; RAN_JOULES=""; CORE_WATTS=""; CORE_JOULES=""
    # Core machine's clock, so the saved core log covers this combination only
    COMBO_START=$(ssh_core "date '+%Y-%m-%d %H:%M:%S'")
    [ -z "$COMBO_START" ] && COMBO_START="15 minutes ago"

    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  TESTING: $(echo $core | tr '[:lower:]' '[:upper:]') + $(ran_label $ran)   [round ${CURRENT_ROUND}/${ROUNDS}]${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"

    local tun=$(get_tunnel $ran)
    local ctun=$(get_core_tunnel $core)

    # ── STEP 1: Start core ────────────────────────────────────────────────────
    log "STEP 1: Starting core network ($core)..."
    case $core in
        open5gs) start_open5gs "$raw_dir" "$([ "$ran" = ocudu ] && echo "$AMF_SRSUE_CONF")" ;;
        free5gc) start_free5gc "$raw_dir" ;;
    esac || { fail_combination $core $ran "$raw_dir" "Core failed to start"; return 1; }

    # ── STEP 2: Start CU on core machine ──────────────────────────────────────
    log "STEP 2: Starting CU ($ran) on ${CORE_IP}..."
    start_cu $ran || { fail_combination $core $ran "$raw_dir" "CU failed"; return 1; }

    # ── STEP 3: Start DU on RAN machine ───────────────────────────────────────
    log "STEP 3: Starting DU ($ran) on ${RAN_IP}..."
    start_du $ran "$raw_dir" || { fail_combination $core $ran "$raw_dir" "DU failed"; return 1; }

    # ── STEP 4: Start UE ──────────────────────────────────────────────────────
    log "STEP 4: Starting UE ($ran)..."
    start_ue $ran "$raw_dir"

    # ── STEP 5: Wait for tunnel ───────────────────────────────────────────────
    log "STEP 5: Waiting for UE to connect (max ${WAIT_UE_CONNECT}s)..."
    if ! wait_for_tunnel "$tun" "$WAIT_UE_CONNECT"; then
        fail_combination $core $ran "$raw_dir" "UE did not connect within ${WAIT_UE_CONNECT}s"
        return 1
    fi
    log_ok "UE connected: IP=${UE_IP} on ${tun}"
    setup_ue_routing "$tun" "$UE_IP"

    # Check that UE-sourced traffic really goes through the tunnel
    local route=$(ip route get ${CORE_IP} from ${UE_IP} 2>/dev/null | head -1)
    {
        echo "=== Tunnel Interface State ==="
        echo "Timestamp: $(date)"
        ip addr show "$tun"
        echo ""
        echo "Route for UE traffic: ${route}"
        echo ""
        echo "=== Policy rules ==="
        ip rule show
    } > "${raw_dir}/tunnel_proof.txt"
    if echo "$route" | grep -q "dev ${tun}"; then
        log_ok "UE traffic routed via ${tun}"
    else
        fail_combination $core $ran "$raw_dir" "UE traffic would bypass ${tun} (${route})"
        return 1
    fi

    # ── STEP 6: NAT on core ───────────────────────────────────────────────────
    log "STEP 6: Ensuring NAT is configured on core..."
    ssh_core "sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1; \
        for net in 10.45.0.0/16 10.60.0.0/16; do \
          sudo iptables -t nat -C POSTROUTING -s \$net -o eno1 -j MASQUERADE > /dev/null 2>&1 \
          || sudo iptables -t nat -A POSTROUTING -s \$net -o eno1 -j MASQUERADE; \
        done"

    # ── STEP 7: Run tests with power + CPU measurement ────────────────────────
    log "STEP 7: Running benchmark tests..."

    collect_cpu_ram "$raw_dir" "$(du_proc $ran)" "$(ue_proc $ran)" "$(cu_proc $ran)"
    start_thermal_log "$raw_dir"
    start_mpstat_both "$raw_dir"

    RAPL_RAN_START=$(read_rapl_ran)
    RAPL_CORE_START=$(read_rapl_core)
    POWER_START_TIME=$(date +%s)

    local tun_rx0=$(cat /sys/class/net/$tun/statistics/rx_bytes 2>/dev/null || echo 0)
    local tun_tx0=$(cat /sys/class/net/$tun/statistics/tx_bytes 2>/dev/null || echo 0)
    local core_bytes0=$(core_tun_bytes $ctun)

    run_ping_test "$raw_dir" "$tun"
    run_iperf_tests "$raw_dir" "$UE_IP"

    local core_bytes1=$(core_tun_bytes $ctun)
    {
        echo ""
        echo "=== Bytes through ${tun} (UE side) during tests ==="
        echo "rx (downlink): $(( $(cat /sys/class/net/$tun/statistics/rx_bytes 2>/dev/null || echo 0) - tun_rx0 ))"
        echo "tx (uplink)  : $(( $(cat /sys/class/net/$tun/statistics/tx_bytes 2>/dev/null || echo 0) - tun_tx0 ))"
        echo ""
        echo "=== ${ctun} (UPF side, core machine) rx/tx bytes ==="
        echo "before: ${core_bytes0}"
        echo "after : ${core_bytes1}"
    } >> "${raw_dir}/tunnel_proof.txt"

    RAPL_RAN_END=$(read_rapl_ran)
    RAPL_CORE_END=$(read_rapl_core)
    POWER_END_TIME=$(date +%s)
    ACTUAL_DURATION=$(( POWER_END_TIME - POWER_START_TIME ))
    [ $ACTUAL_DURATION -lt 1 ] && ACTUAL_DURATION=1

    stop_cpu_ram
    stop_thermal_log
    stop_mpstat_both

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
RAPL Power Measurement - RAN Machine (${RAN_IP}) - DU + UE
===========================================================
Start energy (uJ) : ${RAPL_RAN_START}
End energy   (uJ) : ${RAPL_RAN_END}
Duration      (s) : ${ACTUAL_DURATION}
Total energy  (J) : ${RAN_JOULES:-N/A}
Average power (W) : ${RAN_WATTS:-N/A}
Timestamp         : $(date)
EOF

    cat > "${raw_dir}/power_core.txt" << EOF
RAPL Power Measurement - Core Machine (${CORE_IP}) - CU + core
===============================================================
Start energy (uJ) : ${RAPL_CORE_START}
End energy   (uJ) : ${RAPL_CORE_END}
Duration      (s) : ${ACTUAL_DURATION}
Total energy  (J) : ${CORE_JOULES:-N/A}
Average power (W) : ${CORE_WATTS:-N/A}
Timestamp         : $(date)
EOF

    # ── Fixed-load test (resources for the same job) ──────────────────────────
    run_fixed_load_test "$raw_dir" "$ran"

    # ── STEP 8: Collect logs ──────────────────────────────────────────────────
    log "STEP 8: Collecting logs..."
    collect_logs "$core" "$raw_dir"

    # ── STEP 9: Generate report ───────────────────────────────────────────────
    log "STEP 9: Generating report..."
    generate_report "${combo_dir}/report.txt" "$raw_dir" "$core" "$ran" "$tun"
    append_csv "${BASE_DIR}/all_results.csv" "$core" "$ran" "$raw_dir" "PASS"

    # ── STEP 10: Cleanup ──────────────────────────────────────────────────────
    log "STEP 10: Cleaning up..."
    stop_ran_processes
    stop_cu
    stop_core $core

    log_ok "Combination ${combo_name} complete. Results in: ${combo_dir}"
    echo ""
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
# COMPARISON REPORT
# =============================================================================

generate_comparison() {
    local comp_file="${BASE_DIR}/comparison.txt"
    local csv="${BASE_DIR}/all_results.csv"

    {
        echo "================================================================================"
        echo "                 5G CU/DU SPLIT - ALL COMBINATIONS COMPARISON"
        echo "================================================================================"
        echo "  Generated : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "  Run ID    : ${TIMESTAMP}"
        echo "  TCP = receiver-side Mbps; CPU = avg % (100% = one core)"
        echo "================================================================================"
        echo ""
        echo "  One row per combination per round. Statistics over rounds: summary.txt"
        echo ""
        printf "%-4s %-8s %-12s %-6s %-12s %6s %8s %9s %9s %8s %7s %7s %7s %7s %7s %8s %8s\n" \
            "Rnd" "Core" "RAN" "Status" "UE IP" "Loss%" "RTT(ms)" "DL(Mbps)" "UL(Mbps)" "Jit(ms)" \
            "DU CPU" "UE CPU" "CU CPU" "RAN W" "Core W" "Reg(ms)" "PDU(ms)"
        echo "----------------------------------------------------------------------------------------------------------------------------------------------"
        tail -n +2 "$csv" | while IFS=, read ts core ran status ueip loss rtt mdev dl ul jit uloss du ue cu rw rj cw cj reg pdu rta rtm rf rth cta ctm cf cth rnd; do
            printf "%-4s %-8s %-12s %-6s %-12s %6s %8s %9s %9s %8s %7s %7s %7s %7s %7s %8s %8s\n" \
                "$rnd" "$core" "$ran" "$status" "$ueip" "$loss" "$rtt" "$dl" "$ul" "$jit" "$du" "$ue" "$cu" "$rw" "$cw" "$reg" "$pdu"
        done
        echo ""
    } > "$comp_file"

    for combo_dir in "${BASE_DIR}"/round*/*/; do
        if [ -f "${combo_dir}/report.txt" ]; then
            local name="$(basename "$(dirname "$combo_dir")")/$(basename "$combo_dir")"
            echo "── ${name} ──────────────────────────────────────────────────────" >> "$comp_file"
            grep -E "FL |Downlink|Uplink|RTT Average|Jitter|Packet Loss|Average Power|UE IP Assigned|Process|Registration Time|PDU Session Setup" \
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
        echo "Please run with sudo: sudo $0 $*"
        exit 1
    fi

    # Reject unknown names before anything starts (e.g. "srsran" belongs to 5g_benchmark.sh)
    if [ $# -ne 0 ]; then
        if [ $# -ne 2 ] || ! [[ "$1" =~ ^(open5gs|free5gc)$ ]] || ! [[ "$2" =~ ^(ocudu|oai)$ ]]; then
            echo "Usage: sudo $0 [core ran]"
            echo "  core: open5gs | free5gc"
            echo "  ran : ocudu | oai"
            exit 1
        fi
    fi

    mkdir -p "${BASE_DIR}"
    # Hand results back to the invoking user on exit
    # On exit: restore the CPU governors and hand results back to the invoking user
    trap 'restore_cpu_mode; [ -n "${SUDO_USER}" ] && chown -R "${SUDO_USER}:$(id -gn "${SUDO_USER}")" "${BASE_DIR}"' EXIT
    # Record the whole terminal session
    exec > >(tee -a "${BASE_DIR}/terminal_session.txt") 2>&1

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           5G CU/DU SPLIT BENCHMARK SCRIPT                    ║${NC}"
    echo -e "${GREEN}║           $(date '+%Y-%m-%d %H:%M:%S')                                ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo "timestamp,core,ran,status,ue_ip,ping_loss_pct,rtt_avg_ms,rtt_mdev_ms,tcp_dl_mbps,tcp_ul_mbps,jitter_ms,udp_loss,du_cpu_pct,ue_cpu_pct,cu_cpu_pct,ran_watts,ran_joules,core_watts,core_joules,reg_ms,pdu_setup_ms,ran_temp_avg_c,ran_temp_max_c,ran_freq_avg_mhz,ran_throttle_events,core_temp_avg_c,core_temp_max_c,core_freq_avg_mhz,core_throttle_events,round,fl_dl_mbps,fl_ul_mbps,fl_dl_loss_pct,fl_ul_loss_pct,fl_valid,fl_du_cpu_pct,fl_ue_cpu_pct,fl_cu_cpu_pct,fl_du_rss_kb,fl_ue_rss_kb,fl_cu_rss_kb,fl_upf_cpu_pct,fl_ran_watts,fl_ran_joules,fl_core_watts,fl_core_joules,fl_ran_machine_cpu_pct,fl_ran_softirq_pct,fl_core_machine_cpu_pct,fl_core_softirq_pct,core_cpu_pct,core_rss_kb,du_rss_kb,cu_rss_kb,ran_machine_cpu_pct,ran_softirq_pct,core_machine_cpu_pct,core_softirq_pct,fl_core_cpu_pct,fl_core_rss_kb" \
        > "${BASE_DIR}/all_results.csv"

    log "Results will be saved to: ${BASE_DIR}"
    log "Making sure nothing from a previous run is still running..."
    stop_all
    set_performance_mode

    for CURRENT_ROUND in $(seq 1 ${ROUNDS}); do
        echo ""
        log "════════ ROUND ${CURRENT_ROUND} of ${ROUNDS} ════════"
        if [ $# -eq 2 ]; then
            log "Testing 1 combination: $1 + $2"
            run_combination "$1" "$2"
        else
            log "Testing 4 combinations..."
            run_combination open5gs ocudu
            run_combination open5gs oai
            run_combination free5gc ocudu
            run_combination free5gc oai
        fi
    done

    generate_comparison
    generate_summary "ping_loss_pct rtt_avg_ms rtt_mdev_ms tcp_dl_mbps tcp_ul_mbps jitter_ms du_cpu_pct ue_cpu_pct cu_cpu_pct ran_watts core_watts reg_ms pdu_setup_ms ran_temp_max_c core_temp_max_c ran_freq_avg_mhz core_freq_avg_mhz ran_throttle_events core_throttle_events fl_dl_mbps fl_ul_mbps fl_du_cpu_pct fl_ue_cpu_pct fl_cu_cpu_pct fl_du_rss_kb fl_ue_rss_kb fl_cu_rss_kb fl_upf_cpu_pct fl_ran_watts fl_ran_joules fl_core_watts fl_core_joules fl_ran_machine_cpu_pct fl_ran_softirq_pct fl_core_machine_cpu_pct fl_core_softirq_pct core_cpu_pct core_rss_kb du_rss_kb cu_rss_kb ran_machine_cpu_pct ran_softirq_pct core_machine_cpu_pct core_softirq_pct fl_core_cpu_pct fl_core_rss_kb"

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
