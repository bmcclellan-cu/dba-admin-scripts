#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script is a wrapper script for PrintUsers.sh since schemas and users
#          are synonymous in oracle.
#
#####################################################################################

usage="Usage: PrintSchemas.sh [ -o (only list users that own tables)] [ORACLE_SID (optional)]"
example="Example: PrintSchemas.sh mysid"

oopt=false

# Process input options
while getopts ":ho" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    o)
        oopt=true
        shift 1
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

#Checking the amount of arguments
if [ $# -gt 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Set schema to user-provided input or set SID variable to current ORACLE_SID
if [ -z "$1" ] && [ -z "$ORACLE_SID" ]; then
    echo "ERROR: \$ORACLE_SID not set and none provided."
    echo "Rerun the script and enter the target database as the first parameter."
    echo "Exiting..."
    exit 1
elif [ -n "$1" ]; then
    export ORACLE_SID=$1
fi
 
# Check for valid ORACLE_SID
sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I "$ORACLE_SID")
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
       echo "Error, \$ORACLE_SID not set..."
       exit 1
    fi
    echo "Error, provided ORACLE_SID is not open. Exiting..."
    exit 1
  
fi

if $oopt ; then
    schemas=$("$HOME/common/oracle/PrintUsers.sh" -o "$ORACLE_SID")
    if [ $? -ne 0 ]; then
        echo "Problem running PrintUsers.sh, exiting..."
        exit 1
    fi
    schemas=$(echo "$schemas" | grep -v "List of users (schemas) that own tables:")
    echo "$schemas"
else
    "$HOME/common/oracle/PrintUsers.sh" "$ORACLE_SID"
    if [ $? -ne 0 ]; then
        echo "Problem running PrintUsers.sh, exiting..."
        exit 1
    fi
fi