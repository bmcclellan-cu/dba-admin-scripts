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

# Check the current status of the listener
lsnr_status=$("$HOME/common/oracle/CheckIfListenerIsRunning.sh")

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

