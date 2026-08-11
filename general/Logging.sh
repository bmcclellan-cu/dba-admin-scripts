#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script is meant to be sourced by other scripts in the repository
#          in order to handle some basic file + terminal logging use cases with just
#          a few function calls. 
#
# Note: Exits in sourced programs will terminate the program that sourced it/ran the functions from the sourced file.
#
# Note: If you provide a filter that does not read to EOF it will terminate after it's first run. 
#       Commands that read to EOF: cat, grep, sed, etc.
#       Commands that don't read to EOF: head, tail, etc.
#
# Usage Essentials:
#                   1. Before using any of the functions, source the file: `source $HOME/common/general/Logging.sh`.
#                   2. Before reading from the log files you supply to the set_* functions you should always run `close_logs` to prevent any race conditions. 
#                   3. Use set_sid_and_general_logging when you want different log files for each iteration of a loop
#                   4. You can call the 'set logging' functions as many times as you want. Each call blows away the previous configuration and starts from the original state of the program when it was sourced. 
#                   5. As a user who has sourced this script you should never alter the LOGGING_GENERAL_FIFO, LOGGING_FILTER_FIFO, LOGGING_GENERAL_LOG, or LOGGING_SID_LOG global variables as these are important to the functionality of this script. 
# Usage Example: `
#                 source $HOME/common/general/Logging.sh
#                 general_log_file="/tmp/MyScript.log"
#                 set_general_logging "$general_log_file"
#                 if [ $? -ne 0 ]; then
#                       echo "An error occurred while using set_general_logging on $general_log_file. Exiting..."
#                       exit 1
#                 fi
#                 ... do some stuff
#                 for SID in $SIDLIST; do 
#                     sid_log_file="/tmp/MyScript_$SID.log"
#                     set_sid_and_general_logging "$general_log_file" "$sid_log_file"
#                     if [ $? -ne 0 ]; then
#                        echo "An error occurred while using set_sid_and_general_logging on $general_log_file and $sid_log_file. Exiting..."
#                        exit 1
#                     fi
#                     .... do some sid specific stuff
#                     if [ $? -ne 0 ]; then
#                         echo "$suppressed_output"
#                         # close_logs to ensure nothing is still writing to "$sid_log_file" when we use it in mailx
#                         close_logs
#                         mailx -s "MyScript.sh Failed for $SID" "$ALL_DBA_EMAIL_LIST" < "$sid_log_file"
#                         continue
#                     fi
#                 done 
#                 set_general_logging "$general_log_file"
#                 if [ $? -ne 0 ]; then
#                       echo "An error occurred while using set_general_logging on $general_log_file. Exiting..."
#                       exit 1
#                 fi
#                 ... do some cleanup/validation
#                 close_logs
#                 mailx -s "MyScript.sh Completed" "$ALL_DBA_EMAIL_LIST" < "$general_log_file"
#                 exit 0
#               `
#
################################################################################
# Save stdout and stderr to fd 3,4 so we can reset the state using restore_stdout_stderr
exec 3>&1
exec 4>&2
# Internal globals for cleaning up and preventing race conditions by waiting on the PIDs in close_logs
# All the globals are prepended with LOGGING to create something similar to a namespace to reduce likelihood a user overwrites the variable in their own script. 
LOGGING_FILTER_FIFO=""
LOGGING_GENERAL_FIFO=""
LOGGING_GENERAL_PID=""
LOGGING_FILTER_PID=""
LOGGING_GENERAL_LOG=""
LOGGING_SID_LOG=""

