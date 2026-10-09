#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: The purpose of this script is to monitor the oracle listener log for TNS errors. The
#          user can specify specific errors to include in the output and can specify an option -p
#          to map error logging output to the key/value format that Prometheus can read. The user
#          can also specify a time interval in minutes. If the user specifies X minutes for this
#          parameter, the script will only report TNS errors that occurred within the past X
#          minutes.
#
# NOTE: The -p option can only be used with the TNS-12516 and TNS-12528 errors because the -p
#       option requires mapping each TNS error to a service name. These are the only two errors
#       that have thus far been found to consistently be logged in the TNS log file following the
#       relevant service name.
#
#####################################################################################
usage="Usage: CheckForTNSErrors.sh [-p (prometheus output format, optional)] [time interval (minutes)] [TNS errors to include (comma separated)]"
example="Example: CheckForTNSErrors.sh -p 5 TNS-12516,TNS-12528"

# Process input options
popt=""
while getopts ":hp" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    p)
        popt=1
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done
shift "$((OPTIND-1))"

if [ $# -ne 2 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# set your Oracle environment here
source "$HOME/.bashrc"
if [ $? -ne 0 ]; then
    echo "An error occurred while sourcing $HOME/.bashrc. Exiting..."
    exit 1
fi

# Set time interval variable
time_interval="$1"
if [[ ! "$time_interval" =~ ^[0-9]+$ ]]; then
    echo "The time in minutes must be a positive whole number. Exiting..."
    exit 1
fi

# Validate/convert the provided date into YYYY-MM-DDTHH:MM:SS.microseconds+offset and discard the error output
converted_date=$(date -d "$time_interval minutes ago" +"%Y-%m-%dT%H:%M:%S.%6N%:z" 2>/dev/null)
if [ $? -ne 0 ]; then
    echo "Error, given time interval in minutes \"$time_interval\" is invalid. Exiting..."
    exit 1
fi

# Define errors regex pattern matching string by replacing ',' with '|'
errors=""
# Read TNS errors to include in indexed array 'error_codes', separate them by ','
# IFS is temporarily set to ',' for the read command below
IFS=',' read -ra error_codes <<< "$2"
for code in "${error_codes[@]}"; do
    if [[ ! "$code" =~ ^TNS-[0-9]{5}$ ]]; then
        echo "Error: Invalid error code format for $code. Should be TNS- followed by 5 digits. Exiting..."
        exit 1
    fi
    errors+="$code|"
done
# Remove trailing |
errors="${errors:0:-1}"

# If -p option is used, verify that no error code other than TNS-12516 or TNS-12528 was passed
if [ -n "$popt" ]; then
    if [[ "$errors" != "TNS-12516|TNS-12528" ]] && [[ "$errors" != "TNS-12516" ]] && [ "$errors" != "TNS-12528" ]; then
        echo "Error: TNS error code $errors not valid when using -p option"
        echo "Only TNS-12516 and TNS-12528 are valid errors to include when using -p option"
        echo "Exiting..."
        exit 1
    fi
fi

# Add the server name into the path. For instance if the server name is my-host this would add 'my-host' to the path
tns_log_file="$ORACLE_BASE"/diag/tnslsnr/$(hostname | cut -d. -f1)/listener/alert/log.xml
if [ ! -f "$tns_log_file" ]; then
    echo "TNS alert log does not exist at '$tns_log_file' where it is expected. Exiting..."
    exit 1
fi

# Defines an 'afterDate' variable as '$converted_date' and then searches for times (with YYYY-MM-DD-THH:MM:SS.<fractional second><+ or - timezone offset>)
# If the time is less than the afterDate, save its line number to latest_line, continue until the end of 'tns_log_file'
# Result: Find the last line in the 'tns_log_file' before the time range
line_num=$(awk \
    -v afterDate="$converted_date" \
    -v re="time=['\"]([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\\\.[0-9]+[+-][0-9]{2}:[0-9]{2})['\"]" '{
        if (match($0, re, m)) {
            logDate = m[1]
            if (logDate < afterDate) {
                latest_line = NR
            }
        }
    } END { if (latest_line) print latest_line; else print 0 }' "$tns_log_file")
if [ $? -ne 0 ]; then
    echo "$line_num"
    echo "Error occurred while finding line number from date in TNS log. Exiting..."
    exit 1
fi
# Use line_num to find out how many lines to tail
if [ "$line_num" -ne 0 ]; then
    # wc -l "$tns_log_file" counts the lines in tns_log_file
    # Then subtract the last line before the time range from the total lines in the file
    tail_lines_to_check=$(( $(wc -l "$tns_log_file" | awk '{print $1}') - line_num))
else
    tail_lines_to_check=$(wc -l "$tns_log_file" | awk '{print $1}')
fi

text_in_range=$(tail -n "$tail_lines_to_check" "$tns_log_file")
tns_error=$(echo "$text_in_range" | grep -E "$errors" )
if [ -z "$popt" ]; then
    if [ -z "$tns_error" ]; then
        echo "No ${errors//|/,} errors within this time interval"
    else
        echo "$tns_error"
    fi
    exit 0
fi

if [ -n "$popt" ]; then
    # Find all open SIDs and add their tns error logs to prometheus output for TNS-12516 and TNS-12528
    dbs=$("$HOME/common/oracle/PrintAllRunningDatabases.sh" -i)
    dbs_status=$?
    # No running databases means there are no metrics to report. Without this check the
    # "No running databases. Exiting..." message is looped over below as if it were a list of SIDs.
    if [ "$dbs" == "No running databases. Exiting..." ]; then
        exit 0
    fi
    if [ $dbs_status -ne 0 ]; then
        echo "$dbs"
        echo "Error occurred while running PrintAllRunningDatabases.sh. Exiting..."
        exit 1
    fi

    output=""
    for db in $dbs; do
        # Replace '|' with ' ' in $errors so it can be looped through without changing IFS
        for error in ${errors//|/ }; do
            # Grep for service name and each of the TNS errors and count how many times each error
            # appears for each database then append to output
            count=$(echo "$text_in_range" | grep "(SERVICE_NAME=$db)" -A 6 | grep -c "<txt>$error: ")
            output+="tns_error{database=\"$db\", error=\"$error\"} $count\n"
        done
    done

    echo -e "${output::-2}"
fi
