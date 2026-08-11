#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: The purpose of this script is to shutdown the Oracle listener and either
#	   one or all databases by ORACLE_SID. If no parameter is provided, the
#	   script will default to use the current ORACLE_SID if it is set. The shutdown
#    mode can also be optionally configured, and defaults to immediate.
#
#####################################################################################

usage="Usage: shutdown_oracle.sh [SID/ALL] [ shutdown mode (optional, ABORT|IMMEDIATE) ]"
example="Example: shutdown_oracle.sh mydbprod"

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

if [ $# -ne 1 ] && [ $# -ne 2 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Process shutdown mode if given
if [ $# -eq 2 ]; then
    shutdown_mode=${2^^}
    if [[ ! $shutdown_mode =~ ABORT|IMMEDIATE ]]; then
        echo "Shutdown mode must be abort or immediate, exiting..."
        exit 1 
    fi
fi

input_sid=$1

# Process SID, display error if it is abort or immediate
if [[ ${input_sid^^} =~ ABORT|IMMEDIATE ]]; then
    echo "Input SID cannot be immediate or abort, exiting..."
    exit 1
fi

shutdown_sid() {
    # Will shutdown an Oracle sid, given as the first argument.
    # Optionally takes the shutdown mode as the second argument.
    sid=$1
    shutdown_mode=$2
    export ORACLE_SID=$sid
    # Check DB status to make sure it is not closed.
    # We are purposefully not calling VerifyAllParam.sh because given databases may
    # be in MOUNT/NOMOUNT mode.
    db_status=$("$HOME/common/oracle/CheckDatabaseOpenStatus.sh" "$sid")
    if [ $? -ne 0 ]; then
        echo "Error encountered while running CheckDatabaseOpenStatus.sh on ORACLE_SID $sid."
        return 1
    fi
    
    if [ "$db_status" == "CLOSED" ]; then
        echo "Error: database $sid is already closed."
        return 1
    fi
    # If database status is anything other than OPEN, use ABORT shutdown method.
    if [ -z "$shutdown_mode" ]; then
        if [ "$db_status" == "OPEN" ]; then
            shutdown_mode="immediate"
        else
            shutdown_mode="abort"
        fi
    fi
    echo "Shutting down $sid using mode $shutdown_mode..."
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOF
        whenever oserror exit 1
        whenever sqlerror exit 1
        shutdown ${shutdown_mode};
        exit;
EOF
    # Check for errors.
    if [ $? -ne 0 ]; then
        echo "Error encountered when shutting down database $sid."
        return 1
    fi
    # Print list of remaining processes matching the shutdown instance
    remaining_processes=$(ps -ef | grep "$sid" | grep -v 'grep' | grep -v 'shutdown')
    if [ -n "$remaining_processes" ]; then
        echo "Database $sid had active processes upon shutdown:"
        echo "$remaining_processes"
        echo "If any unnecessary processes are listed, the user should kill them using \"kill -9 [PID]\"."
    else
        echo "Database $sid shutdown successfully."
    fi
    return 0
}

if [ "${input_sid^^}" == "ALL" ]; then
    for sid in $SIDSLIST; do
        # Run shutdown function
        shutdown_sid "$sid" "$shutdown_mode"
        if [ $? -ne 0 ]; then
            # Errors will be shown from function
            continue
        fi
    done
    # Check listener status
    listener_status=$("$HOME/common/oracle/CheckIfListenerIsRunning.sh")
    if [ $? -ne 0 ]; then
        echo "Error occurred while running CheckIfListenerIsRunning.sh. Exiting..."
        exit 1
    fi

    echo "Listener running status: $listener_status"
    echo
else
    # Run shutdown function
    shutdown_sid "$input_sid" "$shutdown_mode"
    if [ $? -ne 0 ]; then
        # Errors will be shown from function
        exit 1
    fi
fi
