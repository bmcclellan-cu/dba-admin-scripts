#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script acts as a helper script for other scripts to check whether
#	   a tablespace exists or doesn't exist in the current database. It checks
#	   dba_tablespaces for the tablespace and returns 'Yes' if found or 'No' if not.
# 
#####################################################################################

usage="Usage: CheckIfTablespaceExists.sh [tablespace]"
example="Example: CheckIfTablespaceExists.sh MY_TBSP"

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
if [ $# -ne 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Check oracle sid
sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "Error, \$ORACLE_SID not set..."
        exit 1
    fi
    echo "Error, databse $ORACLE_SID is not open"
    exit 1
fi

# Set tablespace to uppercase
tablespace=${1^^}

# Check dba_tablespaces for $tablespace, store if found
tablespace_check=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
whenever oserror exit 1
whenever sqlerror exit 1
set heading off
set feedback off
select tablespace_name from dba_tablespaces
where tablespace_name = '$tablespace';
EOD
)

sql_error=$?
ora_error=$(echo "$tablespace_check" | grep "ORA-")

# Check if table was found
if [ $sql_error -ne 0 ] | [ ! -z "$ora_error" ]; then
    echo "ERROR"
    echo "$ora_error"
    exit 1
elif [ -z "$tablespace_check" ]; then
    echo "No"
    exit 0
else
    echo "Yes"
    exit 0
fi
