#!/bin/bash
# AvailabilityFlag: Public
# CrontabFlag: True
#
# Purpose: To perform weekly RMAN backups
#
# Explanation: This script is designed to be run regularly inside a cron job in order
#              to take backups of all Oracle databases on the server. This can take awhile
#              so the script should be run inside nohup (see usage below).
#
# Note: This script can ONLY be run in nohup mode or as a cronjob. It will forcibly exit if run interactively.
#
# Note: The location where backups will be stored is determined by the PrintParamDBrecoveryFileDest.sh script
#
# Error Handling for ORA-27056:
#     The ORA-27056 error (could not delete file) occurs when RMAN attempts to delete archivelogs on a read-only
#     file system (e.g., /DATABASE_BACKUP_DB1).
# 
#    To resolve, connect to RMAN (`rman target /`), run `CROSSCHECK ARCHIVELOG ALL;` to validate archivelogs, 
#    review the dates of archivelogs on the read-only file system, and then run `DELETE FORCE ARCHIVELOG ALL COMPLETED BEFORE 'SYSDATE-N';` 
#    (e.g., N=5 for 5 days if the last archivelog on the read-only file system was created before 5 days ago) to expire entries without requiring physical deletion.
#
# Note: This script used to omit ORA-01511 in the error logs, but this has been removed. In the event we need to omit ORA-01511 from our logs again
#       please add a comment explaining why this is necessary 
#
# Note: Sourcing .bashrc was tested in Crontab and succeeded
#
###############################################
usage="Usage: nohup OraclePrimaryRMANBackupScript.sh [ ORACLE_SID (csv) | ALL] &"
example="Example 1: nohup OraclePrimaryRMANBackupScript.sh sid1 &
Example 2: nohup OraclePrimaryRMANBackupScript.sh sid1,sid2 &"

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

# Check input
if [ $# -ne 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Check if stdin is connected to a terminal.
if [ -t 0 ]; then
    echo "Error, this script must be run in nohup mode or the crontab. Exiting..."
    exit 1
fi

# creating run directory
if [ ! -d "/tmp" ]; then
    mkdir "/tmp"
    #Error check 
    if [ $? -ne 0 ]; then
        echo "Error creating run directory /tmp. Exiting..."
        exit 1
    fi
fi

# Append timestamp to log files
current_timestamp=$(date "+%Y-%m-%d_%H-%M-%S")

source "$HOME/.bashrc"
if [ $? -ne 0 ]; then
    # No point in sending email if the email recipients are sourced from .bashrc (ALL_DBA_EMAIL_LIST)
    echo "An error occurred while sourcing $HOME/.bashrc. Exiting..."
    exit 1
fi

# Move into run directory
cd "/tmp" || { echo "Could not cd into tmp directory. Exiting..."; exit 1; }

exit_status=0

# Initialize variable for email body & total size of backups
email_body=""
total_backup_size=0
# Checking ORACLE_SID/input check
if [ "$1" == "ALL" ]; then 
    all_sid_output=$("$HOME/common/oracle/VerifyAllParam.sh" -V "$1")
    if [ $? -ne 0 ]; then
        echo "$all_sid_output"
        echo "Error, VerifyAllParam.sh failed for ALL input. Exiting..."
        echo "$all_sid_output" | mailx -s "$HOSTNAME Oracle backups: Error VerifyAllParam failed for ALL" "$ALL_DBA_EMAIL_LIST"
        exit 1
    fi
    export SIDS="$all_sid_output"
elif [[ "$1" == *"ALL"* ]]; then 
    echo "Error, if using ALL you cannot include other SIDs. Exiting..."
    exit 1
else 
    unchecked_sids=$(echo "$1" | tr "," " ")
    valid_sids=()
    for SID in $unchecked_sids; do 
        sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I "$SID")
        if [ $? -ne 0 ]; then
            echo "$sid_check"
            echo "Error, VerifyAllParam.sh failed while validating SID $SID. Continuing..."
            echo "$sid_check" | mailx -s "$HOSTNAME Oracle backups: Error VerifyAllParam failed for SID $SID" "$ALL_DBA_EMAIL_LIST"
            exit_status=1
            continue
        fi
        if [ -n "$sid_check" ]; then
            if [ "$sid_check" == "-1" ]; then
                echo "Error, \$ORACLE_SID not set..."
                exit_status=1
                continue
            fi
            echo "Error, provided ORACLE_SID $SID is not open. Continuing..."
            echo "Error, provided ORACLE_SID $SID is not open. Continuing..." | mailx -s "$HOSTNAME Oracle backups: Error invalid SID $SID" "$ALL_DBA_EMAIL_LIST"
            exit_status=1
            continue
        else
            valid_sids+=("$SID")
        fi
    done
    export SIDS="${valid_sids[*]}"
