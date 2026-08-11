#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: The purpose of this script is to startup either one or all databases by ORACLE_SID
#
#####################################################################################

usage="Usage: startup_oracle.sh [SID/ALL]"
example="Example: startup_oracle.sh dbprod"

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

# function to check if spfile or pfile exists for $ORACLE_SID
check_for_spfile_and_pfile() {
    if [ -f "$ORACLE_HOME/dbs/spfile$ORACLE_SID.ora" ] || [ -f "$ORACLE_HOME/dbs/init$ORACLE_SID.ora" ]; then
        return 0
    else
        return 1
    fi
}

if [ $# -ne 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

sid=$1

# Check available memory
memory_needed=2048
memory_check=$("$HOME/common/general/CheckServerMemory.sh" "$memory_needed")
if [ $? -ne 0 ]; then
    echo "Error occurred while checking available memory on server. Exiting..."
    exit 1
elif [[ "$memory_check" =~ *No* ]]; then
    echo "Error: There is not enough memory available on the server to accomodate this database startup. There must be at least $((${memory_needed} + 1024))MB available. Exiting..."
    exit 1
fi

# If user typed "ALL", startup all databases
if [ "${sid^^}" == "ALL" ]; then
    listener_status=$("$HOME/common/oracle/CheckIfListenerIsRunning.sh")
    if [ $? -ne 0 ]; then
        echo "Error occured while checking if listener is running. Exiting..."
        exit 1
    fi
    if [[ $listener_status =~ "No" ]]; then
        echo "Starting Oracle listener..."
        $ORACLE_HOME/bin/lsnrctl start
        if [ $? -eq 0 ]; then
            echo "Listener started. Continuing..."
        else
            echo "Error occcured while starting oracle listener. Exiting..."
            exit 1
        fi
    elif [[ $listener_status =~ "Yes" ]]; then
        echo "Oracle Listener already running. Continuing..."
    fi
    echo ""
    for ORACLE_SID in $SIDSLIST; do
        export ORACLE_SID=$ORACLE_SID

        # Ensure that database is offline
        db_status=$("$HOME/common/oracle/CheckDatabaseOpenStatus.sh" $sid)

        if [ $? -ne 0 ]; then
            echo "Error occurred while checking status of $ORACLE_SID database"
            echo "$db_status"
            exit_status=1
            continue
        elif [[ "$db_status" != *"CLOSED"* ]]; then
            echo "ERROR: $ORACLE_SID is not closed. Skipping..."
            exit_status=1
            continue
        fi

        # Check if spfile or pfile exists for database $ORACLE_SID
        check_for_spfile_and_pfile
        if [ $? -ne 0 ]; then
            echo "Error: No spfile or pfile found for database $ORACLE_SID"
            exit_status=1
            continue
        fi

        echo "Starting up $ORACLE_SID"
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever sqlerror exit 1
        whenever oserror exit 1
        startup;
        exit;
EOD
        echo
    done

# Startup user-provided SID if input isn't "all"
else
    export ORACLE_SID=$sid

    # Ensure that database is offline
    db_status=$("$HOME/common/oracle/CheckDatabaseOpenStatus.sh" $sid)

    if [ $? -ne 0 ]; then
        echo "Error occurred while checking status of $ORACLE_SID database"
        echo "$db_status"
        exit 1
    elif [[ "$db_status" != *"CLOSED"* ]]; then
        echo "ERROR: $ORACLE_SID is not closed. Exiting..."
        exit 1
    fi

    # Check status of listener
    lsnr_status=$("$HOME/common/oracle/CheckIfListenerIsRunning.sh")
    if [ $? -ne 0 ]; then
        echo "Error occured while checking if listener is running. Exiting..."
        exit 1
    fi

    if [[ $lsnr_status =~ "No" ]]; then
        echo "Error: Listener is not started. Run 'StartOracleListener.sh' script before reattempting startup."
        exit 1
    fi

    # Check if spfile or pfile exists for database $ORACLE_SID
    check_for_spfile_and_pfile
    if [ $? -ne 0 ]; then
        echo "Error: No spfile or pfile found for database $ORACLE_SID"
        exit 1
    fi

    echo "Starting up $sid"
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever sqlerror exit 1
    whenever oserror exit 1
    startup;
    exit;
EOD
fi

if [ $? -ne 0 ] || [ -n "$exit_status" ]; then
    echo "Error encountered when starting database(s), exiting..."
    exit 1
else
    echo "Database(s) started. Exiting..."
    exit 0
fi
