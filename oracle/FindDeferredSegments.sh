#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script will either list or fix deferred segments that are
#          user created on the given SID(s). The FIX option will only correct
#          segments in ONLINE tablespaces, and READ ONLY or OFFLINE segments
#          need to be brought ONLINE to be fixed.
#
# Background: "Deferred segment creation" is a feature in Oracle that
#             delays segment creation until data is inserted into a row.
#             Filtering out IOT_OVERFLOW segments is to prevent ORA-25191 
#             errors. IOT_OVERFLOW segments will have the same segment 
#             deferred status of their primary table.
#
##########################################################################
usage="Usage: FindDeferredSegments.sh [ ORACLE_SID | ALL ] [ LIST | FIX ]"
example="Example: FindDeferredSegments.sh MY_SID list"

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

# Check input parameters 
if [ $# -ne 2 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

input_sid=${1,,}
action=${2^^}
exit_status=0

# Verify action
if [[ ! "$action" =~ ^(LIST|FIX)$ ]]; then
    echo "Second argument must be list or fix. Exiting..."
    exit 1
fi

# Function to print deferred segments
printDeferredSegments() {
    deferred_segments=$(
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set feedback off
    set serveroutput off

    column owner format a30
    column table_name format a40
    set linesize 100
    set pagesize 10000
    select table_name, owner from dba_tables tb where 
        owner IN (select username from dba_users where ORACLE_MAINTAINED = 'N') 
        AND partitioned = 'NO' AND segment_created = 'NO' AND (IOT_TYPE != 'IOT_OVERFLOW' OR IOT_TYPE IS NULL)
        AND (SELECT status from dba_tablespaces ts WHERE ts.tablespace_name=tb.tablespace_name) = '$1'
    UNION 
    select table_name, table_owner from dba_tab_partitions tp where 
    table_owner IN (select username from dba_users where ORACLE_MAINTAINED = 'N') AND segment_created = 'NO'
    AND (SELECT status from dba_tablespaces ts WHERE ts.tablespace_name=tp.tablespace_name) = '$1';
    exit;
EOD
)
    # Check return code and output
    if [ $? -ne 0 ]; then
        echo "$deferred_segments"
        echo "Error: Problem fetching deferred segments for ${ORACLE_SID}. Continuing..."
        return 1
    fi

    # Remove blank lines only after the exit-code check: piping sqlplus into sed
    # inside the command substitution would make $? report sed's status instead
    deferred_segments=$(echo "$deferred_segments" | sed '/^$/d')
    if [ -z "$deferred_segments" ]; then
        echo "No $1 deferred segments found for ${ORACLE_SID}."
        return 0
    fi
    echo "$1 Deferred segments for $ORACLE_SID:"
    echo "$deferred_segments"
    return  0
}

SIDS=$("$HOME/common/oracle/VerifyAllParam.sh" "$input_sid")

if [ $? -ne 0 ]; then
    echo "Error: Failed to validate $input_sid with VerifyAllParam.sh"
    echo "$SIDS"
    exit 1
fi

# With no option, VerifyAllParam.sh prints an "Invalid SIDS: ..." line and a
# "Valid SIDS: ..." line; keep the space-separated list after each label
valid_sids=$(printf '%s\n' "$SIDS" | sed -n 's/^Valid SIDS: *//p')
invalid_sids=$(printf '%s\n' "$SIDS" | sed -n 's/^Invalid SIDS: *//p')

if [ -z "$valid_sids" ]; then
    echo "No Valid SIDS were returned from VerifyAllParam.sh."
    if [ -n "$invalid_sids" ]; then
        echo "Error: database(s) $invalid_sids are not open."
    fi
    echo "Exiting..."
    exit 1
fi

for sid in $valid_sids; do
    export ORACLE_SID=$sid

    # Check for online deferred segments (these are the only ones the script can actually fix)
    online_deferred_segments=$(printDeferredSegments ONLINE)
    if [ $? -ne 0 ]; then
        echo "$online_deferred_segments"
        echo "An error occurred while running function printDeferredSegments for SID $sid ONLINE segments. Continuing..."
        exit_status=1
        continue
    fi
    echo "$online_deferred_segments"
    echo

    # Check for offline deferred segments
    offline_deferred_segments=$(printDeferredSegments OFFLINE)
    if [ $? -ne 0 ]; then
        echo "$offline_deferred_segments"
        echo "An error occurred while running function printDeferredSegments for SID $sid OFFLINE segments. Continuing..."
        exit_status=1
        continue
    fi
    echo "$offline_deferred_segments"
    echo

    # Check for READ ONLY deferred segments
    read_only_deferred_segments=$(printDeferredSegments "READ ONLY")
    if [ $? -ne 0 ]; then
        echo "$read_only_deferred_segments"
        echo "An error occurred while running function printDeferredSegments for SID $sid READ ONLY segments. Continuing..."
        exit_status=1
        continue
    fi
    echo "$read_only_deferred_segments"
    echo
    
    # If action is list, continue to the next sid
    if [[ $action =~ LIST ]]; then
        continue
    fi
    
    # Check if any deferred tables, if none found, then exit.
    if [[ "$online_deferred_segments" == *"No ONLINE deferred segments found"* ]]; then
        echo "No online deferred segments found for SID $sid. Nothing to fix. Continuing..."
        continue
    fi

    echo "Fixing ONLINE deferred segments for SID $sid. Segments in OFFLINE and READ ONLY tablespaces will not be affected..."

    # Fix action. Only fixes ONLINE deferred segments. OFFLINE and READ ONLY segments will fail.
    fix_segments=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1

    set serveroutput on
    set feedback off

    DECLARE
    err_num NUMBER;
    err_msg VARCHAR2(100);
    BEGIN
    FOR tab IN
    (
    select table_name, owner from dba_tables tb where owner IN 
    (select username from dba_users where ORACLE_MAINTAINED = 'N') AND partitioned = 'NO' AND segment_created = 'NO' 
        AND (IOT_TYPE != 'IOT_OVERFLOW' OR IOT_TYPE IS NULL)
        AND (SELECT status from dba_tablespaces ts WHERE ts.tablespace_name=tb.tablespace_name) = 'ONLINE'
    UNION 
    select table_name, table_owner from dba_tab_partitions tp where table_owner IN 
    (select username from dba_users where ORACLE_MAINTAINED = 'N') AND segment_created = 'NO'
    AND (SELECT status from dba_tablespaces ts WHERE ts.tablespace_name=tp.tablespace_name) = 'ONLINE'
    )
    LOOP
        EXECUTE IMMEDIATE 'alter table ' || tab.owner || '.' || tab.table_name || ' allocate extent';
    END LOOP;
    EXCEPTION
    WHEN OTHERS THEN
        err_num := SQLCODE;
        err_msg := SUBSTR(SQLERRM, 1, 100);
    dbms_output.put_line('Error '|| err_num || '- ' || err_msg);
    RAISE;
    END;
    /
    exit;
EOD
    )
    if [ $? -ne 0 ]; then
        echo "$fix_segments"
        echo
        echo "An error occurred while fixing deferred segments for $sid, Continuing..."
        exit_status=1
        continue
    else
        remaining=$(printDeferredSegments ONLINE)
        if [ $? -ne 0 ]; then
            echo "$remaining"
            echo "An error occurred while running function printDeferredSegments for SID $sid. Continuing..."
            exit_status=1
            continue
        elif [ "$remaining" != "No ONLINE deferred segments found for $sid." ]; then 
            echo "Error: The following deferred segments are remaining for SID $sid:"
            echo
            echo "$remaining"
            exit_status=1
        else
            echo "Deferred segments fixed successfully for $sid"
            echo
        fi
    fi
done

if [ -n "$invalid_sids" ]; then
    echo "Error: database(s) $invalid_sids are not open. Exiting..."
    exit_status=1
fi

if [ "$exit_status" -ne 0 ]; then
    echo "One or more errors occurred while running the script, check above output for more information"
else
    echo "The script completed successfully!"
fi

exit $exit_status