fi

if [ -z "$SIDS" ]; then
    echo "Error: No valid SIDs inputted/ALL option returned no SIDs. Exiting..."
    echo "Error: No valid SIDs inputted/ALL option returned no SIDs. Exiting..." | mailx -s "$HOSTNAME Oracle backups: Error no valid SIDs" "$ALL_DBA_EMAIL_LIST"
    exit 1
fi

# Source the logging library to use its functions
source "$HOME/common/general/Logging.sh"
if [ $? -ne 0 ]; then
    echo "Could not source logging library. Exiting..."
    echo "Could not source logging library. Exiting..." | mailx -s "$HOSTNAME Oracle backups: Error sourcing logging library" "$ALL_DBA_EMAIL_LIST"
    exit 1
fi

out_logs="/tmp/OraclePrimaryRMANBackupScript_${current_timestamp}.out"

# This will set up logging so that all output goes both to the all_log file and to the terminal 
# until close_logs or a different set_*_logging function is called
set_general_logging "$out_logs"
if [ $? -ne 0 ]; then
    echo "An error occurred while setting general logging. Exiting..." 
    echo "An error occurred while setting general logging. Exiting..."  | mailx -s "$HOSTNAME Oracle Backups: Error running set_general_logging" "$ALL_DBA_EMAIL_LIST"
    exit 1
fi
echo "General log location: $out_logs"

# This is used later in the script to determine what information should end up in the sid specific error logs
# The first grep does an inverse match (-v) to filter out any lines that have 'echo' or 'ORA-01511' as these are just noise in the logs
# The second grep actually selects the strings, and surrounding information, that we want in the log file. 
# The filter uses grep with --line-buffered to ensure as grep produces a line of output it is immediately passed to the next pipe
# This is not strictly necessary, but it is helpful, especially for nohup scripts, because you can now use `tail -f` to follow the live sid specific logs with minimal delay caused by buffering
# There is also a -A and -B flag used which gets the output after (-A) and before (-B) the line that matched
# Using -i to ignore letter casing in second grep
err_log_filter='grep --line-buffered -v -e "ORA-01511 errors can be ignored" -e "echo" -e "error log"|\
                grep --line-buffered -i -A 10 -B 10 -e "ORA-" -e "RMAN-" -e "not valid" -e "not found" -e "integer expression expected" -e "too many arguments" -e "is not a directory" -e "error"'

# Record start timestamp in format accepted by ComputeTimeGap.sh for time calculations
pre_backup_timestamp=$(date "+%Y-%m-%d %H:%M:%S")

