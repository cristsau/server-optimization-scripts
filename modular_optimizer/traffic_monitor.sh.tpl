#!/bin/bash
# Generated traffic monitor script v__CURRENT_VERSION__
# Based on user script, adapted for modular framework configuration.

# --- Robustness ---
set -uo pipefail

# --- Configuration Placeholders (Will be replaced by sed) ---
# These values are embedded during generation by lib_install.sh reading /etc/traffic_monitor.conf
# Do NOT source the config file here; values are baked in.
TELEGRAM_BOT_TOKEN="__TELEGRAM_BOT_TOKEN__"
CHAT_ID="__CHAT_ID__"
LIMIT_GB="__LIMIT_GB__"
RESET_DAY="__RESET_DAY__"
SSH_PORT="__SSH_PORT__"
OVER_LIMIT_ACTION="__OVER_LIMIT_ACTION__"
# Use standard log and flag locations
LOG_FILE="/var/log/traffic_monitor.log"
FLAG_DIR="/var/run/traffic_monitor" # Use /var/run for volatile flags
DAILY_REPORT_SENT_FLAG="$FLAG_DIR/daily_report_sent"
THRESHOLD_1_FLAG="$FLAG_DIR/vnstat_threshold_1" # Assuming thresholds might be configurable later
THRESHOLD_2_FLAG="$FLAG_DIR/vnstat_threshold_2"
THRESHOLD_3_FLAG="$FLAG_DIR/vnstat_threshold_3"
VNSTAT_RESET_FLAG="$FLAG_DIR/vnstat_reset"

# --- Initialization and Function Definitions ---

# Ensure log and flag directories exist
mkdir -p "$(dirname "$LOG_FILE")" || { echo "Error creating log directory $(dirname "$LOG_FILE")"; exit 1; }
mkdir -p "$FLAG_DIR" || { echo "Error creating flag directory $FLAG_DIR"; exit 1; }
touch "$LOG_FILE" || { echo "Error touching log file $LOG_FILE"; exit 1; }
chmod 644 "$LOG_FILE" # Ensure log is readable

# Logging function specific to this script
log_message() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Send message to Telegram function (only if token/chatid provided)
send_to_telegram() {
  local message="$1"
  if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$CHAT_ID" ]; then
      log_message "Sending notification to Telegram..."
      # Use timeout to prevent curl hanging indefinitely
      timeout 15s curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d text="$message" \
        -d parse_mode="Markdown"
      if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to send message to Telegram (curl exit code $? or timeout)."
      else
        log_message "Telegram notification sent."
      fi
  else
      log_message "INFO: Telegram token or chat ID not configured, skipping notification."
  fi
}

# --- Dependency Checks ---
# Check essential commands needed by this generated script
essential_commands=("vnstat" "bc" "curl" "iptables" "ip" "awk" "sed" "grep" "date" "cut" "tr" "head" "date" "mkdir" "touch" "chmod" "rm")
if [[ "$OVER_LIMIT_ACTION" == "shutdown" ]]; then essential_commands+=("shutdown"); fi
if command -v ip6tables >/dev/null 2>&1; then essential_commands+=("ip6tables"); fi

for cmd in "${essential_commands[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_message "FATAL ERROR: Required command '$cmd' not found. Exiting."
        # Optionally send a Telegram message if possible
        send_to_telegram "$(date '+%Y-%m-%d %H:%M:%S') Traffic Monitor FATAL ERROR: Command '$cmd' not found!"
        exit 1
    fi
done
log_message "Dependency check passed."


# --- Main Logic ---
log_message "--- Traffic Monitor Check Started ---"

# 1. Detect Network Interface
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n 1)
if [ -z "$INTERFACE" ]; then
  log_message "ERROR: Could not detect default network interface."
  send_to_telegram "$(date '+%Y-%m-%d %H:%M:%S') Traffic Monitor ERROR: Cannot detect network interface."
  exit 1
fi
log_message "Monitoring network interface: $INTERFACE"

# Ensure vnstat is tracking the interface
if ! vnstat -i "$INTERFACE" > /dev/null 2>&1; then
    log_message "INFO: Interface $INTERFACE not found in vnstat database or vnstatd not running. Attempting to add/enable..."
    # Use vnstat add or enable (depends on version, -u is safer for update/create)
    vnstat -u -i "$INTERFACE" --force
    if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to add/update interface $INTERFACE in vnstat database."
        send_to_telegram "$(date '+%Y-%m-%d %H:%M:%S') Traffic Monitor ERROR: Failed to init vnstat for interface $INTERFACE."
        # Decide whether to exit or continue without data
        exit 1 # Exit if vnstat cannot be initialized
    else
        log_message "Interface $INTERFACE added/updated in vnstat database. Waiting for data..."
        # Give vnstatd some time to collect initial data if just added
        sleep 5
    fi
