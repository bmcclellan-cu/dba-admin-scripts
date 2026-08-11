#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: The purpose of this script is run a SQL file, utlrp.sql, on one or all
#	   databases and check for any invalid objects. The SQL file itself recompiles
#	   invalid objects in the current database.
#
#####################################################################################
usage="Usage: RecompileAllObjects.sh [ORACLE_SID | ALL (optional)]"
example="Example: RecompileAllObjects.sh mydbprod"

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
if [ $# -gt 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Set sid to user-provided input or set sid variable to current ORACLE_SID
if [ -z "$1" ] && [ -z "$ORACLE_SID" ]; then
    echo "ERROR: \$ORACLE_SID not set and none provided."
    echo "Rerun the script and enter the target database as the first parameter."
    echo "Exiting..."
    exit 1
elif [ -n "$1" ]; then
    sid=$1
elif [ -n "$ORACLE_SID" ]; then
    sid=$ORACLE_SID
fi
 
# Check for valid ORACLE_SID
sid_check=$("$HOME/common/oracle/VerifyAllParam.sh -I $sid")
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "Error, \$ORACLE_SID not set..."
        exit 1
    elif [ "$sid" == "ALL" ]; then
        echo "Not all databases are open, closed databases will be skipped. Continuing..."
    else
        echo "Error, provided ORACLE_SID is not open. Exiting..."
        exit 1
    fi
fi
sids=$("$HOME/common/oracle/VerifyAllParam.sh" -V "$sid")

# Loop through sids
for sid in $sids; do
    export ORACLE_SID=$sid
    # Run utlrp.sql and query the dba_objects table for invalid objects
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set pagesize 10000
    set linesize 160
    column owner format a20
    column object_name format a40
    @$ORACLE_HOME/rdbms/admin/utlrp.sql
    select owner, object_name, object_type from dba_objects where status != 'VALID';
EOD
done

if [ $? -ne 0 ]; then
    echo "Error returned while running script on $sid. Exiting..."
    exit 1
else
    echo "Script finished successfully"
    exit 0
fi
