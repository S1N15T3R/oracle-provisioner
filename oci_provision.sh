#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# ░▒▓ OCI COMPUTE INSTANCE PROVISIONER — AUTONOMOUS CAPACITY CATCHER ▓▒░
# ═══════════════════════════════════════════════════════════════════════════════
#  Autonomous 24/7 provisioner for Oracle Cloud Always Free ARM (A1.Flex) instances.
#  Features AIMD adaptive rate limiting, exponential backoff, single-shot API calls,
#  post-launch SSH verification, and strict single-instance exit guarantees.
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── LOAD CONFIGURATION ────────────────────────────────────────────────────────
# Check local directory first, then standard config locations
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/config.env"
elif [[ -f "${HOME}/.config/oci-provisioner/config.env" ]]; then
    # shellcheck source=/dev/null
    source "${HOME}/.config/oci-provisioner/config.env"
fi

# ─── DEFAULTS & VALIDATION ─────────────────────────────────────────────────────
SHAPE="${SHAPE:-VM.Standard.A1.Flex}"
OCPU_COUNT="${OCPU_COUNT:-2}"
MEMORY_GB="${MEMORY_GB:-12}"
BOOT_VOLUME_SIZE_GB="${BOOT_VOLUME_SIZE_GB:-200}"
BOOT_VOLUME_VPUS="${BOOT_VOLUME_VPUS:-10}"

# Timing & AIMD Defaults
RETRY_BASE="${RETRY_BASE:-95}"
RETRY_JITTER="${RETRY_JITTER:-10}"
MIN_BASE_INTERVAL="${MIN_BASE_INTERVAL:-85}"
MAX_BASE_INTERVAL="${MAX_BASE_INTERVAL:-115}"
RETRY_MAX="${RETRY_MAX:-360}"
CURRENT_BASE_INTERVAL="$RETRY_BASE"

# SSH / Verification Defaults
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
REMOTE_USER="${REMOTE_USER:-ubuntu}"
INSTANCE_STATE_POLL_INTERVAL=15
INSTANCE_STATE_TIMEOUT=300
RUNNING_TO_SSH_BUFFER=60
SSH_PROBE_INTERVAL=5
SSH_PROBE_TIMEOUT=180
SSH_CONNECT_TIMEOUT=10

# Telegram Defaults
TELEGRAM_ENGINE="${TELEGRAM_ENGINE:-none}"
TELEGRAM_DIGEST_INTERVAL="${TELEGRAM_DIGEST_INTERVAL:-600}"
TELEGRAM_429_THROTTLE="${TELEGRAM_429_THROTTLE:-300}"

# Network Guard Defaults
NET_CHECK_HOST="8.8.8.8"
NET_CHECK_TIMEOUT=5
NET_CHECK_INTERVAL=10

# Runtime Paths
LOG_FILE="${HOME}/.oci/provisioner.log"
LOCK_FILE="${HOME}/.oci/provisioner.lock"

# Scoreboard State
ATTEMPT=0
TOTAL_CAPACITY_HITS=0
TOTAL_429_HITS=0
TOTAL_NET_ERRORS=0
TOTAL_OTHER_ERRORS=0

CONSECUTIVE_CAPACITY_HITS=0
CONSECUTIVE_429_HITS=0
CONSECUTIVE_AUTH_HITS=0

NETWORK_WAS_DOWN=false
LAST_TELEGRAM_TIME=$(date +%s)
LAST_429_ALERT_TIME=0

# ═══════════════════════════════════════════════════════════════════════════════
# HELPER & VALIDATION FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

log_event() {
    local msg="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg"
}

print_help() {
    cat <<EOF
OCI Compute Instance Provisioner - Autonomous Always Free Capacity Catcher

Usage:
  ./oci_provision.sh [OPTIONS]

Options:
  -s, --status    Show real-time status of running daemon, lifetime scoreboard, and logs
  -t, --test      Execute a single launch attempt to test OCI credentials and connectivity
  -h, --help      Display this help menu and exit

Configuration:
  Copy 'config.env.example' to 'config.env' and set your OCI compartment, subnet,
  availability domain, and image OCIDs.

Documentation:
  https://github.com/S1N15T3R/oracle-provisioner
EOF
}

