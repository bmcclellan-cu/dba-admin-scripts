#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script is used to update the config file in the PGDATA directory for
#          a postgres instance. If a config file already exists the script saves it 
#          under a new name and replaces it with the default template file 
#          for the current version from $HOME/internal-dba-admin/postgres/configs/ (can be overwritten with -d)
#          The user can change the size of the shared buffer
#          and the port the instance will run on in the config
#          file using the shared memory and port inputs.
#
#          Setting the log_directory is handled in PgLoadInstance.sh
# 
# Note: Shared buffer sets the amount of memory that can be used for caching. For
#       the best performance the shared buffer should be around 25% to 40% of the
#       total system memory.
# 
# Note: For the updates on the config file to go into effect, the postgres instance 
#       will need to be restarted.
#
#####################################################################################

usage="Usage: UpdateConfTemplateFile.sh [ -d <config_directory> (optional) ] [port] [shared_memory (in GB)] [PGDATA]"
example="Example 1: UpdateConfTemplateFile.sh 5433 4 /postgresWeeklyRestoreTests/instance/PGDATA
Example 2: UpdateConfTemplateFile.sh -d /postgres-configs/ 5433 4 /myPgInstance/PGDATA"

# Process input options
# Directory holding the postgresql.conf.v* templates; override with -d
config_dir="$HOME/internal-dba-admin/postgres/configs/"
while getopts ":hd:" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    d)
        config_dir="$OPTARG"
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done
shift "$((OPTIND-1))"

# Check arguments
if [ $# -ne 3 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

if ! [ -d "$config_dir" ]; then
    echo "Configuration directory $config_dir does not exist. Exiting..."
    exit 1
fi
resolved_config_dir=$(realpath "$config_dir")
if [ $? -ne 0 ]; then
    echo "An error occurred while resolving $config_dir with realpath. Exiting..."
    exit 1
fi

existing_config=0
port=$1
shared_mem=$2
path=$3

# Check if port is a number
if ! [[ "$port" =~ ^[0-9]+$ ]]; then
    echo "Port $port is not a valid port number. Exiting..."
    exit 1
fi

# Check if port is between 1 and 65535
if [ "$port" -gt 65535 ] || [ "$port" -lt 1 ]; then
    echo "Error, port must be between 0 and 65535. Exiting..."
    exit 1
fi

# Check that shared memory is a number
if ! [[ "$shared_mem" =~ ^[0-9]+$ ]]; then
    echo "Second input, shared memory, must be a number. Exiting..."
    exit 1
fi

# Check if shared memory is between 1 GB and 8192 GB
# This is just a recomendation/sensibility check
if [ "$shared_mem" -gt 8192 ] || [ "$shared_mem" -lt 1 ]; then
    echo "Error, Shared memory must be between 1 and 8192 GB. Exiting..."
    exit 1
fi

# Check if path directory exists
if [ ! -d "$path" ]; then 
    echo "Provided PGDATA path $path could not be found or accessed. Exiting..."
    exit 1
fi

# Remove double forward slashes and trailing slash at the end of given path
path=$(echo "$path" | sed -e 's/\/\{2,\}/\//g' -e 's/\/$//')

# Save old conf file
if [ -f "$path/postgresql.conf" ]; then
    # Create timestamp
    timestamp=$(date +%Y_%m_%d_%H:%M)
    # Copy file with timestamp
    cp "$path/postgresql.conf" "$path/postgresql_${timestamp}.conf"
    # Error check
    if [ $? -ne 0 ]; then
        echo "Error: Could not make copy of previous config file. Exiting..."
        exit 1
    fi
    echo "Previous config file was backed up in: $path/postgresql_${timestamp}.conf"
    existing_config=1
else
    echo "No postgres config file found, creating one based on the current template file."
    existing_config=0
fi

# Verify that postgres is installed
# This is a nice way to check if psql is installed, it only checks the exit status of 'psql' command. If psql is not installed, enter the conditional
# '1>/dev/null 2>&1' will discard output from file descriptor 1 and file descriptor 2 
if ! psql --version 1>/dev/null 2>&1; then 
    echo "Error: postgres is not installed. Exiting..."
    exit 1
else
    postgres_version=$(psql --version) 
    postgres_exit=$?
    postgres_major_version=$(echo "$postgres_version" | awk '{print $3}' | cut -d. -f1)
    # Find which major version of postgres is currently installed
    if [ "$postgres_exit" -ne 0 ]; then
        echo "Error: failed to get psql version. Exiting..."
        exit 1
    fi

fi

echo "Current postgres major version identified as $postgres_major_version"

# Copy the config file based on the postgres version
if [ "$postgres_major_version" -eq "18" ]; then
    cp "$resolved_config_dir/postgresql.conf.V18.05_31_26" "$path/postgresql.conf"
elif [ "$postgres_major_version" -eq "16" ]; then
    cp "$resolved_config_dir/postgresql.conf.V16.05_16_24" "$path/postgresql.conf"
else
    echo "Unsupported postgres version $postgres_major_version! This script only supports versions 16 and 18. Exiting..."
    exit 1
fi

# Error check
if [ $? -ne 0 ]; then
    echo "Error: config file could not be found in directory $resolved_config_dir. Exiting..."
    exit 1
fi

if [ ! -f "$path/postgresql.conf" ]; then
    echo "Error: PostgreSQL configuration file not found at $path/postgresql.conf. Exiting..."
    exit 1
fi

# Update shared buffer
# -i tells sed to edit the file in place
# -E tells sed to use extended regex
if ! sed -i -E "s/shared_buffers = [0-9]+/shared_buffers = $shared_mem/" "$path/postgresql.conf"; then
    echo "Error: Failed to update shared buffer in postgresql.conf. Exiting..."
    exit 1
fi

# Update port number
# -i tells sed to edit the file in place
# -E tells sed to use extended regex
if ! sed -i -E "s/port = [0-9]+/port = $port/" "$path/postgresql.conf"; then
    echo "Error: Failed to update port number in postgresql.conf. Exiting..."
    exit 1
fi

updated_buffer=$(grep "shared_buffers = " "$path/postgresql.conf")
updated_port=$(grep "port = " "$path/postgresql.conf")
echo "Updated values in file:"
echo "$updated_port"
echo "$updated_buffer"

if [ "$existing_config" -eq 0 ]; then
    echo "New file $path/postgresql.conf created successfully."
    exit 0
else
    echo "File $path/postgresql.conf updated successfully."
    exit 0
fi