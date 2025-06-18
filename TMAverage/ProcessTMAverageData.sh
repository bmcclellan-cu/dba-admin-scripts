#!/bin/bash
#
# Purpose: A wrapper for the ProcessTMAverageData.py helper script, which averages the data from 
#          TMAnalog over 5 minute periods per TMID and inserts it into L1A.TMAVERAGE. This script
#          runs a few extra checks beforehand to ensure the script is ready to run.
#          This wrapper allows you to run the script at an offset from the current date and a range, 
#          allowing for consistent use via a crontab (i.e, today is 16-JUL-25, offset is set to 5 days, and
#          range is set to 3 days, so the script will process data from 11-JUL-25 to 13-JUL-25 (3 days of data)).
#          If you want to specify a specific date range, you need to invoke the .py script directly.
# 
# Author: Robert Schmidt
# Created on: June 16th, 2025
###############################################################
usage="Usage: ./ProcessTMAverageData.sh [ -o (optional, use OTFD) ] [database] [TMID | ALL] [ offset (days) ] [ range (days) ] [parallel_degree (optional)]"
example="Example: ./ProcessTMAverageData.sh goldprod ALL 14 7 8"

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
        otfd_opt="-o"
        shift 1
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

database=${1,,}
tmid=${2^^}
offset=${3^^}
range=${4^^}
parallel_degree=${5^^}

export ORACLE_SID=${database}


sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I "$ORACLE_SID")
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "ERROR"
        echo "\$ORACLE_SID not set..."
        exit 1
    fi
    echo "ERROR"
    echo "provided \$database is not open. Exiting..."
    exit 1
fi

timestamp=$(date "+%Y%m%d-%H%M%S")
LOGDIR="/tmp/TMAverageLogs/"
LOGFILE="$LOGDIR/TMAverage-$database-$timestamp-Bash.log"
# Sets all script output to be put into a logfile as well, including stderr
exec > >(tee -a "$LOGFILE") 2>&1

# Check that the .passwd and .username files exist.
if [ ! -f "$SCRIPT_DIR/.username" ] || [ ! -f "$SCRIPT_DIR/.passwd" ]; then
    echo "Missing .username and .passwd files at $SCRIPT_DIR. Exiting..."
    mailx -s "ProcessTMAverageData.sh failed" "$DB_EMAIL_LIST" < "$LOGFILE"
    exit 1
fi

# Check for existence of Python virtual environment
VENV_ACTIVATE="${SCRIPT_DIR}/venv/bin/activate"
if [ ! -f "$VENV_ACTIVATE" ]; then
    echo "ERROR: File venv/bin/activate not found in $SCRIPT_DIR! You must create a Python virtual environment to execute this script."
    mailx -s "ProcessTMAverageData.sh failed" "$DB_EMAIL_LIST" < "$LOGFILE"
    exit 1
fi

# Source activate file for the Python virtual environment
source "$VENV_ACTIVATE"

# Virtual environment check
if [ -z "$VIRTUAL_ENV" ]; then
    echo "Error: A valid python virtual environment must exist in $SCRIPT_DIR. Exiting..."
    mailx -s "ProcessTMAverageData.sh failed" "$DB_EMAIL_LIST" < "$LOGFILE"
    exit 1
fi

# Ensure that both range and offset are integers.
if [[ ! "$offset" =~ ^-?[0-9]+$ ]] || [[ ! "$range" =~ ^-?[0-9]+$ ]]; then
    echo "Error: Offset and range must both be integers. Exiting..."
    mailx -s "ProcessTMAverageData.sh failed" "$DB_EMAIL_LIST" < "$LOGFILE"
    exit 1
fi

# Parse the offset and range and get a start and end date.
start_date=$(date -d "-$offset days" "+%d-%b-%y")
# Subtract 1 from range, so that script processes $range days of data, as the script is inclusive
end_date=$(date -d "$start_date +$((range-1)) days" "+%d-%b-%y")
echo "Using start_date $start_date and end_date $end_date"

# Get the project name from $ORACLE_SID
if [[ $database == *"dev" ]]; then
    project_name="${ORACLE_SID::-3}"
elif [[ $database == *"prod" ]]; then
    project_name="${ORACLE_SID::-4}"
else
    echo "Failed to parse project name from database name $database. Database name must end in 'dev' or 'prod'. Exiting..."
    mailx -s "ProcessTMAverageData.sh failed" "$DB_EMAIL_LIST" < "$LOGFILE"
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
    mailx -s "ProcessTMAverageData.sh failed" "$DB_EMAIL_LIST" < "$LOGFILE"
    exit 1
fi

# Trim ALL whitespace, then check that all privileges are present.
select_check=$(echo "$select_check" | tr -d '[:space:]')
if [[ $select_check != "$select_tab_count" ]]; then
    echo "Error: User $username does not have SELECT permission for tables $select_tables. Please run CreateTMAverageTable.sh to configure user. Exiting..."
    mailx -s "ProcessTMAverageData.sh failed" "$DB_EMAIL_LIST" < "$LOGFILE"
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
    mailx -s "ProcessTMAverageData.sh failed" "$DB_EMAIL_LIST" < "$LOGFILE"
    exit 1
    
fi

# Trim ALL whitespace, then check that all privileges are present.
insert_check=$(echo "$insert_check" | tr -d '[:space:]')
if [[ "$insert_check" != "1" ]]; then
    echo "Error: User $username does not have INSERT permission for tables $insert_tables. Please run CreateTMAverageTable.sh to configure user. Exiting..."
    mailx -s "ProcessTMAverageData.sh failed" "$DB_EMAIL_LIST" < "$LOGFILE"
    exit 1
fi

echo "$HOME/Robert/scripts/TMAverage/ProcessTMAverageData.py $otfd_opt $database $tmid $start_date $end_date $parallel_degree"


# Any additional checks are run by the script itself, running script
echo "Running ProcessTMAverageData.py. See log output at /tmp/TMAverageLogs/"
python "$HOME/Robert/scripts/TMAverage/ProcessTMAverageData.py" $otfd_opt "$database" "$tmid" "$start_date" "$end_date" $parallel_degree
if [ $? -ne 0 ]; then
    echo "ProcessTMAverageData.py failed See log outputs at /tmp/TMAverageLogs/ for more information."
    mailx -s "ProcessTMAverageData.sh failed" "$DB_EMAIL_LIST" < "$LOGFILE"
    exit 1
fi

mailx -s "ProcessTMAverageData.sh Ran Successfully" "$DB_EMAIL_LIST" < "$LOGFILE"