validate_config() {
    local missing=()

    [[ -z "${COMPARTMENT_ID:-}" || "${COMPARTMENT_ID}" == *"your_"* ]] && missing+=("COMPARTMENT_ID")
    [[ -z "${SUBNET_ID:-}" || "${SUBNET_ID}" == *"your_"* ]] && missing+=("SUBNET_ID")
    [[ -z "${AVAILABILITY_DOMAIN:-}" || "${AVAILABILITY_DOMAIN}" == *"your_"* ]] && missing+=("AVAILABILITY_DOMAIN")
    [[ -z "${IMAGE_OCID:-}" || "${IMAGE_OCID}" == *"your_"* ]] && missing+=("IMAGE_OCID")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "❌ Missing or unconfigured variables: ${missing[*]}"
        echo "   Please create and configure 'config.env':"
        echo "   cp config.env.example config.env && nano config.env"
        exit 1
    fi

    if ! command -v oci &>/dev/null; then
        echo "❌ Oracle Cloud CLI ('oci') not found. Please install OCI CLI."
        exit 1
    fi

    if [[ ! -f ~/.oci/config ]]; then
        echo "❌ OCI configuration file not found at ~/.oci/config"
        echo "   Run 'oci setup config' to configure API credentials."
        exit 1
    fi

    if [[ ! -f "${SSH_KEY_PATH}.pub" ]]; then
        echo "❌ SSH public key missing at ${SSH_KEY_PATH}.pub"
        echo "   Generate one with: ssh-keygen -t ed25519"
        exit 1
    fi
}

calc_percent() {
    local part="$1"
    local total="$2"
    if [[ "$total" -le 0 ]]; then
        echo "0.0%"
    else
        awk "BEGIN {printf \"%.1f%%\", ($part / $total) * 100}"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TELEGRAM NOTIFICATION SYSTEM
# ═══════════════════════════════════════════════════════════════════════════════

send_telegram() {
    local msg="$1"

    case "$TELEGRAM_ENGINE" in
        "hermes")
            if command -v hermes &>/dev/null; then
                hermes send --to telegram "$msg" -q 2>/dev/null || true
            fi
            ;;
        "curl")
            if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
                curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                    -d "chat_id=${TELEGRAM_CHAT_ID}" \
                    --data-urlencode "text=${msg}" &>/dev/null || true
            fi
            ;;
        *)
            # Notifications disabled
            ;;
    esac
}

send_telegram_throttled() {
    local msg="$1"
    local now=$(date +%s)
    local elapsed=$(( now - LAST_TELEGRAM_TIME ))
    if [[ $elapsed -ge $TELEGRAM_DIGEST_INTERVAL ]]; then
        LAST_TELEGRAM_TIME=$now
        send_telegram "$msg"
    fi
}

