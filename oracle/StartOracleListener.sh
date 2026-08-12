#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: The purpose of this script is to start the Oracle listener after
#          checking its status
#
################################################################################

usage="Usage: StartOracleListener.sh"

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

# Fail closed on a bad $ORACLE_HOME rather than on the lsnrctl start below
if [ ! -x "$ORACLE_HOME/bin/lsnrctl" ]; then
    echo "Error: \$ORACLE_HOME is not set to an Oracle home containing bin/lsnrctl. Exiting..."
    exit 1
fi

# Check the current status of the listener
lsnr_status=$("$HOME/common/oracle/CheckIfListenerIsRunning.sh")
if [ $? -ne 0 ]; then
    echo "$lsnr_status"
    echo "Error occurred while running CheckIfListenerIsRunning.sh. Exiting..."
    exit 1
fi

# Status code 0: listener is up
if [ "$lsnr_status" != "No" ]; then
    echo "Listener is already running. Exiting..."
    exit 1

# Status code 1: listener is down or has an error
else
    # Check if any TNS- errors occurred on the listener
    if [[ "$lsnr_status" == *TNS-* ]]; then
        echo "TNS error(s) found on listener"
        echo "$lsnr_status"
        exit 1
    else
        echo "Starting listener..."
        $ORACLE_HOME/bin/lsnrctl start
    fi
fi

if [ $? -ne 0 ]; then
    echo
    echo "Error encountered while starting listener. Exiting..."
    exit 1
else
    echo
    echo "Listener started successfully."
    exit 0
fi

