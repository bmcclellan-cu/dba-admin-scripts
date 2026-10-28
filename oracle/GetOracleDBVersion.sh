#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose:  This script will attempt to determine what version of oracle a database is running,
#           as well as the ORACLE_HOME directory where the binaries are running from. 
#           Additionally, this script will issue a WARNING if the database was started on a version of oracle
#           that is different from the oracle version that database components are running on.
#           Passing ALL runs these checks on every database returned by PrintAllRunningDatabases.sh script.
#
#####################################################################################
usage="Usage: GetOracleDBVersion.sh [ \$ORACLE_SID | ALL ]"
example="Example: GetOracleDBVersion.sh mydbprod"
# Example of the ALL argument, which checks every running database
example2="         GetOracleDBVersion.sh ALL"

# Process input options
while getopts ":h" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        echo "$example2"
        exit 0
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

# Check arguments
# An empty argument (e.g. an unset variable passed as the SID) is a usage error, not a database to look up
if [ $# -ne 1 ] || [ -z "$1" ]; then
    echo "$usage"
    exit 1
fi

# Get the list of running databases with PIDs (-p) while ignoring (-i) errors while filtering out
# containerized processes.
running_dbs=$("$HOME/common/oracle/PrintAllRunningDatabases.sh" -i -p)

if [ $? -ne 0 ]; then
    echo "$running_dbs"
    echo "An error occurred while running PrintAllRunningDatabases.sh. Exiting..."
    exit 1
fi

# Prints the ORACLE_HOME and Oracle version of a running database, warning if its components
# are on a different version than its binaries.
# Inputs:
#   sid: ORACLE_SID of the database to get Oracle software version
# Return Value:
#   0: Success
#   1: An error occurred
# Errors return rather than exit so that with ALL the remaining databases are still checked.
# The failed SIDs are reported together once every database has been checked.
get_db_version(){
    local smon_pid smon_environ oracle_version db_status parsed_db_status check_rows column
    local oracle_full_version full_version_exit_status parsed_oracle_full_version
    local oracle_component_version comp_exit_status

    export ORACLE_SID=$1

    # Get the row corresponding with the database and extract the SMON PID.
    smon_pid=$(awk -v sid="$ORACLE_SID" '$1 == sid {print $2}' <<< "$running_dbs")

    if [ -z "$smon_pid" ]; then
        echo "ERROR: Database $ORACLE_SID does not appear to be running, no SMON process active."
        return 1

    elif [ "$(echo "$smon_pid" | wc -l)" -gt 1 ]; then
        echo "ERROR: More than one SMON process found for database $ORACLE_SID:"
        echo "$smon_pid"
        return 1
    fi

    # Get the environment of the SMON process and extract ORACLE_HOME from it.
    # Note: /proc/<PID>/environ is a null-delimited array of the environment variables of the process when
    #       it was started, and bash string variables are unable to store nulls, so we must substitute them
    #       out for newlines.
    smon_environ=$(tr '\0' '\n' < "/proc/$smon_pid/environ")
    if [ $? -ne 0 ]; then
        echo "$smon_environ"
        echo "An error occurred while reading environment variables of the SMON process for database $ORACLE_SID."
        return 1
    fi

    ORACLE_HOME=$(echo "$smon_environ" | grep "^ORACLE_HOME=" | cut -d= -f2)
    if [ -z "$ORACLE_HOME" ]; then
        echo "ERROR: No ORACLE_HOME found in environment of SMON process of $ORACLE_SID. Unable to determine ORACLE_HOME."
        return 1
    fi
    # Export it so the sqlplus calls below run with this database's ORACLE_HOME even when the caller's
    # environment never exported one (e.g. cron without .bashrc)
    export ORACLE_HOME

    echo "Successfully determined ORACLE_HOME for database $ORACLE_SID:"
    echo "ORACLE_HOME=$ORACLE_HOME"
    echo
    oracle_version=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        set feedback off
        set heading off

        SELECT banner_full FROM v\$version;
EOD
    )
    if [ $? -ne 0 ]; then
        echo "$oracle_version"
        echo "An error occurred while querying for Oracle Database version."
        return 1
    fi
    # Trim excess whitespace
    oracle_version=$(echo "$oracle_version" | xargs)

    # Check the open status of the database because DBA_REGISTRY can not be queried if DB is not open.
    # We query v$instance because it can be queried in NOMOUNT mode.
    # Additionally, we do not use CheckDatabaseOpenStatus.sh because that script uses ORACLE_HOME from .bashrc file.
    # We must be on the same ORACLE_HOME that the database is running on in order to avoid 'ORA-01034: ORACLE not available' errors.
    # Extracting ORACLE_HOME from $smon_environ above guarantees this.
    db_status=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        set feedback off
        set heading off
        select STATUS from v\$instance;
EOD
    )

    if [ $? -ne 0 ]; then
        echo "$db_status"
        echo "An error occurred while checking database mode from v\$instance"
        return 1
    fi

    parsed_db_status=$(echo "$db_status" | xargs)

    if [[ "$parsed_db_status" == *"OPEN"* ]]; then
    
        oracle_full_version=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
            whenever oserror exit 1
            whenever sqlerror exit 1
            set feedback off
            set heading off

            select DISTINCT VERSION_FULL from DBA_REGISTRY WHERE comp_id != 'APEX';
