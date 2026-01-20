#!/bin/bash
#
# Purpose:  This script deletes data from TMAverage when given a date input. The script allows a CSV of dates/date ranges 
#           as follows: 
#           Single Date: DD-MMM-YY
#           Date Range: DD-MMM-YY:DD-MMM-YY
# 
# Notes:    This script uses TMAverageHelpers.py to set various static parameters that vary by 
#           database. Any updates to tmaverage configurations must be done in TMAverageHelpers.py
# 
#           For more detailed documentation go to https://confluence.lasp.colorado.edu/spaces/MODSDB/pages/228214621/TMAverage+-+Usage+Performance
# 
# Author: Robert Schmidt
# Created on: January 19th, 2026
# Modified on: January 19th, 2026 - RS
###############################################################
usage="Usage: ./DeleteTMAverageData.sh [ -y (Skip confirmation prompt) ] [ -l (optional, list # of rows)] [ database ] [ system_id ] [ dates_to_delete (CSV of dates/date ranges. See docstring) ]"
example1="Example: ./DeleteTMAverageData.sh -l ixpeprod 1 20-DEC-25,21-DEC-25"
example2="         ./DeleteTMAverageData.sh -y emadev 20 01-JAN-26:05-JAN-26,07-JAN-26"

list_opt=0
yes_opt=0
# Process input options
while getopts ":hly" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example1"
        echo "$example2"
        exit 0
        ;;
    l)
        list_opt=1
        ;;
    y)
        yes_opt=1
        ;;
    \?)
        echo "ERROR: Invalid option. Exiting..."
        exit 1
        ;;
    esac
done

shift $(($OPTIND -1))

# Resolve the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


if [ $# -ne 3 ]; then
    echo "Invalid parameters."
    echo "$usage"
    echo "$example1"
    echo "$example2"
    exit 1
fi

if [ $yes_opt -ne 0 ] && [ $list_opt -ne 0 ]; then
    echo "The -y and -l options are mutually exclusive. Exiting..."
    exit 1
fi

export ORACLE_SID=${1,,}
system_id=${2}
dates_to_delete=${3^^}


sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "ERROR: \$ORACLE_SID not set. Exiting..."
        exit 1
    fi
    echo "ERROR: Provided database is not open. Exiting..."
    exit 1
fi

# If system_id is set, check it.
if ! [[ $system_id =~ ^[0-9]+$ ]]; then
    echo "ERROR: System_ID must be a valid integer. Exiting..."
    exit 1
fi


newest_python=$(ls /usr/bin/python3* | grep -oP 'python3\.\d+' | sort -V | tail -n 1)
if [ $? -ne 0 ] || [ -z "$newest_python" ]; then
    echo "$newest_python"
    echo "Failed to find newest version of python. TMAverage requires the use of python. Exiting..."
    exit 1
fi

# Set config variables to default values:
tmaverage_table_name="";table_time_column="";

# Set TMAverage static values from helper script. If the database name is not supported, this will fail.
# Set static values from helper script. If the database name is not supported, this will fail.
var_commands=$($newest_python "$SCRIPT_DIR/TMAverageHelpers.py" "$ORACLE_SID" "$system_id" 2>&1)
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

convert_dt2gps (){
    datetime_value=${1^^}
    gps_timestamp=$("$ORACLE_HOME"/bin/sqlplus -s / as sysdba <<EOD | xargs
        set heading off
        set feedback off
        whenever oserror exit 1
        whenever sqlerror exit 1

        set numwidth 16

        -- The ALTER SESSION is only required for AIM, as all other DBs have the correct
        -- default set.
        ALTER SESSION SET NLS_TIMESTAMP_FORMAT='DD-MON-RR HH.MI.SSXFF AM';
        SELECT DT2GPS('$datetime_value') FROM dual;
EOD
    )
    if [ $? -ne 0 ] || [[ "$gps_timestamp" == *"ORA-"* ]]; then
        echo "$gps_timestamp"
        echo "An error occurred while computing GPS timestamp for $datetime_value. Exiting..."
        exit 1
    fi

    echo "$gps_timestamp"
}

# Start with 1=0 so that all additional restrictions can be simply added as 'OR <CONDITION>'
where_clause="WHERE 1=0"

IFS=','
for date in $dates_to_delete; do
    IFS=':' read -r start_date end_date <<< "$date"
    end_date=${start_date:-$end_date}

    start_time_gps=$(convert_dt2gps "$start_date 12.00.00.000000000 AM")
    if [ $? -ne 0 ]; then
        echo "$start_time_gps"
        exit 1
    fi
    # If end_date does not exist, use start_date instead.
    end_time_gps=$(convert_dt2gps "$end_date 11.59.59.999999999 PM")
    if [ $? -ne 0 ]; then
        echo "$end_time_gps"
        exit 1
    fi

    where_clause+=" OR $table_time_column BETWEEN $start_time_gps AND $end_time_gps" 
done

echo "Getting count of # of rows affected."

tmaverage_delete_count=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD | xargs
    set heading off
    set feedback off
    whenever oserror exit 1
    whenever sqlerror exit 1

    set numwidth 16

    SELECT COUNT(*) FROM $tmaverage_table_name $where_clause;
EOD
)
if [ $? -ne 0 ] || [[ $tmaverage_delete_count == *"ORA-"* ]]; then
    echo "$tmaverage_delete_count"
    echo "An error occurred while getting number of records to delete. Exiting..."
    exit 1
fi

echo "TMAverage Delete Count: $tmaverage_delete_count"

if [ $list_opt -ne 0 ]; then
    echo "Finished listing. Exiting..."
    exit 0
fi
if [ $yes_opt -ne 0 ]; then
    echo "The -y option was provided, so skipping confirmation..."
else
    read -r -p "Are you sure you want to delete $tmaverage_delete_count rows? (Y/N): " confirm && confirm=${confirm^^}
    if ! [ "$confirm" == "Y" ] || [ "$confirm" == "YES" ]; then
        echo "Cancelling Delete."
        exit 0
    fi
fi

tmaverage_delete_rows=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba << EOD | xargs
    set heading off
    set feedback off
    whenever oserror exit 1
    whenever sqlerror exit 1

    DELETE FROM $tmaverage_table_name $where_clause;
    COMMIT;
EOD
)
if [ $? -ne 0 ] || [[ "$tmaverage_delete_rows" == *"ORA-"* ]]; then
    echo "$tmaverage_delete_rows"
    echo "An error occurred while deleting records. Exiting..."
    exit 1
fi

echo "Successfully deleted rows from TMAverage."
exit 0