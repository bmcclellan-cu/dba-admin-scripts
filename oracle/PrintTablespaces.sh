#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script prints a list of tablespaces in the current or given database
#	   along with the tablespace status and size in GB. The basis of the script
#	   was taken from PrintPartitions.sh, which performs a similar task using
#	   partitions rather than tablespaces. 
#
# Note: Whether sorting by size or alphabetical output with the -s or -a options,
#       the tablespaces will first be sorted by their online statuses and then by
#       the select option (size by default).
#
# Note: Each individual tablespace size measurement is rounded to the nearest GB. Due to rounding,
#       the integer values in GB for each tablespace size may not sum to exactly the value 
#       shown under "Total size in GB"
#
#####################################################################################

usage="Usage: PrintTablespaces.sh [ -s | -a (size sorted or alphabetical output) ] [SID (optional)] [READONLY|READWRITE (optional)]"
example="Example: PrintTablespaces.sh mydbd19 READWRITE"

# Default order of printing tablespaces is descending by size
sortby="CASE WHEN dt.status IN ('ONLINE', 'READ ONLY') AND REGEXP_LIKE(\"Size in GB\", '^[0-9]+$') THEN TO_NUMBER(\"Size in GB\") ELSE NULL END"
order='DESC'

# Process input options
while getopts ":hsa" option; do
    case $option in
        h)
            echo "$usage"
            echo "$example"
            exit 0;;
        s)
            sortby="CASE WHEN dt.status IN ('ONLINE', 'READ ONLY') AND REGEXP_LIKE(\"Size in GB\", '^[0-9]+$') THEN TO_NUMBER(\"Size in GB\") ELSE NULL END"
            order='DESC'
            ;;
        a)
            sortby='dt.tablespace_name'
            order='ASC'
            ;;
        \?)
            echo "Error: Invalid option"
            exit 1
    esac
done

if [ $((OPTIND -1)) -gt 1 ]; then
    echo "-s and -a options are mutually exclusive. Exiting..."
    exit 1
fi

shift $((OPTIND -1))

# Check arguments
if [ $# -gt 2 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Sets SID variable and read status if user provides, or leaves blank if not provided
if [ -n "$2" ]; then
    if [ "${1^^}" == "READONLY" ]; then
        readonlyquery="WHERE dt.status = 'READ ONLY'"
        sid=$2
    elif [ "${1^^}" == "READWRITE" ]; then
        readonlyquery="WHERE dt.status != 'READ ONLY'"
        sid=$2
    elif [ "${2^^}" == "READONLY" ]; then
        readonlyquery="WHERE dt.status = 'READ ONLY'"
        sid=$1
    elif [ "${2^^}" == "READWRITE" ]; then
        readonlyquery="WHERE dt.status != 'READ ONLY'"
        sid=$1
    else
        echo "Invalid input, one of the two given inputs must be READWRITE or READONLY. Exiting..."
        exit 1
    fi
elif [ -n "$1" ]; then
    if [ "${1^^}" == "READONLY" ]; then
        readonlyquery="WHERE dt.status = 'READ ONLY'"
    elif [ "${1^^}" == "READWRITE" ]; then
        readonlyquery="WHERE dt.status != 'READ ONLY'"
    else
        sid=$1
    fi
fi

# Set schema to user-provided input or set SID variable to current ORACLE_SID
if [ -z "$sid" ] && [ -z "$ORACLE_SID" ]; then
    echo "ERROR: \$ORACLE_SID not set and none provided."
    echo "Rerun the script and enter the target database as the first parameter."
    echo "Exiting..."
    exit 1
elif [ -n "$sid" ]; then
    export ORACLE_SID="$sid"
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

# Execute Oracle query
"$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set pagesize 10000
    set linesize 175
    column tablespace_name format a30
    column status format a10
    column "Size in GB" format a10

    SELECT DISTINCT
        dt.tablespace_name,
        dt.status,
        CASE 
            WHEN SUM(vd.bytes) = 0 THEN 'OFFLINE'
            ELSE TO_CHAR(COALESCE(
                SUM(ROUND(vd.bytes/1024/1024/1024)),
                SUM(ROUND(dtf.bytes/1024/1024/1024)))) 
        END AS "Size in GB"
    FROM 
        dba_tablespaces dt
    LEFT JOIN dba_temp_files dtf
        ON (dt.tablespace_name = dtf.tablespace_name)
    LEFT JOIN V\$TABLESPACE vt
        ON (dt.tablespace_name = vt.name)
    LEFT JOIN V\$DATAFILE vd
        ON (vt.ts# = vd.ts#)
    ${readonlyquery} GROUP BY dt.tablespace_name, dt.status
    ORDER BY dt.status, ${sortby} ${order};
exit;
EOD

# Check exit status of Oracle query
if [ $? -ne 0 ]; then
    echo " "
    echo "**PrintTablespaces.sh query failed... Exiting**"
    echo " "
    exit 1
else
    echo " "
    echo "Tablespaces successfully printed for ${ORACLE_SID}"
fi

# Print total size
total_size=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set pagesize 10000
    set linesize 175
    column tablespace_name format a28
    column status format a10

    SELECT sum(round(vd.bytes/1024/1024/1024)) AS "Total size in GB" 
    FROM dba_tablespaces dt
    LEFT JOIN dba_temp_files dtf
        ON (dt.tablespace_name = dtf.tablespace_name) 
    LEFT JOIN V\$TABLESPACE vt
        ON (dt.tablespace_name = vt.name)
    LEFT JOIN V\$DATAFILE vd
    ON (vt.ts# = vd.ts#) ${readonlyquery};
exit;
EOD
)

if [ $? -ne 0 ]; then
    echo "$total_size"
    echo "Error occurred while querying for total size. Exiting..."
    exit 1
fi

echo "$total_size"

# If no tablespaces are found, the total size query will contain only 3 lines of headers. If only
# these 3 lines are present, print 0 as the total size
num_lines=$(echo "$total_size" | wc -l)
if [ "$num_lines" -eq 3 ]; then
    echo "               0"
fi