fi


# 2. Calculate Limits in MiB
# Ensure LIMIT_GB is treated as a number, default to 0 if invalid (means no limit)
[[ ! "$LIMIT_GB" =~ ^[0-9]+$ ]] && LIMIT_GB=0
LIMIT_MIB=$(echo "$LIMIT_GB * 1024" | bc)
log_message "Traffic limit configured: $LIMIT_GB GB ($LIMIT_MIB MiB)"
# Note: Thresholds (like 80%, 90%) were removed from interactive config,
# but the flags remain if needed later. We only check the main LIMIT_GB now.


# 3. Handle Monthly Reset
CURRENT_DAY=$(date +'%-d')
LAST_DAY_OF_MONTH=$(date -d "$(date +'%Y%m01') +1 month -1 day" +%d)
# Ensure RESET_DAY is valid
[[ ! "$RESET_DAY" =~ ^[0-9]+$ ]] && RESET_DAY=1
[[ "$RESET_DAY" -lt 1 || "$RESET_DAY" -gt 31 ]] && RESET_DAY=1

IS_RESET_DAY=false
if [ "$CURRENT_DAY" -eq "$RESET_DAY" ]; then IS_RESET_DAY=true;
elif [ "$RESET_DAY" -gt "$LAST_DAY_OF_MONTH" ] && [ "$CURRENT_DAY" -eq "$LAST_DAY_OF_MONTH" ]; then IS_RESET_DAY=true; fi

if $IS_RESET_DAY; then
  if [ ! -f "$VNSTAT_RESET_FLAG" ]; then
    log_message "Reset day ($RESET_DAY) detected. Attempting traffic data reset for $INTERFACE..."
    # Use vnstat --delete (newer versions) or --reset (older) - try delete first
    if vnstat --delete -i "$INTERFACE" --force >/dev/null 2>&1; then
        log_message "vnstat data deleted successfully for $INTERFACE."
    elif vnstat --reset -i "$INTERFACE" --force >/dev/null 2>&1; then # Fallback for older vnstat
        log_message "vnstat data reset successfully for $INTERFACE."
    else
        log_message "ERROR: Failed to delete/reset vnstat data for $INTERFACE. Trying database clear..."
        # Fallback: Try clearing the database file (use with caution)
        if cp /var/lib/vnstat/"$INTERFACE" /var/lib/vnstat/"$INTERFACE.bak.$(date +%s)"; then
            if echo "" > /var/lib/vnstat/"$INTERFACE"; then
                log_message "Cleared vnstat database file for $INTERFACE."
            else
                log_message "ERROR: Failed to clear vnstat database file for $INTERFACE."
                send_to_telegram "$(date '+%Y-%m-%d %H:%M:%S') Traffic Monitor ERROR: Failed to reset vnstat data."
                # Don't touch flags or restart if clearing failed
                exit 1 # Exit if reset completely fails
            fi
        else
             log_message "ERROR: Failed to backup vnstat database file for $INTERFACE before clearing."
             send_to_telegram "$(date '+%Y-%m-%d %H:%M:%S') Traffic Monitor ERROR: Failed to reset vnstat data (backup failed)."
             exit 1
        fi
    fi
    # Restart vnstat service after successful delete/reset/clear
    if systemctl restart vnstat; then
        log_message "vnstat service restarted successfully."
        log_message "Traffic data reset completed. Next reset on day $RESET_DAY."
        rm -f "$THRESHOLD_1_FLAG" "$THRESHOLD_2_FLAG" "$THRESHOLD_3_FLAG" # Clear old threshold flags
        touch "$VNSTAT_RESET_FLAG" # Mark reset done for today
    else
        log_message "ERROR: Failed to restart vnstat service after reset."
        send_to_telegram "$(date '+%Y-%m-%d %H:%M:%S') Traffic Monitor ERROR: Failed to restart vnstat after reset."
        # Mark as done anyway to avoid loops, but log the error.
        touch "$VNSTAT_RESET_FLAG"
    fi
  else
    log_message "Reset already performed today."
  fi
else
  # Not reset day, ensure reset flag is removed
  if [ -f "$VNSTAT_RESET_FLAG" ]; then rm -f "$VNSTAT_RESET_FLAG"; log_message "Removed daily reset flag."; fi
  # Calculate days until next reset
  local DAYS_UNTIL_RESET=0
  if [ "$CURRENT_DAY" -lt "$RESET_DAY" ] && [ "$RESET_DAY" -le "$LAST_DAY_OF_MONTH" ]; then DAYS_UNTIL_RESET=$((RESET_DAY - CURRENT_DAY));
  elif [ "$RESET_DAY" -gt "$LAST_DAY_OF_MONTH" ]; then DAYS_UNTIL_RESET=$((LAST_DAY_OF_MONTH - CURRENT_DAY)); # Reset on last day
  else DAYS_UNTIL_RESET=$((LAST_DAY_OF_MONTH - CURRENT_DAY + RESET_DAY)); fi
  log_message "$DAYS_UNTIL_RESET days until next traffic reset (approx)."
