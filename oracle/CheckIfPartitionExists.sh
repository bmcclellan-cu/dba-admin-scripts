#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script acts as a helper script for other scripts to check whether
#	   the given partition exists in the given table under the given schema.
#	   The script returns 'Yes' if it does, 'No' if it doesn't, or 'ERROR'
#	   followed by the message of the error if it occurs.
# 
#####################################################################################

usage="Usage: CheckIfPartitionExists.sh [schema] [table] [partition]"
example="Example: CheckIfPartitionExists.sh MY_SCHEMA MY_TABLE MY_TABLE_PART1307"

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
    esac
done


# Check arguments
if [ $# -ne 3 ]; then
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

# Set user, table, and partition to uppercase
schema=${1^^}
table=${2^^}
partition=${3^^}

# Check if schema exists
schema_check=$("$HOME/common/oracle/CheckIfSchemaExists.sh" -v "$schema")
if [ $? -ne 0 ]; then
    echo "$schema_check"
    echo "Error occurred while attempting to run CheckIfSchemaExists.sh. Exiting..."
    exit 1
elif [ "$schema_check" != "Yes" ]; then
    echo "Schema $schema doesn't exist in the current database $ORACLE_SID"
    exit 1
fi

# Check if table exists
table_check=$("$HOME/common/oracle/CheckIfTableExists.sh" "$schema" "$table")

if [ $? -ne 0 ]; then
    echo "$table_check"
    echo "Error occurred while attempting to run CheckIfTableExists.sh. Exiting..."
    exit 1
elif [ "$table_check" != "Yes" ]; then
    echo "Table $table doesn't exist under the schema $schema in $ORACLE_SID"
    exit 1
fi

# Check dba_tab_partitions for $partition, store if found
partition_check=$("$ORACLE_HOME"/bin/sqlplus -s / as sysdba <<EOD
whenever oserror exit 1
whenever sqlerror exit 1
set heading off
set feedback off
select partition_name from dba_tab_partitions where partition_name = '$partition'
and table_name = '$table'
and table_owner = '$schema';
EOD
)

sql_error=$?
ora_error=$(echo "$partition_check" | grep "ORA-")

# Check if partition was found
if [ $sql_error -ne 0 ] || [ -n "$ora_error" ]; then
    echo "ERROR"
    echo "$partition_check"
    exit 1
elif [ -z "$partition_check" ]; then
    echo "No"
    exit 0
else
    echo "Yes"
    exit 0
fi
