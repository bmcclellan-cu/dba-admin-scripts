#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: The purpose of this script is to show all invalid indexes on a single
#	   database or all databases.
#
#####################################################################################

usage="Usage: DisplayInvalidIndexes.sh [ALL | \$ORACLE_SID (optional)] | [[schema|tablespace] [identifier (either schema or tablespace)]]"
example="Example 1: DisplayInvalidIndexes.sh mydbprod
Example 2: DisplayInvalidIndexes.sh SYS schema"

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
if [ $# -gt 2 ]; then
    echo "$usage"
    echo "$example"
    exit 1
elif [ $# -lt 2 ]; then
    # Set sids to user-provided input or set sids variable to current ORACLE_SID
    if [ -z "$1" ] && [ -z "$ORACLE_SID" ]; then
        echo "ERROR: \$ORACLE_SID not set and none provided."
        echo "Rerun the script and enter the target database as the first parameter."
        echo "Exiting..."
        exit 1
    elif [ -n "$1" ]; then
        input_sids=$1
    else
        input_sids=$ORACLE_SID
    fi

    sids=$("$HOME/common/oracle/VerifyAllParam.sh" -V "$input_sids")
    if [ $? -ne 0 ]; then
        echo "Error occurred while attempting to run VerifyAllParam.sh. Exiting..."
        echo "$sids"
        exit 1
    fi

else
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

    sids=$ORACLE_SID

    identifier=${2^^}
    if [ "$identifier" == "SCHEMA" ]; then
        schema=${1^^}

        # Check if schema exists
        schema_check=$("$HOME/common/oracle/CheckIfSchemaExists.sh" -v "$schema")
        if [ $? -ne 0 ]; then
            echo "Error occurred while attempting to run CheckIfSchemaExists.sh on $schema. Exiting..."
            echo "$schema_check"
            exit 1
        elif [ "$schema_check" != "Yes" ]; then
            echo "Schema $schema does not exist on database $ORACLE_SID. Exiting..."
            exit 1
        fi

        # Set clauses to be used in below query
        owner_clause="and owner = '$schema'"
        index_owner_clause="and index_owner = '$schema'"
        tablespace_clause=""

    elif [ "$identifier" == "TABLESPACE" ]; then
        tablespace=${1^^}

        # Check if tablespace exists
        tablespace_check=$("$HOME/common/oracle/CheckIfTablespaceExists.sh" "$tablespace")
        if [ $? -ne 0 ]; then
            echo "Error occurred while attempting to run CheckIfTablespaceExists.sh on $tablespace. Exiting..."
            echo "$tablespace_check"
            exit 1
        elif [ "$tablespace_check" != "Yes" ]; then
            echo "Tablespace $tablespace does not exist on database $ORACLE_SID. Exiting..."
            exit 1
        fi
        
        # Set clauses to be used in below query
        tablespace_clause="and tablespace_name = '$tablespace'"
        owner_clause=""
        index_owner_clause=""
    else
        echo "Error, invalid identifier. Identifier must be 'schema' or 'tablespace'. Exiting..."
        exit 1
    fi
fi

# Loop through sids, which contains either the user-entered SID, all SIDs in SIDSLIST, or the set ORACLE_SID
exit_status=0
failed_sids=()
for sid in $sids; do
    echo "Displaying invalid indexes on $sid"
    export ORACLE_SID=$sid
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever sqlerror exit 1
    whenever oserror exit 1

    set pagesize 10000
    set linesize 250

    column owner format a20
    column index_name format a40
    column NULL format a20
    column partition_name format a40
    column subpartition_name format a40
    column tablespace_name format a20

    SELECT owner, index_name, NVL(NULL, 'N/A') as partition_name, NVL(NULL, 'N/A') as subpartition_name, tablespace_name
    FROM dba_indexes
    WHERE status = 'UNUSABLE' $owner_clause $tablespace_clause
    UNION ALL
    SELECT index_owner, index_name, partition_name, NVL(NULL, 'N/A') as subpartition_name, tablespace_name
    FROM dba_ind_PARTITIONS
    WHERE status = 'UNUSABLE' $index_owner_clause $tablespace_clause
    UNION ALL
    SELECT index_owner, index_name, partition_name, subpartition_name, tablespace_name
    FROM dba_ind_SUBPARTITIONS
    WHERE status = 'UNUSABLE' $index_owner_clause $tablespace_clause ;
EOD

    if [ $? -ne 0 ]; then
        echo "Error occurred while displaying invalid indexes on database $sid. Continuing..."
        echo
        exit_status=1
        failed_sids+=("$sid")
        continue
    fi
done


if [ $# -lt 2 ]; then
    # Output invalid ORACLE_SIDs
    sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I "$input_sids")
    if [ -n "$sid_check" ]; then
        echo "Error: database(s) $sid_check are not open."
        exit_status=1
    fi
fi

# Don't print any success output to maintain compatibility with dependent scripts
if [ "$exit_status" -eq 0 ]; then
    exit 0
else
    if [ -n "$failed_sids" ]; then
        echo "The following SIDs had an error while querying for invalid indexes: ${failed_sids[*]}"
    fi
    echo "Script completed with errors"
    exit 1
fi
