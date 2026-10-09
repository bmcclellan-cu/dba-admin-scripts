#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script will add back in read-only tablespaces to a database that has been restored
#          and send an email indicating success or failure
#
#####################################################################################

usage="Usage: AddBackInReadOnlyTablespaces.sh [-s (optional, suppresses email output)] [ORACLE_SID csv] [archive dir csv] [backup dir csv]"
example="Example: AddBackInReadOnlyTablespaces.sh mysid1,mysid2 /ARCHIVE_1/,/ARCHIVE_2/ /BACKUP_1/,/OTHER_BACKUP/recovery/"

# Process input options
send_email=1
while getopts ":hs" option; do
    case $option in
        h)
            echo "$usage"
            echo "$example"
            exit 0;;
        s)
            send_email=0
            # Shift the positional parameter by one so that the flag is not treated like a parameter
            # outside of the getopts loop
            shift 1
            ;;
        \?)
            echo "Error: Invalid option"
            exit 1
    esac
done


# Check arguments
if [ $# -ne 3 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Calculate number of values to expect for each csv input param by using awk's NF value
# to count how many values occurred in $1 with comma delimiters
num_sids=$(echo "$1" | awk -F ',' '{print NF}')

# Calculate the number of csv values present in $2 and $3 and verify that it matches the number of
# SIDs passed in $1
num_archive_dirs=$(echo "$2" | awk -F ',' '{print NF}')
num_backup_dirs=$(echo "$3" | awk -F ',' '{print NF}')
if [ "$num_archive_dirs" -ne "$num_sids" ] || [ "$num_backup_dirs" -ne "$num_sids" ]; then
    echo "Error: invalid input"
    echo "Number of archive directories and backup directories passed must equal the number of SIDs passed"
    exit 1
fi

# Define arrays for SIDs, archive directories, and backup directories by replacing commas
# with spaces using Bash array reads; here-strings (<<<) feed the CSV values into read
# A here-string is a way to send data directly to the stdin of the command
# This allows you to transform `echo "$1" | cmd` to `cmd <<< "$1"`. 
IFS=, read -r -a SIDs <<< "$1"
IFS=, read -r -a archive_dirs <<< "$2"
IFS=, read -r -a backup_dirs <<< "$3"

# Remove trailing slash from directory input parameters using parameter expansion
# - "${archive_dirs[@]}" expands each array element as a separate word (no word-splitting inside elements)
# - %/ trims the shortest matching suffix "/" from each element (no-op if it already lacks a slash)
# - (...) captures the results back into an array so indexes stay aligned
archive_dirs=("${archive_dirs[@]%/}")
backup_dirs=("${backup_dirs[@]%/}")

# Source the logging library
source "$HOME/common/general/Logging.sh"
if [ $? -ne 0 ]; then
    echo "An error occurred while sourcing the logging library. Exiting..."
    exit 1
fi

# Save stdout and stderr to a timestamped log file
log_timestamp=$(date "+%Y-%m-%d_%H-%M-%S")
all_log="/tmp/AddBackInReadOnlyTablespaces_${log_timestamp}.log"
touch "$all_log"
# This will set up logging so that all output goes both to the all_log file and to the terminal 
# until close_logs or a different set_*_logging function is called 
set_general_logging "$all_log"
if [ $? -ne 0 ]; then
    # Because logging is likely broken we pipe to tee to ensure this error summary still ends up in all_log
    echo "An error occurred while setting general logging for $all_log. Exiting..." | tee -a "$all_log"
    mailx -s "$HOSTNAME ERROR: AddBackInReadOnlyTablespaces.sh set_general_logging Failed" $ALL_DBA_EMAIL_LIST \
                <<< "An error occurred while setting general logging for $all_log. Exiting..."
    exit 1
fi

echo "All logs location: $all_log"
exit_status=0
sid_status=0
for ((i=0; i < num_sids; i++)); do
    if [ "$send_email" -ne 0 ] && [ "$sid_status" -ne 0 ]; then
        # Close the logging to the logging files before reading from it to prevent race conditions
        close_logs
        # Redirect the last SID log into the email body ($all_log if that SID's log could not be set up)
        mailx -s "$sid_err_subject" $ALL_DBA_EMAIL_LIST < "$current_log"
        # Re-enable general logging to capture anything that happens between here and setting up for the next SID
        set_general_logging "$all_log"
        if [ $? -ne 0 ]; then
            # Because logging is likely broken we pipe to tee to ensure this error summary still ends up in all_log
            echo "An error occurred while setting general logging for $all_log. Continuing..." | tee -a "$all_log"
            mailx -s "$HOSTNAME $ORACLE_SID ERROR: AddBackInReadOnlyTablespaces.sh set_general_logging Failed" $ALL_DBA_EMAIL_LIST \
                <<< "An error occurred while setting general logging for $all_log. Continuing..."
        fi
        exit_status=1
    fi
    sid_status=0

    echo
    # Set the Oracle SID for this iteration
    export ORACLE_SID=${SIDs[i]}
    sid_err_subject="$HOSTNAME $ORACLE_SID ERROR: AddBackInReadOnlyTablespaces.sh SID Specific Error"

   
    current_log="/tmp/AddBackInReadOnlyTablespaces_${log_timestamp}_${ORACLE_SID}.log"
    touch "$current_log"
    if [ $? -ne 0 ]; then
        echo "An error occurred while creating $current_log. Continuing..."
        sid_status=1
        exit_status=1
        sid_err_subject="$HOSTNAME $ORACLE_SID ERROR: AddBackInReadOnlyTablespaces.sh Creating $current_log Failed"
        # $current_log does not exist, so the SID error email reads its body from $all_log, which has the error above.
        current_log="$all_log"
        continue
    fi

    # Begin logging to both $all_log and $current_log
    set_sid_and_general_logging "$all_log" "$current_log"
    if [ $? -ne 0 ]; then
        # Because logging is likely broken we pipe to tee to ensure this error summary still ends up in all_log
        echo "An error occurred while setting sid and general logging for $ORACLE_SID for logs $all_log and $current_log. Continuing..."  | tee -a "$all_log"
        sid_status=1
        exit_status=1
        sid_err_subject="$HOSTNAME $ORACLE_SID ERROR: AddBackInReadOnlyTablespaces.sh set_sid_and_general_logging Failed"
        # Nothing was logged to $current_log, so the SID error email reads its body from $all_log, which has the error above.
        current_log="$all_log"
        continue
    fi

    echo "Log location for $ORACLE_SID: $current_log"

    # Verify SID
    # Capture helper output in a variable so we can inspect status text
    sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I "${ORACLE_SID}")
    if [ -n "$sid_check" ]; then
        if [ "$sid_check" == "-1" ]; then
            echo "Error, \$ORACLE_SID not set..."
            sid_status=1
            exit_status=1
            sid_err_subject="$HOSTNAME $ORACLE_SID ERROR: AddBackInReadOnlyTablespaces.sh ORACLE_SID Not Set"
            continue
        fi

        echo "Error, provided ORACLE_SID is not open. Exiting..."
        sid_status=1
        exit_status=1
        sid_err_subject="$HOSTNAME $ORACLE_SID ERROR: AddBackInReadOnlyTablespaces.sh DB Not Open"
        continue
    fi

    # Copy RMANOnlineREADonlyTablespaces.sh script to /tmp and add execute permission to avoid 
    # permission denied errors
    mkdir -p /tmp/"${ORACLE_SID}" # Make subdirectory in /tmp if it does not exist
    if [ $? -ne 0 ]; then
        echo "Error occurred while attempting to make subdirectory /tmp/${ORACLE_SID} Continuing..."
        sid_status=1
        exit_status=1
        sid_err_subject="$HOSTNAME $ORACLE_SID ERROR: AddBackInReadOnlyTablespaces.sh Could Not Create /tmp/$ORACLE_SID"
        continue
    fi
    
    # Ensure that RMANOnlineREADonlyTablespaces.sh exists in correct location
    # The ^^ expansion uppercases ORACLE_SID to match directory naming
    if ! [ -f "${backup_dirs[i]}/${ORACLE_SID^^}/scripts/${ORACLE_SID^^}/RMANOnlineREADonlyTablespaces.sh" ]; then
        echo "ERROR: File ${backup_dirs[i]}/${ORACLE_SID^^}/scripts/${ORACLE_SID^^}/RMANOnlineREADonlyTablespaces.sh could not be found. Continuing..."
        sid_status=1
        exit_status=1
        sid_err_subject="$HOSTNAME $ORACLE_SID ERROR: AddBackInReadOnlyTablespaces.sh RMANOnlineREADonlyTablespaces.sh Not Found"
        continue
    fi

    cp "${backup_dirs[i]}/${ORACLE_SID^^}/scripts/${ORACLE_SID^^}/RMANOnlineREADonlyTablespaces.sh" "/tmp/${ORACLE_SID}"
    if [ $? -ne 0 ]; then
        echo "Error occurred while attempting to copy ${backup_dirs[i]}/${ORACLE_SID^^}/scripts/${ORACLE_SID^^}/RMANOnlineREADonlyTablespaces.sh to /tmp/${ORACLE_SID}. Continuing..."
        sid_status=1
        exit_status=1
        sid_err_subject="$HOSTNAME $ORACLE_SID ERROR: AddBackInReadOnlyTablespaces.sh Could Not Copy RMANOnlineREADonlyTablespaces.sh To /tmp/${ORACLE_SID}"
        continue
    fi

    chmod 755 "/tmp/${ORACLE_SID}/RMANOnlineREADonlyTablespaces.sh"

    # Collect lines with the statement ALTER DATABASE RENAME FILE within RMANOnlineREADonlyTablespaces.sh
    # and extract the new filepath with modifications made for proper formatting
    # - grep filters only the rename statements
    # - awk strips quotes/semicolon and prints the new file path (field after " to ")
    # - sed substitutes the RMAN \${1} placeholder and trims whitespace
    new_filenames=$(grep "ALTER DATABASE RENAME FILE" "/tmp/${ORACLE_SID}/RMANOnlineREADonlyTablespaces.sh" | awk -F " to " '{gsub(/'\''|;/, "", $2); print $2}' | sed "s|\${1}|${archive_dirs[i]}/${ORACLE_SID^^}_READONLY|" | sed 's/^[ \t]*//' | sed 's/[ \t]*$//')
    # Gather all data files on the SID
    all_data_files=$("$HOME/common/oracle/PrintAllDataFiles.sh" "$ORACLE_SID")
    # Error check
    if [ $? -ne 0 ]; then
        echo "$all_data_files"
        echo "Error occurred in PrintAllDataFiles.sh helper script. Continuing..."
        sid_status=1
        exit_status=1
        sid_err_subject="$HOSTNAME $ORACLE_SID ERROR: AddBackInReadOnlyTablespaces.sh PrintAllDataFiles.sh Failed"
        continue
    fi

    # IFS (Internal Field Separator) in Bash determines how strings are split into words, defaulting to whitespace characters (space, tab, newline).
    IFS=$'\n'
    # Loop over statements in RMANOnlineREADonlyTablespaces.sh file to check if they have already been added back
    data_file_not_found_by_oracle=false
    data_file_not_found_on_system=false
    missing_files=()
    for line in $new_filenames; do
        # Check result of PrintAllDataFiles.sh to determine if database is already aware of file (grep each line for existence within helper output)
        # -F tells grep to interpret the input as a fixed string rather than regex
        # -x tells grep to only count full line matches
        if ! echo "$all_data_files" | grep -Fxq "$line"; then
            data_file_not_found_by_oracle=true
        fi

        # Check for the existence of the path 
        if ! [ -e "$line" ]; then
            data_file_not_found_on_system=true
            missing_files+=("$line")
        fi
    done
    unset IFS

    if [ "$data_file_not_found_by_oracle" == "false" ] && [ "$data_file_not_found_on_system" == "false" ]; then
        echo "All read only tablespaces are already part of database SID $ORACLE_SID, bringing read only tablespaces online..."
        # Since all read only tablespaces are already part of the database, there is no need to try to rename them to their current names
        # The only thing that needs to be done is to bring the tablespaces online with 'ALTER TABLESPACE <tablespace_name> ONLINE;'
        # Removing lines that rename tablespaces in RMANOnlineREADonlyTablespaces.sh
        sed -i '/ALTER DATABASE RENAME FILE/d' "/tmp/${ORACLE_SID}/RMANOnlineREADonlyTablespaces.sh"
    fi

    if [ "$data_file_not_found_on_system" == "true" ]; then
        echo "The following datafiles in RMANOnlineREADonlyTablespaces.sh do not exist:"
        printf '%s\n' "${missing_files[@]}"
        sid_status=1
        exit_status=1
        sid_err_subject="$HOSTNAME $ORACLE_SID ERROR: AddBackInReadOnlyTablespaces.sh One Or More Datafiles Oracle Is Expecting Are Missing On Disk"
        echo "Continuing..."
        continue
    fi
    
    # Restore read only tablespaces
    echo "Restoring read-only tablespaces for database $ORACLE_SID..."
    restore_read_only=$("/tmp/${ORACLE_SID}/RMANOnlineREADonlyTablespaces.sh" "${archive_dirs[i]}/${ORACLE_SID^^}_READONLY")
    bash_error=$?
    # Capture up to 10 ORA- errors from the RMAN output
    SQL_errors=$(echo "$restore_read_only" | grep "ORA-" -m 10)
    if [ "$bash_error" -ne 0 ]; then
        echo "RMANOnlineREADonlyTablespaces.sh failed for database $ORACLE_SID"
        echo "Full RMANOnlineREADonlyTablespaces.sh output:"
        echo "$restore_read_only"
        echo "Continuing...."
        sid_status=1
        exit_status=1
        sid_err_subject="$HOSTNAME $ORACLE_SID ERROR: AddBackInReadOnlyTablespaces.sh RMANOnlineREADonlyTablespaces.sh Failed"
        continue
    elif [ -n "$SQL_errors" ]; then
        echo "RMANOnlineREADonlyTablespaces.sh failed for database $ORACLE_SID"
        echo "Full RMANOnlineREADonlyTablespaces.sh output:"
        echo "$restore_read_only"
        echo "First ten SQL errors from RMANOnlineREADonlyTablespaces.sh:"
        echo "$SQL_errors"
        echo "Continuing..."
        sid_status=1
        exit_status=1
        sid_err_subject="$HOSTNAME $ORACLE_SID ERROR: AddBackInReadOnlyTablespaces.sh RMANOnlineREADonlyTablespaces.sh Failed"
        continue
    else
        echo "Read-only tablespace restore for database $ORACLE_SID successful"
    fi

    # Remove helper script from /tmp
    rm -f "/tmp/${ORACLE_SID}/RMANOnlineREADonlyTablespaces.sh"
