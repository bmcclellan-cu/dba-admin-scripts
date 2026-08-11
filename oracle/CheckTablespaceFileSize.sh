#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: To check the tablespace and its associated datafile sizes in the database.
#          This script includes available free space within the tablespace and the available
#          room to grow for each individual datafile if the autoextensible
#          parameter is set to ON. The output can be limited to a specific tablespace
#	   if the user provides the tablespace name as a parameter.
#
#####################################################################################
usage="Usage: CheckTablespaceFileSize.sh [tablespace name | ALL (optional)]"
example="Example: CheckTablespaceFileSize.sh TEMP"

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

# Check arguments
if [ $# -gt 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Checking ORACLE_SID
sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "Error, \$ORACLE_SID not set..."
        exit 1
    fi
    echo "Error, provided \$ORACLE_SID is not open. Exiting..."
    exit 1
fi

if [ $# -eq 1 ] && [ "${1^^}" != "ALL" ]; then
    # Check if tablespace exists in the current database
    tablespace_check=$("$HOME/common/oracle/CheckIfTablespaceExists.sh" "${1^^}")
    if [ $? -ne 0 ]; then
        echo "Error occurred while checking if tablespace ${1^^} exists. Exiting..."
        exit 1
    elif [ "$tablespace_check" != "Yes" ]; then
        echo "Error: Tablespace ${1^^} not found on $ORACLE_SID. Exiting..."
        exit 1
    fi

    tablespace_name="and a.tablespace_name='${1^^}'"
fi

# Execute SQL to gather tablespace filesize on both standard and temporary tablespaces
$ORACLE_HOME/bin/sqlplus -s / as sysdba <<EOD

whenever oserror exit 1
whenever sqlerror exit 1
set pagesize 10000
set heading on
set linesize 165
set feedback off
set sqlblanklines on
col tablespacename form a28 heading "Tablespace"
col fid form 99999 heading "F id"
col file_name form a80 heading "File         All sizes in MB";
col maxsize_mb heading "DataFile|Max Size"
col size_mb heading "Current|File Size"
col free_mb heading "Current|Free Space"
col room heading "Total Room|To Grow"

col host_name new_value hn noprint
col instance_name new_value in_n noprint
select instance_name, host_name from v\$instance;

!echo "Below is a table displaying the used space and available room for database growth."

col dummy noprint
clear breaks;
clear computes;
compute sum of room on dummy;
break on tablespacename on dummy skip 1;
ttitle left 'Free Space Report for ORACLE_SID: ' format a8 in_n', running on host server: ' format a40 hn

-- This query gets the current size and available room to grow info from standard DBs
select
    a.tablespace_name dummy,
    substr(a.tablespace_name,1,28) tablespacename,
    a.file_id fid,
    a.file_name,
    trunc(a.maxsize/1024/1024) maxsize_mb,
    trunc(a.bytes/1024/1024) size_mb,
    trunc(NVL(b.free,0)/1024/1024) free_mb,
    trunc((a.maxsize-a.bytes+NVL(b.free,0))/1024/1024) room,
    a.autoextensible ae
from
    (select file_id,
        file_name,
            tablespace_name,
            autoextensible,
            bytes,
            decode(autoextensible,'YES',maxbytes,bytes) maxsize
        from dba_data_files
        group by file_id,
            file_name,
            tablespace_name,
            autoextensible,
            bytes,
            decode(autoextensible,'YES',maxbytes,bytes)
    ) a,
    (select file_id,
            tablespace_name,
            sum(bytes) free
        from dba_free_space
        group by file_id,
            tablespace_name
    ) b
where a.file_id=b.file_id(+)
    $tablespace_name
    and a.tablespace_name=b.tablespace_name(+)
order by ae, a.tablespace_name, a.file_id
/

col tablespacename form a28 heading "Temp Tablespace"
ttitle off
-- This query gets the same information as the above query but for temp tablespaces
select
    a.tablespace_name dummy,
    substr(a.tablespace_name,1,14) tablespacename,
    a.file_id fid,
    a.file_name,
    trunc(a.maxsize/1024/1024) maxsize_mb,
    trunc(a.bytes/1024/1024) size_mb,
    trunc(NVL(b.free,0)/1024/1024) free_mb,
    trunc((a.maxsize-a.bytes+NVL(b.free,0))/1024/1024) room,
    a.autoextensible ae
from
    (select file_id,
            file_name,
            tablespace_name,
            autoextensible,
            bytes,
            decode(autoextensible,'YES',maxbytes,bytes) maxsize
        from dba_temp_files
        group by file_id,
            file_name,
            tablespace_name,
            autoextensible,
            bytes,
            decode(autoextensible,'YES',maxbytes,bytes)
    ) a,
    (select file_id,
            tablespace_name,
            sum(bytes) free
        from dba_free_space
        group by file_id,
            tablespace_name
    ) b
where a.file_id=b.file_id(+)
    $tablespace_name
    and a.tablespace_name=b.tablespace_name(+)
order by ae, a.tablespace_name, a.file_id
/

exit;
EOD

if [ $? -ne 0 ]; then
    echo " "
    echo "**CheckTablespaceFileSize.sh failed...exiting**"
    echo " "
    exit 1
else
    echo " "
    echo "* Column \"AE\" above is AutoExtend. AE reflects the ability to add to the \"Current File Size\" by allowing Oracle to automatically increase the size of the datafile, up to the amount displayed in the DataFile Max Size column."
    exit 0
fi
