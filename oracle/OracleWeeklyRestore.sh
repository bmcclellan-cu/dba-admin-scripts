#!/bin/bash
# AvailabilityFlag: Public
# CrontabFlag: True
#
# Purpose:  This script loops through sids in $SIDSLIST and restores each one using 
#           RMANMasterRestoreScript.sh. An email is sent upon both success and failure.
#           
#           The backup directories parameter lists all of the locations where the read-write
#           oracle database files are located. The archive directories parameter
#           is a list of all of the locations of read-only datafiles that need to be copied to 
#           the new database (directories have to be appended with _READONLY). Only directories 
#           that correspond to databases in the SIDSLIST will be used for the restore.
# 
#           The -d option creates a new timestamped directory that is used for the restore location.
#           On a successful restore, the old timestamped directory gets deleted, and if there is not
#           enough storage space the old timestamped directory gets deleted before the restore takes
#           place.
# 
#####################################################################################

usage="Usage: OracleWeeklyRestore.sh [-d (optional, creates timestamped directory, see notes)] [backup dirs csv] [archive dirs csv] [restore location]"
example="Example: OracleWeeklyRestore.sh /DB_BACKUP/ /DB_ARCHIVE/ /DB_RESTORE/restore1/"

dopt=0

# Process input options
while getopts ":hd" option; do
    case $option in
        h)
            echo "$usage"
            echo "$example"
            exit 0
            ;;
        d)
            dopt=1
            ;;
        \?)
            echo "Error: Invalid option"
            exit 1
    esac
done

shift "$((OPTIND-1))"

# Source Oracle environment
source "/export/home/oracle/19c.env"

if [ $? -ne 0 ]; then 
    echo "Sourcing 19c.env failed. Exiting..."
    exit 1
fi

