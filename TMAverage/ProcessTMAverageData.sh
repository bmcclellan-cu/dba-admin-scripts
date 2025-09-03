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
# Note:    Please do not run this script at a parallel degree above 16 on lasp-db5, as the script consumes
#          a lot of IO, and may cause performance issues.
# 
#          For more detailed documentation go to https://confluence.lasp.colorado.edu/spaces/MODSDB/pages/228214621/TMAverage+-+Usage+Performance
# 
# Author: Robert Schmidt
# 
# Created on: July 21st, 2025
# Modified on: July 29th, 2025 - RS
###############################################################
usage="Usage: ./ProcessTMAverageData.sh [ -r (optional, only email on error) ] [ -o (optional, use OTFD) ] [ -e [ filename ] (absolute path filename containing newline-separated TMIDs to exclude. Only valid with 'ALL' option.) ] [ -d (optional, use start and end date instead of offset and range) ] [database] [TMID | ALL | filename] [ offset (days) | start date (DD-MMM-YY) ] [ range (days) | end date (DD-MMM-YY) ] [parallel_degree (optional)]"
example1="Example: ./ProcessTMAverageData.sh goldprod ALL 14 7 8"
example2="         ./ProcessTMAverageData.sh -d goldprod ALL 12-JAN-23 14-JAN-23"

