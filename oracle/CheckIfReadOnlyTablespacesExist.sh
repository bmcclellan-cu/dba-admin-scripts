#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script checks the current database or all databases for existing
#          read-only tablespaces and returns 'Yes' or 'No' depending on if any
#          are found.
#
################################################################################

usage="Usage: CheckIfReadOnlyTablespacesExist.sh [ORACLE_SID | ALL (optional)]"
example="Example: CheckIfReadOnlyTablespacesExist.sh mysid"

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

# Check arguments
if [ $# -eq 1 ]; then
    if [ "${1^^}" != "ALL" ]; then
        export SIDS="$1"
    else
        export SIDS="$SIDSLIST"
    fi
elif [ $# -gt 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
# If no input is provided, verify the set ORACLE_SID
elif [ $# -eq 0 ]; then
    # VerifyAllParam.sh not required, script should work with mounted dbs
    if [ -n "$ORACLE_SID" ]; then
        export SIDS="$ORACLE_SID"
    else
        echo "Error, \$ORACLE_SID not set..."
        exit 1
    fi
fi

exit_status=0
for SID in $SIDS; do
    export ORACLE_SID=$SID

    sid_check=$($HOME/common/oracle/CheckDatabaseOpenStatus.sh "$ORACLE_SID")
    if [ $? -ne 0 ]; then
        echo "Error occurred while checking database open status on database $ORACLE_SID"
        echo "Skipping database $ORACLE_SID..."
        exit_status=1
        continue
    elif [ "$sid_check" == "CLOSED" ] || [ "$sid_check" == "NOMOUNT" ]; then
        echo "Database cannot be in CLOSED or NOMOUNT mode. Skipping $ORACLE_SID..."
        exit_status=1
        continue
    fi

    # Count the number of read-only tablespaces on the database
    readonly_tbsps=$(
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD | xargs
    whenever oserror exit 1
    whenever sqlerror exit 1
    set heading off
    set feedback off

    select count(*) from v\$datafile where enabled = 'READ ONLY';

    exit;
EOD
    )

    # Check for errors
    if [ $? -ne 0 ]; then
        echo "ERROR"
        echo "Script was unable to count read-only tablespaces on $ORACLE_SID"
        echo "$readonly_tbsps"
        exit 1
    fi

    # Return 'Yes' if count is greater than zero or 'No' if equal to zero
    # If a different output was obtained, assume an error occurred
    if [ "$readonly_tbsps" -gt 0 ] 2>/dev/null; then
        echo "$ORACLE_SID: Yes"

    elif [ "$readonly_tbsps" -eq 0 ] 2>/dev/null; then
        echo "$ORACLE_SID: No"

    else
        echo "ERROR"
        echo "Invalid output: $readonly_tbsps"
        exit 1
    fi
done

# Report failure if any database was skipped
exit "$exit_status"
