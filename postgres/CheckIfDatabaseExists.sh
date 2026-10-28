#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script acts as a helper script for other scripts to check if a
#          database exists on the server. It returns 'Yes' if the database is found,
#          or 'No' if not. If the query fails, it prints 'ERROR' and psql's exit code and exits 1.
# 
#####################################################################################

usage="Usage: CheckIfDatabaseExists.sh [database]"
example="Example: CheckIfDatabaseExists.sh pg_dev"

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


# Check arguments
if [ $# -ne 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Set variable from parameter
database=${1,,}

# Check for database, store if found
db_check=$(psql -q -v ON_ERROR_STOP=on <<EOD
\pset tuples_only on
select datname from pg_database where datname = '$database';
EOD
)

sql_error=$?

# Check if database was found
if [ "$sql_error" -ne 0 ]; then
    echo "ERROR"
    echo "$sql_error"
    exit 1
elif [ -z "$db_check" ]; then
    echo "No"
    exit 0
else
    echo "Yes"
    exit 0
fi
