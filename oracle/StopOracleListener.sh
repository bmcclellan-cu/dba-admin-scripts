#!/bin/bash
# AvailabilityFlag: Public
# CrontabFlag: True
#
# Purpose: The purpose of this script is to stop the Oracle listener after
#          checking its status
#
################################################################################

usage="Usage: ./StopOracleListener.sh"

# Process input options
while getopts ":h" option; do
    case $option in
        h)
            echo "$usage"
            exit 0
            ;;
        \?)
            echo "Error: Invalid option"
            exit 1
            ;;
    esac
done

# Check that no inputs were entered
if [ $# -ne 0 ]; then
    echo "$usage"
    exit 1
fi

# Source .bashrc only when $ORACLE_HOME is unset, which is the case under crontab
# and systemd since neither loads the oracle user's profile. A caller that has
# deliberately selected a different Oracle home (19c.env, 12c.sh) keeps its own.
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

# Check the current status of the listener
lsnr_status=$("$HOME/common/oracle/CheckIfListenerIsRunning.sh")
if [ $? -ne 0 ]; then
    echo "$lsnr_status"
    echo "Error occurred while checking the Oracle Listener"
    exit 1
fi
# CheckIfListenerIsRunning.sh exits 0 whether or not the listener is up, so its
# output is the only status: an exact "Yes" when it is running and the lsnrctl output when it is not running.
if [ "$lsnr_status" == "Yes" ]; then
    echo "Stopping listener..."
    "$ORACLE_HOME"/bin/lsnrctl stop
else
    echo "Listener is already down. Exiting..."
    exit 1
fi

if [ $? -ne 0 ]; then
    echo
    echo "Error encountered while stopping listener. Exiting..."
    exit 1
else
    echo
    echo "Listener stopped successfully."
    exit 0
fi

