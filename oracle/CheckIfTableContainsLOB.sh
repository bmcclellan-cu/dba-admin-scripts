#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script acts as a helper script to check whether or not a table in
#	   the current database contains a *LOB type column (CLOB, BLOB, etc).
#      The output will simply be "YES" if the table contains a *LOB column or "NO" if it does not.
#
# Explanation: Some SQL operations, like the 'minus' operator, are blocked by Oracle
#	       if the table contains any type of LOB column. This script helps to
#	       check if the table being operated on contains a LOB column so that a
#	       different operation that considers LOB columns may be used instead.
#
#####################################################################################

usage="Usage: CheckIfTableContainsLOB.sh [schema] [table (optional)]"
example="Example: CheckIfTableContainsLOB.sh MY_SCHEMA MY_TABLE"

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
if [ $# -eq 0 ] || [ $# -gt 2 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Set user input to uppercase
schema=${1^^}
table=${2^^}

# Check oracle sid
sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
if [ $? -ne 0 ]; then
    echo "An error occurred while running VerifyAllParam.sh. Exiting..."
    echo "$sid_check"
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

# Check if schema exists in database
schema_exists=$("$HOME/common/oracle/CheckIfSchemaExists.sh" -v "$schema")
if [ $? -ne 0 ]; then
    echo "Error occurred while attempting to run CheckIfSchemaExists.sh. Exiting..."
    echo "$schema_exists"
    exit 1
fi

if [[ $schema_exists != Yes ]]; then
    echo "Entered schema $schema does not exist in current database ${ORACLE_SID}. Exiting..."
    exit 1
fi

# Check if table exists in database if provided
if [ $# -eq 2 ]; then
    table_exists=$("$HOME/common/oracle/CheckIfTableExists.sh" "$schema" "$table")
    if [ $? -ne 0 ]; then
        echo "Error occurred while checking if table $table exists under schema $schema in the current database"
        echo "$table_exists"
        exit 1
    elif [[ "$table_exists" != Yes ]]; then
        echo "Entered table $table does not exist under schema $schema in current database ${ORACLE_SID}. Exiting..."
        exit 1
    fi

    table_clause="and table_name = '$table'"
fi

# Check for LOB tables in dba_lobs
table_check=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
whenever oserror exit 1
whenever sqlerror exit 1
set heading off
set feedback off
select * from dba_lobs
where owner = '$schema' ${table_clause};
EOD
)

sql_error=$?
ora_error=$(echo "$table_check" | grep "ORA-")

# Check for errors and if table was found
if [ $sql_error -ne 0 ] || [ ! -z "$ora_error" ]; then
    echo "ERROR"
    echo "$table_check"
    exit 1
elif [ -z "$table_check" ]; then
    echo "NO"
    exit 0
else
    echo "YES"
    exit 0
fi
