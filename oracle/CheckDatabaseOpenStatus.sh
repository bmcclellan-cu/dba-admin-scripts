#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: The purpose of this script is to return the status of a given database.
#	   This script will tell the user if the database is closed, in nomount mode,
#	   mounted, or open.
#
#####################################################################################

usage="Usage: CheckDatabaseOpenStatus.sh [ORACLE_SID | ALL] | [tns_entry] [username] [password (optional)]"
example="Example: CheckDatabaseOpenStatus.sh dbprod"

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

# Set environment variables
if [ -f /export/home/oracle/.bashrc ]; then
    source /export/home/oracle/.bashrc
    if [ $? -ne 0 ]; then
        echo "An error occurred while sourcing /export/home/oracle/.bashrc. Exiting..."
        exit 1
    fi
else
    export ORACLE_HOME=/dba/oracle/installs/orabase/product/19.7.0/dbhome_1
    export LD_LIBRARY_PATH=$ORACLE_HOME/lib
fi

# Check arguments
if [ $# -lt 1 ] || [ $# -gt 3 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

if [ $# -eq 1 ]; then
    # Set sids to loop through based on input
    if [ "${1^^}" == "ALL" ]; then
        sids="$SIDSLIST"
    else
        sids="$1"
    fi

    for sid in $sids; do
        # Set current oracle sid
        export ORACLE_SID="$sid"

        # Set variable for sid name if ALL is provided
        if [ "${1^^}" == "ALL" ]; then
            sid_name="$sid: "
        fi

        # Check if any non-grep processes are running to determine if the database is closed
        check_processes=$(ps -ef | grep -w "ora_smon_${ORACLE_SID}" | grep -v grep)

        if [ -z "$check_processes" ]; then
            echo "${sid_name:-}CLOSED"
            continue
        fi

        # Check the mode of the database using the open_mode column of v$database
        check_mode=$(
            "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        set heading off
        set feedback off
        SELECT open_mode FROM v\$database;
EOD
        )
        sqlplus_error=$?

        # Check for any ORA errors in sqlplus output
        oraError=$(echo "$check_mode" | grep "ORA-")

        # Check if sqlplus ran into any error except for ORA-01507 which determines if the database is in NOMOUNT mode
        if [ $sqlplus_error -ne 0 ] || [ -n "$oraError" ]; then
            isNOMOUNT=$(echo "$check_mode" | grep "ORA-01507")
            if [ -z "$isNOMOUNT" ]; then
                echo "---------------"
                echo "${sid_name:-}ERROR"
                
                if [ -n "$oraError" ]; then 
                    echo "${oraError}"
                    echo "---------------"
                    continue
                else
                    echo "${check_mode}"
                    echo "---------------"
                    continue
                fi

            fi
        fi

        # Determine which mode the database is in based on the result of $check_mode
        if [ "${check_mode:1}" == "READ WRITE" ]; then
            echo "${sid_name:-}OPEN"
        elif [ "${check_mode:1}" == "MOUNTED" ]; then
            echo "${sid_name:-}MOUNTED"
        else
            echo "${sid_name:-}NOMOUNT"
        fi
    done
else
    tns_entry="$1"
    username="$2"
    password="$3"

    tns_check=$("$HOME/common/oracle/CheckTNSEntry.sh" "$1")
    if [ $? -ne 0 ]; then
        if [[ "$tns_check" =~ 'TNS-03505' ]]; then
            echo "Error: no matching entry found for $tns_entry in $ORACLE_HOME/network/admin/tnsnames.ora. Exiting..."
            exit 1
        fi
        echo "$tns_check"
        echo "Error occurred while checking tns entry. Exiting..."
        exit 1
    fi

    if [ -z "$password" ]; then
        echo -n " Please enter the password for the given user: "
        read -r password
    fi

    # Redirecting any error output to stdout (2>&1)
    # The output of the sql query is piped into xargs which removes leading and trailing whitespace/newlines 
    result=$(
        "$ORACLE_HOME/bin/sqlplus" -s "$username/$password@$tns_entry" <<EOD 2>&1 | xargs
    whenever oserror exit 1
    whenever sqlerror exit 1
    set heading off
    set feedback off
    SELECT open_mode FROM v\$database;
EOD
    )

    if [[ "$result" =~ "ORA-01034" ]] || [[ "$result" =~ "ORA-27101" ]] || [[ "$result" =~ "ORA-12514" ]]; then
        # Check if database is unavailable
        # ORA-01034: ORACLE not available
        # ORA-27101: shared memory realm does not exist
        # ORA-12514: The listener is unaware of the particular database service or instance you are trying to connect to
        echo "CLOSED"
        exit 0
    elif [[ "$result" =~ "ORA-01017" ]]; then
        # ORA-01017: invalid username/password; logon denied
        echo "Error user has invalid credentials to logon. Database is open. Exiting..."
        exit 1
    elif [[ "$result" =~ 'ORA-01033' ]]; then
        # ORA-01033: ORACLE initialization or shutdown in progress
        # db is in mount or nomount mode. Provided credentials have not been granted DBA and cannot query v$ tables.
        echo "NOMOUNT/MOUNT"
        exit 0
    elif [[ "$result" =~ 'ORA-00942' ]] || [ "$result" == "READ WRITE" ]; then
        # ORA-00942: table or view does not exist
        # If this message is received the database is open as the user is able to connect, also the user does not have DBA
        # privs, since they cannot see the v$ tables.
        echo "OPEN"
        exit 0
    else
        echo "An unexpected error occurred while attempting to reach the database"
        echo "$result" 
        echo "Exiting..."
        exit 1
    fi
fi

exit 0