send_telegram_429() {
    local msg="$1"
    local now=$(date +%s)
    local elapsed=$(( now - LAST_429_ALERT_TIME ))
    if [[ $elapsed -ge $TELEGRAM_429_THROTTLE ]]; then
        LAST_429_ALERT_TIME=$now
        send_telegram "$msg"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TELEGRAM ALERT CARDS
# ═══════════════════════════════════════════════════════════════════════════════

alert_startup() {
    send_telegram "🚀 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
┃ 🛰️  OCI INSTANCE PROVISIONER — ACTIVATED
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📋 ┌──────────────────────────────────────────
┃ │ Shape    : ${SHAPE}
┃ │ Compute  : ${OCPU_COUNT} OCPUs  ·  ${MEMORY_GB} GB RAM
┃ │ Storage  : ${BOOT_VOLUME_SIZE_GB} GB @ ${BOOT_VOLUME_VPUS} VPU/gb
┃ │ Region   : ${AVAILABILITY_DOMAIN}
┃ │ Network  : Ephemeral Public IPv4
┃ │ Mode     : Autonomous Single-Instance Catcher
📋 └──────────────────────────────────────────

⚙️ ENGINE SPECIFICATIONS:
   ├─ Execution Mode : Single-request (--no-retry enforced)
   ├─ Interval Engine: AIMD Adaptive (${MIN_BASE_INTERVAL}s–${MAX_BASE_INTERVAL}s dynamic)
   ├─ Anti-Ban Logic : Exponential refill backoff on 429
   ├─ SSH Probe      : TCP port + Key Auth + Hostname verify
   └─ Lifecycle      : Halts automatically upon success

⏳ Provisioning loop initiated. Actively hunting for capacity..."
}

alert_capacity_digest() {
    local next_delay="$1"
    local cap_pct
    local rate_pct
    local net_pct
    cap_pct=$(calc_percent "$TOTAL_CAPACITY_HITS" "$ATTEMPT")
    rate_pct=$(calc_percent "$TOTAL_429_HITS" "$ATTEMPT")
    net_pct=$(calc_percent "$TOTAL_NET_ERRORS" "$ATTEMPT")

    local checks_per_hr
    checks_per_hr=$(awk "BEGIN {printf \"%.1f\", 3600 / ($CURRENT_BASE_INTERVAL + ($RETRY_JITTER / 2))}")

    send_telegram_throttled "🔄 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
┃ 📡 OCI PROVISIONER — STATUS DIGEST (10m)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🎯 TARGET & ENDPOINT:
   ├─ Action   : launchInstance (POST /20160918/instances)
   ├─ Target   : ${SHAPE} (${OCPU_COUNT} OCPU / ${MEMORY_GB} GB)
   ├─ Location : ${AVAILABILITY_DOMAIN} · Ephemeral Public IP
   └─ Engine   : AIMD Self-Tuning (--no-retry enabled)

📊 LAST CALL RESULT:
   ├─ Status   : 500 InternalError (Out of host capacity)
   └─ Meaning  : Target data center is currently full.
                 No rate limits active. Waiting for freed slot.

📈 SCOREBOARD & METRICS:
   ├─ Total Attempts    : ${ATTEMPT}
   ├─ 📦 Host Capacity  : ${TOTAL_CAPACITY_HITS} (${cap_pct})  [Normal/Hunting]
   ├─ ⏳ Rate Limits    : ${TOTAL_429_HITS} (${rate_pct})  [Safely handled]
   ├─ 🌐 Network Blips  : ${TOTAL_NET_ERRORS} (${net_pct})
   └─ 🔥 Current Streak : ${CONSECUTIVE_CAPACITY_HITS} consecutive capacity checks

⚡ PERFORMANCE & CADENCE:
   ├─ Speed     : ~${checks_per_hr} valid capacity checks/hr
   ├─ Interval  : ${CURRENT_BASE_INTERVAL}s (±${RETRY_JITTER}s jitter)
   └─ Next Try  : In ~${next_delay}s

🤖 BOT STATUS & ACTION:
   🟢 HEALTHY & ACTIVELY RETRYING
   The bot is firing clean, single-shot requests at peak speed
   without triggering 429 rate limits. When a slot frees up,
   it will secure it instantly, verify SSH, and notify you."
}

alert_rate_limit() {
    local backoff_delay="$1"
    local cap_pct
    local rate_pct
    cap_pct=$(calc_percent "$TOTAL_CAPACITY_HITS" "$ATTEMPT")
    rate_pct=$(calc_percent "$TOTAL_429_HITS" "$ATTEMPT")

    send_telegram_429 "⏳ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
┃ 🚫 RATE LIMIT (429) — COOLDOWN ACTIVE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🎯 TARGET & ENDPOINT:
   ├─ Action   : launchInstance (POST /20160918/instances)
   ├─ Status   : 429 Too Many Requests
   └─ Detail   : \"Too many requests for the user\"

📈 SCOREBOARD & METRICS:
   ├─ Total Attempts    : ${ATTEMPT}
   ├─ 📦 Host Capacity  : ${TOTAL_CAPACITY_HITS} (${cap_pct})
   ├─ ⏳ Rate Limits    : ${TOTAL_429_HITS} (${rate_pct})
   └─ 🔁 Consecutive 429: ${CONSECUTIVE_429_HITS} of 3 (Safe Tier)

🛡️ BOT STATUS & ACTION:
   🟡 PAUSING FOR ${backoff_delay}s (Anti-Ban Protection)
   Oracle's rolling token bucket has temporarily emptied.
   The bot is pausing for ~${backoff_delay}s to allow Oracle's
   token pool to refill completely before resuming.
   
   Next retry in : ~${backoff_delay}s
   Loop will auto-resume competitive speed once cleared."
}

alert_network_down() {
    NETWORK_WAS_DOWN=true
    send_telegram "📵 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
┃ 🌐 NETWORK DISCONNECTED — PAUSING
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📊 Status  : No internet connection detected
📊 Attempt : #${ATTEMPT}
🔁 Probing : Every ${NET_CHECK_INTERVAL}s until connection returns

💡 Bot has paused API requests. Will resume instantly
   when internet is restored without losing state."
}

alert_network_recovered() {
    send_telegram "🌐 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
┃ 📡 NETWORK RESTORED — RESUMING
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

✅ Status  : Internet connection confirmed
📊 Attempt : Resuming at #${ATTEMPT}
⚡ Action  : Re-entering competitive provisioning loop immediately."
}

alert_auth_error() {
    local error_msg="$1"
    send_telegram "🚫 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
┃ 🔒 PERSISTENT AUTHENTICATION FAILURE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📊 Status : Unauthorized / Forbidden (3x consecutive)
📝 Detail : ${error_msg:0:200}

💡 Please verify OCI credentials in ~/.oci/config.
⛔ Bot halted to prevent API lockout. Restart service when fixed."
}

alert_instance_created() {
    local instance_id="$1"
    local public_ip="$2"
    send_telegram "🔄 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
┃ ⏳ INSTANCE CREATED — WAITING FOR BOOT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🖥️  Instance ID : ${instance_id}
🌐 Public IPv4 : ${public_ip}

⏱️  Boot sequence underway:
   ├─ Infrastructure provisioning : ~60-120s
   ├─ Linux kernel boot           : ~15-30s
   ├─ cloud-init & SSH key setup  : ~30-60s
   └─ Probing port 22 & SSH auth  : in progress...

🔔 An alert with verified SSH instructions will follow shortly."
}

alert_success() {
    local instance_id="$1"
    local public_ip="$2"
    local attempts="$3"
    local total_boot_time="$4"
    local host_info="$5"

    send_telegram "🎉 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
┃ ✅  OCI INSTANCE DEPLOYED & SSH VERIFIED!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🖥️ ┌──────────────────────────────────────────
┃ │ Instance ID : ${instance_id}
┃ │ Public IPv4 : ${public_ip}
┃ │ Shape       : ${SHAPE} (${OCPU_COUNT} OCPU / ${MEMORY_GB} GB)
┃ │ Boot Disk   : ${BOOT_VOLUME_SIZE_GB} GB Balanced (${BOOT_VOLUME_VPUS} VPU)
┃ │ Host Info   : ${host_info}
🖥️ └──────────────────────────────────────────

🔑 ┌──────────────────────────────────────────
┃ │ Connect via SSH:
┃ │ ssh -i ${SSH_KEY_PATH} ${REMOTE_USER}@${public_ip}
🔑 └──────────────────────────────────────────

📊 METRICS:
   ├─ Total Attempts : ${attempts}
   ├─ Boot Duration  : ${total_boot_time}s (launch → verified SSH)
   └─ Status         : Fully operational & accessible

🟢 Deployment complete. Bot has terminated successfully."
}

# ═══════════════════════════════════════════════════════════════════════════════
# NETWORK CONNECTIVITY GUARDS
# ═══════════════════════════════════════════════════════════════════════════════

check_network() {
    if ping -c 1 -W "$NET_CHECK_TIMEOUT" "$NET_CHECK_HOST" &>/dev/null; then
        return 0
    elif curl -s --connect-timeout "$NET_CHECK_TIMEOUT" https://www.oracle.com &>/dev/null; then
        return 0
    fi
    return 1
}

wait_for_network() {
    local net_attempts=0
    while ! check_network; do
        net_attempts=$((net_attempts + 1))
        if [[ $net_attempts -eq 1 ]]; then
            TOTAL_NET_ERRORS=$((TOTAL_NET_ERRORS + 1))
            alert_network_down
        fi
        sleep "$NET_CHECK_INTERVAL"
    done
    if [[ "$NETWORK_WAS_DOWN" == true ]]; then
        alert_network_recovered
        NETWORK_WAS_DOWN=false
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# ERROR DETECTION & EXTRACTION ENGINE
# ═══════════════════════════════════════════════════════════════════════════════

detect_error_type() {
    local response="$1"

    local http_status
    local error_code

    http_status=$(echo "$response" | sed -n '/^{/,$p' | jq -r '.status // empty' 2>/dev/null || true)
    error_code=$(echo "$response" | sed -n '/^{/,$p' | jq -r '.code // empty' 2>/dev/null || true)

    # 1. Network / connection timeout
    if echo "$response" | grep -qiE "(connection.*timed out|connection timeout|connect timeout|timed out|network is unreachable|temporary failure in name resolution|failed to connect|SSL connect error|RequestTimeout|ClientConnectionError)"; then
        echo "NETWORK"
        return
    fi

    # 2. Rate Limit (HTTP 429)
    if [[ "$http_status" == "429" || "$error_code" == "TooManyRequests" ]] || echo "$response" | grep -qiE "(TooManyRequests|Too many requests for the user)"; then
        echo "RATE_LIMIT"
        return
    fi

    # 3. Capacity Full (HTTP 500)
    if [[ "$http_status" == "500" ]] && echo "$response" | grep -qiE "(out of host capacity|out of capacity|insufficient capacity)"; then
        echo "CAPACITY"
        return
    fi
    if echo "$response" | grep -qiE "(out of host capacity|out of capacity|CapacityExceeded)"; then
        echo "CAPACITY"
        return
    fi

    # 4. Service Unavailable (HTTP 502/503/504)
    if [[ "$http_status" == "503" || "$http_status" == "504" || "$http_status" == "502" || "$error_code" == "ServiceUnavailable" ]]; then
        echo "SERVICE_UNAVAILABLE"
        return
    fi

    # 5. Account/Service Limits
    if [[ "$error_code" == "LimitExceeded" || "$error_code" == "QuotaExceeded" ]] || echo "$response" | grep -qiE "(LimitExceeded|QuotaExceeded|Service limit|quota exceeded)"; then
        echo "LIMIT"
        return
    fi

    # 6. Auth errors
    if [[ "$http_status" == "401" || "$error_code" == "NotAuthenticated" || "$error_code" == "NotAuthorizedOrNotFound" ]]; then
        echo "AUTH"
        return
    fi

    # 7. Invalid Parameter (HTTP 400)
    if [[ "$http_status" == "400" || "$error_code" == "InvalidParameter" ]] || echo "$response" | grep -qiE "(InvalidParameter|MalformedRequest)"; then
        echo "INVALID"
        return
    fi

    # 8. Generic error
    if echo "$response" | grep -qiE "(error|fail|exception)"; then
        echo "GENERIC"
        return
    fi

    echo "NONE"
}

extract_oci_error() {
    local response="$1"
    local error_msg=""

    for path in '.message' '.detail' '.errors[0].message' '.error.message'; do
        error_msg=$(echo "$response" | sed -n '/^{/,$p' | jq -r "${path} // empty" 2>/dev/null || true)
        [[ -n "$error_msg" ]] && break
    done

    if [[ -z "$error_msg" ]]; then
        error_msg=$(echo "$response" | grep -iE "(error|exception|fail|denied|forbidden|timeout)" | head -2 | tr '\n' ' ')
    fi

    if [[ -z "$error_msg" ]]; then
        error_msg=$(echo "$response" | head -3 | tr '\n' ' ')
    fi

    echo "$error_msg"
}

calculate_sleep_duration() {
    local base_delay=$CURRENT_BASE_INTERVAL

    if [[ $CONSECUTIVE_429_HITS -gt 0 ]]; then
        case $CONSECUTIVE_429_HITS in
            1) base_delay=135 ;;   # 1st 429: wait 135s (refills tokens in bucket)
            2) base_delay=250 ;;   # 2nd 429: wait 250s
            *) base_delay=360 ;;   # 3+ 429s: 6-minute deep cooldown
        esac
    else
        base_delay=$CURRENT_BASE_INTERVAL
    fi

    local jitter=$(( RANDOM % (RETRY_JITTER + 1) ))
    echo $(( base_delay + jitter ))
}

