#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose:  This script acts as a helper script for other scripts to check whether
#           a table exists or doesn't exist in the current database. It checks
#           dba_tables for the table and returns 'Yes' if found or 'No' if not.
#           With -v it also checks dba_views for the same name, since a view is a logical
#           table, and prints two lines instead: 'Table: Yes|No' and 'View: Yes|No'.
#
#####################################################################################

usage="Usage: CheckIfTableExists.sh [-v (Check if View Exists)] [schema | ALL] [table]"
example1="Example 1: CheckIfTableExists.sh MY_SCHEMA MY_TABLE"
example2="Example 2: CheckIfTableExists.sh -v MY_SCHEMA MY_TABLE"
check_view=0
output=""
# Process input options
while getopts ":hv" option; do
    case $option in
        h)
            echo "$usage"
            echo "$example1"
            echo "$example2"
            exit 0;;
        v)
            check_view=1
            output="Table: "
            ;;
        \?)
            echo "Error: Invalid option"
            exit 1
    esac
done

shift $((OPTIND - 1))

# Check arguments
if [ $# -ne 2 ]; then
    echo "$usage"
    echo "$example1"
    echo "$example2"
    exit 1
fi

# Checking ORACLE_SID
sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)

if [ $? -ne 0 ]; then
    echo "$sid_check"
    echo "Error, call to VerifyAllParam.sh failed. Exiting..."
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

# Set user and table to uppercase
schema=${1^^}
table=${2^^}

schema_clause=""

# If schema is not all, check if it exists and filter by it.
if [[ "$schema" != "ALL" ]]; then
    schema_check=$("$HOME/common/oracle/CheckIfSchemaExists.sh" -v "$schema")

    if [ $? -ne 0 ]; then
        echo "$schema_check"
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
    output+="No"
else
    output+="Yes"
fi

if [ $check_view -ne 0 ]; then
    view_check=$(
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1

        set feedback off
        set heading off

        SELECT view_name FROM dba_views WHERE view_name='$table' $schema_clause;
EOD
)
    if [ $? -ne 0 ] || echo "$view_check" | grep -q "ORA-"; then
        echo "$view_check"
        echo "An error occurred while checking if view $schema.$table exists. Exiting..."
        exit 1
    elif [ -z "$view_check" ]; then
        output+=$'\n'"View: No"
    else
        output+=$'\n'"View: Yes"
    fi
fi

echo "$output"