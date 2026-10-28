#!/bin/bash
# AvailabilityFlag: Public
# Purpose: This script acts as a helper script to check whether or not a table in
#	   the current database is partitioned. The output will simply be "YES" if
#	   the table is partitioned or "NO" if it isn't.
#
#####################################################################################

usage="Usage: CheckIfTableIsPartitioned.sh [schema] [table name]"
example="Example: CheckIfTableIsPartitioned.sh MY_SCHEMA MY_TABLE"

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

# Set user input to uppercase
schema=${1^^}
table=${2^^}

# Check oracle sid
sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)

if [ $? -ne 0 ]; then
    echo "$sid_check"
    echo "Error, call to VerifyAllParam.sh -I failed. Exiting..."
    exit 1
fi

if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "Error, \$ORACLE_SID not set..."
        exit 1
    fi
    echo "Error, database $ORACLE_SID is not open"
    exit 1
fi

# Check if schema exists in database
schema_exists=$("$HOME/common/oracle/CheckIfSchemaExists.sh" -v "$schema")
if [ $? -ne 0 ]; then
    echo "$schema_exists"
    echo "Error occurred while attempting to run CheckIfSchemaExists. Exiting..."
    exit 1
fi

schema_exists=$(echo "$schema_exists" | grep "Yes")

if [ -z "$schema_exists" ]; then
    echo "Entered schema $schema does not exist in current database ${ORACLE_SID}. Exiting..."
    exit 1
fi

# Check if table exists in schema.
table_exists=$("$HOME/common/oracle/CheckIfTableExists.sh" "$schema" "$table")
if [ $? -ne 0 ]; then
    echo "$table_exists"
    echo "Error occurred while attempting to run CheckIfTableExists.sh. Exiting..."
    exit 1
fi

table_exists=$(echo "$table_exists" | grep "Yes")

if [ -z "$table_exists" ]; then
    echo "Entered table $table does not exist in current schema ${schema}. Exiting..."
    exit 1
fi

# Check for table in dba_tab_partitions
table_check=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
whenever oserror exit 1
whenever sqlerror exit 1
set heading off
set feedback off
select * from dba_tab_partitions
where table_owner = '$schema' and table_name = '$table';
EOD
)

sql_error=$?
ora_error=$(echo "$table_check" | grep "ORA-")

# Check for errors and if table was found
if [ $sql_error -ne 0 ] || [ ! -z "$ora_error" ]; then
    echo "ERROR"
    echo "$ora_error"
    exit 1
elif [ -z "$table_check" ]; then
    echo "NO"
    exit 0
else
    echo "YES"
    exit 0
fi