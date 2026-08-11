#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: The purpose of this script is to print out all data files from a database
#          chosen by the user. If a database is not given, the script will default
#          to the current database specified by the user's current $ORACLE_SID.
#
#####################################################################################

usage="Usage: PrintAllDataFiles [-o (optional, print only online files)] [ORACLE_SID (optional)]"
example="Example: PrintAllDataFiles mydbprod"

status=""

# Process input options
while getopts ":ho" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    o)
        status="WHERE status = 'ONLINE'"
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

if [ -n "$status" ]; then
    shift 1
fi

if [ $# -gt 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Set schema to user-provided input or set SID variable to current ORACLE_SID
if [ -z "$1" ] && [ -z "$ORACLE_SID" ]; then
    echo "ERROR: \$ORACLE_SID not set and none provided."
    echo "Rerun the script and enter the target database as the first parameter."
    echo "Exiting..."
    exit 1
elif [ -n "$1" ]; then
    export ORACLE_SID=$1
fi

# Check for valid ORACLE_SID
sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I "$ORACLE_SID")
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
       echo "Error, \$ORACLE_SID not set..."
       exit 1
    fi
    echo "Error, provided ORACLE_SID is not open. Exiting..."
    exit 1
fi

# Print all data files
#echo "Executing script on ${sid}..."
"$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
whenever oserror exit 1
whenever sqlerror exit 1
set heading off
set feedback off
set pagesize 1000
set linesize 300
column name format a120
Set Newpage none
select * from(
select name from v\$datafile $status
union
select name from v\$tempfile
union
select name from v\$controlfile
union
select member from v\$logfile
) order by name;
exit;
EOD

# Check for errors and exit
if [ $? -ne 0 ]; then
    echo "Error encountered when listing data files, exiting..."
    exit 1
else
    exit 0
fi
