#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script acts as a helper script for other scripts to check if 
#          a given tablespace is READ-ONLY or READ-WRITE or to check the 
#          read status of the tablespace a given segment is stored on
#
#####################################################################################

usage="Usage: CheckTablespaceReadStatus.sh [tablespace] | [[schema] [segment name] [segment type (optional, use quotes if type has 2 words)]]"
example="Example 1: CheckTablespaceReadStatus.sh MY_TBSP
Example 2: CheckTablespaceReadStatus.sh SCHEMA01 DATA_01.SOME_PART_0123 'TABLE PARTITION'"

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
if [ $# -lt 1 ] || [ $# -gt 3 ]; then
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


if [ $# -eq 1 ]; then
    
    tablespace=${1^^}

    # Check if tablespace exists
    tbsp_check=$("$HOME/common/oracle/CheckIfTablespaceExists.sh" "$tablespace")
    if [ $? -ne 0 ]; then
        echo "Error occurred while attempting to run CheckIfTablespaceExists.sh. Exiting..."
        echo "$tbsp_check"
        exit 1
    elif [ "$tbsp_check" != "Yes" ]; then
        echo "Error, tablespace $tablespace doesn't exist in the current database $ORACLE_SID. Exiting..."
        exit 1
    fi
else 
    schema=${1^^}
    segment=${2^^}
    # Left empty if not given by user
    segment_type=${3^^} 
    valid_segments="|INDEX|TABLE|NESTED TABLE|TABLE PARTITION|CLUSTER|LOBINDEX|INDEX PARTITION|LOBSEGMENT|TABLE SUBPARTITION|INDEX SUBPARTITION|LOB PARTITION|LOB SUBPARTITION|ROLLBACK|TYPE2 UNDO|DEFERRED ROLLBACK|TEMPORARY|CACHE|SPACE HEADER|UNDEFINED|"

    # If given, check that segment type is valid
    if [ -n "$segment_type" ]; then
        if (! echo "$valid_segments" | grep -q "|$segment_type|" ); then
            echo "$segment_type is an invalid segment type. Exiting..."
            exit 1
        fi
    fi

    # Check if schema exists
    schema_check=$("$HOME/common/oracle/CheckIfSchemaExists.sh" -v "$schema")
    if [ $? -ne 0 ]; then
        echo "Error occurred while attempting to run CheckIfSchemaExists.sh. Exiting..."
        echo "$schema_check"
        exit 1
    elif [ "$schema_check" != "Yes" ]; then
        echo "Error, schema $schema doesn't exist in the current database $ORACLE_SID. Exiting..."
        exit 1
    fi

    # Get tablespace that segment is stored on
    tablespace=$("$HOME/common/oracle/PrintSegments.sh" "$schema" "SCHEMA" "$segment_type")
    if [ $? -ne 0 ]; then
        echo "Error occurred while attempting to run PrintSegments.sh. Exiting..."
        echo "$tablespace"
        exit 1
    fi

    # Isolate tablespace_name from output
    # Include $5 in case segment type is 2 words
    tablespace=$(echo "$tablespace" | awk -v segment="$segment" '$2 == segment { print $2, $4, $5 }')

    # Check if segment exists and is unique
    if [ -z "$tablespace" ]; then
        if [ -n "$segment_type" ]; then
            echo "Error, $segment_type $segment doesn't exist on schema $schema. Exiting..."
            exit 1
        else
            echo "Error, segment $segment doesn't exist on schema $schema. Exiting..."
            exit 1
        fi
    elif [ "$(echo "$tablespace" | wc -l)" -gt 1 ]; then    
        echo "Error, more than one segment was found with the name $segment. Input a segment type and try again. Exiting"
        exit 1
    else
        if [ "$(echo "$tablespace" | awk '{print $2}')" == "PARTITION" ]; then
            tablespace=$(echo "$tablespace" | awk '{print $3}')
        else
            tablespace=$(echo "$tablespace" | awk '{print $2}')
        fi
    fi
fi

status=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    set heading off
    set feedback off
    set trimspool on 
    set linesize 32000
    whenever oserror exit 1
    whenever sqlerror exit 1

    SELECT status
    FROM dba_tablespaces
    WHERE TABLESPACE_NAME='$tablespace';
    exit;
EOD
)
if [ $? -ne 0 ]; then
    echo "Error occurred while attempting to query for tablespace status. Exiting..."
    echo "$status"
    exit 1
fi
status=$(echo "$status" | sed '/^[[:space:]]*$/d')

# Isolate tablespace read status from output
if [ "$status" == "ONLINE" ]; then
    echo "READ-WRITE"
    exit 0
elif [ "$status" == "READ ONLY" ]; then
    echo "READ-ONLY"
    exit 0
else 
    echo "OFFLINE"
    exit 0
fi