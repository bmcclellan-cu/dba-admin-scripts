#!/bin/bash
#
# Purpose:  A wrapper for the ProcessTMAverageData.py helper script, which averages the data from 
#           TMAnalog over 5 minute periods per TMID and inserts it into L1A.TMAVERAGE. This script
#           runs a few extra checks beforehand to ensure the script is ready to run.
#           This wrapper allows you to run the script at an offset from the current date and a range, 
#           allowing for consistent use via a crontab (i.e, today is 16-JUL-25, offset is set to 5 days, and
#           range is set to 3 days, so the script will process data from 11-JUL-25 to 13-JUL-25 (3 days of data)).
#           The -d flag allows for a date to be passed directly
# 
# Note:     Please do not run this script at a parallel degree above 16 on lasp-db5, as the script consumes
#           a lot of IO, and may cause performance issues.
# 
#           For more detailed documentation go to https://confluence.lasp.colorado.edu/spaces/MODSDB/pages/228214621/TMAverage+-+Usage+Performance
# 
# Author: Robert Schmidt
# Created on: July 21st, 2025
# Modified on: November 17th, 2025 - RS
###############################################################
usage="Usage: ./ProcessTMAverageData.sh [ -r (optional, only email on error) ] [ -o (optional, use OTFD) ] [ -e [ filename ] (absolute path filename containing newline-separated TMIDs to exclude. Only valid with 'ALL' option.) ] [ -d (optional, use start and end date instead of offset and range) ] [database] [ system_id ] [TMID | ALL | filename] [ offset (days) | start date (DD-MMM-YY) ] [ range (days) | end date (DD-MMM-YY) ] [parallel_degree (optional)]"
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

