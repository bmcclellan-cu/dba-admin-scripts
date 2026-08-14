#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: The purpose of this script is to stop or start all databases on a server
#          in parallel. The databases on the server are determined by what is in SIDSLIST
#
# Note: The -f option will run the Oracle command "shutdown abort". This will terminate
#       all running processes, and will successfully shutdown databases in nomount
#       or mount mode (which may not be shutdown if the "shutdown immediate" Oracle command
#       is used).
#
################################################################################

usage="Usage: ./StartStopAllDatabasesOnServer.sh [ -s (suppress emails) ] [ -f (force shutdown abort) ] [ -e csv list of sids (databases to keep online)] [ start | stop ] "
example="Example: ./StartStopAllDatabasesOnServer.sh -f stop"
example_two="Example: ./StartStopAllDatabasesOnServer.sh -e \$ORACLE_SID stop"

sopt=false
fopt=false
eopt=false
elist=""

# Process input options
while getopts ":hsfe:" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        echo "$example_two"
        exit 0
        ;;
    s)
        sopt=true
        ;;
    f)
        fopt=true
        ;;
    e)
        eopt=true

        # If no third argument is provided
        if [ -z "$OPTARG" ]; then
            echo "Error. List of databases to exclude must be provided"
            echo "$usage"
            echo "$example"
            exit 1
        fi

        elist="$(echo "$OPTARG" | tr ',' ' ')"
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;; 
    esac
done
shift "$((OPTIND - 1))"

curr_date=$(date +%Y-%m-%d_%H_%M_%S)
log_file="/tmp/StartStopAllDatabasesOnServer_$curr_date.log"
echo "Logging to $log_file"
exec > >(tee -a "$log_file") 2>&1

action=${1^^}
if ! [[ "${action}" =~ START|STOP ]]; then
    echo "The action can only be start or stop. You provided $action. Exiting..."
    exit 1
fi

if [ -f "$HOME/.bashrc" ]; then
    source "$HOME/.bashrc"
    if [ $? -ne 0 ]; then
        echo "An error occurred while sourcing $HOME/.bashrc. Exiting..."
        exit 1
    fi
else
    echo "Error: $HOME/.bashrc does not exist. Exiting..."
    exit 1
fi

