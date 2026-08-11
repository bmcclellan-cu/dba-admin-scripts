#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script takes in input from another function, and outputs verified
#          sids and invalid sids. The option -V outputs only the valid sids found/inputted
#          and the -I option output only the invalid sids found/inputted. -1 will be output
#          if no oracle_sid is found and there is no input
#
#
################################################################################

usage="Usage: VerifyAllParam.sh -I -V [ALL | SID]"
example="Example: VerifyAllParam.sh ALL"

Iopt=false
Vopt=false

# Process input options
while getopts ":hIV" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    I)
        Iopt=true
        ;;
    V)
        Vopt=true
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

# removing options from the input arguments
while [[ $1 =~ '-' ]]; do
    shift 1
done

inp=$1

# Validating input
if [[ $# -gt 1 ]]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

invalid_sids=""
valid_sids=""

# Checking input
if [ $# -eq 0 ] && [ -z "$ORACLE_SID" ]; then # Case for no input and no oracle_sid
    invalid_sids="-1"
elif [ $# -eq 0 ]; then # Case for checking oracle_sid
    # ORACLE_SID check
    db_status=$("$HOME/common/oracle/CheckDatabaseOpenStatus.sh" "$ORACLE_SID")
    if [ $? -eq 1 ]; then
        echo "Error occurred while checking sid $sid. Exiting..."
        exit 1
    fi
    if [ "$db_status" != "OPEN" ]; then
        invalid_sids="$ORACLE_SID"
    else
        valid_sids=$ORACLE_SID
    fi
elif [ "${inp^^}" != "ALL" ]; then # Case for checking one input
    db_status=$("$HOME/common/oracle/CheckDatabaseOpenStatus.sh" "$inp")
    if [ $? -eq 1 ]; then
        echo "Error occurred while checking sid $sid. Exiting..."
        exit 1
    fi
    if [ "$db_status" != "OPEN" ]; then
        invalid_sids="$inp"
    else
        valid_sids="$inp"
    fi
elif [ "${inp^^}" == "ALL" ]; then # Case for checking all SIDS in sidslist
    sids=$SIDSLIST
    for sid in $sids; do
        db_status=$("$HOME/common/oracle/CheckDatabaseOpenStatus.sh" "$sid")
        if [ $? -eq 1 ]; then
            echo "Error occurred while checking sid $sid. Exiting..."
            exit 1
        fi
        if [ "$db_status" != "OPEN" ]; then
            invalid_sids="$invalid_sids $sid"
        else
            valid_sids="$valid_sids $sid"
        fi
    done
fi

# Removing any trailing or leading whitespace
valid_sids=$(echo $valid_sids | xargs)
invalid_sids=$(echo $invalid_sids | xargs)

if ($Vopt && $Iopt) || (! $Vopt && ! $Iopt); then # Case for both options or no options being input
    echo "Invalid SIDS: $invalid_sids"
    echo "Valid SIDS: $valid_sids"
elif $Vopt; then # Case for just outputting valid sids
    if [ -n "$valid_sids" ]; then
        echo "$valid_sids"
    fi
elif $Iopt; then # case for just outputting invalid sids
    if [ -n "$invalid_sids" ]; then
        echo "$invalid_sids"
    fi
fi

exit 0