# Check arguments
if [ $# -ne 3 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Set logfile and start logging
timestamp="$(date +"%Y-%m-%d_%H_%M_%S")"
log_file="/tmp/OracleWeeklyRestore-$timestamp.log"
touch "$log_file"
exit_status=0

# Redirect file descriptor 1 (stdout) and file descriptor 2 (stderr) to the tee process which logs stdout to $log_file and terminal
exec > >(tee -a "$log_file") 2>&1

echo "OracleWeeklyRestore.sh Starting: $timestamp."
echo -e "Logging to $log_file\n\n"

# Setup trap to send an email whenever the script exits.

exit_handler(){
    exit_code=$?
    # This line removes the trap to ensure the trap only runs once
    trap - EXIT TERM
    if [[ "$exit_code" -ne 0 ]]; then
        mailx -s "$HOSTNAME - OracleWeeklyRestore.sh - Script failed" "$ALL_DBA_EMAIL_LIST" < "$log_file"
        exit 1
    else
        if [[ "$exit_status" -ne 0 ]]; then
            mailx -s "$HOSTNAME - OracleWeeklyRestore.sh - Script completed with errors" "$ALL_DBA_EMAIL_LIST" < "$log_file"
        else
            mailx -s "$HOSTNAME - OracleWeeklyRestore.sh - Script completed successfully" "$ALL_DBA_EMAIL_LIST" < "$log_file"
        fi
        exit 0
    fi
}

# The line below redirects exit and termination (completion of the script) of script to the exit_handler() function above
trap exit_handler EXIT TERM

if [ -z "$SIDSLIST" ]; then
    echo "Error: There are no SIDs in SIDSLIST. Exiting..."
    exit 1
fi

# Verify that $ORACLE_BACKUP_DIR exists. $ORACLE_BACKUP_DIR is set in .bashrc and is used in 
# RMANMasterRestoreScript.sh
if [ ! -d "$ORACLE_BACKUP_DIR" ]; then
    echo "Error: \$ORACLE_BACKUP_DIR $ORACLE_BACKUP_DIR does not exist." 
    exit_status=1
fi

# Declare arrays containing backup and archive dirs
PrevIFS="$IFS"
IFS=',' 
read -r -a backup_dirs <<< "$1"
read -r -a archive_dirs <<< "$2"
IFS="$PrevIFS"

# Verify existence of each backup directory
for dir in "${backup_dirs[@]}"; do
    if [ ! -d "$dir" ]; then
        echo "Error: backup directory $dir not found." 
        exit_status=1
    fi
done

# Verify existence of archive dirs
for dir in "${archive_dirs[@]}"; do
    if [ ! -d "$dir" ]; then
        echo "Error: archive directory $dir not found." 
        exit_status=1
    fi
done

# If any of the directories do not exist, send email and exit
if [[ "$exit_status" -eq 1 ]]; then
    echo -e "\n\nError: One or more backup directories do not exist. See above output for more details. Exiting..."
    exit 1
fi

# Create restore dir if it does not exist
restore_dir="$3"
mkdir -p "$restore_dir"


if [ "$dopt" -eq 1 ]; then
    # Find all directories in $restore_dir with name matching YYYY_mm_dd_HH_MM_SS
    timestamped_dirs=$(ls "$restore_dir" | grep -E "^[0-9]{4}_[0-9]{2}_[0-9]{2}_[0-9]{2}_[0-9]{2}_[0-9]{2}")

    # If there are any timestamped restores in the restore directory, remove them if space is 
    # needed
    if [ -n "$timestamped_dirs" ]; then
        # Find most recent restore by sorting timestamped directories in descending lexicographical
        # order and taking first one
        most_recent_restore="$restore_dir/$(echo "$timestamped_dirs" | sort -r | head -1)"

        # Calculate size of restore location to ensure enough space exists
        filesystem_size=$(df "$restore_dir" | tail -1 | xargs | cut -d " " -f4)

        # Calculate the size of the most recent restore + 10% to use as estimate for size of new 
        # restore
        required_space=$(echo "$(du -s "$most_recent_restore" | xargs | cut -d " " -f1) * 1.1" | bc)

        # If there is not enough space left on the filesystem, delete all old restores
        if (($(echo "$filesystem_size < $required_space" | bc))); then
            echo "Not enough disk space for restored DBs. Deleting old restores"
            # For each directory matching timestamp pattern, loop through each database's subdirectory
            for timestamp in $timestamped_dirs; do
                # Shutdown each database with directory inside timestamped directory
                echo "Deleting databases under timestamp $timestamp..."
                dbs=$(ls "$restore_dir/$timestamp")
                for db in $dbs; do
                    # Shutdown database
                    shutdown=$("$HOME/common/oracle/shutdown_oracle.sh" "$db" abort)

                    # Ignore 'database already closed' error, but catch all others
                    if [ $? -ne 0 ] && [ -z "$(echo "$shutdown" | grep "Error: database $db is already closed")" ]; then
                        echo "Error occurred while shutting down database $db." 
                        echo -e "$shutdown\n\n"
                        exit 1
                    fi
                done

                # Delete timestamped directory now that all databases with data inside it are not longer
                # running
                if [ -n "$restore_dir" ] && [ -n "$timestamp" ]; then
                    rm -rf "${restore_dir:?}/${timestamp:?}"
                fi
            done
        fi
    fi

    # Set restore_dir based on input param and current timestamp
    restore_dir="$restore_dir/$(date '+%Y_%m_%d_%H_%M_%S')"

    restore_dir=$(echo "$restore_dir" | sed 's/\/\/*/\//g') # Remove duplicate / from path.

    # Create the timestamped restore_dir within the directory $3
    mkdir "$restore_dir"
fi

# Check if oracle listener is running. Start it up if it's not running.
listener_running=$("$HOME/common/oracle/CheckIfListenerIsRunning.sh")
if [ $? -ne 0 ]; then
    echo "Error occurred while checking if Oracle listener is running. Exiting..." 
    echo "$listener_running" 
    exit 1
elif [ "$listener_running" != "Yes" ]; then
    echo "Oracle listener is not running. Starting Oracle listener..." 

    # Start listener
    start_listener=$("$HOME/common/oracle/StartOracleListener.sh")
    if [ $? -ne 0 ]; then
        echo "Error occurred while starting oracle listener. Exiting..." 
        echo "$start_listener" 
        exit 1
    fi
fi

# Get timestamp at start of restores
timestamp_start=$(date "+%Y-%m-%d %H:%M:%S")

# Loop through SIDSLIST and restore each SID
for sid in $SIDSLIST; do

    export ORACLE_SID=$sid

    # Verify that restore location is empty
    if [ -d "$restore_dir/$sid" ] && [ -n "$(ls "$restore_dir/$sid")" ]; then
        echo -e "Error: Restore directory $restore_dir/$sid is not empty. Skipping restore for database $sid...\n\n" 
        exit_status=1
        continue
    fi 

    # Loop through backup_dirs until one is found that contains a directory for $sid
    backup=""
    for dir in "${backup_dirs[@]}"; do
        if [ -d "$dir/${sid^^}" ]; then
            backup="$dir"
            break
        fi
    done

    # If one is not found, note the error
    if [ -z "$backup" ]; then
        echo -e "Error: Backup directory not found for database $sid\n\n" 
        exit_status=1
        continue
    fi

    # Shut down database
    echo "Shutting down database $sid" 
    shutdown=$("$HOME/common/oracle/shutdown_oracle.sh" "$sid" abort)

    # Ignore 'database already closed' error, but catch all others
    if [ $? -ne 0 ] && [ -z "$(echo "$shutdown" | grep "Error: database $sid is already closed")" ]; then
        echo -e "Error occurred while shutting down database $sid\n\n" 
        exit_status=1
        continue
    fi

    # Run RMANMasterRestoreScript.sh to initial restore
    echo "Initiating restore of $sid to $restore_dir" 
    
    # Timestamp for /tmp output file names
    timestamp=$(date +%Y_%m_%d_%H_%M_%S)

    # Timestamp in format accepted by ComputeTimeGap.sh for time calculations
    pre_load_timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    # RMANMasterRestoreScript.sh prints out the location of the log file, so directly output to stream.
    # Emails from the helper script are suppressed.
    echo "Log file for restore is located in /tmp/restore_${timestamp}_${sid}.out"
    "$HOME/common/oracle/RMANMasterRestoreScript.sh" -s "$sid" "$backup" "$restore_dir" > "/tmp/restore_${timestamp}_${sid}.out" 2>&1
    
    success_code=$?
    if [ "$success_code" -eq 0 ]; then
        echo -e "Restore of $sid finished successfully. Check the log file [/tmp/restore_${timestamp}_${sid}.out] on $(hostname | cut -d. -f1) for more details.\n\n"
    elif [ "$success_code" -eq 2 ]; then
        echo -e "RMANMasterRestoreScript.sh completed with errors during restore of $sid. Check the log file [/tmp/restore_${timestamp}_${sid}.out] on $(hostname | cut -d. -f1) for more information.\n\n"
        exit_status=1
    else
        echo -e "Error occurred during restore of $sid. Check the log file [/tmp/restore_${timestamp}_${sid}.out] on $(hostname | cut -d. -f1) for more information.\n\n"
        exit_status=1
        continue
    fi

    # Add back in read-only tablespaces
    echo "Adding back in read-only tablespaces." 

    read_only_added=0

    # Loop through archive directories until one is found that contains a ${sid}_READONLY directory
    for dir in "${archive_dirs[@]}"; do
        if [ -d "${dir}/${sid^^}_READONLY" ]; then
            read_only_add=$("$HOME/common/oracle/AddBackInReadOnlyTablespaces.sh" -s "$sid" "$dir" "$backup")
            if [ $? -ne 0 ]; then
                echo -e "$read_only_add\n\n" 
                echo "Error occurred while adding back in read-only tablespaces for database $sid." 
                exit_status=1
                read_only_added=2
            else
                read_only_added=1
            fi
            break
        fi
    done 

    if [[ "$read_only_added" -eq 0 ]]; then
        echo "No read-only archive directory found for database $sid." 
    elif [[ "$read_only_added" -eq 1 ]]; then
        echo "Read-only tablespaces successfully added back into $sid." 
    else
        echo "One or more error(s) occurred while adding back in read-only tablespaces into $sid. See above output for more details."
    fi

    # Record timestamp to be used to calculate time elapsed during restore
    post_load_timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    # Calculate elapsed time
    time_elapsed=$("$HOME/common/general/ComputeTimeGap.sh" "$pre_load_timestamp" "$post_load_timestamp")
    if [ $? -ne 0 ]; then
        echo "Error occurred while computing time gap between $pre_load_timestamp and $post_load_timestamp:" 
        echo "$time_elapsed" 
        exit_status=1
    fi

    # Add timing information to email body
    echo -e "Time completed: $post_load_timestamp\nTime taken for restore: $time_elapsed\n\n" 
done

# Get timestamp at end of restores
timestamp_end=$(date "+%Y-%m-%d %H:%M:%S")

# Calculate total time elapsed during restores
total_restore_time=$("$HOME/common/general/ComputeTimeGap.sh" "$timestamp_start" "$timestamp_end")
if [ $? -ne 0 ]; then
    echo "Error occurred while computing total time elapsed during restores" 
    echo "$total_restore_time" 
    exit_status=1
else
    # Append total restore time to email body
    echo -e "Total restore time: $total_restore_time\n\n" 
fi

# If using -d option and all restores finished successfully, delete any old restores
if [ "$dopt" -eq 1 ] && [ "$exit_status" -eq 0 ]; then
    echo "Restore was successful. Deleting old restores..."
    # timestamped_dirs is a snapshot of the directories BEFORE the restore occurred,
    # so this will only delete old DB files.
    for dir in $timestamped_dirs; do
        # Verify that $3 and $dir are not empty to ensure this rm command will never recursively
        # delete an entire filesystem.
        if [ -n "$3" ] && [ -n "$dir" ]; then
            echo "Recursively deleting directory $3/$dir"
            rm -rf "${3:?}/${dir:?}"
        fi
    done
fi