fi


# 4. Get Current Monthly Traffic
log_message "Fetching traffic data for $INTERFACE..."
DATA=$(vnstat -i "$INTERFACE" --oneline)
if [ $? -ne 0 ]; then
    log_message "ERROR: vnstat command failed when fetching data for $INTERFACE."
    send_to_telegram "$(date '+%Y-%m-%d %H:%M:%S') Traffic Monitor ERROR: vnstat command failed for $INTERFACE."
    exit 1
fi
log_message "vnstat raw data: $DATA"

# Parse month, RX, TX (Fields 8, 9, 10)
CURRENT_MONTH=$(echo "$DATA" | cut -d ';' -f 8)
TRAFFIC_RX_RAW=$(echo "$DATA" | cut -d ';' -f 9 | tr -d ' ')
TRAFFIC_TX_RAW=$(echo "$DATA" | cut -d ';' -f 10 | tr -d ' ')

# Convert RX/TX to MiB using bc
TRAFFIC_RX_MIB=$(echo "$TRAFFIC_RX_RAW" | sed 's/TiB/*1024*1024/;s/GiB/*1024/;s/MiB//;s/KiB/\/1024/' | bc -l 2>/dev/null || echo "0")
TRAFFIC_TX_MIB=$(echo "$TRAFFIC_TX_RAW" | sed 's/TiB/*1024*1024/;s/GiB/*1024/;s/MiB//;s/KiB/\/1024/' | bc -l 2>/dev/null || echo "0")

log_message "Current month ($CURRENT_MONTH) usage: RX=$TRAFFIC_RX_RAW ($TRAFFIC_RX_MIB MiB), TX=$TRAFFIC_TX_RAW ($TRAFFIC_TX_MIB MiB)"

# Determine traffic to check against limit (Max of RX or TX)
TRAFFIC_TO_CHECK_MIB=$(echo "$TRAFFIC_TX_MIB $TRAFFIC_RX_MIB" | awk '{if ($1+0 > $2+0) print $1; else print $2}')
log_message "Traffic to check (Max(RX, TX)): $TRAFFIC_TO_CHECK_MIB MiB"


# 5. Check Limit and Take Action (only if LIMIT_GB > 0)
if [[ "$LIMIT_GB" -gt 0 ]]; then
    log_message "Checking against limit: $LIMIT_GB GB ($LIMIT_MIB MiB)"
    if (( $(echo "$TRAFFIC_TO_CHECK_MIB > $LIMIT_MIB" | bc -l) )); then
        log_message "WARNING: Traffic limit exceeded! Used: $TRAFFIC_TO_CHECK_MIB MiB."
        case "$OVER_LIMIT_ACTION" in
            limit_net)
                log_message "Action: Limiting network (iptables)..."
                send_to_telegram "$(date '+%Y-%m-%d %H:%M:%S') 警告: 服务器 [$HOSTNAME] 流量已超限 (${TRAFFIC_TO_CHECK_MIB} MiB / ${LIMIT_MIB} MiB)！将限制网络，仅保留 SSH (端口 $SSH_PORT)。"
                # Apply IPv4 Rules
                iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT ACCEPT;
                iptables -F INPUT; iptables -F FORWARD; # Flush rules first
                iptables -A INPUT -i lo -j ACCEPT
                iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
                iptables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
                iptables -A INPUT -p icmp -j ACCEPT # Allow ping responses in
                log_message "IPv4 rules applied."
                # Apply IPv6 Rules if ip6tables exists
                if command -v ip6tables >/dev/null 2>&1; then
                    ip6tables -P INPUT DROP; ip6tables -P FORWARD DROP; ip6tables -P OUTPUT ACCEPT;
                    ip6tables -F INPUT; ip6tables -F FORWARD;
                    ip6tables -A INPUT -i lo -j ACCEPT
                    ip6tables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
                    ip6tables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
                    ip6tables -A INPUT -p icmpv6 -j ACCEPT
                    log_message "IPv6 rules applied."
                else log_message "ip6tables not found, skipping IPv6 rules."; fi
                # Consider saving rules if persistence is needed: iptables-save > /etc/iptables/rules.v4; ip6tables-save > /etc/iptables/rules.v6
                ;;
            shutdown)
                log_message "Action: Shutting down system NOW!"
                send_to_telegram "$(date '+%Y-%m-%d %H:%M:%S') 紧急警告: 服务器 [$HOSTNAME] 流量已超限 (${TRAFFIC_TO_CHECK_MIB} MiB / ${LIMIT_MIB} MiB)！系统将立即关机！"
                sleep 5 # Give time for message to potentially send
                shutdown -h now
                ;;
            notify_only)
                log_message "Action: Sending notification only."
                send_to_telegram "$(date '+%Y-%m-%d %H:%M:%S') 警告: 服务器 [$HOSTNAME] 流量已超限 (${TRAFFIC_TO_CHECK_MIB} MiB / ${LIMIT_MIB} MiB)！未执行限制操作。"
                ;;
            *)
                log_message "WARNING: Unknown OVER_LIMIT_ACTION '$OVER_LIMIT_ACTION' defined in config. Taking no action."
                ;;
        esac
    else
        log_message "Traffic within limits."
        # Restore firewall only if it was previously restricted by this script (check policy)
        if ! iptables -L INPUT -n | grep -q "policy ACCEPT"; then
            log_message "Restoring default firewall policies (IPv4)..."
            iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT;
            iptables -F; iptables -t nat -F; iptables -t mangle -F; log_message "IPv4 restored.";
        fi
        if command -v ip6tables >/dev/null 2>&1 && ! ip6tables -L INPUT -n | grep -q "policy ACCEPT"; then
            log_message "Restoring default firewall policies (IPv6)..."
            ip6tables -P INPUT ACCEPT; ip6tables -P FORWARD ACCEPT; ip6tables -P OUTPUT ACCEPT;
            ip6tables -F; ip6tables -t mangle -F; log_message "IPv6 restored.";
        fi
    fi
