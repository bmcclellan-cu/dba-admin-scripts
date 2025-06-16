#!/bin/bash
#
# Purpose: A wrapper for the ProcessTMAverageData.py helper script, which averages the data from 
#          TMAnalog over 5 minute periods per TMID and inserts it into L1A.TMAVERAGE. This script
#          runs a few extra checks beforehand to ensure the script is ready to run.
# 
# Author: Robert Schmidt
# Created on: June 16th, 2025
###############################################################
usage="Usage: ./ProcessTMAverageData.sh [ -o (optional, use OTFD) ] [database] [TMID | ALL] [start_date] [end_date] [parallel_degree (optional)]"
example="Example: ./ProcessTMAverageData.sh goldprod ALL 12-JAN-25 13-FEB-25 8"

otfd_opt=""
# Process input options
while getopts ":ho" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    o)
        otfd_opt=" -o "
        exit 1
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

# Resolve the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check number of arguments
if [ $# -lt 4 ] || [ $# -gt 5 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

database=${1^^}
tmid=${2^^}
start_date=${3^^}
end_date=${4^^}
parallel_degree=${5^^}

# Check that the .passwd and .username files exist.
if [ ! -f "$SCRIPT_DIR/.username" ] || [ ! -f "$SCRIPT_DIR/.passwd" ]; then
    echo "Missing .username and .passwd files at $SCRIPT_DIR. Exiting..."
    exit 1
fi

# Check for existence of Python virtual environment
VENV_ACTIVATE="${SCRIPT_DIR}/venv/bin/activate"
if [ ! -f "$VENV_ACTIVATE" ]; then
    echo "ERROR: File venv/bin/activate not found in $SCRIPT_DIR! You must create a Python virtual environment to execute this script."
    exit 1
fi

# Source activate file for the Python virtual environment
source "$VENV_ACTIVATE"

# Virtual environment check
if [ -z "$VIRTUAL_ENV" ]; then
    echo "Error: A valid python virtual environment must exist in $SCRIPT_DIR. Exiting..."
    exit 1
fi

# Get the project name from $ORACLE_SID
if [[ $database == *"DEV" ]]; then
    project_name="${ORACLE_SID::-3}"
elif [[ $database == *"PROD" ]]; then
    project_name="${ORACLE_SID::-4}"
else
    echo "Failed to parse project name from database name $database. Database name must end in 'dev' or 'prod'. Exiting..."
    exit 1
fi
project_name="${project_name^^}"

select_tab_count=0
# Check for access to the necessary tables
if [[ $project_name == "AIM" ]]; then
    select_tables="'TELEMETRYITEMDEFINITION', 'TELEMETRYANALOGCONVERSIONS', 'TMANALOG_TABLE'"
    select_tab_count=$((select_tab_count+3))
else
    select_tables="'TELEMETRYITEMDEFINITION', 'TELEMETRYANALOGCONVERSIONS', 'TMANALOG_SID1'"
    select_tab_count=$((select_tab_count+3))

fi
insert_tables="'TMAVERAGE'"

# Check for read access to ONTHEFLYDECOM tables.
if [[ -n "$otfd_opt" ]]; then
    select_tables+=", 'ONTHEFLYDECOM_RESULTS', 'ONTHEFLYDECOM_ERRORS'"
    select_tab_count=$((select_tab_count+2))
fi

# Get username to check for access
username=$(<./.username)

# Check read-only table access
select_check=$("$ORACLE_HOME"/bin/sqlplus -s / as sysdba <<EOD
    set heading off
    set feedback off
    whenever oserror exit 1
    whenever sqlerror exit 1

    SELECT COUNT(*) 
    FROM dba_tab_privs 
    WHERE 
    grantee = '$username' AND
    privilege = 'SELECT' AND
    table_name in (${select_tables});
    exit;
EOD
)
if [ $? -ne 0 ]; then
    echo "$select_check"
    echo "Error checking if user $username has select access to tables: $select_tables"
    exit 1
fi

# Trim ALL whitespace, then check that all privileges are present.
select_check=$(echo "$select_check" | tr -d '[:space:]')
if [[ $select_check != "$select_tab_count" ]]; then
    echo "Error: User $username does not have SELECT permission for tables $select_tables. Please run CreateTMAverageTable.sh to configure user. Exiting..."
    exit 1
fi

# Check insert table access
insert_check=$("$ORACLE_HOME"/bin/sqlplus -s / as sysdba <<EOD
    set heading off
    set feedback off
    whenever oserror exit 1
    whenever sqlerror exit 1

    SELECT COUNT(*) 
    FROM dba_tab_privs 
    WHERE 
    grantee = '$username' AND
    privilege = 'INSERT' AND
    table_name in (${insert_tables});
    exit;
EOD
)
if [ $? -ne 0 ]; then
    echo "$insert_check"
    echo "Error checking if user $username has insert access to tables: $select_tables"
    exit 1
fi

# Trim ALL whitespace, then check that all privileges are present.
insert_check=$(echo "$insert_check" | tr -d '[:space:]')
if [[ "$insert_check" != "1" ]]; then
    echo "Error: User $username does not have INSERT permission for tables $insert_tables. Please run CreateTMAverageTable.sh to configure user. Exiting..."
    exit 1
fi


# Any additional checks are run by the script itself, running script
echo "Running ProcessTMAverageData.py. See log output at /tmp/TMAverageLogs/"
python "$HOME/Robert/scripts/TMAverage/ProcessTMAverageData.py" $otfd_opt "$database" "$tmid" "$start_date" "$end_date" $parallel_degree
if [ $? -ne 0 ]; then
    echo "ProcessTMAverageData.py failed. See log outputs at /tmp/TMAverageLogs/ for more information."
    exit 1
fi

echo "Script ran successfully!"