# Set DBA environment variables
if [ -f /export/home/oracle/.bashrc ]; then
    source /export/home/oracle/.bashrc
    if [ $? -ne 0 ]; then
        echo "An error occurred while sourcing /export/home/oracle/.bashrc. Exiting..."
        exit 1
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
if [ $# -lt 5 ] || [ $# -gt 6 ]; then
    echo "$usage"
    echo "$example1"
    echo "$example2"
    exit 1
fi

database=${1,,}
system_id=${2}
tmid=${3}
parallel_degree=${6}
parallel_degree=${parallel_degree:-1}

if [[ ! $parallel_degree =~ ^[0-9]+$ ]]; then
    echo "ERROR: Parallel degree must be a positive integer. Exiting..."
    exit 1
fi

if [[ ! $system_id =~ ^[0-9]+$ ]]; then
    echo "ERROR: System_ID must be a positive integer. Exiting..."
    exit 1
fi

echo "Validating input..."

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

# Set config variables to default values:
tmaverage_table_name="";tmaverage_stats_name="";tablespace_name="";
tmanalog_table_name="";telemetry_analog_conversions_name="";telemetry_item_definitions_name=""

# Set TMAverage static values from helper script. If the database name is not supported, this will fail.
# Set static values from helper script. If the database name is not supported, this will fail.
var_commands=$($newest_python $SCRIPT_DIR/TMAverageHelpers.py "$ORACLE_SID" "$system_id" 2>&1)
if [ $? -ne 0 ]; then
    if [[ "$var_commands" == *"not supported by TMAverage"* ]]; then
        echo "ERROR: Database $ORACLE_SID system_id $system_id is not supported by TMAverage. Exiting..."
    else
        echo "$var_commands"
        echo "ERROR: An error occurred while parsing configs. Exiting..."
    fi
    exit 1
fi

eval "$var_commands"

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


username=$(<"$SCRIPT_DIR/.username")
password=$(<"$SCRIPT_DIR/.passwd")
test_login=$("$HOME/common/oracle/TestOracleUserLogin.sh" "$username" "$password")
if [ $? -ne 0 ]; then
    echo "$test_login"
    echo "An error occurred while running TestOracleUserLogin.sh. Exiting..."
    exit 1
fi
if [[ "$test_login" != "Yes" ]]; then
    echo "ERROR: .username or .passwd file in $SCRIPT_DIR is invalid. Please run './ConfigureTMAverageEnvironment.sh to update. Exiting..."
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
    if [[ ! "$4" =~ ^-?[0-9]+$ ]] || [[ ! "$5" =~ ^-?[0-9]+$ ]]; then
        echo "ERROR: Offset and range must both be integers. Exiting..."
        exit 1
    fi

    # Parse the offset and range and get a start and end date.
    start_date=$(date -d "-$4 days" "+%d-%b-%y")
    # Subtract 1 from range, so that script processes $range days of data, as the script is inclusive
    end_date=$(date -d "$start_date +$(($5-1)) days" "+%d-%b-%y")
    echo "Using start date $start_date and end date $end_date"
else
    start_date=${4^^}
    end_date=${5^^}
fi

# Get MISC schema for GrantNewPermissions.sh
misc_schema=$("$HOME/common/oracle/GetSchemaName.sh" -m -v)
if [ $? -ne 0 ]; then
    echo "$misc_schema"
    echo "An error occurred while getting the MISC schema name. Exiting..."
    exit 1
fi

# Get username to check for access
username=$(<"$SCRIPT_DIR/.username")
username=${username^^}

# Check table permissions.
select_tables="$telemetry_analog_conversions_name,$telemetry_item_definitions_name,$tmanalog_table_name"
full_access_tables="$tmaverage_table_name,$tmaverage_stats_name"

# If using OTFD, check that OTFD packages are functional
if [ -n "$otfd_opt" ]; then
    otfd_status=$("$HOME/common/oracle/GetOTFDStatus.sh" "$ORACLE_SID")
    if [ $? -ne 0 ]; then
        echo "$otfd_status"
        echo "An error occurred while checking OTFD table & package status. Exiting..."
        exit 1
    fi
    if [[ "$otfd_status" == *"Does Not Exist"* ]] || [[ "$otfd_status" == *"Not Loaded"* ]] || [[ "$otfd_status" == *"Compilation Error"* ]]; then
        echo "$otfd_status"
        echo "One or more OTFD Packages/tables do not exist/has compilation errors. See procedure status above. Exiting..."
        exit 1
    fi
    select_tables="$select_tables,$misc_schema.ONTHEFLYDECOM_RESULTS,$misc_schema.ONTHEFLYDECOM_ERRORS"

fi

# Check SELECT permissions for read-only tables
select_check=$("$HOME/common/oracle/TestTablePermissions.sh" "$select_tables" "$username" SELECT)
if [ $? -ne 0 ]; then
    echo "$select_check"
    echo "An error occurred while running TestTablePermissions.sh to check SELECT permissions to $select_tables to $username. Exiting..."
    exit 1
elif [[ "$select_check" == *"MISSING"* ]]; then
    echo "ERROR: $username does not have SELECT permissions on $select_tables, or tables do not exist. Please run ConfigureTMAverageEnvironment.sh. Exiting..."
    exit 1
fi

# Check INSERT permissions for read-write tables
full_access_check=$("$HOME/common/oracle/TestTablePermissions.sh" "$full_access_tables" "$username" ALL)
if [ $? -ne 0 ]; then
    echo "$full_access_check"
    echo "An error occurred while running TestTablePermissions.sh to check ALL permissions to $full_access_tables to $username. Exiting..."
    exit 1
elif [[ "$full_access_check" == *"MISSING"* ]]; then
    echo "ERROR: $username does not have ALL permissions on $full_access_tables, or tables do not exist. Please run ConfigureTMAverageEnvironment.sh. Exiting..."
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
python "$SCRIPT_DIR/ProcessTMAverageData.py" $otfd_opt $exclude_opt "$database" "$system_id" "$tmid" "$start_date" "$end_date" "${parallel_degree}"
if [ $? -ne 0 ]; then
    echo "An error occurred while running ProcessTMAverageData.py. See log outputs at /tmp/TMAverageLogs/ for more information. Exiting..."
    exit 1
fi

exit 0