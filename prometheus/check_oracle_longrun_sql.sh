#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose:  This script checks for the longest running SQL statement.
#
###########################################################################

usage="Usage: check_oracle_longrun_sql.sh [ <ORACLE_SID> ]"
example="Example: check_oracle_longrun_sql.sh sid1"

# Process input options
while getopts ":h" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

if [[ $# -ne 1 ]]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

vm_user=$(whoami)
if [[ "$vm_user" != "oracle" ]]; then
    echo "Script must be run as the oracle user. Exiting..."
    exit 1
fi

# set your Oracle environment here
source "$HOME/19c.env"
if [ $? -ne 0 ]; then
    echo "An error occurred while sourcing $HOME/19c.env. Exiting..."
    exit 1
fi

SID="${1,,}"

# Gather the runtime AND sql_id for the longest-running query
# Returns runtime of 0 if no data is found
longrun_id_query="whenever oserror exit 1
whenever sqlerror exit 1
set pagesize 0
set serveroutput on
set feedback off
DECLARE
    run_time NUMBER :=0;
    my_sql_id VARCHAR(1000) :='';
BEGIN
    SELECT time, SQL_ID
        INTO run_time, my_sql_id
    FROM (
        SELECT round(ELAPSED_TIME/1000000) time, sql_id
        FROM v\$sql_monitor
        WHERE module NOT LIKE 'DBMS_SCHEDULER%'
        AND module IS NOT NULL
        AND SQL_TEXT IS NOT NULL
        and SERVICE_NAME NOT LIKE 'SYS\$BACKGROUND'
        AND STATUS NOT LIKE '%DONE%'
        ORDER BY ELAPSED_TIME desc
    ) WHERE rownum < 2;
    dbms_output.put_line(run_time);
    dbms_output.put_line(my_sql_id);
    EXCEPTION WHEN no_data_found THEN
        dbms_output.put_line(0);
END;
/"

export ORACLE_SID=$SID
result=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    $longrun_id_query
EOD
)

#Check for Oracle errors and exit if present
if [ $? -ne 0 ] || echo "$result" | grep -q ORA-; then
    echo "$result" | tee -a /tmp/check_oracle_longrun_sql_"$SID"_"$(date +%Y_%m_%d_%H_%M_%S)".err
    exit 1
fi

# Gather runtime from result
runtime=$(echo "$result" | cut -d$'\n' -f 1) # Get first substring delimited by newline
id=$(echo "$result" | cut -d$'\n' -f 2)     # Get second substring delimited by newline

#We must use sql_text NOT sql_fulltext as that is stored in a CLOB
sql_text_query="whenever oserror exit 1
whenever sqlerror exit 1
set pagesize 0
set serveroutput on
set feedback off
set linesize 10000
DECLARE
    my_sql_text VARCHAR(8000) :='';
    my_sql_id VARCHAR(1000) :='';
BEGIN
    SELECT REPLACE(REPLACE(REPLACE(sql_text, chr(42), 'star'), chr(10), ' '), chr(13), ' '), sql_id
        INTO my_sql_text, my_sql_id
    FROM (
        SELECT sql_text, sql_id 
        FROM v\$sql_monitor 
        WHERE sql_id = '${id}'
        AND sql_text is not null
        ORDER BY sql_exec_start desc
    )
    WHERE rownum < 2;
    dbms_output.put_line(my_sql_text);
    dbms_output.put_line(my_sql_id);
    EXCEPTION when NO_DATA_FOUND
        then dbms_output.put_line('No SQL available');
END;
/"

sqlstatement=$(
"$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    $sql_text_query
EOD
)


#Check for Oracle errors and exit if present
if [ $? -ne 0 ] || echo "$sqlstatement" | grep -q ORA-; then
    echo "$result $sqlstatement" | tee -a "/tmp/check_oracle_longrun_sql_${SID}_$(date +%Y_%m_%d_%H_%M_%S).err"
    exit 1
fi

# Parse sql text out of $sqlstatement variable
sql_text=$(echo "$sqlstatement" | cut -d$'\n' -f 1) # Get first substring delimited by newline

# Final output
echo "oracle_long_running_jobs{sid=\"$SID\",sql_statement_id=\"$id\",sql_statement_text=\"$sql_text\"} $runtime"