# Purpose: Log all stdout and stderr output to both a file and a terminal.
# Inputs:
#   1: General log location that will be created if it doesn't exist.
set_general_logging() {
    # Ensure any previous logging is completed and file descriptors are reset before configuring anything.
    close_logs

    # Ensure the user provided a general log file path then create the general log file if it doesn't exist.
    local general_log=$1
    if [ -z "$general_log" ]; then
        echo "ERROR function set_general_logging expects a path to the general log as its first parameter. Exiting..."
        close_logs
        return 1
    else
        touch "$general_log" 
        if [ $? -ne 0 ]; then
            echo "An error occurred while creating general log $general_log. Exiting..."
            close_logs
            return 1
        fi
    fi
    LOGGING_GENERAL_LOG="$general_log"

    # Create a fifo pipe that tee will read from and the programs stdout and stderr will write to
    LOGGING_GENERAL_FIFO=$(mktemp -u)
    if [ $? -ne 0 ]; then
        echo "An error occurred while generating tmp file name. Exiting..."
        close_logs
        return 1
    fi
    mkfifo "$LOGGING_GENERAL_FIFO"
    if [ $? -ne 0 ]; then
        echo "An error occurred while creating the general FIFO $LOGGING_GENERAL_FIFO. Exiting..."
        close_logs
        return 1
    fi

    # Create a background tee process that reads from the fifo pipe (& at the end)
    # and writes to the LOGGING_GENERAL_LOG and stdout which we redirect to fd 3.
    # We redirect stdout to fd 3 because we previously saved fd 3 as the terminal output
    # at the beginning of the script using exec 3>&1.
    # This causes anything that writes to the pipe (LOGGING_GENERAL_FIFO) to be written to the terminal and the LOGGING_GENERAL_LOG file.
    tee -a "$LOGGING_GENERAL_LOG" < "$LOGGING_GENERAL_FIFO" >&3 2>&1 &
    # We capture the general tee's process ID for later use in close_logs to avoid race conditions. 
    # We wait on this PID to ensure all data the general tee is processing has been written to the file before we read from it or do other operations like re-configuring the logging. 
    LOGGING_GENERAL_PID=$!
    # Redirect script stdout and stderr to write to the FIFO
    exec > "$LOGGING_GENERAL_FIFO" 2>&1
}