# ═══════════════════════════════════════════════════════════════════════════════
# INSTANCE LIFECYCLE POLLING & SSH VERIFICATION
# ═══════════════════════════════════════════════════════════════════════════════

wait_for_instance_running() {
    local instance_id="$1"
    local start_time=$(date +%s)
    local elapsed=0
    local state=""

    while [[ $elapsed -lt $INSTANCE_STATE_TIMEOUT ]]; do
        state=$(oci compute instance get \
            --instance-id "$instance_id" \
            --query 'data."lifecycle-state"' \
            --no-retry \
            --raw-output 2>/dev/null || echo "UNKNOWN")

        log_event "  ├─ State probe: ${state} (${elapsed}s elapsed)"

        case "$state" in
            "RUNNING")
                return 0
                ;;
            "TERMINATED"|"TERMINATING")
                return 2  # Terminated during placement
                ;;
            *)
                sleep "$INSTANCE_STATE_POLL_INTERVAL"
                elapsed=$(( $(date +%s) - start_time ))
                ;;
        esac
    done

    return 1  # Timeout
}

get_instance_public_ip() {
    local instance_id="$1"
    local public_ip=""
    local attempts=0
    local max_attempts=20  # 20 * 5s = 100s

    while [[ $attempts -lt $max_attempts ]]; do
        attempts=$((attempts + 1))
        public_ip=$(oci compute instance list-vnics \
            --instance-id "$instance_id" \
            --query 'data[0]."public-ip"' \
            --no-retry \
            --raw-output 2>/dev/null || echo "")

        if [[ -n "$public_ip" && "$public_ip" != "null" && "$public_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$public_ip"
            return 0
        fi

        log_event "  ├─ Awaiting public IP assignment (probe ${attempts}/${max_attempts})..."
        sleep 5
    done
    return 1
}

probe_ssh_port() {
    local host="$1"
    local port=22
    if command -v nc &>/dev/null; then
        timeout "$SSH_CONNECT_TIMEOUT" nc -z -w "$SSH_CONNECT_TIMEOUT" "$host" "$port" &>/dev/null
    else
        timeout "$SSH_CONNECT_TIMEOUT" bash -c "</dev/tcp/$host/$port" &>/dev/null
    fi
}

wait_for_ssh_ready() {
    local public_ip="$1"
    local start_time=$(date +%s)
    local elapsed=0

    log_event "  ├─ Waiting ${RUNNING_TO_SSH_BUFFER}s cloud-init setup buffer..."
    sleep "$RUNNING_TO_SSH_BUFFER"

    log_event "  ├─ Probing TCP port ${public_ip}:22..."
    while [[ $elapsed -lt $SSH_PROBE_TIMEOUT ]]; do
        if probe_ssh_port "$public_ip"; then
            log_event "  ├─ Port 22 open. Validating SSH key authentication..."
            if ssh -i "$SSH_KEY_PATH" \
                   -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
                   -o StrictHostKeyChecking=no \
                   -o UserKnownHostsFile=/dev/null \
                   -o BatchMode=yes \
                   "${REMOTE_USER}@${public_ip}" "echo ready" &>/dev/null; then
                return 0
            fi
        fi
        sleep "$SSH_PROBE_INTERVAL"
        elapsed=$(( $(date +%s) - start_time ))
    done

    return 1
}

verify_ssh_and_get_hostname() {
    local public_ip="$1"
    local output
    output=$(ssh -i "$SSH_KEY_PATH" \
                 -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
                 -o StrictHostKeyChecking=no \
                 -o UserKnownHostsFile=/dev/null \
                 -o BatchMode=yes \
                 "${REMOTE_USER}@${public_ip}" "hostname && uptime -p" 2>/dev/null || echo "ubuntu-arm")
    echo "$output" | tr '\n' ' '
}

# ═══════════════════════════════════════════════════════════════════════════════
# STATUS DASHBOARD COMMAND
# ═══════════════════════════════════════════════════════════════════════════════

show_status() {
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  OCI INSTANCE PROVISIONER STATUS (Autonomous Catcher)"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    local service_status
    service_status=$(systemctl --user is-active oci-provisioner.service 2>/dev/null || echo "not-found")
    echo "  Service State   : $service_status"

    local pid
    pid=$(systemctl --user show -p MainPID --value oci-provisioner.service 2>/dev/null || echo "")
    if [[ -n "$pid" && "$pid" != "0" ]]; then
        echo "  Active PID      : $pid"
    else
        echo "  Active PID      : None (stopped)"
    fi

    if check_network; then
        echo "  Network Status  : Online ✓"
    else
        echo "  Network Status  : OFFLINE ✗"
    fi

    if [[ -f ~/.oci/config ]]; then
        echo "  OCI Config      : ~/.oci/config ✓"
    else
        echo "  OCI Config      : MISSING ✗"
    fi

    if [[ -f "$LOG_FILE" ]]; then
        echo ""
        echo "─── Recent Activity Log ──────────────────────────────────────────"
        tail -10 "$LOG_FILE"
        echo ""
        echo "─── Lifetime Scoreboard ─────────────────────────────────────────"
        local total_reqs
        local cap_hits
        local rate_hits
        total_reqs=$(grep -c "Attempt #" "$LOG_FILE" 2>/dev/null || echo 0)
        cap_hits=$(grep -c "Result: CAPACITY" "$LOG_FILE" 2>/dev/null || echo 0)
        rate_hits=$(grep -c "Result: RATE_LIMIT" "$LOG_FILE" 2>/dev/null || echo 0)
        echo "  Total Attempts  : $total_reqs"
        echo "  Capacity (500)  : $cap_hits"
        echo "  Rate-Limit (429): $rate_hits"
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
}

# ═══════════════════════════════════════════════════════════════════════════════
# CLI ENTRY POINT & INITIALIZATION
# ═══════════════════════════════════════════════════════════════════════════════

ACTION="${1:-}"

case "$ACTION" in
    "-h"|"--help")
        print_help
        exit 0
        ;;
    "-s"|"--status")
        show_status
        exit 0
        ;;
    "-t"|"--test")
        validate_config
        MAX_ATTEMPTS=1
        log_event "🧪 TEST MODE: Executing 1 launch attempt to verify OCI credentials"
        ;;
    *)
        validate_config
        MAX_ATTEMPTS=0  # Loop endlessly until instance is secured
        ;;
