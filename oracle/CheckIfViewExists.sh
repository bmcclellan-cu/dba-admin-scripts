#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: Check if the specified view exists. If it exists return 'Yes' otherwise 
#          return 'No'
#
#####################################################################################
usage="Usage: CheckIfViewExists.sh [ schema | ALL ] [ view ]"
example="Example: CheckIfViewExists.sh MYSCHEMA MYVIEW"

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
if [ $# -ne 2 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

schema=${1^^}
view=${2^^}

# Checking ORACLE_SID
sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "Error, \$ORACLE_SID not set..."
        exit 1
    fi
    echo "Error, \$ORACLE_SID is not open. Exiting..."
    exit 1
fi

schema_clause=""
if [ "$schema" != "ALL" ]; then
    schema_check=$("$HOME/common/oracle/CheckIfSchemaExists.sh" -v "$schema")
    if [ $? -ne 0 ]; then
        echo "An error occurred while calling CheckIfSchemaExists.sh. Exiting..."
        exit 1
    fi

    if [ "$schema_check" != "Yes" ]; then
        echo "Schema $schema does not exist for $ORACLE_SID. Exiting..."
        exit 1
    fi
    schema_clause="AND owner='$schema'"
fi

view_check=$(
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1

    set feedback off
    set heading off

    SELECT view_name FROM dba_views WHERE view_name='$view' $schema_clause;
EOD
)
if [ $? -ne 0 ]; then
    echo "Error occurred while checking for view_name $view. Exiting..."
    exit 1
elif [ -z "$view_check" ]; then
    echo "No"
else
    echo "Yes"
fi

exit 0