# Purpose: Log all stdout and stderr output to a general log and a sid specific log along with the terminal.
#          The sid specific log can optionally have a command that accepts input from stdin as a filter. 
# Inputs:
#    1: General log file path that will be created if it does not exist. 
#    2: Sid specific log file path that will be created if it does not exist.
#    3 (optional): Filter/preprocessing. A command that accepts input from stdin for the log output to be run through first before ending up in the sid specific log file.
#                  Ex: `grep -A3 -B3 'not found'`
#                  Defaults to having no filter and passing all program output to the sid specific log file
set_sid_and_general_logging() {
    # Ensure any previous logging is completed and file descriptors are reset before configuring anything.
    close_logs

    # Ensure the user provided a log file path for general logs then create the general log file if it doesn't exist.
    local general_log=$1
    if [ -z "$general_log" ]; then
        echo "ERROR function set_sid_and_general_logging expects a path to the general log as its first parameter. Exiting..."
        close_logs
        return 1
    else
        touch "$general_log" 
        if [ $? -ne 0 ]; then
            echo "An error occurred while creating general log $general_log. Exiting..."
            close_logs
            return 1
        fi
    fi
    LOGGING_GENERAL_LOG="$general_log"

    # Ensure the user provided a log file path for sid logs then create the sid log file if it doesn't exist.
    local sid_log=$2
    if [ -z "$sid_log" ]; then
        echo "ERROR function set_sid_and_general_logging expects a path to the sid specific log as its second parameter. Exiting..."
        close_logs
        return 1
    else
        touch "$sid_log"
        if [ $? -ne 0 ]; then
            echo "An error occurred while creating sid log $sid_log. Exiting..."
            close_logs
            return 1
        fi
    fi
    LOGGING_SID_LOG="$sid_log"

    # Setup functionality to have arbitrary bash programs alter which logs are output to the SID specific log
    # The primary use case for this is to filter logs with grep. Ex: `grep -A3 -B3 'not found'`
    local sid_filter=$3
    if [ -n "$sid_filter" ]; then
        # mktemp -u just gives us a valid tmp file name that we then use to actually create the fifo/pipe which is actually a file on disk
        LOGGING_FILTER_FIFO=$(mktemp -u)
        if [ $? -ne 0 ]; then
            echo "An error occurred while generating tmp file name. Exiting..."
            close_logs
            return 1
        fi
        # Initialize a new FIFO that we can have the filter read from 
        mkfifo "$LOGGING_FILTER_FIFO"
        if [ $? -ne 0 ]; then
            echo "An error occurred while creating the filter FIFO $LOGGING_FILTER_FIFO. Exiting..."
            close_logs
            return 1
        fi

        # Setup the logging sid filter fifo
        # We use a fifo here because it is a file that tee can write to later
        # We use 'eval' to execute an arbitrary filter that the user chooses and can be any bash program that gets input via stdin
        # The filter reads from this fifo in the background (< "$LOGGING_FILTER_FIFO"). This fifo is written to by tee. 
        # The filters output is redirected and written to LOGGING_SID_LOG file (>> "$LOGGING_SID_LOG" 2>&1) meaning the filtered logs get appended to the sid specific log file.
        eval "$sid_filter" < "$LOGGING_FILTER_FIFO" >> "$LOGGING_SID_LOG" 2>&1 &
        # We capture the filters process ID for later use in close_logs to avoid race conditions. 
        # We wait on this PID to ensure all data the filter is processing has been written to the file before we read from it or do other operations like re-configuring the logging. 
        LOGGING_FILTER_PID=$!
    fi

    # mktemp -u just gives us a valid tmp file name that we then use to actually create the fifo/pipe which is actually a file on disk
    LOGGING_GENERAL_FIFO=$(mktemp -u)
    if [ $? -ne 0 ]; then
        echo "An error occurred while generating tmp file name. Exiting..."
        close_logs
        return 1
    fi
    # Create a fifo pipe that tee will read from and the programs stdout and stderr will write to
    mkfifo "$LOGGING_GENERAL_FIFO"
    if [ $? -ne 0 ]; then
        echo "An error occurred while creating the general FIFO $LOGGING_GENERAL_FIFO. Exiting..."
        close_logs
        return 1
    fi

    # Depending on whether a sid specific logging filter is configured, tee to different files (FIFOs are just files on disk)
    if [ -n "$LOGGING_FILTER_FIFO" ]; then
        # High level: Outputs the logs sent to LOGGING_GENERAL_FIFO to LOGGING_GENERAL_LOG, LOGGING_FILTER_FIFO, and the terminal.
        #             LOGGING_GENERAL_FIFO is setup later in this script to capture all of the programs output to stdout and stderr 
        #             so all program output to stdout and stderr ends up in LOGGING_GENERAL_LOG, LOGGING_FILTER_FIFO (which applies a filter and then writes to the LOGGING_SID_LOG as configured earlier in the script), and the terminal.
        #
        # Specifics: This creates a background tee process that reads from the fifo pipe (< "$LOGGING_GENERAL_FIFO")
        #            and writes to three places. Tee writes to a set of files in addition to stdout. Here we tell tee to write
        #            to the files LOGGING_GENERAL_LOG and LOGGING_FILTER_FIFO (which applies a filter then writes to the LOGGING_SID_LOG as configured earlier in the script). We also tell tee to send its stdout and stderr to file descriptor 3 (>&3 2>&1).
        #            When Logging.sh is sourced we saved the terminal stdout to file descriptor 3 (exec 3>&1). 
        #            This results in the data tee reads from the pipe (LOGGING_GENERAL_FIFO) being output to LOGGING_GENERAL_LOG, LOGGING_SID_LOG, and the terminal.
        tee -a "$LOGGING_GENERAL_LOG" "$LOGGING_FILTER_FIFO" < "$LOGGING_GENERAL_FIFO" >&3 2>&1 &
    else
        # High level: Outputs the logs sent to LOGGING_GENERAL_FIFO to LOGGING_GENERAL_LOG, LOGGING_SID_LOG, and the terminal.
        #             LOGGING_GENERAL_FIFO is setup later in this script to capture all of the programs output to stdout and stderr 
        #             so all program output to stdout and stderr ends up in LOGGING_GENERAL_LOG, LOGGING_SID_LOG, and the terminal.
        #
        # Specifics: This creates a background tee process that reads from the fifo pipe (< "$LOGGING_GENERAL_FIFO")
        #            and writes to three places. Tee writes to a set of files in addition to stdout. Here we tell tee to write
        #            to the files LOGGING_GENERAL_LOG and LOGGING_SID_LOG. We also tell tee to send its stdout and stderr to file descriptor 3 (>&3 2>&1).
        #            When Logging.sh is sourced we saved the terminal stdout to file descriptor 3 (exec 3>&1). 
        #            This results in the data tee reads from the pipe (LOGGING_GENERAL_FIFO) being output to LOGGING_GENERAL_LOG, LOGGING_SID_LOG, and the terminal.
        tee -a "$LOGGING_GENERAL_LOG" "$LOGGING_SID_LOG" < "$LOGGING_GENERAL_FIFO" >&3 2>&1 &
    fi
    # We capture the general tee's process ID for later use in close_logs to avoid race conditions. 
    # We wait on this PID to ensure all data the filter is processing has been written to the file before we read from it or do other operations like re-configuring the logging. 
    LOGGING_GENERAL_PID=$!

    # Tell stdout and stderr to write to LOGGING_GENERAL_FIFO which we configured earlier to use tee to send its output to the terminal and appropriate files (FIFOs are also files!)
    exec > "$LOGGING_GENERAL_FIFO" 2>&1
}