echo "Backing up the following SIDs: ${SIDS}"
# Iterate over the SIDs
sid_status=0
for SID in $SIDS; do
    # If an error was indicated by the script or there is error output in the log file, send an email
    if [ "$sid_status" -ne 0 ] || [ -s "${err_logs}" ]; then
        # Close logging to prevent any race conditions when reading from the log file
        close_logs
        mailx -s "$sid_err_subject" "$ALL_DBA_EMAIL_LIST" < "${err_logs}"
        # Set exit_status so the main script email can indicate an error
        exit_status=1
    fi    
    export ORACLE_SID=$SID
    sid_status=0
    sid_err_subject="Error alert $HOSTNAME $ORACLE_SID unknown error"

    # Create the sid specific error log
    err_logs="/tmp/OraclePrimaryRMANBackupScript_${current_timestamp}_${ORACLE_SID}.err"

    # Output all logs to $out_logs and filtered logs to $err_logs
    # The first grep in $err_log_filter does an inverse match (-v) to filter out any lines that have 'echo' or 'ORA-01511' as these are just noise in the logs
    # The second grep in $err_log_filter actually selects the strings, and surrounding information, that we want in the log file. 
    # The filter uses grep with --line-buffered to ensure as grep produces a line of output it is immediately passed to the next pipe
    # This is not strictly necessary, but it is helpful, especially for nohup scripts, because you can now use `tail -f` to follow the live sid specific logs with minimal delay caused by buffering
    # There is also a -A and -B flag used which gets the output after (-A) and before (-B) the line that matched
    set_sid_and_general_logging "$out_logs" "$err_logs" "$err_log_filter"
    if [ $? -ne 0 ]; then
        echo "An error occurred while setting sid and general logging for ${ORACLE_SID}. Continuing..."
        echo "An error occurred while setting sid and general logging for ${ORACLE_SID}. Continuing..."  | mailx -s "Error alert $HOSTNAME $ORACLE_SID set_sid_and_general_logging failed" "$ALL_DBA_EMAIL_LIST"
        # Do not want to set sid_status=1 here because that would send an email with an empty body at the beginning of the next iteration
        exit_status=1
        continue
    fi

    echo
    echo "=== Beginning backup process for $ORACLE_SID ==="
    echo "$ORACLE_SID error log location: ${err_logs}"

    # Set the local scripts backup directory for this SID
    recovery_file_dest=$("$HOME/common/oracle/PrintParamDBrecoveryFileDest.sh" "$ORACLE_SID")
    if [ $? -ne 0 ]; then
        echo "Error, PrintParamDBrecoveryFileDest.sh failed. Continuing..."
        echo "$recovery_file_dest"
        sid_err_subject="Error alert $HOSTNAME $ORACLE_SID PrintParamDBrecoveryFileDest.sh failed"
        sid_status=1
        continue
    fi
    # Uppercase ORACLE_SID and add it to the script dir path
    scripts_dir="${recovery_file_dest}/$(echo "$ORACLE_SID" | tr "[:lower:]" "[:upper:]")/scripts"
    
    # Verify that the database is open before proceeding
    db_status=$("$HOME/common/oracle/CheckDatabaseOpenStatus.sh" "$ORACLE_SID")

    bash_error=$?
    ora_error=$(echo "$db_status" | grep "ORA-")

    if [ $bash_error -ne 0 ] || [ -n "$ora_error" ]; then
        echo " "
        echo "Error: failed while attempting to check status of database $ORACLE_SID. Continuing..."
        sid_err_subject="Error alert $HOSTNAME $ORACLE_SID CheckDatabaseOpenStatus failed"
        sid_status=1
        continue
    elif [ "$db_status" != "OPEN" ]; then
        echo " "
        echo "Error: Database $ORACLE_SID is not open. Continuing..."
        sid_err_subject="Error alert $HOSTNAME $ORACLE_SID not open - database is in $db_status mode"
        sid_status=1
        continue
    fi

    #Verify that backup space is available before proceeding
    "$HOME/common/oracle/CheckDBRecoveryFileDestSize.sh"
    # Send email alert if there is not enough backup space
    if [ $? -ne 0 ]; then
        echo " "
        echo "Error: Backup directory space NOT available. Continuing..."
        sid_err_subject="Error alert $HOSTNAME $ORACLE_SID not enough backup space"
        sid_status=1
        continue
    else
        echo "------------------------------------------------------------------"
        echo "Backup directory space available"
        echo "------------------------------------------------------------------"
    fi
    
    # Archive the current redo at the start of the backup, this is required to create a consistent backup
    "$HOME/common/oracle/ArchiveCurrentRedoLog.sh" "$ORACLE_SID"
    if [ $? -ne 0 ]; then
        echo " "
        echo "ArchiveCurrentRedoLog failed for ${ORACLE_SID}. Continuing..."
        sid_err_subject="$HOSTNAME ArchiveCurrentRedoLog failed for ${ORACLE_SID}"
        sid_status=1
        continue
    fi

    # Echo start date to console and write to a local scripts file
    start_time=$(date "+%Y-%m-%d %H:%M:%S")
    # 2>/dev/null discards tee's possible errors from appearing in logs or terminal 
    echo "Starting backup for ${ORACLE_SID} at: $start_time" | tee -a "$scripts_dir/rmanbackup_start_end_time.txt" 2>/dev/null

    # Cleaning up old RMAN files
    "$HOME/common/oracle/RMANCleanupControlFileReferences.sh"
    if [ $? -ne 0 ]; then
        echo "Error when calling RMANCleanupControlFileReferences.sh for ${ORACLE_SID}. Continuing..."
        sid_err_subject="Error alert $HOSTNAME RMANCleanupControlFileReferences.sh failed"
        sid_status=1
        continue
    fi

    # Start the RMAN backup
    rman target=/ <<EOD
    RUN {
        CONFIGURE CHANNEL DEVICE TYPE DISK CLEAR;
        CONFIGURE COMPRESSION ALGORITHM 'BASIC' OPTIMIZE FOR LOAD FALSE;
        SQL 'ALTER SYSTEM ARCHIVE LOG CURRENT';
        BACKUP DATABASE SKIP READONLY;
        SQL 'ALTER SYSTEM ARCHIVE LOG CURRENT';
        restore database validate;
    }
    EXIT;
