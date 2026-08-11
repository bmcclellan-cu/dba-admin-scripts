#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script will return Yes if a user exists and No if not.
#
################################################################################

usage="Usage: CheckIfUserExists.sh [username]"
example="Example: CheckIfUserExists.sh [username]"

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

# Check argument count
if [ $# -ne 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

username=${1^^}

# Check ORACLE_SID
invalid_sid=$($HOME/common/oracle/VerifyAllParam.sh -I)
if [ $? -ne 0 ]; then
    echo "Error: script VerifyAllParam.sh did not execute correctly. Exiting..."
    exit 1
elif [ -n "$invalid_sid" ]; then
    if [ "$invalid_sid" == "-1" ]; then
        echo "Error: \$ORACLE_SID not set. Exiting..."
        exit 1
    fi
    echo "Error: \$ORACLE_SID $ORACLE_SID is not open. Exiting..."
    exit 1
fi

# Check dba_users for $username, store if found
res=$(
    $ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOD | sed '/^$/d'
whenever oserror exit 1
whenever sqlerror exit 1
set heading off
set feedback off
    SELECT USERNAME FROM DBA_USERS WHERE USERNAME = '$username';
EOD
)

# Check if the query got a result
if [ -n "$res" ]; then
    echo "Yes"
    exit 0
fi
echo "No"
exit 0