# Purpose: Reset to the initial state which allows users to use the log files/redirect file descriptors
#          without any risk of race conditions or other weird behavior.
# Inputs: None
close_logs() {
    local return_status=0

    # Close write end of FIFO by pointing stdout and stderr back to the terminal.
    # This will cause an EOF to be sent to the readers which causes them to terminate 
    # once they have finished writing these changes to the appropriate files.
    restore_stdout_stderr

    # Wait for the general tee to terminate which prevents a race condition where the user immediately reads from the LOGGING_GENERAL_LOG file while this process is still writing.
    # Ex race condition: cat bigfile.txt
    #                    mailx -s "Success" "$ALL_DBA_EMAIL_LIST" < "$LOGGING_GENERAL_LOG"
    if [ -n "$LOGGING_GENERAL_PID" ]; then
        wait "$LOGGING_GENERAL_PID"
    fi
    # Unset the LOGGING_GENERAL_PID to prevent errors relating to waiting on a non-existent PID
    LOGGING_GENERAL_PID=""

    # Wait for the filter to terminate which prevents a race condition where the user immediately reads from the LOGGING_SID_LOG file while this process is still writing.
    # Ex race condition: cat bigfile.txt  
    #                    mailx -s "$ORACLE_SID failed" "$ALL_DBA_EMAIL_LIST" < "$LOGGING_SID_LOG"
    if [ -n "$LOGGING_FILTER_PID" ]; then
        wait "$LOGGING_FILTER_PID"
    fi
    # Unset the LOGGING_FILTER_PID to prevent errors relating to waiting on a non-existent PID
    LOGGING_FILTER_PID=""

    # Remove the general fifo file if it exists
    if [ -p "$LOGGING_GENERAL_FIFO" ]; then
        rm "$LOGGING_GENERAL_FIFO"
        # We don't error out so the cleanup can continue
        if [ $? -ne 0 ]; then
            echo "An error occurred while removing general FIFO $LOGGING_GENERAL_FIFO."
            return_status=1
        fi
    fi
    LOGGING_GENERAL_FIFO=""

    # Remove the filter fifo file if it exists
    if [ -p "$LOGGING_FILTER_FIFO" ]; then
        rm "$LOGGING_FILTER_FIFO"
        # We don't error out so the cleanup can continue
        if [ $? -ne 0 ]; then
            echo "An error occurred while removing filter FIFO $LOGGING_FILTER_FIFO."
            return_status=1
        fi
    fi
    LOGGING_FILTER_FIFO=""

    LOGGING_GENERAL_LOG=""
    LOGGING_SID_LOG=""

    return "$return_status"
}

# Purpose: Restore stdout and stderr to what they were pointing to when the script was sourced.
# Inputs: None
restore_stdout_stderr() {
    # Redirect stdout and stderr to point to what we saved when the file is sourced. 
    # Assuming the user did no shenanigans with stdout or stderr prior to the script being sourced,
    # this will point stdout and stderr back at just the terminal. 
    exec 1>&3
    exec 2>&4
}