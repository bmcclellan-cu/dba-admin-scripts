#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script attempts to start a postgres instance, either with the
#          default PGData directory or with one given.
#
# Note: If you supply both PGDATA and PGPORT as arguments,
#           the instance will be started at the specified port and its $PGDATA/postgresql.conf will be updated to reflect that.
#       If you supply the PGDATA argument but not the PGPORT argument,
#           the instance will be booted with the port found in $PGDATA/postgresql.conf
#       If you do not supply either PGDATA or PGPORT arguments,
#           your environment values will be used and $PGDATA/postgresql.conf will be updated with the PGPORT in your environment. 
#       If you do not supply the PGDATA argument but do supply the PGPORT argument,
#           the instance will be started at the specified port and PGDATA will come from your environment. $PGDATA/postgresql.conf will be updated with the supplied port.
#          
################################################################################

usage="Usage: startup_postgres.sh [ PGDATA (optional) ] [ PGPORT (optional) ]"
example="Example: startup_postgres.sh /pg_data"

# Process input options
while getopts ":h" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0;;
    \?)
        echo "Error: Invalid option"
        exit 1
    esac
done

# Check the user didn't provide more than 2 or less than 1 input(s)
if [ $# -gt 2 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Check available memory
memory_needed=2048
memory_check=$("$HOME/common/general/CheckServerMemory.sh" "$memory_needed")
if [ $? -ne 0 ]; then
    echo "Error occurred while checking available memory on server. Exiting..."
    exit 1
elif [[ "$memory_check" != *Yes* ]]; then
    echo "There is not enough memory available on the server to accomodate this database startup. There must be at least $((${memory_needed} + 1024))MB available. Exiting..."
    exit 1
fi

# Get list of PGDATA directories in use
directories_in_use=$("$HOME/common/postgres/FindPgRunningInstances.sh")
if [ $? -ne 0 ]; then
    echo "Error occurred while running FindPgRunningInstances.sh. Exiting..."
    exit 1
fi 
directories_in_use=$(echo "$directories_in_use" | grep "PGDATA directory for port" | awk '{print $NF}')

# Set path and port variables based on which arguments were used
if [ $# -eq 2 ]; then
    path="$1"
    port="$2"
elif [ $# -eq 1 ]; then
    input=$1
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        path="$PGDATA"
        port="$input"
    else
        path="$input"
        # Port will be determined by value in "$path/postgresql.conf" later in the script
        port=""
    fi
else
    path="$PGDATA"
    port="$PGPORT"
fi

# Check if path variable is set
if [ -z "$path" ]; then
    echo "PGDATA is unset"
    echo "PGDATA directory must be set either using the environment variable \$PGDATA or by passing it as in input parameter to this script"
    echo "Exiting..."
    exit 1
fi

# Check if path directory exists
if [ ! -d "$path" ]; then 
    echo "Provided PGData path $path could not be found or accessed. Exiting..."
    exit 1
fi

# Verify that inputted path is not already in use
for dir in $directories_in_use; do
    # realpath command use to ensure same directory format is used for $dir and $path
    if [ "$(realpath "$dir")" == "$(realpath "$path")" ]; then
        echo "PGDATA directory $path already in use. Exiting..."
        exit 1
    fi
done

# Check if port is set
path_to_conf="$path/postgresql.conf"
if [ ! -f "$path_to_conf" ]; then
    echo "Config file $path_to_conf not found. Exiting..."
    exit 1
fi
# -n -> suppress output to terminal
# -E -> extended regex
# find a line containing port = '<some_number>' tolerating arbitrary spacing and take the last (tail -1) port number found 
# Note: the last port number is the only one we care about because that is the port number postgres applies
conf_file_port=$(sed -E -n 's/^[[:space:]]*port[[:space:]]*=[[:space:]]*([0-9]+).*$/\1/p' "$path_to_conf" | tail -1)
if [ -z "$conf_file_port" ]; then
    conf_file_port=0
fi

# Remember whether a port came from the arguments or the environment, as opposed to
# being derived from the conf file. This distinguishes "no port anywhere" from
# "port supplied, conf line commented out".
port_supplied=1
if [ -z "$port" ]; then
    port_supplied=0
    port="$conf_file_port"
    # The conf has no active "port =" line, so fall back to the environment before failing.
    # Passing a PGDATA path clears $port above, so without this the error below would tell the
    # operator to set $PGPORT on the one code path that cannot use it.
    if [ "$port" -eq 0 ] && [ -n "$PGPORT" ]; then
        port="$PGPORT"
        port_supplied=1
    fi
fi

# Check if port is a number
if ! [[ "$port" =~ ^[0-9]+$ ]]; then
    echo "Port $port is not a valid port number. Exiting..."
    exit 1
fi

# conf_file_port is 0 only when the conf has no active "port =" line. That is only fatal when
# no port was supplied either - with one supplied, the commented line is updated below.
if [ "$port" -eq 0 ] && [ "$port_supplied" -eq 0 ]; then
    echo "No PGPORT supplied and no active 'port =' setting found in $path_to_conf."
    echo "Pass a port as an argument, set \$PGPORT, or uncomment the port line. Exiting..."
    exit 1
fi

# Check if port is already in use
port_in_use=$(netstat -tulpn 2>&1 | awk '{print $4}' | grep :$port$)
if [ -n "$port_in_use" ]; then
    echo "Provided PGPORT $port is already in use. Exiting..."
    exit 1
fi

# Check if port is between 0 and 65535
if [ "$port" -gt 65535 ] || [ "$port" -lt 1 ]; then
    echo "Error. Port must be between 0 and 65535. Exiting..."
    exit 1
fi

if [ "$conf_file_port" -ne "$port" ]; then
    echo "Port mismatch found, updating $path_to_conf to port $port"
    backup_time=$(date +%Y_%m_%d_%H:%M:%S)
    cp "$path_to_conf" "${path_to_conf}.$backup_time.backup"
    if [ $? -ne 0 ]; then
        echo "Could not back up $path_to_conf. Exiting..."
        exit 1
    fi
    echo "Backed up ${path_to_conf} to ${path_to_conf}.$backup_time.backup"
    # -i -> edit file in place
    # -E -> extended regex
    # Find file line with 'port = <number>' tolerating arbitrary spacing and replace with 'port = $port'
    # #? allows a commented default (e.g. "#port = 5432") to be uncommented and set
    sed -i -E "s/^[[:space:]]*#?[[:space:]]*port[[:space:]]*=[[:space:]]*[0-9]+/port = $port/" "$path_to_conf"
    if [ $? -ne 0 ]; then
        echo "Failed to update port in $path_to_conf. Exiting..."
        exit 1
    fi
    # Check that the sed edit above landed in the file
    # Check for a file line with 'port = $port' tolerating arbitrary spacing and comments after port number
    if ! grep -qE "^[[:space:]]*port[[:space:]]*=[[:space:]]*${port}([[:space:]]|#|$)" "$path_to_conf"; then
        if [ "$conf_file_port" -eq 0 ]; then
            echo "No 'port =' line found in $path_to_conf to update. Add one and retry. Exiting..."
        else
            echo "Port update did not apply to $path_to_conf. Exiting..."
        fi
        exit 1
    fi
fi

# Start instance
echo "Starting instance..."
pg_ctl start -D "$path" -o "-p $port"
if [ $? -ne 0 ]; then 
    echo "An error occurred while starting instance. Exiting..."
    exit 1
fi

echo "Script finished successfully."