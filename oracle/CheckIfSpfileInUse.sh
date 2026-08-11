#!/bin/bash
# AvailabilityFlag: Public
#
#  Purpose: The purpose of this script is to check if a specific spfile exists in the
#	    database. The output is either "YES" if the spfile exists, or "NO" if it
#	    doesn't. If an error occurs in the sqlplus block, "ERROR" will be returned.
#	    This script is a helper script for other scripts, so the output will be
#	    used by outside scripts to determine if the used spfile exists.
#
#   Note: Using ALL for ORACLE_SID will cause both the ORACLE_SID and whether or not the spfile is in use to be printed
#
#####################################################################################

usage="Usage: CheckIfSpfileInUse.sh [ ALL | ORACLE_SID (optional) ]"
example="Example: CheckIfSpfileInUse.sh ALL"

# Process input options
while getopts ":h" option; do
    case $option in
    h)
        echo $usage
        echo $example
        exit 0
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

if [ $# -gt 1 ]; then
    echo $usage
    echo $example
    exit 1
fi

if [ $# -eq 0 ]; then
    # Check oracle sid
    sid_check=$($HOME/common/oracle/VerifyAllParam.sh -I)
    if [ -n "$sid_check" ]; then
        if [ "$sid_check" == "-1" ]; then
        echo "Error, \$ORACLE_SID not set..."
        exit 1
        fi
    fi
    SIDS=$ORACLE_SID
else 
    if [ "${1^^}" != "ALL" ]; then 
        sid_check=$($HOME/common/oracle/VerifyAllParam.sh -I $1)
        if [ -n "$sid_check" ]; then
            echo "Error, provided ORACLE_SID $1 is not open. Exiting..."
            echo "VerifyAllParam.sh output:
$sid_check"
            exit 1
        fi
        SIDS=$1
    else
        SIDS=$($HOME/common/oracle/VerifyAllParam.sh -V "ALL")
    fi
fi

for SID in $SIDS; do 
    # Check if current database is CLOSED using CheckDatabaseOpenStatus.sh
    database_status=$($HOME/common/oracle/CheckDatabaseOpenStatus.sh "$SID")
    if [ $? -ne 0 ]; then
        echo "Error occured while checking database status for $SID. Continuing..."
        continue
    fi
    if [ "$database_status" == "CLOSED" ]; then
        echo "$SID database is closed. Continuing..."
        continue
    fi
    export ORACLE_SID=$SID

    # Runs sqlplus command to check if spfile is in use and stores it in $spfile_check
    spfile_check=$(
        $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set feedback off
    set heading off
    select value from v\$parameter where name = 'spfile';
EOD
    )

    # Checks for errors from the sqlplus output
    if [ $? -ne 0 ]; then
        echo "ERROR occured while checking spfile for $SID"
        echo "$spfile_check"
        continue
    fi

    # Used to preserve scripts original behavior 
    if [ $# -eq 0 ] || [ "${1^^}" != "ALL" ]; then
        if [ -z "${spfile_check:2}" ]; then
            echo "NO"
        else
            echo "YES"
        fi
    else
        if [ -z "${spfile_check:2}" ]; then
            echo "$SID NO"
        else
            echo "$SID YES"
        fi
    fi
done

exit 0
