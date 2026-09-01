#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script shuts down the current postgres instance and prints out
#          any remaining processes that were terminated during the shut down.
#
################################################################################

usage="Usage: shutdown_postgres.sh [ PGPORT | ALL ]"
example="Example: shutdown_postgres.sh 5432"

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

if [ $# -ne 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi
port=${1^^}
# Tracks whether any instance failed during an ALL sweep so the exit code reflects it
exit_status=0

# Get active instances
active_instances=$("$HOME/common/postgres/FindPgRunningInstances.sh")
if [ $? -ne 0 ]; then
    echo "Problem finding running instances, exiting..."
    echo "$active_instances"
    exit 1
fi

active_instance_dirs=$(echo "$active_instances" | grep "PGDATA directory")

# Check to see if first argument is a number or not.
if [[ "$port" =~ ^[0-9]+$ ]]; then
    # If you don't override PGPORT you will get the remaining queries from the wrong instance
    export PGPORT="$port"

    # Check if provided port is between 0 and 65535
    if [ "$port" -gt 65535 ] || [ "$port" -lt 1 ]; then
        echo "Error. Port must be between 0 and 65535. Exiting..."
        exit 1
    fi

    port_directory=$(echo "$active_instance_dirs" | grep "for port ${port}:")
    if [ -z "$port_directory" ]; then
        echo "Provided PGPORT is not running, exiting..."
        exit 1
    fi
    # Get everything after the last ':'
    port_directory=$(echo "${port_directory##*:}" | xargs)

    if [ -z "$port_directory" ]; then
        echo "Could not find instance directory for port $port, exiting..."
        exit 1
    fi
    
    echo "Shutting down instance on port $port with PGDATA directory: $port_directory"

    # Capturing the remaining queries before shutdown, then shutting down
    remaining_queries=$( #Displaying the queries that are active
        psql -q -v ON_ERROR_STOP=on <<EOD
        SELECT usename "Username", query "Query", datname "Database",
        application_name "Application"
        FROM pg_stat_activity 
        WHERE (query <> '') IS TRUE
        and query not like '%SELECT usename "Username", query "Query", datname "Database",
            application_name "Application"
            FROM pg_stat_activity%'
        ORDER BY 1;
EOD
    )

    # Check for SQL errors. This query is informational only, so a failure must not prevent the
    # shutdown - the likeliest cause is an instance out of connections or refusing them, which is
    # exactly when it still needs to be stopped.
    if [ $? -ne 0 ]; then
        echo "An error occurred while finding remaining queries on port ${port}. Continuing..."
        exit_status=1
        remaining_queries=""
    fi

    # Shut down instance
    pg_ctl -m fast -D "$port_directory" stop
    if [ $? -ne 0 ]; then
        echo "Problem stopping instance, exiting..."
        exit 1
    fi
    
    if [ -z "$remaining_queries" ]; then
        echo "Could not determine which queries were running on port $port before shutdown."
    elif ! (echo "$remaining_queries" | grep -q "(0 rows)"); then
        echo "Queries that were running on port $port before shutdown occurred: "
        echo "$remaining_queries"
    else
        echo "No queries running on port $port before shutdown occurred."
    fi
elif [ "$port" == "ALL" ]; then
    # No running instances is a normal state, not a failure. Guard here because a bare
    # `echo ""` still feeds the loop one empty line, which would otherwise be counted
    # as an unparseable instance and set exit_status.
    if [ -z "$active_instance_dirs" ]; then
        echo "No running postgres instances found. Nothing to shut down."
        exit 0
    fi

    while read -r instance; do
        # Find the port number after 'port ' and before ':'
        instance_port=$(echo "$instance" | sed -n 's/^.*port \([0-9]*\):.*$/\1/p')

        if [ -z "$instance_port" ]; then
            echo "Could not parse a port from instance line: $instance. Continuing..."
            exit_status=1
            continue
        fi

        # Get everything after the last ':'
        instance_directory=$(echo "${instance##*:}" | xargs)
        if [ -z "$instance_directory" ]; then
            echo "Could not find instance directory for port ${instance_port}. Continuing..."
            exit_status=1
            continue
        fi
        # If you don't override PGPORT you will get the remaining queries from the wrong instance
        export PGPORT=${instance_port}

        echo "Shutting down instance on port $instance_port with PGDATA directory: $instance_directory"
        #Capturing the remaining queries before shutdown, then shutting down
        remaining_queries=$( #Displaying the queries that are active
            psql -p "${instance_port}" -q -v ON_ERROR_STOP=on <<EOD
            SELECT usename "Username", query "Query", datname "Database",
            application_name "Application"
            FROM pg_stat_activity 
            WHERE (query <> '') IS TRUE
            and query not like '%SELECT usename "Username", query "Query", datname "Database",
            application_name "Application"
            FROM pg_stat_activity%'
            ORDER BY 1;
EOD
        )

        # Check for SQL errors. Informational only - see the single-port branch above. Clear the
        # variable explicitly so this instance does not report the previous iteration's queries.
        if [ $? -ne 0 ]; then
            echo "An error occurred while finding remaining queries on port ${instance_port}. Continuing..."
            exit_status=1
            remaining_queries=""
        fi

        # Shut down the instance
        pg_ctl -m fast -D "$instance_directory" stop
        if [ $? -ne 0 ]; then
            echo "Problem stopping instance at port $instance_port with directory:"
            echo "${instance_directory}" 
            echo "Continuing..."
            exit_status=1
            continue
        fi

        if [ -z "$remaining_queries" ]; then
            echo "Could not determine which queries were running on port $instance_port before shutdown."
        elif ! (echo "$remaining_queries" | grep -q "(0 rows)"); then
            echo "Processes that were running on port $instance_port before shutdown occurred: "
            echo "$remaining_queries"
        else
            echo "No queries running on port $instance_port before shutdown occurred."
        fi
    done < <(echo "$active_instance_dirs")
else
    echo "Invalid input. Input must either be a valid port number or ALL. Exiting..."
    exit 1
fi

if [ "$exit_status" -ne 0 ]; then
    echo "One or more instances failed to shut down. Check above output for details. Exiting..."
    exit 1
fi

echo "shutdown_postgres.sh script finished successfully."
exit 0
