#!/bin/bash
# AvailabilityFlag: Public
# Purpose: This script acts as a helper script for other partition-related scripts.
#	   It takes the current schema and checks the partition type from
#	   dba_part_tables. If the clause returns RANGE or LIST, then they are
#	   outputted to the user. If the clause returns NULL, or if the clause doesn't
#	   return anything, the user is told that there is no partitioning or no result
#	   before the script exits.
#
#####################################################################################

usage="Usage: CheckPartitionType.sh"

# Process input options
while getopts ":h" option; do
    case $option in
    h)
        echo "$usage"
        exit 0
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
    esac
done

# Check arguments
if [ $# -ne 0 ]; then
    echo "$usage"
    exit 1
fi

# Checking ORACLE_SID
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
    echo "Error, provided \$ORACLE_SID is not open. Exiting..."
    exit 1
fi

# Check partition_type from dba_part_tables and store in $partition_type
partition_type=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set heading off
    set feedback off
    select distinct partitioning_type from dba_part_tables
    where owner IN (select username from dba_users where oracle_maintained = 'N');
EOD
)

# Check for errors
sql_error=$?
ora_error=$(echo "$partition_type" | grep "ORA-")

# Remove whitespace
partition_type=${partition_type:1}
# Check the result stored in $partition_type
if [ $sql_error -ne 0 ] || [ ! -z "$ora_error" ]; then
    echo "Error occurred while checking partition type. Exiting..."
    exit 1
elif [ "${partition_type^^}" == "RANGE" ] || [ "${partition_type^^}" == "LIST" ]; then
    echo "$partition_type"
    exit 0
elif [ "${partition_type^^}" == "NULL" ]; then
    echo "No partitioning in database $ORACLE_SID"
    exit 1
else
    echo "No partitioning_type found for database $ORACLE_SID"
fi
