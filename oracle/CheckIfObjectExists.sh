#!/bin/bash
# AvailabilityFlag: Public
# Purpose: This script acts as a helper script for other scripts to check whether
#	   an object does or does not exist in the current database. It checks the
#	   dba_objects table for the object and returns 'Yes' if found or 'No' if not.
#
#####################################################################################

usage="Usage: CheckIfObjectExists.sh [schema] [object_name]"
example="Example: CheckIfObjectExists.sh MY_SCHEMA MY_OBJECT"

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

# Checking arguments
if [ $# -ne 2 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Checking ORACLE_SID
sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)

# Check exit status
if [ $? -ne 0 ]; then
    echo "$sid_check"
    echo "Error occurred while checking ORACLE_SID. Exiting..."
    exit 1
elif [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "Error, \$ORACLE_SID not set..."
        exit 1
    fi
    echo "Error, provided ORACLE_SID is not open. Exiting..."
    exit 1
fi

# Set user input to uppercase
schema=${1^^}
object_name=${2^^}

# Check if schema exists
schema_exists=$("$HOME/common/oracle/CheckIfSchemaExists.sh" -v "$schema")
if [ $? -ne 0 ]; then
    echo "$schema_exists"
    echo "Error occurred while attempting to run CheckIfSchemaExists.sh. Exiting..."
    exit 1
elif [ "$schema_exists" != "Yes" ]; then
    echo "Error. Schema ${schema} does not exist in the current database $ORACLE_SID. Exiting..."
    exit 1
fi

# SQL query to check if object exists
object_check=$(
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set heading off
    set feedback off
    select object_name from dba_objects where owner like '${schema}' and object_name='$object_name';
EOD
)

sql_error=$?
ora_error=$(echo "$object_check" | grep "ORA-")

# Check if table was found
if [ $sql_error -ne 0 ] || [ -n "$ora_error" ]; then
    echo "ERROR"
    echo "$ora_error"
    exit 1
elif [ -z "$object_check" ]; then
    echo "No"
    exit 0
else
    echo "Yes"
    exit 0
fi
