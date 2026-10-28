#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose:  This script prints a list of tablespaces in the provided database
#           or all databases on the instance along with the owner, location, and size.
#
# Notes:    This script typically excludes pg_global because it does not have any databases
#           and thus is not included in any of the database outputs. If this script is run
#           without any parameters, it prints out all the tablespaces on the instance, including
#           pg_global.
#
################################################################################

usage="Usage: PrintTablespaces.sh [ -d (data only)] [database | ALL (optional)]"
example="Example: PrintTablespaces.sh data_dev"

dataonly=false

# Process input options
while getopts ":hd" option; do
    case $option in
        h)
            echo "$usage"
            echo "$example"
            exit 0
            ;;
        d)
            dataonly=true
            ;;
        \?)
            echo "Error: Invalid option"
            exit 1
    esac
done

shift $((OPTIND-1))


# Check arguments
if [ $# -gt 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# If user input a value, set the database variable
if [ $# -eq 1 ]; then
    database="${1,,}"
fi

exit_code=0

filter_tbsp=true

# Check that instance on port is running.
instance_check=$("$HOME/common/postgres/CheckInstanceOpenStatus.sh")
if [ $? -ne 0 ]; then
    echo "$instance_check"
    echo "Error occurred while checking open status of instance on port $PGPORT."
    exit 1
elif [ "$instance_check" != "open" ]; then
    echo "No instance open on port $PGPORT"
    exit 1
fi

# If no database was specified, connect to postgres database and print out all tablespaces on instance.
if [ -z "$database" ]; then
    ! $dataonly && echo "No database provided, printing all tablespaces on instance..."
    databases="postgres"
    filter_tbsp=false
# Gather list of all databases if ALL option is given
elif [ "${database}" == "all" ]; then
    databases=$("$HOME/common/postgres/PrintDatabases.sh" -d)
    if [ $? -ne 0 ]; then
        echo "$databases"
        echo "Error occurred while gathering list of all databases on instance. Exiting..."
        exit 1
    fi
else
    # Ensure that database exists if db name given
    db_exists=$("$HOME/common/postgres/CheckIfDatabaseExists.sh" "$database")
    if [ $? -ne 0 ]; then
        echo "$db_exists"
        echo "Error occurred while checking if database $database exists. Exiting..."
        exit 1
    elif [ "$db_exists" != "Yes" ]; then
        echo "ERROR: database $database does not exist on the server. Exiting..."
        exit 1
    fi
    databases=$database
fi

for database in $databases; do
    # Only print user-friendly header if -d option not provided.
    if ! $dataonly; then
        # If no database is provided, we print out all tablespaces on instance, otherwise
        # we print out tablespaces per-database.
        if $filter_tbsp; then
            echo "Printing tablespaces on database $database"
        else
            echo "Printing all tablespaces on instance"
        fi
    else
        if [ "${1^^}" == "ALL" ]; then
            # Echo database name with data only option only if ALL database given as input
            echo "ON DATABASE: $database"
        fi
    fi

    # If the user doesn't provide a database, we log into the postgres DB and print out ALL tablespaces for
    # all DBs, including pg_global. Otherwise, we filter as normal.
    if "$filter_tbsp"; then
        database_clause="
        WHERE
            t.spcname <> 'pg_global'
        AND (
            SELECT oid FROM pg_database WHERE datname = '$database'
        ) IN (SELECT pg_tablespace_databases(t.oid))"
    fi

    # If user didn't provide dataonly option, output all tablespaces on desired database
    # straight from psql with no format changes
    if ! $dataonly; then

        echo ""

        tbsp_details=$(psql -q -v ON_ERROR_STOP=on "$database" <<EOD
            SELECT t.spcname AS "Tablespace Name",
            pg_get_userbyid(t.spcowner) AS "Owner",
            pg_tablespace_location(t.oid) AS "Location",
            pg_size_pretty(pg_tablespace_size(t.oid)) AS "Size"
            FROM pg_tablespace t
            $database_clause
            ORDER BY 1;
EOD
        )
        if [ $? -ne 0 ]; then
            echo "$tbsp_details"
            echo "An error occurred while querying for tablespace details on database $database. Continuing..."
            exit_code=1
            continue
        fi

        if (echo "$tbsp_details" | grep -q "(0 rows)"); then
            echo "No tablespaces found on database $database. Continuing..."
        else
            echo "$tbsp_details"
            echo "Tablespaces successfully printed for database $database"
        fi

        echo
    # If user did provide dataonly option, output all tablespaces on desired database
    # with no formatting
    else
        tbsp_list=$(
            psql -q -v ON_ERROR_STOP=on "$database" <<EOD
            \pset tuples_only on
            SELECT t.spcname AS "Tablespace Name"
            FROM pg_tablespace t
            $database_clause
            ORDER BY 1;
EOD
        )
        if [ $? -ne 0 ]; then
            echo "$tbsp_list"
            echo "An error occurred while querying for raw tablespace list on $database. Continuing..."
            exit_code=1
            continue
        fi

        echo "$tbsp_list" | xargs | tr " " "\n"
    fi
done

# Check exit status of query
if [ "$exit_code" -ne 0 ]; then
    echo "One or more errors occurred during script execution. Check above output for more information. Exiting..."
    exit 1
else
    # Only output messaging if user did not include dataonly option
    if ! $dataonly; then
        echo "All tablespaces successfully printed"
    fi
    exit 0
fi
