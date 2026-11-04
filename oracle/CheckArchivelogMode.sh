#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script queries either the current database or a given database to
#          check if the database is in archive log mode. The last line it prints is
#          'YES' if the database is in archive log mode, or 'NO' if it is not.
#          The database must be OPEN: the script exits with an error if
#          VerifyAllParam.sh reports that it is not. With ALL, it instead prints one
#          line per open database and lists the databases that are not open.
#
#####################################################################################

usage="Usage: CheckArchivelogMode.sh [ORACLE_SID | ALL (Optional)]"
example="Example: CheckArchivelogMode.sh my_db"

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

check_archivelog_mode() {
    archivelog_check=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        archive log list;
EOD
    )
    if [ $? -ne 0 ]; then
        echo "ERROR"
    else
        echo "$archivelog_check"
    fi
}

# Check arguments
if [ $# -gt 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

if [ "${1^^}" == "ALL" ]; then
    sids=$("$HOME/common/oracle/VerifyAllParam.sh" -V "ALL")
    if [ $? -ne 0 ]; then
        echo "$sids"
        echo "Error occurred while listing open databases with VerifyAllParam.sh. Exiting..."
        exit 1
    fi
 
    for sid in $sids; do
        export ORACLE_SID=${sid,,}
        result=$(check_archivelog_mode)
        if [ "$result" == "ERROR" ]; then
            echo "Error occurred while getting archive log mode on $ORACLE_SID. Continuing..."
            exit_status=1
            continue
        else
            result=$(echo "$result" | grep "Automatic archival" | xargs | cut -d " " -f3)
            echo "Archive log mode is ${result,,} on database $ORACLE_SID"
        fi
    done

    if [ -n "$exit_status" ]; then
        echo "One or more errors occurred while checking archive log mode, check above output for more information. Exiting..."
        exit 1
    fi
 
    invalid_sids=$("$HOME/common/oracle/VerifyAllParam.sh" -I "ALL")
    if [ $? -ne 0 ]; then
        echo "$invalid_sids"
        echo "Error occurred while listing databases that are not open with VerifyAllParam.sh. Exiting..."
        exit 1
    fi
    if [ -n "$invalid_sids" ]; then
        echo "The following database(s) are not open and were not checked: $invalid_sids. Exiting..."
    fi

    exit 0

else
    # Set ORACLE_SID equal to user input if given
    if [ -n "$1" ]; then
        export ORACLE_SID=${1,,}
    fi

    # Checking ORACLE_SID
    sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
    if [ $? -ne 0 ]; then
        echo "$sid_check"
        echo "Error occurred when checking ORACLE_SID. Exiting..."
        exit 1
    elif [ -n "$sid_check" ]; then
        if [ "$sid_check" == "-1" ]; then
            echo "Error, \$ORACLE_SID not set..."
            exit 1
        fi
        echo "Error, provided ORACLE_SID is not open. Exiting..."
        exit 1
    fi

    echo "Checking archive log mode for ${ORACLE_SID}..."

    result=$(check_archivelog_mode)

    if [ "$result" == "ERROR" ]; then
        echo "ERROR"
        exit 1
    else
        # Check result of archive log query
        result=$(echo "$result" | grep "Automatic archival" | xargs | cut -d " " -f3)
        if [ "$result" == "Enabled" ]; then
            echo "YES"
            exit 0
        elif [ "$result" == "Disabled" ]; then
            echo "NO"
            exit 0
        else
            echo "ERROR"
            exit 1
        fi
    fi
fi