esac

# Concurrency lock
mkdir -p "$HOME/.oci"
if [[ -f "$LOCK_FILE" ]]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$LOCK_PID" && "$LOCK_PID" != "$$" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
        log_event "⚠️ Provisioner already active (PID: ${LOCK_PID}). Exiting redundant process."
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

SOURCE_DETAILS="{\"sourceType\":\"image\",\"imageId\":\"${IMAGE_OCID}\",\"bootVolumeSizeInGBs\":${BOOT_VOLUME_SIZE_GB},\"bootVolumeVpusPerGb\":${BOOT_VOLUME_VPUS}}"

alert_startup
wait_for_network

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN PROVISIONING LOOP
# ═══════════════════════════════════════════════════════════════════════════════

while [[ $MAX_ATTEMPTS -eq 0 || $ATTEMPT -lt $MAX_ATTEMPTS ]]; do
    ATTEMPT=$((ATTEMPT + 1))

    if ! check_network; then
        wait_for_network
    fi

    CURRENT_DISPLAY_NAME="oci-arm-vm-$(date +%Y%m%d-%H%M%S)"

    # CRITICAL: --no-retry ensures strictly 1 single HTTP request per call (~1s).
    # Eliminates hidden 8-request bursts that caused 429 rate limiting.
    LAUNCH_OUTPUT=$(oci compute instance launch \
        --compartment-id "$COMPARTMENT_ID" \
        --availability-domain "$AVAILABILITY_DOMAIN" \
        --shape "$SHAPE" \
        --shape-config "{\"ocpus\": ${OCPU_COUNT}, \"memoryInGBs\": ${MEMORY_GB}}" \
        --source-details "$SOURCE_DETAILS" \
        --subnet-id "$SUBNET_ID" \
        --display-name "$CURRENT_DISPLAY_NAME" \
        --assign-public-ip true \
        --ssh-authorized-keys-file "${SSH_KEY_PATH}.pub" \
        --no-retry \
        --output json 2>&1) || true

    # ═══════════════════════════════════════════════════════════════════════════
    # STEP 1: CHECK FOR SUCCESS FIRST (STRICT SINGLE-INSTANCE GUARANTEE)
    # ═══════════════════════════════════════════════════════════════════════════
    INSTANCE_ID=$(echo "$LAUNCH_OUTPUT" | sed -n '/^{/,$p' | jq -r '.data.id // empty' 2>/dev/null || true)

    if [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "null" && "$INSTANCE_ID" == ocid1.instance.* ]]; then
        local_launch_time=$(date +%s)
        log_event "🎉 SUCCESS! Instance created: ${INSTANCE_ID}"

        # Phase 1: Poll until state is RUNNING
        log_event "  ├─ Polling instance state until RUNNING (timeout ${INSTANCE_STATE_TIMEOUT}s)..."
        set +e
        wait_for_instance_running "$INSTANCE_ID"
        RUNNING_STATUS=$?
        set -e

        if [[ $RUNNING_STATUS -eq 2 ]]; then
            log_event "  ├─ Instance terminated by OCI during placement. Resuming hunt."
            sleep 30
            continue
        elif [[ $RUNNING_STATUS -ne 0 ]]; then
            log_event "  ├─ Instance state probe timed out. Ceasing launch loop."
            send_telegram "⚠️ Instance ${INSTANCE_ID} created but timed out reaching RUNNING. Check OCI Console."
            exit 0
        fi

        log_event "  ├─ Instance is RUNNING ($(( $(date +%s) - local_launch_time ))s elapsed)"

        # Phase 2: Retrieve Public IP
        set +e
        PUBLIC_IP=$(get_instance_public_ip "$INSTANCE_ID")
        IP_STATUS=$?
        set -e

        if [[ $IP_STATUS -ne 0 || -z "$PUBLIC_IP" ]]; then
            log_event "  ├─ Public IP retrieval timed out after 100s"
            send_telegram "⚠️ Instance ${INSTANCE_ID} is RUNNING but public IP could not be retrieved via API."
            exit 0
        fi

        log_event "  ├─ Public IPv4 assigned: ${PUBLIC_IP}"
        alert_instance_created "$INSTANCE_ID" "$PUBLIC_IP"

        # Phase 3: Wait for cloud-init and validate SSH key authentication
        set +e
        wait_for_ssh_ready "$PUBLIC_IP"
        SSH_STATUS=$?
        set -e

        if [[ $SSH_STATUS -ne 0 ]]; then
            local total_time=$(( $(date +%s) - local_launch_time ))
            log_event "  ├─ SSH readiness probe timed out after ${SSH_PROBE_TIMEOUT}s"
            send_telegram "⚠️ Instance ${INSTANCE_ID} running at ${PUBLIC_IP}, but SSH handshake timed out. Connect manually: ssh -i ${SSH_KEY_PATH} ${REMOTE_USER}@${PUBLIC_IP}"
            exit 0
        fi

        local total_time=$(( $(date +%s) - local_launch_time ))
        log_event "  ├─ SSH verified! Total boot duration: ${total_time}s"

        # Phase 4: Retrieve live hostname and uptime
        HOST_INFO=$(verify_ssh_and_get_hostname "$PUBLIC_IP")
        log_event "  ├─ Verified remote host: ${HOST_INFO}"

        # Phase 5: Celebratory Telegram Alert & Clean Termination
        alert_success "$INSTANCE_ID" "$PUBLIC_IP" "$ATTEMPT" "$total_time" "$HOST_INFO"

        log_event "🏁 Single-instance provisioning completed. Exiting provisioner."
        exit 0
    fi

    # ═══════════════════════════════════════════════════════════════════════════
    # STEP 2: ERROR CLASSIFICATION & ADAPTIVE BACKOFF (ONLY IF NO INSTANCE)
    # ═══════════════════════════════════════════════════════════════════════════
    ERROR_TYPE=$(detect_error_type "$LAUNCH_OUTPUT")

    case "$ERROR_TYPE" in
        "NETWORK")
            TOTAL_NET_ERRORS=$((TOTAL_NET_ERRORS + 1))
            log_event "Attempt #${ATTEMPT} | Result: NETWORK_TIMEOUT | Waiting for connection..."
            wait_for_network
            sleep 15
            continue
            ;;

        "RATE_LIMIT")
            TOTAL_429_HITS=$((TOTAL_429_HITS + 1))
            CONSECUTIVE_429_HITS=$((CONSECUTIVE_429_HITS + 1))
            CONSECUTIVE_CAPACITY_HITS=0
            CONSECUTIVE_AUTH_HITS=0

            # AIMD: Step back interval (+5s)
            if [[ $CURRENT_BASE_INTERVAL -lt $MAX_BASE_INTERVAL ]]; then
                CURRENT_BASE_INTERVAL=$((CURRENT_BASE_INTERVAL + 5))
                log_event "🛡️ AIMD Safety Backoff: Increased base interval to ${CURRENT_BASE_INTERVAL}s"
            fi

            sleep_duration=$(calculate_sleep_duration)
            log_event "Attempt #${ATTEMPT} | Result: RATE_LIMIT (429) | Streak: ${CONSECUTIVE_429_HITS} | Lifetime: ${TOTAL_CAPACITY_HITS} Cap, ${TOTAL_429_HITS} 429s | Backoff: ${sleep_duration}s"

            alert_rate_limit "$sleep_duration"
            sleep "$sleep_duration"
            continue
            ;;

        "CAPACITY")
            TOTAL_CAPACITY_HITS=$((TOTAL_CAPACITY_HITS + 1))
            CONSECUTIVE_CAPACITY_HITS=$((CONSECUTIVE_CAPACITY_HITS + 1))
            CONSECUTIVE_429_HITS=0
            CONSECUTIVE_AUTH_HITS=0

            # AIMD: If 5 clean capacity checks in a row, gently explore faster speed (-2s)
            if [[ $((CONSECUTIVE_CAPACITY_HITS % 5)) -eq 0 && $CURRENT_BASE_INTERVAL -gt $MIN_BASE_INTERVAL ]]; then
                CURRENT_BASE_INTERVAL=$((CURRENT_BASE_INTERVAL - 2))
                log_event "⚡ AIMD Speed Probe: Clean run detected. Testing interval ${CURRENT_BASE_INTERVAL}s"
            fi

            sleep_duration=$(calculate_sleep_duration)
            log_event "Attempt #${ATTEMPT} | Result: CAPACITY (500) | Streak: ${CONSECUTIVE_CAPACITY_HITS} | Lifetime: ${TOTAL_CAPACITY_HITS} Cap, ${TOTAL_429_HITS} 429s | Base: ${CURRENT_BASE_INTERVAL}s | Next: ${sleep_duration}s"

            alert_capacity_digest "$sleep_duration"
            sleep "$sleep_duration"
            continue
            ;;

        "SERVICE_UNAVAILABLE")
            TOTAL_OTHER_ERRORS=$((TOTAL_OTHER_ERRORS + 1))
            CONSECUTIVE_CAPACITY_HITS=0
            CONSECUTIVE_429_HITS=0
            CONSECUTIVE_AUTH_HITS=0

            sleep_duration=$(calculate_sleep_duration)
            log_event "Attempt #${ATTEMPT} | Result: SERVICE_UNAVAILABLE (503/504) | Next: ${sleep_duration}s"
            sleep "$sleep_duration"
            continue
            ;;

        "LIMIT")
            TOTAL_OTHER_ERRORS=$((TOTAL_OTHER_ERRORS + 1))
            CONSECUTIVE_CAPACITY_HITS=0
            CONSECUTIVE_429_HITS=0

            ERROR_MSG=$(extract_oci_error "$LAUNCH_OUTPUT")
            sleep_duration=$(calculate_sleep_duration)
            log_event "Attempt #${ATTEMPT} | Result: QUOTA_LIMIT_EXCEEDED | Next: ${sleep_duration}s"
            sleep "$sleep_duration"
            continue
            ;;

        "AUTH")
            CONSECUTIVE_AUTH_HITS=$((CONSECUTIVE_AUTH_HITS + 1))
            ERROR_MSG=$(extract_oci_error "$LAUNCH_OUTPUT")
            log_event "Attempt #${ATTEMPT} | Result: AUTH_FAILURE (Streak: ${CONSECUTIVE_AUTH_HITS}/3)"

            if [[ $CONSECUTIVE_AUTH_HITS -ge 3 ]]; then
                alert_auth_error "$ERROR_MSG"
                exit 1
            fi
            sleep 30
            continue
            ;;

        "INVALID")
            ERROR_MSG=$(extract_oci_error "$LAUNCH_OUTPUT")
            log_event "Attempt #${ATTEMPT} | Result: INVALID_REQUEST | $ERROR_MSG"
            echo "❌ Invalid parameter error from OCI: ${ERROR_MSG}"
            exit 1
            ;;

        "GENERIC")
            TOTAL_OTHER_ERRORS=$((TOTAL_OTHER_ERRORS + 1))
            ERROR_MSG=$(extract_oci_error "$LAUNCH_OUTPUT")
            sleep_duration=$(calculate_sleep_duration)
            log_event "Attempt #${ATTEMPT} | Result: GENERIC_ERROR | Detail: ${ERROR_MSG:0:100} | Next: ${sleep_duration}s"
            sleep "$sleep_duration"
            continue
            ;;
    esac

    # Fallback safety sleep
    sleep 90
done

exit 0
