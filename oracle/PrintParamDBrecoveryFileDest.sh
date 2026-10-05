#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script is a helper script that outputs each specified database's
#          recovery file destination. The script takes an optional input of a
#          specific SID or ALL, and uses the user's current ORACLE_SID by
#          default. The script does not validate SIDs with VerifyAllParam.sh
#          because databases in NOMOUNT or MOUNTED state are valid parameters.
#          If this script only checked for OPEN databases, then dependent scripts would fail.
#
################################################################################

usage="Usage: PrintParamDBrecoveryFileDest.sh [\$ORACLE_SID|ALL (optional)]"
example="Example: PrintParamDBrecoveryFileDest.sh mysid"

# Process input options
while getopts ":h" option; do
    case $option in
        h)
            echo "$usage"
            echo "$example"
            exit 0;;
        \?)
            echo "Error: Invalid option"
            exit 1
    esac
done


# Check arguments
if [ $# -gt 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi
# If no SID was provided and ORACLE_SID env. variable is empty error out
# Otherwise set SIDs to ORACLE_SID env. variable
if [ -z "$1" ] && [ -z "$ORACLE_SID" ]; then
    echo "ERROR: \$ORACLE_SID not set and none provided."
    echo "Rerun the script and enter the target database as the first parameter."
    echo "Exiting..."
    exit 1
elif [ -n "$ORACLE_SID" ]; then
    SIDs=$ORACLE_SID
fi

# Set SIDs to either user-provided input or all SIDS in SIDSLIST env. variable when 'ALL' is provided
if [ -n "$1" ]; then
    if [ "${1^^}" == "ALL" ]; then
        if [ -z "$SIDSLIST" ]; then
            echo "Error: \$SIDSLIST has not been set"
            echo "Exiting..."
            exit 1
        else
            SIDs=$SIDSLIST
        fi
    else
        SIDs=$1
    fi
fi

if [ -z "$SIDs" ]; then
    echo "Error: No SIDs to query for recovery file destination."
    echo "Exiting..."
    exit 1
fi

# Loop through specified SIDs
for SID in $SIDs; do
    export ORACLE_SID=$SID

    # Determine the location of the recovery file destination
    file_dest=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        set heading off
        whenever oserror exit 1
        whenever sqlerror exit 1
        select value from v\$parameter where name = 'db_recovery_file_dest';
EOD
)

    if [ $? -ne 0 ]; then
        echo "$file_dest"
        echo "ERROR: SQL query for db recovery file destination failed on $SID database"
        exit_status=1
        continue
    fi

    file_dest=$(echo "$file_dest" | grep -ve '^Current\|^$')

    if [ "${1^^}" != "ALL" ]; then
        echo "${file_dest}"
    else    
        echo "Current db_recovery_file_dest on $SID: ${file_dest}"
    fi

done

if [ -n "$exit_status" ]; then
    exit 1
else
    exit 0
fi