EOD

    # RMAN backup error check
    if [ $? -ne 0 ]; then 
        echo "Error occurred when attempting the RMAN backup for ${ORACLE_SID}. Continuing..."
        sid_err_subject="Error alert $HOSTNAME $ORACLE_SID RMAN backup failed"
        sid_status=1
        continue
    fi

    echo "RMAN Backup successful, cleaning up archive logs..."

    # Delete all archived redo logs older than 2 days, then delete any extraneous ones (ones that have been backed up/are 
    # no longer necessary for a restore), and then de-catalog archive logs that do not exist on disk. 
    # NOTE: If this fails, let the remainder of the loop finish, do not 'continue'
    rman target=/ <<EOD
    RUN {
        delete noprompt archivelog until time='sysdate-2';
        crosscheck archivelog all;
        delete noprompt expired archivelog all;
        delete noprompt obsolete;
    }
EOD
    if [ $? -ne 0 ]; then
        # Set a sid_err_subject so that the logic that sends out error emails has a useful subject
        sid_err_subject="Error alert $HOSTNAME $ORACLE_SID RMAN archive log cleanup failed."
        # Set sid_status=1 so that the logic that sends out error emails is triggered
        sid_status=1
    fi

    # Run script to create dynamic restore scripts
    "$HOME/common/oracle/RMANCreateRestoreDynamicScripts.sh" "$ORACLE_SID" "$scripts_dir"

    # Verify script ran correctly, if not send email alert
    if [ $? -ne 0 ]; then
        echo "An error occurred when running RMANCreateRestoreDynamicScripts.sh for ${ORACLE_SID}. Continuing..." 
        sid_err_subject="Error alert $HOSTNAME $ORACLE_SID RMANCreateRestoreDynamicScripts.sh failed"
        sid_status=1
        continue
    fi

    # Archive the current redo at the end of the backup, this is required to create a consistent backup
    "$HOME/common/oracle/ArchiveCurrentRedoLog.sh" "$ORACLE_SID"
    if [ $? -ne 0 ]; then
        echo " "
        echo "ArchiveCurrentRedoLog failed for ${ORACLE_SID}. Continuing..."
        sid_err_subject="$HOSTNAME ArchiveCurrentRedoLog failed for ${ORACLE_SID}"
        sid_status=1
        continue
    fi

    # Ensure backupset exists for SID
    # Uppercasing ORACLE_SID
    backupset_dir="${recovery_file_dest}/$(echo "$ORACLE_SID" | tr "[:lower:]" "[:upper:]")"
    if [ -d "$backupset_dir/backupset" ]; then
        backupset_dir="$backupset_dir/backupset"
    fi
    end_time=$(date "+%Y-%m-%d %H:%M:%S")

    # Determine size of backupset to add to email output
    fileSystemUsed=$(du -s "$backupset_dir")
    if [ $? -ne 0 ]; then
        echo "$fileSystemUsed"
        echo "An error occurred when getting disk space used by $backupset_dir. Continuing..."
        sid_err_subject="$HOSTNAME Finished backup for ${ORACLE_SID}, but disk utilized command failed"
        sid_status=1
        continue
    fi
    fileSystemUsed=$(echo "$fileSystemUsed" | awk '{printf "%.0f", $1/1024/1024}')
    # Increase variable for total space used by all backups
    total_backup_size=$((fileSystemUsed + total_backup_size))
    echo "Space used by backups for $ORACLE_SID: $fileSystemUsed GB"
    email_body+="Space used by backups for $ORACLE_SID: $fileSystemUsed GB\n"

    # Determine time took to backup SID
    time_diff=$("$HOME/common/general/ComputeTimeGap.sh" "$start_time" "$end_time")
    if [ $? -ne 0 ]; then
        echo "$time_diff"
        echo "An error occurred when computing the time elapsed to backup sid $SID. Continuing..."
        sid_err_subject="$HOSTNAME ComputeTimeGap failed for ${ORACLE_SID}"
        sid_status=1
        continue
    fi
    email_body+="Time elapsed for backup of $SID: $time_diff\n"

    # Echo end date to console and write to a local scripts file
    # 2>/dev/null discards tee's possible errors from appearing in logs or terminal 
    echo "Finished backup for ${ORACLE_SID} at: $(date "+%Y-%m-%d_%H_%M")" | tee -a "$scripts_dir/rmanbackup_start_end_time.txt" 2>/dev/null
    echo