EOD
        )
        full_version_exit_status=$?

        oracle_component_version=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
            whenever oserror exit 1
            whenever sqlerror exit 1
            set feedback off
            set heading off
            set pagesize 0

            select COMP_ID || ' | ' || VERSION_FULL from DBA_REGISTRY;
EOD
        )
        comp_exit_status=$?
    
        if [ $comp_exit_status -ne 0 ] || [ $full_version_exit_status -ne 0 ]; then
            if [ "$full_version_exit_status" -ne 0 ]; then
                echo "$oracle_full_version"
            else
                echo "$oracle_component_version"
            fi
            echo "An error occurred while querying for DBA_REGISTRY table for Oracle software version."
            return 1
        fi
        # The grep counts the number of rows returned from the query above
        check_rows=$(echo "$oracle_full_version"| grep -c '[0-9]')
        # Trim excess whitespace
        parsed_oracle_full_version=$(echo "$oracle_full_version" | xargs)

        # There should only ever be one DISTINCT row returned from the query above. If that is not the case, warn the user.
        if [ "$check_rows" != '1' ]; then
            echo "WARNING: $ORACLE_SID database has components on multiple versions!"
            echo
            echo "$oracle_component_version"
            echo
        fi

        for column in $parsed_oracle_full_version; do
            if ! [[ "$oracle_version" == *"$column"* ]] ; then
                echo "WARNING: $ORACLE_SID database has components running on different version from the binaries!"
                echo "Oracle Version:"
                echo "$oracle_version"
                echo "Database components are on:"
                echo
                echo "$oracle_component_version"
                echo
            fi
        done
    else
        echo "Unable to query DBA_REGISTRY because $ORACLE_SID database is not OPEN."
        echo "$ORACLE_SID database status: $parsed_db_status"
        echo
    fi

    echo "Oracle Version:"
    echo "$oracle_version"
    return 0
}

if [ "${1,,}" == "all" ]; then
    # Each row of $running_dbs is "<sid> <smon pid>"
    # NF == 2 only prints out rows containing two columns, so only rows like "<sid> <smon pid>"
    # Sort and remove duplicate SIDs (sort -u) so a database with multiple SMON processes is only reported once.
    # readarray -t: read one SID per line into the sids array, dropping the trailing newlines
    readarray -t sids < <(awk 'NF == 2 {print $1}' <<< "$running_dbs" | sort -u)
    if [ "${#sids[@]}" -eq 0 ]; then
        echo "ERROR: No running databases found."
        echo "Exiting..."
        exit 1
    fi
else
    # A one-element array holding the lowercased argument, so the loop below checks it as one SID rather than
    # splitting it on whitespace or expanding glob characters such as * against the current directory
    sids=("${1,,}")
fi

failed_sids=()
for sid in "${sids[@]}"; do
    echo "-----------------------------------------------------------------------------------------"
    if ! get_db_version "$sid"; then
        failed_sids+=("$sid")
    fi
done
echo "-----------------------------------------------------------------------------------------"
# If failed_sids array is not empty, output sids that failed get_db_version() call
if [ "${#failed_sids[@]}" -ne 0 ]; then
    echo "ERROR: Unable to determine Oracle version for database(s): ${failed_sids[*]}"
    exit 1
fi

exit 0