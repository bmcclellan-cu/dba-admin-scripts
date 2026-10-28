#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script determines if a postgres instance is open, or closed by
#          attempting to connect and run a simple postgresql command.
#
################################################################################

usage="Usage: CheckInstanceOpenStatus.sh [ Port (optional) ]"
example="Example: CheckInstanceOpenStatus.sh 5432"

# Process input options
while getopts ":h" option; do
    case $option in
        h)
            echo $usage
            echo $example
            exit 0;;
        \?)
            echo "Error: Invalid option"
            exit 1
    esac
done


if [[ $# -gt 1 ]]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Set port to input if given or PGPORT if input is not given
if [ -n "$1" ]; then
    port=$1
elif [ -n "$PGPORT" ]; then
    port=$PGPORT
else
    echo "ERROR: \$PGPORT is not set and no port value was given to CheckInstanceOpenStatus.sh"
    exit 1
fi

#Validating input if given
if [[ ! "$port" =~ ^[0-9]+$ ]] && [ "${#port}" -ne 0 ]; then
    echo "ERROR: port must only contain only numbers. Exiting..."
    exit 1
fi

# Valid TCP ports are 1-65535 (0 is reserved and cannot be connected to).
# The length check comes first: a number too large for bash makes [ -lt ] and [ -gt ] error out
# instead of returning true, which would let it through.
if [ "${#port}" -gt 5 ] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo "ERROR: Port number must be between 1 and 65535. Exiting..."
    exit 1
fi

# Creating a dump variable to hold the output of trying to connect
dump=$(2>&1 psql -q -v ON_ERROR_STOP=on -p $port <<EOD
    \pset tuples_only on
    SELECT version();
EOD
)

if [ $? -ne 0 ]; then
    echo "closed"
    exit 0
else
    echo "open"
    exit 0
fi
