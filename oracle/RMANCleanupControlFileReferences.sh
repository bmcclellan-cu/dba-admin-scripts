#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script clears stale RMAN repository records for a specific database or all
#	       databases in $SIDSLIST. Running NOCATALOG, the RMAN repository lives in the
#	       control file: 'crosscheck' marks records whose physical files are missing as
#          EXPIRED, and 'delete expired' removes those records. Backups, archivelogs and
#          copies are all crosschecked. No backup files or control files are deleted -- only
#          the control file's references to pieces that no longer exist on disk. The commands
#          can only be run when the database is in either mounted or open mode.
#
#####################################################################################

usage="Usage: RMANCleanupControlFileReferences.sh [ALL (optional)]"
example="Example: RMANCleanupControlFileReferences.sh ALL"

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

# Ensure that user entered at most one parameter
if [ $# -gt 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

if [ "${1^^}" == "ALL" ]; then
    # If user entered 'ALL' parameter, use all valid SIDs in $SIDSLIST
    SIDs=$("$HOME/common/oracle/VerifyAllParam.sh" -V "ALL")
    if [ $? -ne 0 ]; then
        echo "$SIDs"
        echo "Error, VerifyAllParam.sh failed for ALL input. Exiting..."
        exit 1
    fi
elif [ -z "$1" ]; then
    # Checking ORACLE_SID is set and open
    sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
    if [ -n "$sid_check" ]; then
        if [ "$sid_check" == "-1" ]; then
            echo "Error, \$ORACLE_SID not set..."
            exit 1
        fi
        echo "Error, provided \$ORACLE_SID is not open. Exiting..."
        exit 1
    fi
    # Set user's current SID
    SIDs=$ORACLE_SID
else
    # If user didn't enter 'ALL', exit script
    echo "Invalid input; first input must be either 'ALL' or empty. Check input and try again."
    exit 1
fi

# Loop through each applicable SID
for SID in $SIDs; do
    export ORACLE_SID=$SID

    # Check if current database is either mounted or open using CheckDatabaseOpenStatus.sh
    database_status=$("$HOME/common/oracle/CheckDatabaseOpenStatus.sh" "$ORACLE_SID")

    bash_error=$?
    ora_error=$(echo "$database_status" | grep "ORA-")

    # Check success of helper script
    if [ $bash_error -ne 0 ] || [ -n "$ora_error" ]; then
        echo "Error occurred while checking status of $ORACLE_SID database."
        echo "$database_status"
        exit_status=1
        continue
    # Skip database if it is not mounted or open
    elif [ "$database_status" != "MOUNTED" ] && [ "$database_status" != "OPEN" ]; then
        echo "$ORACLE_SID database is neither mounted nor open. Current database mode: $database_status"
        continue
    fi

    # Crosscheck marks any repository record whose file is missing as EXPIRED; delete then
    # removes those records. Covers backups, archivelogs and copies.
    rman target / <<EOD
    crosscheck backup;
    delete noprompt expired backup;
    crosscheck archivelog all;
    delete noprompt expired archivelog all;
    CROSSCHECK COPY;
    delete noprompt expired copy;
    exit;
EOD

    # Check the success of the old control file cleanup
    if [ $? -ne 0 ]; then
        echo
        echo "Script failed while cleaning up old files on ${ORACLE_SID}. Exiting..."
        echo
        exit_status=1
        continue
    else
        echo
        echo "Old RMAN files successfully cleaned up from ${ORACLE_SID}"
        echo
    fi
done

if [ "${1^^}" == "ALL" ]; then
    invalid_sids=$("$HOME/common/oracle/VerifyAllParam.sh" -I "ALL")
    if [ -n "$invalid_sids" ]; then
        echo "Error: database(s) $invalid_sids are not open. Exiting..."
        exit_status=1
    fi
fi

# Check if any errors occurred during the loop. Exit with failure status if there were
if [ -n "$exit_status" ]; then
    echo "One or more errors occurred while running script. Check above output for more details"
    exit 1
else
    echo "Script completed successfully on the requested databases."
    exit 0
fi
