#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script acts as a helper script for other scripts to check whether
#	   a column in a table exists or doesn't exist in the current database. It checks
#	   dba_tab_columns for the column and returns 'Yes' if found or 'No' if not.
#
#####################################################################################

usage="Usage: CheckIfColumnExists.sh [ -v (optional, skip input validation) ] [schema] [table] [column]"
example="Example: CheckIfColumnExists.sh MY_SCHEMA MY_TABLE MY_COLUMN"

validation_opt=0
while getopts ":hv" option; do
    case $option in
        h)
            echo "$usage"
            echo "$example"
            exit 0
            ;;
        v)
            validation_opt=1
            ;;
        \?)
            echo "Error: Invalid option"
            exit 1
    esac
done

shift "$((OPTIND - 1))"

# Check arguments
if [ $# -ne 3 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Set user input to uppercase
schema=${1^^}
table=${2^^}
column=${3^^}

if [ $validation_opt -eq 0 ]; then
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

    # Check if schema exists
    schema_check=$("$HOME/common/oracle/CheckIfSchemaExists.sh" -v "$schema")
    if [ $? -ne 0 ]; then
        echo "Error occurred while attempting to run CheckIfSchemaExists.sh. Exiting..."
        exit 1
    elif [ "$schema_check" != "Yes" ]; then
        echo "ERROR: Schema $schema doesn't exist in the current database $ORACLE_SID"
        exit 1
    fi

    # Check if table or view inputted exists.
    table_check=$("$HOME/common/oracle/CheckIfTableExists.sh" "$schema" "$table")
    if [ $? -ne 0 ]; then
        echo "Error occurred while attempting to run CheckIfTableExists.sh. Exiting..."
        exit 1
    elif [ "$table_check" != "Yes" ]; then
        check_view=$("$HOME/common/oracle/CheckIfViewExists.sh" "$schema" "$table")
        if [ $? -ne 0 ]; then
            echo "An error occurred while checking if view $table exists. Exiting..."
            exit 1
        fi
        if [ "$check_view" != "Yes" ]; then
            echo "ERROR: Table or view $schema.$table does not exist in database $ORACLE_SID. Exiting..."
            exit 1
        fi
    fi
fi

# Check dba_tab_columns for $column, store if found
column_check=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set heading off
    set feedback off

    select column_name from dba_tab_columns
    where owner = '$schema'
    and table_name = '$table'
    and column_name = '$column';
EOD
)
if [ $? -ne 0 ] || echo "$column_check" | grep -q "ORA-"; then
    echo "$column_check"
    echo "An error occurred while querying for column $column in table $schema.$table. Exiting..."
    exit 1
elif [ -z "$column_check" ]; then
    echo "No"
    exit 0
else
    echo "Yes"
    exit 0
fi
