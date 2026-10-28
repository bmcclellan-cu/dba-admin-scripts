#!/bin/bash
# AvailabilityFlag: Public
# Purpose: This script checks whether a given database is partitioned or not, printing out either yes or no
# 
#####################################################################################

usage="Usage: CheckIfDatabaseIsPartitioned.sh [ -v (skip VerifyAllParam.sh call)] [ORACLE_SID (optional)]"
example="Example: CheckIfDatabaseIsPartitioned.sh MY_DB"

vopt=false

# Process input options
while getopts ":hv" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0;;
    v)
        vopt=true
        shift 1
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
    esac
done

#Checking the amount of arguments
if [ $# -gt 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

sid=${1,,}

# Set SID to user-provided input or set SID variable to current ORACLE_SID
if [ -z "$sid" ]; then
    sid=$ORACLE_SID
fi

# Check for valid ORACLE_SID
if [ "$vopt" != true ]; then
    sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I "$sid")

    if [ $? -ne 0 ]; then
        echo "$sid_check"
        echo "Error, call to VerifyAllParam.sh -I $sid failed. Exiting..."
        exit 1
    fi

    if [ -n "$sid_check" ]; then
        if [ "$sid_check" == "-1" ]; then
            echo "Error, \$ORACLE_SID not set..."
            exit 1
        fi
        echo "Error, provided ORACLE_SID is not open. Exiting..."
        exit 1
    fi
fi

export ORACLE_SID=$sid

#Storing the results of querying the database to find partitions
numberOfLines=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set feedback off
    set heading off
    select count(*) from dba_tab_partitions
    where table_owner IN (select username from dba_users where oracle_maintained = 'N');
EOD
)

# Check to ensure the above SQL statement executed properly 
if [ $? -ne 0 ]; then
    echo
    echo "$numberOfLines"
    echo
    echo "Error occurred while running SQL, check above output for details"
    exit 1
fi

numberOfLines=$(echo "$numberOfLines" | xargs)

#Case that the output of the query contains no rows selected
if [ "$numberOfLines" -eq 0 ]; then
    echo "No"
    exit 0
fi

# Case for if there was a result the query above
echo "Yes"
exit 0