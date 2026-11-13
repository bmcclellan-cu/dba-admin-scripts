#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script acts as a helper script for other scripts to check the type
#          of a tablespace. It checks dba_tablespaces for the tablespace type and prints
#          PERM, TEMP or UNDO for a PERMANENT, TEMPORARY or UNDO tablespace and exits 0.
#          For any other type, a missing tablespace or a failed query it prints an
#          error message and exits 1.
#
#####################################################################################

usage="Usage: CheckTablespaceType.sh [tablespace]"
example="Example: CheckTablespaceType.sh MY_TBSP"
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

# Checking ORACLE_SID
sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
if [ $? -ne 0 ]; then
    echo "$sid_check"
    echo "An error occurred while checking for invalid SIDs. Exiting..."
    exit 1
fi
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "Error, \$ORACLE_SID not set..."
        exit 1
    fi
    echo "Error, provided \$ORACLE_SID is not open. Exiting..."
    exit 1
fi

# Set user input to uppercase
tablespace=${1^^}


# Check if tablespace exists
tbsp_check=$("$HOME/common/oracle/CheckIfTablespaceExists.sh" "$tablespace")
if [ $? -ne 0 ]; then
    echo "$tbsp_check"
    echo "Error occurred while attempting to run CheckIfTablespaceExists.sh. Exiting..."
    exit 1
elif [ "$tbsp_check" == "No" ]; then
    echo "ERROR: Tablespace $tablespace doesn't exist in the current database $ORACLE_SID"
    exit 1
elif [ "$tbsp_check" != "Yes" ]; then
    echo "ERROR"
    echo "$tbsp_check"
    exit 1
fi

# Check dba_tablespaces for contents column, store if found
type_check=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
whenever oserror exit 1
whenever sqlerror exit 1
set heading off
set feedback off
select contents from dba_tablespaces 
where tablespace_name = '$tablespace';
EOD
)

sql_error=$?
ora_error=$(echo "$type_check" | grep "ORA-")

if [ $sql_error -ne 0 ] || [ ! -z "$ora_error" ]; then
    echo "ERROR"
    echo "$type_check"
    exit 1
fi

# Removes the newline character at the beginning of $type_check that the sqlplus block adds
type_check=${type_check#$'\n'}

if [ "$type_check" == "PERMANENT" ]; then
    echo "PERM"
    exit 0
elif [ "$type_check" == "TEMPORARY" ]; then
    echo "TEMP"
    exit 0
elif [ "$type_check" == "UNDO" ]; then
    echo "UNDO"
    exit 0
else
    echo "ERROR"
    echo "$type_check"
    exit 1
fi