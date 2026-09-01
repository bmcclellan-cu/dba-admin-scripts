#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script archives the current redo log for a specific database or all
#	   SIDs in $SIDSLIST. Before doing this, the script identifies the location
#	   that the archive log was written to and it finds the current sequence
#	   number for the relative database.
#
usage="Usage: ArchiveCurrentRedoLog.sh [\$ORACLE_SID | ALL (optional) ] | [ redo-log group number (optional) ]"
example="Example: ArchiveCurrentRedoLog.sh mysid"
#####################################################################################

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

if [[ "$1" =~ ^[0-9]+$ ]]; then
    # Check for valid ORACLE_SID
    sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
    if [ -n "$sid_check" ]; then
        if [ "$sid_check" == "-1" ]; then
            echo "Error, \$ORACLE_SID not set..."
            exit 1
        fi
        echo "Error, provided ORACLE_SID is not open. Exiting..."
        exit 1
    fi

    # Display the redo log groups
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    select group#, status, round(bytes/1000000) as "Size in MB" from v\$log;
    exit;
EOD

    # Check for errors
    if [ $? -ne 0 ]; then
        echo "An error occurred while attempting to display the redo log groups. Exiting..."
        exit 1
    fi

    echo "Altering log group $1 based on status..."

    # Find the status of the provided redo log
    current_status=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set heading off
    set feedback off
    select status from v\$log where group# = '$1';
    exit;
EOD
    )

    # Check for errors
    if [ $? -ne 0 ]; then
        echo "$current_status"
        echo "An error occurred while determining the status of redo log group ${1}. Exiting..."
        exit 1
    fi

    # Clear extra whitespace
    current_status=$(echo "$current_status" | xargs)

    if [ -z "$current_status" ]; then
        echo "Error. Redo log group $1 does not exist on database ${ORACLE_SID}. Exiting..."
        exit 1
    elif [ "$current_status" == "ACTIVE" ]; then
        # Attempt to archive the provided redo log group
        alter_archive_log=$(
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        alter system archive log group $1;
        exit;
EOD
        )

        bash_error=$?

    elif [ "$current_status" == "INACTIVE" ]; then
        echo "Group is inactive no data to archive. Exiting..."
        exit 0
    elif [ "$current_status" == "CURRENT" ]; then

        # Switch system logfile
        alter_archive_log=$(
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        ALTER SYSTEM SWITCH LOGFILE;
        ALTER SYSTEM ARCHIVE LOG GROUP $1;
        exit;
EOD
        )

        bash_error=$?
    else
        echo "Unsupported status $current_status encountered. Exiting..."
        exit 1
    fi

    # Check for specific ORA errors
    ora_error_one=$(echo "$alter_archive_log" | grep "ORA-00261")
    ora_error_two=$(echo "$alter_archive_log" | grep "ORA-16013")

    # Check for ORA-00261 error
    if [ "$ora_error_one" ]; then
        echo "Redo log group ${1} is already currently being archived"
        exit 0
    # Check for ORA-16013 error
    elif [ "$ora_error_two" ]; then
        echo "Redo log group ${1} is active, and does not need archiving"
        exit 0
    # Check for general errors
    elif [ "$bash_error" -ne 0 ]; then
        echo "An error occurred while attempting to archive log group ${1}. Error:"
        echo "$alter_archive_log"
        echo ""
        echo "Exiting..."
        exit 1
    else
        echo "Log group ${1} successfully archived"
        exit 0
    fi
    
