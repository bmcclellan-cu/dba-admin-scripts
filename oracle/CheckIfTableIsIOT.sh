#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This is a helper script that is used to determine whether or not a table
#	   is an IOT. The script searches the dba_indexes table for any 'IOT - TOP'
#	   indexes. If any are found, the table is an IOT, which is returned to the
#	   user. If not, the word 'NULL' is returned instead.
# 
#####################################################################################

usage="Usage: CheckIfTableIsIOT.sh [ -s (skip input validation) ] [owner] [table name]"
example="Example: CheckIfTableIsIOT.sh MY_SCHEMA MY_TABLE"

# Process input options
skip_opt=false
while getopts ":hs" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0;;
    s)
        skip_opt=true
        shift 1
        ;;
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

owner=${1^^}
table_name=${2^^}

if ! $skip_opt; then
    # Check oracle sid
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
        echo "Error, database $ORACLE_SID is not open"
        exit 1
    fi

    # Check if owner exists
    owner_exists=$("$HOME/common/oracle/CheckIfSchemaExists.sh" -v "$owner")
    if [ $? -ne 0 ]; then
        echo "Error occurred while attempting to run CheckIfSchemaExists.sh. Exiting..."
        echo "$owner_exists"
        exit 1
    fi

    if [ "$owner_exists" != "Yes" ]; then
        echo "Owner $owner does not exist in the current database. Exiting..."
        exit 1
    fi

    # Check if provided table exists under the provided owner in the database
    table_exists=$("$HOME/common/oracle/CheckIfTableExists.sh" "$owner" "$table_name")
    if [ $? -ne 0 ]; then
        echo "Error occurred while attempting to run CheckIfTableExists.sh. Exiting..."
        echo "$table_exists"
        exit 1
    elif [ "$table_exists" != "Yes" ]; then
        echo "Table $table_name does not exist for owner $owner in the current database. Exiting..."
        exit 1
    fi
fi

# Query the dba_indexes table to count the number of IOT indexes for the owner/table pair
# If this number is greater than 0, then the table is an IOT table
check_iot=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set heading off
    set feedback off
    select count(*) from dba_indexes where 
    table_owner like '$owner'
    and table_name = '$table_name'
    and index_type = 'IOT - TOP';
EOD
)
# Check for errors
sql_error=$?
ora_error=$(echo "$check_iot" | grep "ORA-")

# Remove whitespace
check_iot=$(echo "$check_iot" | xargs)

if [ $sql_error -ne 0 ] || [ -n "$ora_error" ]; then
    echo "$check_iot"
    echo "Error occurred while checking if table $owner.$table_name is an IOT table"
    exit 1
elif [ "$check_iot" -eq 0 ]; then
    echo "NULL"
    exit 0
else
    echo "IOT"
    exit 0
fi