else
    log_message "Traffic limit check skipped (LIMIT_GB is 0)."
fi

# 6. Daily Report Logic (Simplified - Send around specific hour, e.g., 9 AM)
REPORT_HOUR=9 # Hour for daily report
current_hour=$(date +%H)
if [ "$current_hour" -eq $REPORT_HOUR ]; then
    if [ ! -f "$DAILY_REPORT_SENT_FLAG" ]; then
        log_message "Generating daily report (Hour: $current_hour)..."
        # Prepare report message (reuse parsed data if possible, or re-fetch)
        local REPORT_RX_GB=$(echo "scale=1; $TRAFFIC_RX_MIB / 1024" | bc)
        local REPORT_TX_GB=$(echo "scale=1; $TRAFFIC_TX_MIB / 1024" | bc)
        local REPORT_MAX_GB=$(echo "scale=1; $TRAFFIC_TO_CHECK_MIB / 1024" | bc)
        local REMAINING_LIMIT_MIB=0 REMAINING_LIMIT_GB=0 REMAINING_LIMIT_PERCENT=0
        if [[ "$LIMIT_GB" -gt 0 ]]; then
            REMAINING_LIMIT_MIB=$(echo "$LIMIT_MIB - $TRAFFIC_TO_CHECK_MIB" | bc)
            if (( $(echo "$REMAINING_LIMIT_MIB < 0" | bc -l) )); then REMAINING_LIMIT_MIB=0; fi
            REMAINING_LIMIT_GB=$(echo "scale=1; $REMAINING_LIMIT_MIB / 1024" | bc)
            REMAINING_LIMIT_PERCENT=$(echo "scale=1; ($REMAINING_LIMIT_MIB * 100) / $LIMIT_MIB" | bc)
             if (( $(echo "$REMAINING_LIMIT_PERCENT < 0" | bc -l) )); then REMAINING_LIMIT_PERCENT=0.0; fi
        else
             REMAINING_LIMIT_GB="N/A" # No limit set
             REMAINING_LIMIT_PERCENT="N/A"
        fi

        local report_message; report_message=$(cat <<-END_MSG
        *服务器 [$HOSTNAME] 每日流量报告*
        时间: $(date '+%Y-%m-%d %H:%M')
        接口: $INTERFACE
        月份: $CURRENT_MONTH
        已用 (上传): $TRAFFIC_TX_RAW ($REPORT_TX_GB GB)
        已用 (下载): $TRAFFIC_RX_RAW ($REPORT_RX_GB GB)
        已用总量 (计费): $REPORT_MAX_GB GB / $LIMIT_GB GB
        剩余可用 (估算): $REMAINING_LIMIT_GB GB ($REMAINING_LIMIT_PERCENT %)
        END_MSG
        )
        send_to_telegram "$report_message" && touch "$DAILY_REPORT_SENT_FLAG" && log_message "Daily report sent."
    else
        log_message "Daily report already sent today."
    fi
else
    # Reset flag outside the reporting hour
    if [ -f "$DAILY_REPORT_SENT_FLAG" ]; then rm -f "$DAILY_REPORT_SENT_FLAG"; log_message "Reset daily report flag."; fi
fi


log_message "--- Traffic Monitor Check Finished ---"
exit 0
