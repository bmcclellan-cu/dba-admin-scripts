#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script is a helper script that outputs each specified database's
#          recovery file destination. The script takes an optional input of a
#          specific SID or ALL, and uses the user's current ORACLE_SID by
#          default. SIDs are resolved and checked for open status through
#          VerifyAllParam.sh; databases that are not open are reported and
#          skipped, and the script exits non-zero when any are skipped.
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

# Set schema to user-provided input or set SID variable to current ORACLE_SID
if [ -z "$1" ] && [ -z "$ORACLE_SID" ]; then
    echo "ERROR: \$ORACLE_SID not set and none provided."
    echo "Rerun the script and enter the target database as the first parameter."
    echo "Exiting..."
    exit 1

fi

# Resolve the target SIDs through VerifyAllParam.sh, matching
# OraclePrimaryRMANBackupScript.sh:80-113: -V returns the open SIDs for ALL, and -I returns a
# specific SID when it is not open.
if [ "${1^^}" == "ALL" ]; then
    SIDs=$("$HOME/common/oracle/VerifyAllParam.sh" -V "$1")
    if [ $? -ne 0 ]; then
        echo "$SIDs"
        echo "Error, VerifyAllParam.sh failed for ALL input. Exiting..."
        exit 1
    fi
    # -V returns only the open SIDs, so ask -I which ones it dropped rather than skipping them
    # silently; this script reports one value per SID and a missing line should be explained.
    skipped_sids=$("$HOME/common/oracle/VerifyAllParam.sh" -I "$1")
    if [ -n "$skipped_sids" ]; then
        echo "Skipping databases that are not open: $skipped_sids"
        exit_status=1
    fi
else
    if [ -n "$1" ]; then
        export ORACLE_SID=$1
    fi
    sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I "$ORACLE_SID")
    if [ $? -ne 0 ]; then
        echo "$sid_check"
        echo "Error, VerifyAllParam.sh failed while validating SID $ORACLE_SID. Exiting..."
        exit 1
    fi
    if [ -n "$sid_check" ]; then
        echo "Error, provided ORACLE_SID $ORACLE_SID is not open. Exiting..."
        exit 1
    fi
    SIDs=$ORACLE_SID
fi

if [ -z "$SIDs" ]; then
    echo "No open databases to report on. Exiting..."
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