done
# If an error was indicated by the script or there is error output in the log file, send an email
# This block catches any errors that occur in the final SID that was backed up
if [ "$sid_status" -ne 0 ] || [ -s "${err_logs}" ]; then
    # Close logging to prevent any race conditions when reading from the log file
    close_logs
    mailx -s "$sid_err_subject" "$ALL_DBA_EMAIL_LIST" < "${err_logs}"
    # Set exit_status so the main script email can indicate an error
    exit_status=1
fi

# Set general logging up again so no more logs go to sid specific files but output is still captured in the general file
set_general_logging "$out_logs"
if [ $? -ne 0 ]; then
    echo "An error occurred while setting general logging"
    echo "An error occurred while setting general logging" | mailx -s "$HOSTNAME set_general_logging failed in OraclePrimaryRMANBackupScript.sh" "$ALL_DBA_EMAIL_LIST"
    exit_status=1
fi

# Record end timestamp to be used to calculate time elapsed during restore
post_backup_timestamp=$(date "+%Y-%m-%d %H:%M:%S")

# Calculate elapsed time
time_elapsed=$("$HOME/common/general/ComputeTimeGap.sh" "$pre_backup_timestamp" "$post_backup_timestamp")
if [ $? -ne 0 ]; then
    echo "Error occurred while computing time gap between start time $pre_backup_timestamp and end time $post_backup_timestamp:"
    echo "$time_elapsed"
    email_body+="An error occurred while calculating time taken for backup:\n$time_elapsed"
else
    # Add timing information to email body
    email_body+="Time started: $pre_backup_timestamp\nTime completed: $post_backup_timestamp\nTime elapsed for backup: $time_elapsed\n"
fi

echo
echo "Script completed."

# Add size of ALL backupset folders to email output
email_body+="Total size of ALL backups: $total_backup_size GB\n"

out_logs_email_subject=""
if [ "$exit_status" -ne 0 ]; then
    out_logs_email_subject="Error $HOSTNAME Oracle backups"
else
    out_logs_email_subject="Success $HOSTNAME Oracle backups"
fi

# Close the log files before reading from them to prevent race conditions
close_logs

{
    echo -e "$email_body"
    cat "$out_logs"
} | mailx -s "$out_logs_email_subject" "$ALL_DBA_EMAIL_LIST"

exit "$exit_status"
