#!/usr/bin/env bash
# AvailabilityFlag: Public
#
# Purpose: This script is meant to push/pull files to and from remote locations.
#
# Note: Using a trailing slash e.g. "/remote/path/to/dir/" will transfer the CONTENTS of the directory.
#       Not using a trailing slash e.g. "/remote/path/to/dir" will transfer the directory itself.
#
#####################################################################################
usage="Usage: scp_script.sh [ -s (optional, suppress email output) ] [ -i <days_to_keep> (optional, skip pulling files older than given # of days) ] [ -o (optional, only works with pull and -i, override scp and use rsync) ] [ pull | push ] [ remote location ] [ local location ]"
example="Example: scp_script.sh push MY_USER@MY_SERVER:MY_DIR MY_LOCAL/DIR
Example 2: scp_script.sh pull MY_USER@MY_SERVER:MY_DIR MY_LOCAL/DIR"

# Validates remote and local destination paths
check_src_and_dest() {
    local mode=$1               # "push" or "pull"
    local remote_full=$2        # e.g. MY_USER@MY_SERVER:MY_DIR
    local local_path=$3         # e.g. MY_LOCAL/DIR

    # Parse user, host, and remote path
    local user=${remote_full%@*}                # part before '@'
    local host_and_path=${remote_full#*@}       # part after '@'
    local host=${host_and_path%%:*}             # part before ':'
    local remote_path=${host_and_path#*:}       # part after ':'


    if [[ "$mode" == "pull" ]]; then
        local src="$remote_path"
        local dest="$local_path"

        remote_type=$(ssh -q "$user@$host" "if [ -d '$src' ]; then echo dir; elif [ -f '$src' ]; then echo file; else echo none; fi")

        if [[ "$remote_type" == "none" ]]; then
            echo "Error, Remote path '$src' does not exist"
            return 1
        elif [ ! -e "$dest" ]; then
            mkdir "$dest"
        elif [[ "$remote_type" == "dir" ]] && [ -f "$dest" ]; then
            echo "Error, Remote location is a directory but local destination is a file"
            return 1
        fi
    else
        local dest="$remote_path"
        local src="$local_path"

        remote_type=$(ssh -q "$user@$host" "if [ -d '$dest' ]; then echo dir; elif [ -f '$dest' ]; then echo file; else echo none; fi")

        if [ ! -e "$src" ]; then
            echo "Error, Local path '$src' does not exist"
            return 1
        elif [ -d "$src" ] && [[ "$remote_type" == "file" ]]; then
            echo "Error, Local location is a directory but remote destination is a file"
            return 1
        elif [[ "$remote_type" == "none" ]]; then
            ssh -q "$user@$host" "mkdir -p '$dest'"
        fi
    fi

    return 0
}

# Convert seconds to HH:MM:SS
convert_seconds_to_hms() {
    local total_seconds=$1

    # Use bc and floor the result
    local hours=$(echo "$total_seconds / 3600" | bc)
    local minutes=$(echo "($total_seconds % 3600) / 60" | bc)
    local seconds=$(echo "$total_seconds - ($hours * 3600) - ($minutes * 60)" | bc)

    # Truncate decimal part of seconds
    local seconds_int=$(echo "$seconds" | cut -d'.' -f1)

    printf "%02d:%02d:%02d" "$hours" "$minutes" "$seconds_int"
}


# Process input options
sopt=0
iopt=0
oopt=0
while getopts ":hsoi:" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    s)
        sopt=1
        ;;
    o)
        oopt=1
        ;;
    i)
        iopt=1
        if [[ -z "$OPTARG" || ! "$OPTARG" =~ ^[0-9]+$ ]]; then
            echo "Error: -i requires a positive integer argument. Exiting..."
            exit 1
        fi
        del_age=$OPTARG
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done
shift $((OPTIND - 1))