# Check that either start or stop is provided and nothing else
if [ $# -ne 1 ]; then
    echo "Error. Invalid number of inputs."
    echo "$usage"
    echo "$example"
    echo "$example_two"
    exit 1
fi

exit_status=0
exit_handler(){
    new_exit_code=$? # This gets the exit code used to exit(i.e. exit 1 -> new_exit_code=1)
    # This is done so that we can identify whether the script made it to the end.
    if [[ $new_exit_code -eq 0 ]]; then
        if [ $exit_status -ne 0 ]; then
            echo "StartStopAllDatabasesOnServer.sh completed with errors at $(date +'%Y-%m-%d %H:%M:%S')"
            email_header="$HOSTNAME - StartStopAllDatabasesOnServer.sh completed with errors"
        else
            echo "StartStopAllDatabasesOnServer.sh successfully completed at $(date +'%Y-%m-%d %H:%M:%S')"
            email_header="$HOSTNAME - StartStopAllDatabasesOnServer.sh Completed Successfully"
        fi
    else
        echo "StartStopAllDatabasesOnServer.sh failed during execution. Exiting..."
        email_header="$HOSTNAME - StartStopAllDatabasesOnServer.sh - FATAL ERROR OCCURRED"
    fi
    # The tr removes carriage return characters from the email input, allowing for it to send in plaintext, instead
    # of an attachment.
    if [ "$sopt" != true ]; then
        mailx -s "$email_header" "$ALL_DBA_EMAIL_LIST" < <( tr '\r' '\n' < "$log_file" )
    fi
    exit $(( new_exit_code || exit_status ))
}
trap exit_handler EXIT INT TERM # On exit, call exit_handler.

date

# Set sids to SIDSLIST (preferred over VerifyAllParam.sh in this situation as it allows finer control over db checking)
# Iterate over each db in the optional -e parameter and remove it from the sids variable
sids="$SIDSLIST"
for esid in $elist; do
    echo "Excluding sid $esid"
    sids=$(echo " $sids " | sed "s/ $esid / /g" | xargs)
done

lsnrstatus=$("$HOME/common/oracle/CheckIfListenerIsRunning.sh")
if [ $? -ne 0 ]; then
    echo "$lsnrstatus"
    echo "Error occurred while checking if listener is running. Exiting..."
    exit 1
elif [ "$lsnrstatus" != "Yes" ] && [ "${action}" == "START" ]; then
    echo "Listener is not started. Starting listener"
    startlsnrres=$("$HOME/common/oracle/StartOracleListener.sh")
    if [ $? -ne 0 ]; then
        echo "$startlsnrres"
        echo "Error occurred while starting oracle listener. Exiting..."
        exit 1
    fi
    lsnrstatus=$("$HOME/common/oracle/CheckIfListenerIsRunning.sh")
    
    if [ $? -ne 0 ]; then
        echo "$lsnrstatus"
        echo "Error occurred while running CheckIfListenerIsRunning.sh. Exiting..."
        exit 1
    fi

    if [ "$lsnrstatus" != "Yes" ]; then
        echo "$lsnrstatus"
        echo "Error, listener failed to start. Exiting..."
        exit 1
    fi
    echo "Listener successfully started. Continuing..."
    echo
fi

declare -A pids
if [ "${action}" == "START" ]; then
    if $fopt; then
        echo "Warning, -f option has no impact on script when starting databases."
    fi
    # Loop through each sid
    #     Check database open status
    #         if db is closed - run startup_oracle script
    #         if db is open - output to user and skip
    #         otherwise output to user the status and continue
    for sid in $sids; do
        open_check=$("$HOME/common/oracle/CheckDatabaseOpenStatus.sh" "$sid")
        if [ $? -ne 0 ]; then
            echo "$open_check"
            echo "An error occurred while checking if $sid is open. Continuing..."
            exit_status=1
            continue
        fi

        if [ "$open_check" == "CLOSED" ]; then
            echo "Starting $sid"
            # Use nohup to create a child process for starting up each database
            nohup "$HOME/common/oracle/startup_oracle.sh" "$sid" > "/tmp/startup_${sid}_${curr_date}.log" 2>&1 &
            pids[$sid]=$!
            echo
        elif [ "$open_check" == "OPEN" ]; then
            echo "DB $sid is already open. Continuing..."
            echo
        else
            echo "DB $sid is in $open_check state. Continuing..."
            echo
        fi
    done

    # Wait for all calls to startup_oracle.sh to complete.
    echo
    echo "Scripts have begun executing. Waiting for completion to check status..."
    for sid in "${!pids[@]}"; do 
        pid=${pids[$sid]}
        wait "$pid"
        if [ $? -ne 0 ]; then
            echo "One or more errors detected by exit code occurred while running startup_oracle.sh for $sid. Check the output below for details:"
            cat "/tmp/startup_${sid}_${curr_date}.log"
            echo
            echo
            exit_status=1
        elif ( grep -i -q "error" "/tmp/startup_${sid}_${curr_date}.log" ); then
            echo "One or more errors occurred while running startup_oracle.sh for $sid. Check the output below for details:"
            cat "/tmp/startup_${sid}_${curr_date}.log"
            echo
            echo
            exit_status=1
        fi
    done

    echo "Execution of scripts finished."

    # Check status of sids, outputting to the user if any failed to open, and noting that in the exit_status return variable
    echo
    echo "Checking status of sids..."
    for sid in $sids; do
        open_check=$("$HOME/common/oracle/CheckDatabaseOpenStatus.sh" "$sid")

        if [ $? -ne 0 ]; then
            echo "$open_check"
            echo "An error occurred while checking if $sid is open. Continuing..."
            exit_status=1
            continue
        fi

        if [ "$open_check" != "OPEN" ]; then
            echo "Error: $sid is in $open_check mode. Continuing..."
            exit_status=1
        fi
    done
    echo "Status of sids checked successfully"
elif [ "${action}" == "STOP" ]; then
    # Loop through each sid
    #     Check database open status
    #         if db is open - run shutdown_oracle script
    #         if db is closed - output to user and skip
    #         otherwise output to user and
    #             if f option is given run shutdown abort in nohup, otherwise echo 'Continuing...'
    for sid in $sids; do
        open_check=$("$HOME/common/oracle/CheckDatabaseOpenStatus.sh" "$sid")
        if [ $? -ne 0 ]; then
            echo "$open_check"
            echo "An error occurred while checking if $sid is open. Continuing..."
            exit_status=1
            continue
        fi

        if [ "$fopt" == false ] && [ "$open_check" == "OPEN" ]; then
            echo "Shutting down $sid"
            nohup "$HOME/common/oracle/shutdown_oracle.sh" "$sid" > "/tmp/shutdown_${sid}_${curr_date}.log" 2>&1 &
            pids[$sid]=$!
            echo
        elif [ "$open_check" == "CLOSED" ]; then
            echo "DB $sid is already stopped. Continuing..."
            echo
        elif [ "$fopt" == true ]; then
            echo "Shutting down $sid using shutdown abort..."
            nohup "$HOME/common/oracle/shutdown_oracle.sh" "$sid" "ABORT" > "/tmp/shutdown_${sid}_${curr_date}.log" 2>&1 &
            pids[$sid]=$!
            echo
        else
            echo "DB $sid is in $open_check state. Pass the -f option to use shutdown abort to shutdown databases that aren't in the OPEN state."
            exit_status=1
        fi
    done

    # Wait for all calls to shutdown_oracle.sh to complete.
    echo
    echo "Scripts have begun executing. Waiting for completion to check status..."
    for sid in "${!pids[@]}"; do 
        pid=${pids[$sid]}
        wait "$pid"
        if [ $? -ne 0 ]; then
            echo "One or more errors were detected by exit code while running shutdown_oracle.sh for $sid. Check the output below for details:"
            cat "/tmp/shutdown_${sid}_${curr_date}.log"
            echo
            echo
            exit_status=1
        elif ( grep -i -q "error" "/tmp/shutdown_${sid}_${curr_date}.log" ); then
            echo "One or more errors occurred while running shutdown_oracle.sh for $sid. Check the output below for details:"
            cat "/tmp/shutdown_${sid}_${curr_date}.log"
            echo
            echo
            exit_status=1
        fi
        
        if  ( grep -q "active processes" "/tmp/shutdown_${sid}_${curr_date}.log" ); then
            echo "Warning: $sid had active processes upon shutdown. Please check the output below for details:"
            # Print out all lines between "had active processes upon shutdown:" and "If any unnecessary processes are listed", inclusive.
            cat "/tmp/shutdown_${sid}_${curr_date}.log" | awk '/had active processes upon shutdown:/,/If any unnecessary processes are listed/'
            echo
            echo 
        fi
        
    done


    echo "Execution of scripts finished."

    # Check the status of the sids, now that the scripts are done running.
    # If they are not closed, output that to the user and change the exit_status
    echo
    echo "Checking status of sids..."
    for sid in $sids; do
        open_check=$("$HOME/common/oracle/CheckDatabaseOpenStatus.sh" "$sid")

        if [ $? -ne 0 ]; then
            echo "$open_check"
            echo "An error occurred while checking if $sid is open. Continuing..."
            exit_status=1
            continue
        fi

        if [ "$open_check" != "CLOSED" ]; then
            echo "Error: $sid is in $open_check mode. Continuing..."
            exit_status=1
        fi
    done
    echo "Status of sids checked successfully"
else # Case for invalid option
    echo "Error: argument must be either stop or start. Exiting..."
    exit 1
fi

# Output to the user the results of the script based on exit_status variable
echo
if [ $exit_status -eq 0 ]; then
    echo "Script finished successfully. "
    if [ "${action}" == "STOP" ]; then
        echo "All sids stopped. "
        if [ "$lsnrstatus" == "Yes" ] && ! $eopt; then
            echo "Listener is still running. Stopping listener..."
            stoplsnrres=$("$HOME/common/oracle/StopOracleListener.sh")
            if [ $? -ne 0 ]; then
                echo "$stoplsnrres"
                echo "Error occurred while stopping oracle listener. Exiting..."
                exit 1
            fi
            lsnrstatus=$("$HOME/common/oracle/CheckIfListenerIsRunning.sh")
            if [ "$lsnrstatus" == "Yes" ]; then
                echo "Error, listener failed to stop. Exiting..."
                exit 1
            fi
            echo "Listener successfully stopped. Exiting..."
            echo
        else
            echo "Exiting..."
        fi
    else
        echo "All sids started. Exiting..."
    fi
else
    echo "Script finished with some errors. Exiting..."
fi

exit 0