done
# Send an individual error email if the last SID in the loop failed
if [ "$send_email" -ne 0 ] && [ "$sid_status" -ne 0 ]; then
    # Close the logging to the logging files before reading from it to prevent race conditions
    close_logs
    # Redirect the last SID log into the email body ($all_log if that SID's log could not be set up)
    mailx -s "$sid_err_subject" $ALL_DBA_EMAIL_LIST < "$current_log"
    # Reopen general logging to capture the rest of the script output
    set_general_logging "$all_log"
    if [ $? -ne 0 ]; then
        # We don't hard error and exit here because the logging is not essential and we still want the final script logic to complete
        # Because logging is likely broken we pipe to tee to ensure this error summary still ends up in all_log
        echo "An error occurred while setting general logging for $all_log. Continuing..." | tee -a "$all_log"
        mailx -s "$HOSTNAME $ORACLE_SID ERROR: AddBackInReadOnlyTablespaces.sh set_general_logging Failed" $ALL_DBA_EMAIL_LIST \
                <<< "An error occurred while setting general logging for $all_log. Continuing..."
    fi
fi

if [ "$exit_status" -eq 0 ]; then
    echo "Script completed successfully."
    if [ "$send_email" -eq 1 ]; then
        echo "Read-only tablespaces have been successfully added to the following database(s): ${SIDs[*]}"
        # Close the logging to the logging files before reading from it to prevent race conditions
        close_logs
        # Redirect the aggregated log into the email body
        mailx -s "$HOSTNAME SUCCESS: AddBackInReadOnlyTablespaces.sh " $ALL_DBA_EMAIL_LIST < "$all_log"
    fi

    exit 0
else
    echo "Script had one or more errors."
    if [ "$send_email" -eq 1 ]; then
        # Close the logging to the logging files before reading from it to prevent race conditions
        close_logs
        # Redirect the aggregated log into the email body
        mailx -s "$HOSTNAME ERROR: AddBackInReadOnlyTablespaces.sh " $ALL_DBA_EMAIL_LIST < "$all_log"
    fi

    exit 1
fi
