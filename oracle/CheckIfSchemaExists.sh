#!/bin/bash 
# AvailabilityFlag: Public
#
# Purpose: This script acts as a helper script for other scripts to check whether
#	   a schema does or does not exist in the current database. It checks the
#	   dba_users table for the schema and returns 'Yes' if found or 'No' if not.
#
#####################################################################################

usage="Usage: CheckIfSchemaExists.sh [ -o (exclude oracle maintained schemas)] [ -v (skip VerifyAllParam.sh call)] [schema]"
example="Example: CheckIfSchemaExists.sh mydbprod"

#initalize -o option as false
oopt=false
vopt=false

# Process input option -o
while getopts ":hov" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    o)
        oopt=true
        ;;
    v)
        vopt=true
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

shift $((OPTIND - 1))

# Check arguments
if [ $# -ne 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Checking ORACLE_SID
if ! $vopt ; then
    sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
    if [ -n "$sid_check" ]; then
        if [ "$sid_check" == "-1" ]; then
        echo "Error, \$ORACLE_SID not set..."
        exit 1
        fi
        echo "Error, provided \$ORACLE_SID is not open. Exiting..."
        exit 1
    fi
fi

# Set user input to uppercase
schema=${1^^}

# Store the schema in $schema_check if found in dba_user
schema_check=$(
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD | xargs
    set heading off
    set feedback off
    whenever oserror exit 1
    whenever sqlerror exit 1
    select ORACLE_MAINTAINED from dba_users where username = '$schema';
EOD
)

# Check if schema was found 
if [ $? -ne 0 ]; then
    echo "Error occurred while checking if schema exists. Exiting..."
    exit 1
elif [ -z "$schema_check" ]; then
    echo "No"
    exit 0
else
    if $oopt && [ "$schema_check" == 'Y' ]; then
        echo "Oracle_managed"
        exit 0
    fi
    echo "Yes"
    exit 0
fi