else
    # ${1:+"$1"} expands to nothing when $1 is unset or empty, and to "$1" otherwise.
    # Plain "$1" would pass one empty argument, which VerifyAllParam.sh reads as "check
    # this specific SID" rather than "check $ORACLE_SID", so its -1 "not set" sentinel
    # would never be returned and the guard below would not fire.
    sids=$("$HOME/common/oracle/VerifyAllParam.sh" -V ${1:+"$1"})
    if [ $? -ne 0 ]; then
        echo "$sids"
        echo "Error occurred while calling VerifyAllParam.sh. Exiting..."
        exit 1
    fi

    # Run through the script on all applicable SIDs
    for sid in $sids; do
        echo ""

        export ORACLE_SID="$sid"

        echo "Running script on $sid..."
        echo "--------------------------------------------------"

        # Use UpdateDBrecoveryFileDest.sh to check where archive log is written
        archivelog_dir=$("$HOME/common/oracle/UpdateDBrecoveryFileDest.sh" list "$ORACLE_SID")
        if [ $? -ne 0 ]; then
            echo "$archivelog_dir"
            echo "Error occurred while running UpdateDBrecoveryFileDest.sh for $ORACLE_SID. Continuing..."
            exit_status=1
            continue
        fi

        archivelog_dir=$(echo "$archivelog_dir" | grep /)

        if [ -z "$archivelog_dir" ]; then
            echo "Could not determine archivelog_dir for $ORACLE_SID. Continuing..."
            exit_status=1
            continue
        fi

        # Check for the active sequence number in v$log for the current database
        sequence_num=$(
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        set heading off
        set feedback off
        select SEQUENCE# from v\$log where status = 'ACTIVE';
        exit;
EOD
        )

        # Check for errors
        bash_error=$?
        ora_error=$(echo "$sequence_num" | grep "ORA-")

        # Remove whitespace from output
        sequence_num=$(echo "$sequence_num" | xargs)

        # Check result of sequence number check
        if [ "$bash_error" -ne 0 ]; then
            echo "$sequence_num"
            echo "Error occurred during sequence number check ${sequence_num}. Error: "
            echo "Continuing..."
            exit_status=1
            continue
        elif [ -n "$ora_error" ]; then
            echo "$sequence_num"
            echo "Error occurred during sequence number check ${sequence_num}. Error: "
            echo "Continuing..."
            exit_status=1
            continue
        fi

        # Archive the redo log for the current database
        archive_log=$(
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        alter system archive log current;
        exit;
EOD
        )

        # Check for errors
        bash_error=$?
        ora_error=$(echo "$archive_log" | grep "ORA-")

        # Check result of archive log block
        if [ "$bash_error" -ne 0 ]; then
            echo "$archive_log"
            echo "Error occurred during archive log ${archive_log}. Error: "
            echo "Continuing..."
            exit_status=1
            continue
        elif [ -n "$ora_error" ]; then
            echo "$archive_log"
            echo "Error occurred during archive log ${archive_log}. Error: "
            echo "Continuing..."
            exit_status=1
            continue
        else
            echo "Redo log archived completed successfully"
        fi

        # Find the group number for the current redo log
        log_group=$(
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        set heading off
        set feedback off
        select group# from v\$log where status = 'CURRENT';
        exit;
EOD
        )

        # Check for errors
        if [ $? -ne 0 ]; then
            echo "$log_group"
            echo "An error occurred while finding the group number for the current redo log for $ORACLE_SID. Exiting..."
            exit_status=1
            continue
        fi

        log_group=$(echo "$log_group" | xargs)

        
        if [ -z "$sequence_num" ]; then
            echo "Current redo log group ${log_group} written to $archivelog_dir"
        else
            echo "Current redo log group ${log_group}, sequence $sequence_num written to $archivelog_dir"
        fi
    done

    # See the note on ${1:+"$1"} above.
    invalid_sids=$("$HOME/common/oracle/VerifyAllParam.sh" -I ${1:+"$1"})
    if [ -n "$invalid_sids" ]; then
        if [ "$invalid_sids" == "-1" ]; then
            echo "Error: \$ORACLE_SID not set and none provided. Exiting..."
            exit 1
        fi
        echo "Error: database(s) $invalid_sids are not open. Exiting..."
        exit_status=1
    fi
fi

# If any errors occurred during the script, exit with error code 1, otherwise exit 0
if [ -n "$exit_status" ]; then
    exit 1
else
    exit 0
fi
