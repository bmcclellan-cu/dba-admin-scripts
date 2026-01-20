#!/bin/bash
#
# Purpose: Queries the TMAverage table for the most recent data, and returns the GPS timestamp in DT format.
# 
# 
# Note:    For more detailed documentation go to https://confluence.lasp.colorado.edu/spaces/MODSDB/pages/228214621/TMAverage+-+Usage+Performance
# 
# Author: Robert Schmidt
# Created: June 21st, 2025
# Last Modified: January 26th, 2026 - RS
###############################################################
usage="Usage: ./FindTMAverageLastIngested.sh [ database ] [ (default 1) System_ID ]"
example1="Example: ./FindTMAverageLastIngested.sh goldprod"


# Process input options
while getopts ":h" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example1"
        exit 0
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "$usage"
    echo "$example1"
    exit 1
fi

# Resolve the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export ORACLE_SID=${1,,}
system_id=${2:-1}

if ! [[ $system_id =~ ^[0-9]+$ ]]; then
    echo "ERROR: System_ID must be a valid integer. Exiting..."
    exit 1
fi

sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "ERROR: \$ORACLE_SID not set..."
        exit 1
    fi
    echo "ERROR: Provided \$database is not open. Exiting..."
    exit 1
fi

# Check for existence of Python virtual environment
VENV_ACTIVATE="${SCRIPT_DIR}/venv/bin/activate"
if [ ! -f "$VENV_ACTIVATE" ]; then
    echo "ERROR: File venv/bin/activate not found in $SCRIPT_DIR! Please run './ConfigureTMAverageEnvironment.sh -v' to create one with the necessary dependencies. Exiting..."
    exit 1
fi

# Source activate file for the Python virtual environment
source "$VENV_ACTIVATE"

# Virtual environment check
if [ -z "$VIRTUAL_ENV" ]; then
    echo "ERROR: A valid Python virtual environment must exist in $SCRIPT_DIR. Please run './ConfigureTMAverageEnvironment.sh -v' to create one with the necessary dependencies. Exiting..."
    exit 1
fi

version=$($newest_python --version 2>&1 | awk '{print $2}')
major=${version%%.*}
minor=${version#*.}
minor=${minor%%.*}

if [ "$major" -ne 3 ] || [ "$minor" -lt 9 ]; then
    echo "ERROR: Incompatible version of python is installed. TMAverage needs minimum of 3.9"
    exit 1
fi

# Set config variables to default values:
tmaverage_table_name=""

# Set static values from helper script. If the database name is not supported, this will fail.
var_commands=$(python TMAverageHelpers.py "$ORACLE_SID" "$system_id" 2>&1)
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

IFS="." read -r tmaverage_s tmaverage_t <<< "$tmaverage_table_name"

# Check that table exists.
table_check=$("$HOME/common/oracle/CheckIfTableExists.sh" "$tmaverage_s" "$tmaverage_t")
if [ $? -ne 0 ]; then
    echo "$table_check"
    echo "An error occurred while checking the existence of table '$tmaverage_table_name' . Exiting..."
    exit 1
fi
if [ "$table_check" != "Yes" ]; then
    echo "ERROR: Table $tmaverage_table_name does not exist. Exiting..."
    exit 1
fi

echo "Getting latest data timestamp for $tmaverage_table_name. This may take a while for larger tables..."

get_latest_timestamp=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    set heading off
    set feedback off
    whenever oserror exit 1
    whenever sqlerror exit 1

    SELECT /*+ PARALLEL */ GPS2DT(MAX(SCT_VTCW)) 
    FROM $tmaverage_table_name;
    
    exit;
EOD
)
if [ $? -ne 0 ]; then 
    echo "$get_latest_timestamp"
    echo "An error occurred while getting latest timestamp. Exiting..."
    exit 1
fi

get_latest_timestamp=$(echo "$get_latest_timestamp" | xargs) # Trim

if [[ -z "$get_latest_timestamp" ]]; then
    echo "No data found in $tmaverage_table_name."
else
    echo "Latest data timestamp: $get_latest_timestamp"
fi

exit 0