#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script archives the current redo log for a specific database or all
#	   SIDs in $SIDSLIST. Before doing this, the script identifies the location
#	   that the archive log was written to and it finds the current sequence
#	   number for the relative database. With -g, it instead archives the given
#	   redo log group if that group still needs archiving. A database that is not
#	   in archive log mode is skipped and reported as an error.
#
usage="Usage: ArchiveCurrentRedoLog.sh [ -g redo-log group number (optional) ] [ \$ORACLE_SID | ALL (optional) ]"
example1="Example 1: ArchiveCurrentRedoLog.sh mysid"
example2="Example 2: ArchiveCurrentRedoLog.sh -g 7 mysid"
#####################################################################################

group_num=""

# Process input options
while getopts ":hg:" option; do
    case $option in
        h)
            echo "$usage"
            echo "$example1"
            echo "$example2"
            exit 0
            ;;
        g)
            if [[ ! "$OPTARG" =~ ^[0-9]+$ ]]; then
                echo "Error: Invalid redo log group number $OPTARG, must be a number"
                exit 1
            fi
            group_num="$OPTARG"
            ;;
        :)
            echo "Error: Option -$OPTARG requires an argument"
            exit 1
            ;;
        \?)
            echo "Error: Invalid option"
            exit 1
            ;;
    esac
done

shift "$((OPTIND - 1))"

# Check arguments
if [ $# -gt 1 ]; then
    echo "$usage"
    echo "$example1"
    echo "$example2"
    exit 1
fi

if [ -z "$1" ]; then
    sids=$("$HOME/common/oracle/VerifyAllParam.sh" -V)
else
    sids=$("$HOME/common/oracle/VerifyAllParam.sh" -V "$1")
fi

if [ $? -ne 0 ]; then
    echo "$sids"
    echo "Error occurred while calling VerifyAllParam.sh. Exiting..."
    exit 1
fi

# Run through the script on all applicable SIDs
for sid in $sids; do
    echo

    export ORACLE_SID="$sid"

    echo "Running script on $sid..."
    echo "--------------------------------------------------"

    archive_log_mode=$("$HOME/common/oracle/CheckArchivelogMode.sh" "$sid")
    if [ $? -ne 0 ]; then
        echo "Archive Log Mode Status:"
        echo "$archive_log_mode"
        echo "Error: Call to CheckArchivelogMode.sh failed for $sid. Continuing..."
        exit_status=1
        continue
    fi

    if ! [[ "$archive_log_mode" =~ "YES" ]]; then
        echo "Archive Log Mode Status:"
        echo "$archive_log_mode"
        echo "Error: Database $sid is not in Archive Log Mode. Continuing..."
        exit_status=1
        continue
    fi

    if [ -n "$group_num" ]; then
        # Display the redo log groups
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        select group#, status, round(bytes/1000000) as "Size in MB" from v\$log;
        exit;
EOD

        # Check for errors
        if [ $? -ne 0 ]; then
            echo "An error occurred while attempting to display the redo log groups for $ORACLE_SID. Continuing..."
            exit_status=1
            continue
        fi

        echo "Archiving log group $group_num based on status..."

        # Find the status of the provided redo log group and whether it is already archived
        group_info=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        set heading off
        set feedback off
        select status, archived from v\$log where group# = '$group_num';
        exit;
EOD
        )

        # Check for errors
        if [ $? -ne 0 ]; then
            echo "$group_info"
            echo "An error occurred while determining the status of redo log group ${group_num}. Continuing..."
            exit_status=1
            continue
        fi

        # Clear extra whitespace and split into status and archived
        read -r group_status group_archived <<< "$(echo "$group_info" | xargs)"
        # Choose the statement from the group's state up front, rather than running one
        # and interpreting its ORA error afterwards
        if [ -z "$group_status" ]; then
            echo "Error: Redo log group $group_num does not exist on database ${ORACLE_SID}. Continuing..."
            exit_status=1
            continue
        elif [ "$group_archived" == "YES" ]; then
            echo "Redo log group $group_num does not need archiving"
            continue
        elif [ "$group_status" == "CURRENT" ]; then
            # Without THREAD, ARCHIVE LOG CURRENT archives every unarchived group, "including logs
            # previous to current logs" (19c ALTER SYSTEM reference). So group N is still archived if
            # it switched out of CURRENT after the status check above.
            archive_sql="alter system archive log current;"
        elif [ "$group_status" == "ACTIVE" ] || [ "$group_status" == "INACTIVE" ]; then
            archive_sql="alter system archive log group $group_num;"
        else
            echo "Unsupported status $group_status encountered. Continuing..."
            exit_status=1
            continue
        fi
    else
        # Use UpdateDBrecoveryFileDest.sh to check where archive logs are written
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

        # Check result of sequence number check
        if [ $? -ne 0 ] || [[ "$sequence_num" =~ "ORA-" ]]; then
            echo "$sequence_num"
            echo "Error occurred during sequence number check for ${ORACLE_SID}. Continuing..."
            exit_status=1
            continue
        fi

        # Remove whitespace from output
        sequence_num=$(echo "$sequence_num" | xargs)

        archive_sql="alter system archive log current;"
    fi

    # Archive the redo log for the current database
    archive_log=$(
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    $archive_sql
    exit;
EOD
    )

    # Check for errors
    bash_error=$?

    # Kept this check because during normal operations a redo log could get archived during this script's execution. That should not result in an error.
    # ORA-16013 -> An attempt was made to archive the named file manually, but the file did not require archiving. The file had previously been successfully archived.
    ora_16013=$(echo "$archive_log" | grep "ORA-16013")
    
    group_specifier="log"
    if [ -n "$group_num" ]; then
        group_specifier="log group ${group_num}"
    fi

    if [ -n "$ora_16013" ]; then
        echo "Redo ${group_specifier} on $ORACLE_SID does not need archiving"
        continue
    elif [ "$bash_error" -ne 0 ] || [[ "$archive_log" =~ "ORA-" ]]; then
        echo "$archive_log"
        echo "Error occurred while archiving the redo ${group_specifier} for ${ORACLE_SID}. Continuing..."
        exit_status=1
        continue
    fi

    if [ -n "$group_num" ]; then
        echo "Log group ${group_num} successfully archived"
        continue
    fi

    echo "Redo log archive completed successfully"

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
        echo "An error occurred while finding the group number for the current redo log for $ORACLE_SID. Continuing..."
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

if [ -z "$1" ]; then
    invalid_sids=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
else
    invalid_sids=$("$HOME/common/oracle/VerifyAllParam.sh" -I "$1")
fi

if [ $? -ne 0 ]; then
    echo "$invalid_sids"
    echo "Failed to validate parameters by running VerifyAllParam.sh. Exiting..."
    exit 1
fi

if [ -n "$invalid_sids" ]; then
    if [ "$invalid_sids" == "-1" ]; then
        echo "Error: \$ORACLE_SID not set and none provided. Exiting..."
        exit 1
    fi
    echo "Error: database(s) $invalid_sids are not open. Exiting..."
    exit_status=1
fi

# If any errors occurred during the script, exit with error code 1, otherwise exit 0
if [ -n "$exit_status" ]; then
    exit 1
else
    exit 0
fi