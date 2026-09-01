#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose:  This script acts as a helper script for other scripts to check whether
#	        a table exists or doesn't exist in the current database. It checks
#	        dba_tables for the table and returns 'Yes' if found or 'No' if not.
#
#####################################################################################

usage="Usage: CheckIfTableExists.sh [schema | ALL] [table]"
example="Example: CheckIfTableExists.sh MY_SCHEMA MY_TABLE"

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
if [ $# -ne 2 ]; then
    echo "$usage"
    echo "$example"
    exit 1
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

# Set user and table to uppercase
schema=${1^^}
table=${2^^}

schema_clause=""

# If schema is not all, check if it exists and filter by it.
if [[ "$schema" != "ALL" ]]; then
    schema_check=$("$HOME/common/oracle/CheckIfSchemaExists.sh" -v "$schema")

    if [ $? -ne 0 ]; then
        echo "Error occurred while attempting to run CheckIfSchemaExists.sh. Exiting..."
        exit 1
    elif [ "$schema_check" != "Yes" ]; then
        echo "Schema $schema doesn't exist in the current database $ORACLE_SID"
        exit 1
    fi
    schema_clause=" AND owner = '$schema'"
fi



# Check dba_tables for $table, store if found
table_check=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set heading off
    set feedback off

    select table_name from dba_tables
    where table_name = '$table'
    $schema_clause;
EOD
)
if [ $? -ne 0 ] || echo "$table_check" | grep -q "ORA-"; then
    echo "$table_check"
    echo "An error occurred while checking if table $schema.$table exists. Exiting..."
    exit 1
elif [ -z "$table_check" ]; then
    echo "No"
    exit 0
else
    echo "Yes"
    exit 0
fi
