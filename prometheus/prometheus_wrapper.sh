#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose:  Take the output of the prometheus scripts and send emails when necessary.
#           This is used for servers in AWS where prometheus is not configured so that
#           prometheus alerts can still go out via email.
#
# Note:     This script must be ran as the oracle user.
#
#####################################################################################

# Parse a prometheus output file and append any alerts to ALERT_BODY.
# $1 = tmpfile path, $2 = label for error messages (e.g. SID name or "global")
parse_prom_output() {
    local tmpfile="$1"
    local sid="$2"

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == "#"* ]] && continue

        local metric_name="${line%%{*}"
        local value
        value=$(awk '{print $NF}' <<< "$line")

        case "$metric_name" in
            oracle_long_running_jobs)
                if (( $(echo "$value > $LONGRUN_THRESHOLD" | bc -l) )); then
                    local runtime_hr sql_id sql_text
                    runtime_hr=$(echo "scale=2; $value / 3600" | bc)
                    sql_id=$(grep -oP 'sql_statement_id="\K[^"]+' <<< "$line")
                    sql_text=$(grep -oP 'sql_statement_text="\K[^"]+' <<< "$line")
                    ALERT_BODY+="[LONGRUN] SID=$sid runtime=${runtime_hr}hr sql_id=$sql_id sql_text='$sql_text'\n"
                fi
                ;;
            oracle_tablespace_used_pcnt)
                if (( $(echo "$value > $TABLESPACE_THRESHOLD" | bc -l) )); then
                    ALERT_BODY+="[TABLESPACE] SID=$sid used=${value}%\n"
                fi
                ;;
            oracle_connect_status)
                # check_oracle is run as global so we need to extract the sid from each line
                sid=$(echo "$line" | sed 's/^.*{sid="\(.*\)"}.*$/\1/')
                if [ "$value" -ne 1 ]; then
                    ALERT_BODY+="[CONNECT] SID=$sid\n"
                fi
            ;;
            tns_error)
                tns_error=$(echo "$line" | sed 's/^.*error="\(.*\)".*$/\1/')
                sid=$(echo "$line" | sed 's/^.*database="\([^"]*\)",.*$/\1/')
                if (( $(echo "$value > 0" | bc -l) )); then
                    ALERT_BODY+="[TNS ERROR] SID=$sid tns_error=$tns_error\n"
                fi
                ;;
            *error*)
                # Generic catch-all for any other error metric
                if (( $(echo "$value > 0" | bc -l) )); then
                    ALERT_BODY+="[ERROR] $line\n"
                fi
                ;;
        esac
    done < "$tmpfile"
}

usage="Usage: prometheus_wrapper.sh"
example="Example: prometheus_wrapper.sh"

# Process input options
while getopts ":h" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

vm_user=$(whoami)
if [ "$vm_user" != "oracle" ]; then
    echo "This script must be ran as the oracle user. You are $vm_user. Exiting..."
    exit 1
fi

if [ -f "$HOME/.bashrc" ]; then
    source "$HOME/.bashrc"
    if [ $? -ne 0 ]; then
        echo "An error occurred while sourcing $HOME/.bashrc"
        exit 1
    fi
else
    echo "Could not find $HOME/.bashrc. Exiting..."
    exit 1
fi

SCRIPT_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_PATH+="/"

# Scripts that run once per SID: <script> <sid> <user> <pass>
SID_SCRIPT_LIST="check_oracle_longrun_sql check_oracle_tablespaces"
# Scripts that run once globally (not per SID)
GLOBAL_SCRIPT_LIST="CheckForTNSErrors check_oracle"

HOSTNAME=$(hostname)

# Alert thresholds
LONGRUN_THRESHOLD=3600  # Alert if SQL runtime exceeds 1 hour (in seconds)
TABLESPACE_THRESHOLD=80  # Alert if tablespace used % exceeds this value

# CheckForTNSErrors parameters
TNS_INTERVAL=120         # Look back this many minutes for TNS errors
TNS_ERRORS="TNS-12516,TNS-12528"

# Create a list of open SIDs
OPEN_SIDs=$("$HOME/common/oracle/VerifyAllParam.sh" -V ALL)
if [ $? -ne 0 ]; then
    echo "An error occurred while trying to determine open sids. Exiting..."
    exit 1
fi

ALERT_BODY=""
ERROR_BODY=""

# Run SID-based scripts in parallel across all open SIDs
for script in $SID_SCRIPT_LIST; do
    pids=()
    sids=()
    tmpfiles=()

    for sid in $OPEN_SIDs; do
        tmpfile="/tmp/${script}-${sid}-wrapper.tmp"
        "$SCRIPT_PATH${script}.sh" "$sid" > "$tmpfile" &
        pids+=("$!")
        sids+=("$sid")
        tmpfiles+=("$tmpfile")
    done

    for ((i=0; i<${#pids[@]}; i++)); do
        wait "${pids[i]}"
        exit_code=$?
        sid="${sids[i]}"
        tmpfile="${tmpfiles[i]}"

        if [ "$exit_code" -ne 0 ]; then
            ERROR_BODY+="Script ${script}.sh failed for SID $sid (exit code: $exit_code)\n"
            cat "$tmpfile"
            rm -f "$tmpfile"
            continue
        fi

        parse_prom_output "$tmpfile" "$sid"
    done
done

# Run global scripts once (not per SID)
for script in $GLOBAL_SCRIPT_LIST; do
    tmpfile="/tmp/${script}-wrapper.tmp"

    case "$script" in
        CheckForTNSErrors)
            "$SCRIPT_PATH${script}.sh" -p "$TNS_INTERVAL" "$TNS_ERRORS" > "$tmpfile"
            ;;
        *)
            "$SCRIPT_PATH${script}.sh" > "$tmpfile"
            ;;
    esac
    exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        ERROR_BODY+="Script ${script}.sh failed (exit code: $exit_code)\n"
        cat "$tmpfile"
        continue
    fi

    parse_prom_output "$tmpfile" "global"
done

# Send email if any alerts or errors were found
if [ -n "$ALERT_BODY" ] || [ -n "$ERROR_BODY" ]; then
    result=$(
        echo "Prometheus alert(s) detected on $HOSTNAME at $(date)"
        echo ""

        if [ -n "$ERROR_BODY" ]; then
            echo "=== SCRIPT ERRORS ==="
            echo -e "$ERROR_BODY"
        fi

        if [ -n "$ALERT_BODY" ]; then
            echo "=== ALERTS ==="
            echo -e "$ALERT_BODY"
        fi
    )
    
    # $ALL_DBA_EMAIL_LIST is deliberately unquoted: s-nail (mailx on RHEL 9) takes one address per argument,
    # so a space-separated list must be split by the shell into one argument per address.
    # Check if the user is using a terminal (as opposed to nohup/cron)
    if [ -t 1 ]; then
        echo "$result" | tee /dev/tty | mailx -s "Prometheus Alert - $HOSTNAME" $ALL_DBA_EMAIL_LIST
    else
        echo "$result" | mailx -s "Prometheus Alert - $HOSTNAME" $ALL_DBA_EMAIL_LIST
    fi
else
    echo "No alerts detected on $HOSTNAME at $(date)"
fi
