#!/bin/bash
#
# Purpose:  Gets the version of the TMAverage tables loaded on the database as well as the version of the TMAverage
#           software and confirms whether they are compatible or not. They are deemed compatible if the major version (X.0)
#           matches between the database and the software (denoted by TMAverageHelper.py). If SID ALL is passed to the script
#           it will iterate through all SIDs.
# 
# Notes:
#           The database and software are considered out-of-sync if the MAJOR version number is different. Major version numbers 
#           indicate a database table/procedure change that causes incompatibility with TMAverage. 
# 
# Author: Robert Schmidt
# Created on: January 5th, 2026
# Modified on: January 5th, 2026 - RS
###############################################################
usage="Usage: ./GetTMAverageStatus.sh [database] [ system_id | ALL ]"
example="Example: ./ProcessTMAverageData.sh ixpeprod"

while getopts ":h" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    \?)
        echo "ERROR: Invalid option. Exiting..."
        exit 1
        ;;
    esac
done

# Check number of arguments
if [ $# -lt 2 ] || [ $# -gt 2 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Resolve the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

database=${1,,}
system_ids=${2^^}

if [ "$system_ids" != "ALL" ] && [[ ! $system_ids =~ ^[0-9]+$ ]]; then
    echo "System_id must either be a positive integer of 'ALL'. Exiting..."
    exit 1
fi

export ORACLE_SID="$database"

sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I "$ORACLE_SID")
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "ERROR: \$ORACLE_SID not set. Exiting..."
        exit 1
    fi
    echo "ERROR: Provided database is not open. Exiting..."
    exit 1
fi

newest_python=$(ls /usr/bin/python3* | grep -oP 'python3\.\d+' | sort -V | tail -n 1)
if [ $? -ne 0 ] || [ -z "$newest_python" ]; then
    echo "$newest_python"
    echo "Failed to find newest version of python. TMAverage requires the use of python. Exiting..."
    exit 1
fi


if [ "$system_ids" == "ALL" ]; then
    # Get all available SIDs for a given database if ALL option is used.
    system_ids=$($newest_python $SCRIPT_DIR/TMAverageHelpers.py "$ORACLE_SID" list 2>&1)
    if [ $? -ne 0 ]; then
        if [[ "$system_ids" == *"not supported by TMAverage"* ]]; then
            echo "ERROR: Database $ORACLE_SID system_id $system_id is not supported by TMAverage. Exiting..."
        else
            echo "$system_ids"
            echo "ERROR: An error occurred while parsing configs. Exiting..."
        fi
        exit 1
    fi
fi

tmaverage_version=$($newest_python $SCRIPT_DIR/TMAverageHelpers.py version 2>&1)
if [ $? -ne 0 ]; then
    echo "ERROR: An error occurred while fetching TMAverage version. Exiting..."
    exit 1
fi

# Get MISC schema for GrantNewPermissions.sh
misc_schema=$("$HOME/common/oracle/GetSchemaName.sh" -m -v)
if [ $? -ne 0 ]; then
    echo "$misc_schema"
    echo "An error occurred while getting the MISC schema name. Exiting..."
    exit 1
fi

table_check=$("$HOME/common/oracle/CheckIfTableExists.sh" "$misc_schema" MIGRATION_STATUS)
if [ $? -ne 0 ]; then
    echo "Error occurred while attempting to run CheckIfTableExists.sh. Exiting..."
    echo "$table_check"
    exit 1
elif [ "$table_check" != "Yes" ]; then
    echo "Error, table MIGRATION_STATUS doesn't exist in the current database $ORACLE_SID under the schema $misc_schema. Exiting..."
    exit 1
fi

tmaverage_incompatible=0

# Iterate through each SID and query the table version history table for the current version for that SID
for system_id in $system_ids; do
    migration_status=$("$ORACLE_HOME"/bin/sqlplus -s / as sysdba <<EOD
        set heading off
        set feedback off
        whenever oserror exit 1
        whenever sqlerror exit 1

        set linesize 10000

        SELECT STATUS_TIMESTAMP || '|' || UPDATE_VERSION || '|' || UPDATE_SUCCESS 
        FROM $misc_schema.MIGRATION_STATUS
        WHERE SID=$system_id ORDER BY STATUS_TIMESTAMP DESC FETCH NEXT 1 ROWS ONLY;
EOD
    )
    if [ $? -ne 0 ]; then
        echo "$migration_status"
        echo "An error occurred while fetching database table version from MIGRATION_STATUS for SID $system_id. Continuing..."
        continue
    fi


    # Remove all newlines & split values
    migration_status=$(echo "$migration_status" | tr -d '\n')
    IFS='|' read -r timestamp db_version status <<< "$migration_status"

    echo "TMAverage Status for SID $system_id: "
    echo "  DB Last Updated:  $timestamp"
    echo "  DB Version:       $db_version ($status)"
    echo "  Software Version: $tmaverage_version"

    # Split version numbers and ensure major version matches
    IFS='.' read -r db_major_v db_minor_v <<< "$db_version"
    IFS='.' read -r tm_major_v tm_minor_v <<< "$tmaverage_version"
    
    if [ $tm_major_v -ne $db_major_v ]; then
        echo "WARNING: Database and software have mismatched major versions. Please update either database or software to prevent compatibility issues. Continuing..."
        tmaverage_incompatible=1
    fi

    if [[ "$status" != "Success" ]]; then
        echo "WARNING: The most recent update to the TMAverage tables failed. Please ensure that tables are correctly setup and re-run ConfigureTMAverageEnvironment.sh. Continuing..."
        tmaverage_incompatible=1
    fi
done

echo

if [ $tmaverage_incompatible -ne 0 ]; then
    echo "ERROR: One or more SIDs for database $database have a failed/incompatible version of TMAverage installed on the database. "
    echo "       Please run ConfigureTMAverageEnvironment.sh to update. Exiting..."
    exit 1
else
    echo "TMAverage is up-to-date!"
fi

# TODO: Add case for if no rows are returned!