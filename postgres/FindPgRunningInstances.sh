#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script shows the user the location of pg_data (PGDATA) for every database
#          on the server (by default) or for the instance the user is currently connected to
#          (by using the -c flag).
#
################################################################################

usage="Usage: FindPgRunningInstances.sh [-c (current instance only)]"
example="Example: FindPgRunningInstances.sh"

current=0

# Process input options
while getopts ":hc" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    c)
        current=1
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

# Check arguments
if [ $# -gt 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Print user defined variables
echo "Printing user defined variables..."
if [ -n "$PGPORT" ]; then
    echo "Current PGPORT variable set to: ${PGPORT}"
else
    echo "PGPORT not set."
    if [ "$current" -eq 1 ]; then
        echo "Cannot print information for current instance, PGPORT is not set. Exiting..."
        exit 1
    fi
fi

if [ -n "$PGDATA" ]; then
    echo "Current PGDATA variable set to: ${PGDATA}"
else
    echo "PGDATA not set."
fi

echo ""

if [ "$current" -eq 1 ]; then
    # Print information for the instance the user is currently connected to
    echo "Printing information for CURRENTLY CONNECTED instance..."
    echo ""
    ports="$PGPORT"
else
    # Print information for all currently running instances
    echo "Printing ALL currently running instances..."
    echo ""
    # ss dumps socket statistics
    # the tr statements make it easier to do regex matching to just match the port number
    # the perl regex eliminates all words other than the latter part of the directory for the database (not PGDATA however)
    # After the perl regex there are words of the form "PGSQL.$PORT", the awk prints the $PORT number, and then sort only unique occurrences (-u)
    ports=$(ss -pa | tr ' ' '\n' | perl -lne '/PGSQL.*/ && print $&' | tr '.' ' ' | awk '{print $2}' | sort -u)
fi

if [ -n "$ports" ]; then
    # Iterate through each port and query the database to find the data directory
    for port in $ports; do
        directory=$(
            psql -p "$port" -q -v ON_ERROR_STOP=on <<EOD
            \pset tuples_only on
            SHOW data_directory;
EOD
        )

        if [ $? -ne 0 ]; then
            echo "Error occurred getting instance directory on port ${port}. Skipping this port..."
            error_occurred=1
            continue
        fi

        start_dt=$(
            psql -p "$port" -q -v ON_ERROR_STOP=on <<EOD
            \pset tuples_only on
            select pg_postmaster_start_time();
EOD
        )

        if [ $? -ne 0 ]; then
            echo "Error occurred getting instance start date on port ${port}. Skipping this port..."
            echo "$start_dt"
            error_occurred=1
            continue
        fi

        echo "PGDATA directory for port ${port}:${directory}"
        echo "Started at: $start_dt"
        echo ""
    done
else
    echo "No currently running instances."
fi

# Getting OS name
os=$(cat /etc/os-release | grep -E "^NAME" | cut -d '"' -f2)

# Listing installed packages
echo "Installed Postgres OS packages:"
if [ "$os" == "Red Hat Enterprise Linux" ]; then
    RHEL_pkgs=$(yum list installed --noplugins 2>&1)
    if [ $? -ne 0 ]; then
        echo "Listing installed packages with 'yum' failed:"
        echo "$RHEL_pkgs"
        exit 1
    fi

    # Finding postgres packages
    filtered_RHEL_pkgs=$(echo "$RHEL_pkgs" | grep postgres)

    if [ -z "$filtered_RHEL_pkgs" ]; then 
        echo "No postgres packages found. Exiting..."
        exit 1
    fi
    echo "$filtered_RHEL_pkgs" | awk '{ print $1 }'

elif [ "$os" == "SLES" ]; then 
    SLES_pkg_all=$(zypper search -i 2>&1)
    if [ $? -ne 0 ]; then
        echo "Listing installed packages with 'zypper' failed"
        echo "$SLES_pkg_all"
        exit 1
    fi

    # Finding postgres packages
    SLES_pkg=$(echo "$SLES_pkg_all" | grep postgres | awk '{print $3}')

    if [ -z "$SLES_pkg" ]; then 
        echo "No postgres packages found. Exiting..."
        exit 1
    fi

    echo "$SLES_pkg" | awk '{ print $1 }'

else
    echo "Error finding Red Hat or SUSE postgres packages."
    exit 1
fi

if [ ! -z "$error_occurred" ]; then 
    echo "An error occurred on at least one instance. Check above output."
    exit 1
else
    exit 0
fi
