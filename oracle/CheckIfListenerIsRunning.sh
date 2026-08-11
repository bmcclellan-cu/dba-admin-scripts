#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script is a helper script that returns the status of the listener
#	   to the end user.
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

# Run listener status check to determine if the listener is running
# Suppress the output by storing output in a variable since script is a helper
lsnr_status=$("$ORACLE_HOME/bin/lsnrctl" status)

# Output the status of the listener
if [ $? -eq 0 ]; then
    echo "Yes"
else 
    echo "No"
fi
