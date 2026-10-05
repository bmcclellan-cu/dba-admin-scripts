#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose:  The purpose of this script is to print all databases with a running `smon`
#           process that aren't running inside a container. This script does not guarantee
#           that the database is open, just that it is running in some capacity.
#
# Notes:    We exclude database processes running inside containers from this script's output
#           because we utilize containerization for our testing suite, and the Oracle processes
#           therein interfere with our script suite.
#
#           This script filters out Oracle processes that are running inside containers
#           by checking their environment variables and cgroup entries. When this script
#           is used as a helper script, the -i option is used to prevent these checks from
#           causing cascade failures if the checks break, as the scripts that depend on this
#           script are utilized throughout our codebase
#
################################################################################

usage="Usage: PrintAllRunningDatabases.sh [ -p (include smon PIDs in output) ] [ -i (ignore errors during process container membership checks) ] [ -s (option for space delimited output) | -c (option for csv output) ]"
example="Example: PrintAllRunningDatabases.sh -c"

csv=false
ssv=false
ignore_container_check_errors=0
print_pids=0
# Process input options
while getopts ":hcsip" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    c)
        csv=true
        ;;
    s)
        ssv=true
        ;;
    i)
        ignore_container_check_errors=1
        ;;
    p)
        print_pids=1
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

shift $((OPTIND-1))

# Check that no inputs were entered
if [ $# -ne 0 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Checks if a process is running in a container by checking cgroup and environment variable heuristics.
# Inputs:
#   proc_pid: PID of the process to inspect
# Return Value:
#   0: Non-containerized process
#   1: Containerized process
check_proc_in_container(){
    local proc_pid=$1
    local smon_cgroup exit_code smon_environ container_variable

    # Check cgroup membership for references to a container engine
    # Capture stderr output to prevent leakage with the -i option.
    smon_cgroup=$(cat "/proc/$proc_pid/cgroup" 2>&1)
    exit_code=$?
    # If an error occurs and the -i flag is passed, just suppress the error and continue
    if [ "$exit_code" -ne 0 ] && [ "$ignore_container_check_errors" -ne 0 ]; then
        smon_cgroup=""
    elif [ "$exit_code" -ne 0 ]; then
        echo "$smon_cgroup"
        echo "An error occurred while checking if process $proc_pid is running inside a container, couldn't get cgroup information. Exiting..."
        exit 1
    fi

    # Check if the cgroup membership has any references to a container engine.
    # grep -q: Quiet, does not output matching lines, only returns success code
    # grep -i: Case insensitive match
    # grep -E: Grep extended regex, allows use of '|'
    if echo "$smon_cgroup" | grep -qiE 'podman|docker'; then
        return 1
    fi

    # Check environment variables. Podman's implicit starting build layer sets container=podman
    # by default.
    # Note: /proc/<PID>/environ is a null-delimited array of the environment variables of the process when
    #       it was started, and bash string variables are unable to store nulls, so we must substitute them
    #       out for newlines.
    # Capture stderr output to prevent leakage with the -i option.
    smon_environ=$(tr '\0' '\n' 2>&1 < "/proc/$proc_pid/environ")
    exit_code=$?
    # If an error occurs and the -i flag is passed, just suppress the error and continue
    if [ "$exit_code" -ne 0 ] && [ "$ignore_container_check_errors" -ne 0 ]; then
        smon_environ=""
    elif [ $exit_code -ne 0 ]; then
        echo "$smon_environ"
        echo "An error occurred while reading environment variables of the smon process for process $proc_pid. Exiting..."
        exit 1
    fi

    # Extracts the value of the container environment variable
    container_variable=$(echo "$smon_environ" | grep "^container=" | cut -d= -f2)

    # If the variable is ever non-empty, we deem it as running in a container. It is extremely unlikely that
    # a non-containerized Oracle process would ever be run with the `container` environment variable set.
    if [ -n "$container_variable" ]; then
        return 1
    fi

    return 0
}

if $csv && $ssv; then
    echo "ERROR: -c and -s cannot be used at the same time. Exiting..."
    exit 1
fi

# Check if this script is being run from inside a container. If this is the case, don't run the checks
# to allow our test suite to function appropriately.
check_proc_in_container "$$"
script_in_container=$?


# Get all process names that begin with ora_smon_
# pgrep -a: List full process name alongside PID
# pgrep -f: Match pattern against full process name
# pgrep -x: Must match pattern exactly (no substrings)
smon_processes=$(pgrep -afx 'ora_smon_.*')
# pgrep returns status 1 if no results are found, so we treat 0 and 1 as successes.
if [ $? -gt 1 ]; then
    echo "$smon_processes"
    echo "An error occurred while getting list of DB smon processes. Exiting..."
    exit 1
fi

# Strip out PIDs that are running inside docker containers. This is done to exclude PIDs from the
# DBs running inside of our test suite.
IFS=$'\n'
databases=()
for smon_process in $smon_processes; do
    IFS=" " read -r smon_pid smon_proc_name <<< "$smon_process"

    # Only run container checks if not currently running in a container.
    if [ $script_in_container -ne 1 ]; then
        # Function returns 1 for containerized processes
        check_proc_in_container "$smon_pid"
        if [ $? -eq 1  ]; then
            continue
        fi
    fi

    # grep -o: Only return matching
    # grep -P: Perl-compatible regex, allows use of \K
    smon_proc_name=$(echo "$smon_proc_name" | grep -oP '^ora_smon_\K.*$' )

    if [ "$print_pids" -eq 1 ]; then
        databases+=("$smon_proc_name $smon_pid")
    else
        databases+=("$smon_proc_name")
    fi
done
unset IFS

if [ "${#databases[@]}" -eq 0 ]; then
    echo "No running databases. Exiting..."
elif $csv; then
    # Print out array as CSV and remove trailing comma.
    printf "%s," "${databases[@]}" | sed 's/,$//g'
    echo
elif $ssv; then
    # Print out array as SSV and remove trailing space.
    printf "%s " "${databases[@]}" | sed 's/ $//g'
    echo
else
    # Print out array as newline-separated values.
    printf "%s\n" "${databases[@]}"
fi
exit 0
