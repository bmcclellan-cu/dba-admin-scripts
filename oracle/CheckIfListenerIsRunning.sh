#!/bin/bash
# AvailabilityFlag: Public
# CrontabFlag: True
#
# Purpose: This script is a helper script that returns the status of the listener
#	   to the end user.
#
# NOTICE: Callers must test for an exact "Yes" to check if the listener is running. If the listener is not running, the script prints the lsnrctl
# output so the caller can report why the listener is not running.
#
#####################################################################################

usage="Usage: CheckIfListenerIsRunning.sh"

# Process input options
while getopts ":h" option; do
    case $option in
        h)
            echo "$usage"
            exit 0;;
        \?)
            echo "Error: Invalid option"
            exit 1
    esac
done


# Check arguments
if [ $# -ne 0 ]; then
    echo "$usage"
    exit 1
fi

# Source .bashrc only when $ORACLE_HOME is unset, which is the case under crontab
# and systemd since neither loads the oracle user's profile. A caller that has
# deliberately selected a different Oracle home keeps that home.
if [ -z "$ORACLE_HOME" ]; then
    if [ -f "$HOME/.bashrc" ]; then
        source "$HOME/.bashrc"
        if [ $? -ne 0 ]; then
            echo "An error occurred while sourcing $HOME/.bashrc. Exiting..."
            exit 1
        fi
    else
        echo "Error: $HOME/.bashrc does not exist. Exiting..."
        exit 1
    fi
fi

# Fail closed on a bad $ORACLE_HOME. Without this the lsnrctl call below runs
# /bin/lsnrctl, exits non-zero, and reports "No", which makes a configuration
# error indistinguishable from a listener that is genuinely down.
if [ ! -x "$ORACLE_HOME/bin/lsnrctl" ]; then
    echo "Error: \$ORACLE_HOME is not set to an Oracle home containing bin/lsnrctl. Exiting..."
    exit 1
fi

# Run listener status check to determine if the listener is running
# Suppress the output by storing output in a variable since script is a helper
lsnr_status=$("$ORACLE_HOME/bin/lsnrctl" status)

# Output the status of the listener.
if [ $? -eq 0 ]; then
    echo "Yes"
else 
    echo "$lsnr_status"
fi