otfd_opt=""
date_opt=0
error_only_email_opt=0
exclude_opt=""
# Process input options
while getopts ":horde:" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example1"
        echo "$example2"
        exit 0
        ;;
    o)
        otfd_opt="-o"
        ;;
    r)
        error_only_email_opt=1
        ;;
    d)
        date_opt=1
        ;;
    e)
        if [ -z "$OPTARG" ]; then
            echo "ERROR: Option -e requires a filename argument. Exiting..."
            exit 1
        fi
        if [ ! -f "$OPTARG" ]; then
            echo "ERROR: File $OPTARG does not exist. Exiting..."
            exit 1
        fi
        if [[ "$OPTARG" != /* ]]; then
            echo "ERROR: Option -e requires an absolute path filename. Providing relative path inputs may lead to unintended behavior in a crontab. Exiting..."
            exit 1
        fi
        exclude_opt=" -e $OPTARG "
        ;;
    \?)
        echo "ERROR: Invalid option. Exiting..."
        exit 1
        ;;
    esac
done

shift $(($OPTIND -1))

# Constant variables
tmaverage_table="TMAVERAGE_SID1"
tablespace_name="TMAVERAGE_SID1"

# Set environment variables
if [ -f /export/home/oracle/.bashrc ]; then
    source /export/home/oracle/.bashrc
    if [ $? -ne 0 ]; then
        echo "An error occurred while sourcing /export/home/oracle/.bashrc. Exiting..."
    fi
else
    export DB_EMAIL_LIST="Brian.McClellan@lasp.colorado.edu Jackson.Cockrum@lasp.colorado.edu Robert.Schmidt@lasp.colorado.edu Bryan.Turns@lasp.colorado.edu"
    export ORACLE_HOME=/dba/oracle/installs/orabase/product/19.7.0/dbhome_1
    export PATH=$ORACLE_HOME/bin:$PATH
    export LD_LIBRARY_PATH=$ORACLE_HOME/lib
fi

# Resolve the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check number of arguments
if [ $# -lt 4 ] || [ $# -gt 5 ]; then
    echo "$usage"
    echo "$example1"
    echo "$example2"
    exit 1
fi

database=${1,,}
tmid=${2}
parallel_degree=${5^^}
parallel_degree=${parallel_degree:-1}

if [[ ! $parallel_degree =~ ^[0-9]+$ ]]; then
    echo "ERROR: Parallel degree must be a positive integer. Exiting..."
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

timestamp=$(date "+%Y%m%d-%H%M%S")
LOGDIR="/tmp/TMAverageLogs/$database"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/TMAverage-$timestamp-Bash.log"
# Sets all script output to be put into a logfile as well, including stderr
exec > >(tee -a "$LOGFILE") 2>&1

# Setup trap to send an email whenever the script exits.
exit_handler(){
    if [[ $? -eq 0 ]]; then
        if [ $error_only_email_opt -eq 0 ]; then
            echo "ProcessTMAverageData.sh ran successfully... Sending email to $DB_EMAIL_LIST."
            mailx -s "$HOSTNAME - $database - ProcessTMAverageData.sh Ran Successfully" "$DB_EMAIL_LIST" < "$LOGFILE"
        else
            echo "ProcessTMAverageData.sh ran successfully... Skipping sending email."
        fi
        exit 0
    else
        echo "ProcessTMAverageData.sh ran with errors... Sending email to $DB_EMAIL_LIST."
        mailx -s "$HOSTNAME - $database - ProcessTMAverageData.sh failed" "$DB_EMAIL_LIST" < "$LOGFILE"
        exit 1
    fi
}
trap exit_handler EXIT INT TERM # On exit, call exit_handler.

# Check that the .username and .passwd files exist
if [ ! -f "$SCRIPT_DIR/.username" ] || [ ! -f "$SCRIPT_DIR/.passwd" ]; then
    echo "ERROR: Missing .username and .passwd files at $SCRIPT_DIR. Exiting..."
    exit 1
fi

# Validate that username and password are valid. (NOTE: Currently pointing to personal repo, will update when PR is merged.)
username=$(<"$SCRIPT_DIR/.username")
password=$(<"$SCRIPT_DIR/.passwd")
test_login=$("$HOME/Robert/anothercommon/oracle/TestOracleUserLogin.sh" "$username" "$password")
if [ $? -ne 0 ]; then
    echo "$test_login"
    echo "An error occurred while running TestOracleUserLogin.sh. Exiting..."
    exit 1
fi
if [[ "$test_login" != "Yes" ]]; then
    echo "ERROR: .username or .passwd file in $SCRIPT_DIR is invalid. Please run './ConfigureTMAverageEnvironment.sh -u <username> <password>' to update. Exiting..."
    exit 1
fi

# Check for existence of Python virtual environment
VENV_ACTIVATE="${SCRIPT_DIR}/venv/bin/activate"
if [ ! -f "$VENV_ACTIVATE" ]; then
    echo "ERROR: File venv/bin/activate not found in $SCRIPT_DIR! Please run ./ConfigureTMAverageEnvironment.sh -v to create one with the necessary dependencies. Exiting..."
    exit 1
fi

# Source activate file for the Python virtual environment
source "$VENV_ACTIVATE"

# Virtual environment check
if [ -z "$VIRTUAL_ENV" ]; then
    echo "ERROR: A valid Python virtual environment must exist in $SCRIPT_DIR. Please run ./ConfigureTMAverageEnvironment.sh -v to create one with the necessary dependencies. Exiting..."
    exit 1
fi

# If date option is not given, then determine dates from offset and range
if [ $date_opt -eq 0 ]; then
    # Ensure that both offset and range are integers
    if [[ ! "$3" =~ ^-?[0-9]+$ ]] || [[ ! "$4" =~ ^-?[0-9]+$ ]]; then
        echo "ERROR: Offset and range must both be integers. Exiting..."
        exit 1
    fi

    # Parse the offset and range and get a start and end date.
    start_date=$(date -d "-$3 days" "+%d-%b-%y")
    # Subtract 1 from range, so that script processes $range days of data, as the script is inclusive
    end_date=$(date -d "$start_date +$(($4-1)) days" "+%d-%b-%y")
    echo "Using start date $start_date and end date $end_date"
else
    start_date=${3^^}
    end_date=${4^^}
fi

# Get the MISC schema, then truncate the _MISC from it
project_name=$("$HOME/common/oracle/GetSchemaName.sh" -m -v)
if [ $? -ne 0 ]; then
    echo "$project_name"
    echo "An error occurred while running GetSchemaName.sh. Exiting..."
    exit 1
fi
if [[ "$project_name" != *"_MISC" ]]; then
    echo "ERROR: Attempted to retrieve MISC schema, got $project_name instead. Schema name must match glob *'_MISC'. Exiting..."
    exit 1
else
    project_name="${project_name::-5}"
fi
project_name="${project_name^^}"

select_tab_count=0
# Set up table names based on project type
if [[ $project_name == "AIM" ]]; then
    select_tables="'TELEMETRYITEMDEFINITION', 'TELEMETRYANALOGCONVERSIONS', 'TMANALOG_TABLE'"
    select_tab_count=$((select_tab_count+3))
elif [[ $project_name == "EVE" ]]; then
    select_tables="'TELEMETRYITEMDEFINITION', 'TELEMETRYANALOGCONVERSIONS', 'TMANALOG'"
    select_tab_count=$((select_tab_count+3))
else
    select_tables="'TELEMETRYITEMDEFINITION', 'TELEMETRYANALOGCONVERSIONS', 'TMANALOG_SID1'"
    select_tab_count=$((select_tab_count+3))
fi
insert_tables="'$tmaverage_table'"

# Check for read access to ONTHEFLYDECOM tables
if [[ -n "$otfd_opt" ]]; then
    select_tables+=", 'ONTHEFLYDECOM_RESULTS', 'ONTHEFLYDECOM_ERRORS'"
    select_tab_count=$((select_tab_count+2))
fi

# Get username to check for access
username=$(<"$SCRIPT_DIR/.username")
username=${username^^}

# Check SELECT permissions for read-only tables
select_check=$("$ORACLE_HOME"/bin/sqlplus -s / as sysdba <<EOD
    set heading off
    set feedback off
    whenever oserror exit 1
    whenever sqlerror exit 1

    SELECT COUNT(table_name) 
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
    echo "An error occurred while checking SELECT permissions for user $username. Exiting..."
    exit 1
fi

# Trim ALL whitespace, then check that all privileges are present
select_check=$(echo "$select_check" | tr -d '[:space:]')
if [[ $select_check != "$select_tab_count" ]]; then
    echo "ERROR: User $username does not have SELECT permission for tables $select_tables. Please run ConfigureTMAverageEnvironment.sh to configure user. Exiting..."
    exit 1
fi

# Check INSERT permissions for read-write tables
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
    echo "An error occurred while checking INSERT permissions for user $username. Exiting..."
    exit 1
fi

# Trim ALL whitespace, then check that all privileges are present
insert_check=$(echo "$insert_check" | tr -d '[:space:]')
if [[ "$insert_check" != "1" ]]; then
    echo "ERROR: User $username does not have INSERT permission for tables $insert_tables, or the tables do not exist."
    echo "Please run ConfigureTMAverageEnvironment.sh to configure user and confirm existence of the required tables. Exiting..."
    exit 1
fi

# Check tablespace write status
check_tablespace=$("$HOME/common/oracle/CheckTablespaceReadStatus.sh" "$tablespace_name")
if [ $? -ne 0 ]; then
    echo "$check_tablespace"
    echo "An error occurred while running CheckTablespaceReadStatus.sh. Exiting..."
    exit 1
elif [ "$check_tablespace" != "READ-WRITE" ]; then
    echo "ERROR: Tablespace $tablespace_name must be in READ-WRITE mode (currently $check_tablespace). Exiting..."
    exit 1
fi

echo "Running... $SCRIPT_DIR/ProcessTMAverageData.py $otfd_opt $exclude_opt $database $tmid $start_date $end_date $parallel_degree"


# Execute the Python script with the prepared arguments
echo "Running ProcessTMAverageData.py. See log output at /tmp/TMAverageLogs/"
python "$SCRIPT_DIR/ProcessTMAverageData.py" $otfd_opt $exclude_opt "$database" "$tmid" "$start_date" "$end_date" "${parallel_degree}"
if [ $? -ne 0 ]; then
    echo "An error occurred while running ProcessTMAverageData.py. See log outputs at /tmp/TMAverageLogs/ for more information. Exiting..."
    exit 1
fi

exit 0