# Check arguments
if [ $# -ne 3 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Set input variables
push_or_pull=$1
remote=$2
local=$3

current_timestamp=$(date "+%Y-%m-%d_%H-%M-%S")
LOGFILE="/tmp/scp_output_$current_timestamp.log"
touch "$LOGFILE"

if [[ "$push_or_pull" == "push" ]] && { [ $iopt -eq 1 ] || [ $oopt -eq 1 ] ;}; then
    echo "The push method is not valid with -i or -o. Exiting..."
    echo "$usage"
    exit 1
fi
if [ $oopt -eq 1 ] && [ $iopt -ne 1 ]; then
    echo "The -o flag can only be used with the -i flag. Exiting..."
    echo "$usage"
    exit 1
fi

pre_timestamp=$(date "+%Y-%m-%d %H:%M:%S")
echo "scp_script.sh $push_or_pull $remote $local started at $pre_timestamp"
echo "Log location: $LOGFILE"

user=$(echo "$remote" | cut -d'@' -f1)
host=$(echo "$remote" | cut -d'@' -f2 | cut -d':' -f1)
ssh_test=$("$HOME/common/general/TestSSHKey.sh" "$user" "$host")
if [ $? -ne 0 ]; then
    echo "$ssh_test"
    echo "Error, unable to connect to ${user}@${host}. Continuing..."
    echo
    exit 1
fi

# Ensure first arg is valid
if [ "${push_or_pull}" == "push" ]; then

    location_check=$(check_src_and_dest "$push_or_pull" "$remote" "$local" 2>&1)
    if [ $? -ne 0 ]; then
        echo "$location_check"
        echo "Exiting..."
        exit 1
    fi

    if [ $iopt -eq 1 ]; then
        echo "Error the -i option can only be used when pulling files. Exiting..."
        exit 1
    fi

    echo "Using scp."
    scp -prv "$local" "$remote" > "$LOGFILE" 2>&1
    exit_code=$?
elif [ "${push_or_pull}" == "pull" ]; then
    location_check=$(check_src_and_dest "$push_or_pull" "$remote" "$local" 2>&1)
    if [ $? -ne 0 ]; then
        echo "$location_check"
        echo "Exiting..."
        exit 1
    fi

    remote_path=$(echo "$remote" | cut -d: -f2)
    if [ $iopt -eq 1 ]; then
        # Remove trailing slash from remote_path if present
        remote_path=$(echo "$remote_path" | sed 's#/$##')

        # Get parent directory of remote_path
        remote_parent=$(dirname "$remote_path")

        # Find files modified in given time range
        file_list=$(ssh -q "$user@$host" "find '$remote_path' -type f -mtime -$del_age")

        if [ -z "$file_list" ]; then
            echo "No files younger than $del_age days found. Exiting..."
            exit 0
        fi

        # Escape parent directory path for sed
        escaped_remote_parent=$(echo "$remote_parent" | sed -e 's/[]\/$*.^|[]/\\&/g')

        # Create temp file with relative paths to parent directory (includes top folder)
        temp_file_list=$(mktemp)
        echo "$file_list" | sed "s#^$escaped_remote_parent/##" > "$temp_file_list"
        
        if [ $oopt -eq 0 ]; then
            total_received_bytes=0
            failed_file_count=0
            scp_loop_start=$(date +%s)

            echo "Using scp to download each file younger than $del_age days individually."

            while IFS= read -r rel_path; do
                local_target_dir="$local/$(dirname "$rel_path")"
                mkdir -p "$local_target_dir"
                if [ $? -ne 0 ]; then
                    echo "Error: Failed to create local directory '$local_target_dir'." >> "$LOGFILE"
                    failed_file_count=$((failed_file_count + 1))
                    continue
                fi

                remote_file_path="$remote_parent/$rel_path"
                remote_spec="$user@$host:'$remote_file_path'"

                scp -prv "$remote_spec" "$local_target_dir/" >> "$LOGFILE" 2>&1
                if [ $? -ne 0 ]; then
                    echo "An error occurred while trying to copy $remote_spec to $local_target_dir. Continuing..."
                    failed_file_count=$((failed_file_count + 1))
                    continue
                fi

                copied_file="$local/$rel_path"
                copied_size=$(stat -c%s "$copied_file" 2>/dev/null)
                if [[ "$copied_size" =~ ^[0-9]+$ ]]; then
                    total_received_bytes=$((total_received_bytes + copied_size))
                fi
            done < "$temp_file_list"

            scp_loop_end=$(date +%s)
            scp_loop_elapsed=$((scp_loop_end - scp_loop_start))
            echo "Transferred: sent 0 bytes, received $total_received_bytes bytes, in $scp_loop_elapsed seconds" >> "$LOGFILE"

            if [ $failed_file_count -ne 0 ]; then
                echo "Error: $failed_file_count file(s) failed during SCP override transfer." >> "$LOGFILE"
                rm -f "$temp_file_list"
                exit_code=1
            else
                exit_code=0
            fi
        else
            echo "Using rsync to sync files newer than $del_age days."
            # Rsync from remote parent dir with trailing slash, pulling relative paths including top folder
            rsync -avz --progress --files-from="$temp_file_list" "$user@$host:$remote_parent/" "$local/" > "$LOGFILE" 2>&1
            exit_code=$?
        fi

        # Clean up
        rm -f "$temp_file_list"
    else
        echo "Using scp to bulk copy all files."
        scp -prv "$remote" "$local" > "$LOGFILE" 2>&1
        exit_code=$?
        # Reset local perms after pull
        chmod -R a+rw "$local"
    fi
else
    echo "First argument must be 'push' or 'pull'"
    echo "$example"
    exit 1
fi

# Split remote on colon
remote_file_name=$(echo "$remote" | sed 's#^[^:]*:##')

# Check for "No such file or directory" errors
# Find the first occurrence of the error, the output will have the error and 10 lines before/after the error
not_found_error=$(grep -A10 -B10 -m 1 "$remote_file_name: No such file or directory" "$LOGFILE")
if [ -n "$not_found_error" ]; then
    # the tr command deletes (-d) all characters other than printable characters and newline.
    parsed_not_found_error=$(echo "$not_found_error" | tr -cd '[:print:]\n')
    echo -e "\nError: SCP failed, file/directory not found on remote machine.\n\n$parsed_not_found_error\n\nExiting..."
    if [ "$sopt" -eq 0 ]; then
        # Email the DBA list; echo -e so '\n' in the email body renders as line breaks
        echo -e "Error: SCP failed, file/directory not found on remote machine\n\n$parsed_not_found_error" | mailx -s "$HOSTNAME ERROR: scp_script.sh $push_or_pull $remote $local FAILED" $ALL_DBA_EMAIL_LIST
    fi
    exit 1
fi

# Check for "Permission denied" errors
# Find the first occurrence of the error, the output will have the error and 10 lines before/after the error
permission_denied_error=$(grep -A10 -B10 -m 1 "Permission denied" "$LOGFILE")
if [ -n "$permission_denied_error" ]; then
    # the tr command deletes (-d) all characters other than printable characters and newline.
    parsed_permission_denied_error=$(echo "$permission_denied_error" | tr -cd '[:print:]\n')
    echo -e "\nError: SCP failed, permission denied.\n\n$parsed_permission_denied_error\n\nExiting..."
    if [ "$sopt" -eq 0 ]; then
        # Email the DBA list; echo -e so '\n' in the email body renders as line breaks
        echo -e "Error: SCP failed, permission denied\n\n$parsed_permission_denied_error" | mailx -s "$HOSTNAME ERROR: scp_script.sh $push_or_pull $remote $local FAILED" $ALL_DBA_EMAIL_LIST
    fi
    exit 1
fi

# Check for general errors
if [ "$exit_code" -ne 0 ]; then
    # tail command defaults to last 10 lines
    # the tr command deletes (-d) all characters other than printable and newline.
    unknown_error=$(tail "$LOGFILE" | tr -cd '[:print:]\n')
    echo -e "\nError: SCP failed with unknown error. See $LOGFILE for details.\n\n$unknown_error\n\nExiting..."
    if [ "$sopt" -eq 0 ]; then
        # Email the DBA list; echo -e so '\n' in the email body renders as line breaks
        echo -e "Unknown error occurred. See $LOGFILE for details.\n\n$unknown_error" | mailx -s "$HOSTNAME ERROR: scp_script.sh $push_or_pull $remote $local FAILED" $ALL_DBA_EMAIL_LIST
    fi
    exit 1
fi

post_timestamp=$(date "+%Y-%m-%d %H:%M:%S")
echo "scp_script.sh $push_or_pull $remote $local completed at $post_timestamp"

# Check if remote file(s) were created in local for pull option
if [ "${push_or_pull}" == "pull" ]; then
    if [ -d "$local" ]; then
        # Check if any files exist inside the directory
        file_count=$(find "$local" -type f | wc -l)
        if [ "$file_count" -eq 0 ]; then
            echo "Error: No new files were created in directory $local. Remote file(s) may not exist or were not pulled correctly. Exiting..."
            if [ "$sopt" -eq 0 ]; then
                # Email the DBA list; echo -e so '\n' in the email body renders as line breaks
                echo -e "scp_script.sh $push_or_pull $remote $local completed WITH ERROR.\n\nError: No new files were created in directory $local. Remote file(s) may not exist or were not pulled correctly." | mailx -s "$HOSTNAME scp_script.sh $push_or_pull $remote $local ERROR" $ALL_DBA_EMAIL_LIST
            fi
            exit 1
        fi
    elif [ -f "$local" ]; then
        # Check if the file exists and is not empty
        if [ ! -s "$local" ]; then
            echo "Error: File $local was created but is empty. Remote file may not exist or was not pulled correctly. Exiting..."
            if [ "$sopt" -eq 0 ]; then
                # Email the DBA list; echo -e so '\n' in the email body renders as line breaks
                echo -e "scp_script.sh $push_or_pull $remote $local completed WITH ERROR.\n\nError: File $local was created but is empty. Remote file may not exist or was not pulled correctly." | mailx -s "$HOSTNAME scp_script.sh $push_or_pull $remote $local ERROR" $ALL_DBA_EMAIL_LIST
            fi
            exit 1
        fi
    else
        echo "Error: $local does not exist after pull. Remote file(s) may not have been pulled correctly. Exiting..."
        if [ "$sopt" -eq 0 ]; then
            # Email the DBA list; echo -e so '\n' in the email body renders as line breaks
            echo -e "scp_script.sh $push_or_pull $remote $local completed WITH ERROR.\n\nError: $local does not exist after pull. Remote file(s) may not have been pulled correctly." | mailx -s "$HOSTNAME scp_script.sh $push_or_pull $remote $local ERROR" $ALL_DBA_EMAIL_LIST
        fi
        exit 1
    fi
fi


# Parse the log for statistics
# Grab "Transferred:" line first, fallback to rsync summary line if not found
transferred_line=$(tac "$LOGFILE" | grep -m 1 "^Transferred:" || true)

if [ -z "$transferred_line" ]; then
    # Fallback to rsync summary line like "sent 42,506 bytes  received 38,850,293 bytes ..."
    transferred_line=$(tac "$LOGFILE" | grep -m 1 -E "^sent [0-9,]+ bytes +received [0-9,]+ bytes" || true)
fi

if [ -z "$transferred_line" ]; then
    echo "Warning: could not parse byte counts from transfer summary:"
    echo "    Full transfer log: $LOGFILE"
    sent_bytes=0
    received_bytes=0
    elapsed_time=0
else
    # Parse sent / received bytes (tolerant of "sent N," , "sent N bytes", etc.)
    sent_bytes=$(echo "$transferred_line"     | grep -oE 'sent [0-9,]+'     | head -1 | tr -dc '0-9')
    received_bytes=$(echo "$transferred_line" | grep -oE 'received [0-9,]+' | head -1 | tr -dc '0-9')

    # If either count didn't parse, show the raw summary line and the log so the operator can read it directly.
    if ! [[ "$sent_bytes" =~ ^[0-9]+$ ]] || ! [[ "$received_bytes" =~ ^[0-9]+$ ]]; then
        echo "Warning: could not parse byte counts from transfer summary:"
        echo "    $transferred_line"
        echo "    Full transfer log: $LOGFILE"

        # If Variable is empty, then it gets set to 0
        [ -z "$sent_bytes" ]     && sent_bytes=0
        [ -z "$received_bytes" ] && received_bytes=0
    fi


    # Try to parse elapsed time from "Transferred:" line
    elapsed_time=$(echo "$transferred_line" | sed -n 's/.*in \([0-9.]*\) seconds.*/\1/p')

    # If elapsed_time is empty (likely rsync summary line), fallback to time difference
    if [ -z "$elapsed_time" ]; then
        start_seconds=$(date -d "$pre_timestamp" +%s 2>/dev/null || echo 0)
        end_seconds=$(date -d "$post_timestamp" +%s 2>/dev/null || echo 0)
        elapsed_time=$((end_seconds - start_seconds))
        # Convert to floating seconds for consistency
        elapsed_time=$(printf "%.1f" "$elapsed_time")
    fi
fi

elapsed_hms=$(convert_seconds_to_hms "$elapsed_time")

# Calling ConvertBytes.sh to convert sent_bytes and received_bytes to human readable byte format (units converted into: "B","KB","MB","GB","TB","PB").
# The transfer has already succeeded, so if the helper fails the script warns, shows the byte count instead and carries on.
sent_readable=$("$HOME/common/general/ConvertBytes.sh" -d "$sent_bytes")
if [ $? -ne 0 ]; then
    echo "Warning: Could not compute the readable sent size with $HOME/common/general/ConvertBytes.sh -d $sent_bytes, so only the byte count is shown. Helper output: $sent_readable"
    sent_readable="$sent_bytes bytes"
fi

received_readable=$("$HOME/common/general/ConvertBytes.sh" -d "$received_bytes")
if [ $? -ne 0 ]; then
    echo "Warning: Could not compute the readable received size with $HOME/common/general/ConvertBytes.sh -d $received_bytes, so only the byte count is shown. Helper output: $received_readable"
    received_readable="$received_bytes bytes"
fi

# PullExternalBackups.sh adds up the exact byte counts in parentheses, since the readable amounts keep only two decimal places
transferred="Transferred: sent $sent_readable ($sent_bytes bytes), received $received_readable ($received_bytes bytes), in $elapsed_hms (raw: $elapsed_time seconds)"
echo "$transferred"

if [ "$sopt" -eq 0 ]; then
    # Email the DBA list; echo -e so '\n' in the email body renders as line breaks
    echo -e "scp_script.sh $push_or_pull $remote $local completed successfully.\n\n$transferred" | mailx -s "$HOSTNAME scp_script.sh $push_or_pull $remote $local completed successfully" $ALL_DBA_EMAIL_LIST
fi