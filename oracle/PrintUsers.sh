#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script prints out the all the usernames in a database, and whether they own tables or not
#
#####################################################################################

usage="Usage: PrintUsers.sh [ -o (only list users that own tables)] [ORACLE_SID (optional)]"
example="Example: PrintUsers.sh mysid"

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
elif [ $# -eq 1 ]; then
    export ORACLE_SID=$1
fi

# Checking ORACLE_SID
sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "Error, \$ORACLE_SID not set..."
        exit 1
    fi
    echo "Error, provided \$ORACLE_SID is not open. Exiting..."
    exit 1
fi

echo "List of users (schemas) that own tables:"

# Generate list of users separated by whether they own tables or do not own tables
"$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set feedback off
    set heading off
    set pagesize 10000
    select username from dba_users where common = 'NO'
    and username in (select distinct owner from dba_segments)
    order by username;
EOD

if [ $? -ne 0 ]; then
    echo "Error occurred while getting users (schemas) that own tables. Exiting..."
    exit 1
fi

if ! $oopt ; then
    echo
    echo "List of users (schemas) that do not own tables:"

    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        set feedback off
        set heading off
        set pagesize 10000
        select username from dba_users where common = 'NO'
        and username not in (select distinct owner from dba_segments)
        order by username;
EOD

    #Checking for errors in the above SQL command
    if [ $? -ne 0 ]; then
        echo "Error occurred while getting users (schemas) that do not own tables. Exiting..."
        exit 1
    fi
fi
