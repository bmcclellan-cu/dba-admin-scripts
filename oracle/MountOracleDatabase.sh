#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose:  The purpose of this script is to mount a database that was previously
#	        unmounted. The script takes an optional SID but will use the current
#	        ORACLE_SID if the user doesn't provide one.
#
#####################################################################################

usage="Usage: MountOracleDatabase.sh [\$ORACLE_SID (optional)]"
example="Example: MountOracleDatabase.sh mysid"

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
if [ $# -gt 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Check if user input and $ORACLE_SID are set
if [ -z "$1" ]; then
    if [ -z "$ORACLE_SID" ]; then
        echo "No input given and \$ORACLE_SID not set."
        exit 1
    fi
else
    export ORACLE_SID=${1,,}
fi

# Check if current database is in NOMOUNT mode using CheckDatabaseOpenStatus.sh
database_status=$("$HOME/common/oracle/CheckDatabaseOpenStatus.sh" "$ORACLE_SID")
if [ $? -ne 0 ]; then
    echo "$database_status"
    echo "An error occurred while running CheckDatabaseOpenStatus.sh. Exiting..."
    exit 1
fi  

if [ "$database_status" != "NOMOUNT" ]; then
    echo "$ORACLE_SID database is not in nomount mode. Exiting..."
    exit 1
fi

result_dump=$(
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set feedback off
    alter database mount;
    exit;
EOD
)

if [ $? -ne 0 ]; then
    echo "$result_dump"
    echo "Error occurred while mounting $ORACLE_SID database."
    exit 1
else
    echo "$ORACLE_SID database successfully mounted."
    exit 0
fi
