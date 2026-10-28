#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose:  Print PostgreSQL roles and their database CONNECT access.
#
#           If a database is specified, this script shows instance superusers and roles with
#           CONNECT access to that database. ALL shows the superuser list, CONNECT roles for each
#           database, roles with LOGIN, and roles without LOGIN privileges.
#
#           -d prints only role names: CONNECT roles for a named database, or
#           every instance role (including roles without LOGIN) for ALL.
#
#           Roles whose names begin with "pg_" are excluded from every query.
#
################################################################################

usage="Usage: PrintRoles.sh [-d (data only option)] [ Database | ALL ]"
example="Example: PrintRoles.sh -d pg_db"

dataonly=false
# -q suppresses psql startup messages; -v ON_ERROR_STOP=on makes SQL errors
# return a nonzero status so the script can stop after a failed query.
psql_options=(-q -v ON_ERROR_STOP=on)

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
        # -A removes table padding and borders; -t omits headings and row counts.
        # Together they print one role per line for data-only output.
        psql_options+=(-A -t)
        shift 1
        ;;
    \?)
        echo "ERROR: Invalid option -$OPTARG."
        exit 1
        ;;
    esac
done

# Check arguments
if [ $# -ne 1 ]; then
    echo "ERROR: Expected exactly one database name or ALL."
    echo "$usage"
    echo "$example"
    exit 1
fi

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

# If the user provided the ALL input, generate a list of valid databases
if [ "${1^^}" == "ALL" ]; then
    if "$dataonly"; then
        # The ALL option combined with -d is a special case, we just spit out
        # all the instance roles instead of iterating through the databases.
        databases=""
    else
        databases=$("$HOME/common/postgres/PrintDatabases.sh" "-d")
        if [ $? -ne 0 ]; then
            echo "$databases"
            echo "An error occurred while listing databases."
            exit 1
        fi
    fi
else
    databases=${1,,}
    # Ensure that database exists
    db_exists=$("$HOME/common/postgres/CheckIfDatabaseExists.sh" "$databases")
    if [ $? -ne 0 ]; then
        echo "An error occurred while checking whether database $databases exists."
        if [ -n "$db_exists" ]; then
            echo "$db_exists"
        fi
        exit 1
    elif [ "$db_exists" != "Yes" ]; then
        echo "ERROR: Database $databases does not exist on the server."
        exit 1
    fi
fi

if ! "$dataonly"; then
    echo "Printing roles with SUPERUSER status on instance..."
    echo

    # Query for all roles with superuser status
    psql "${psql_options[@]}" <<EOD
        SELECT rolname AS "ROLE",
            CASE WHEN rolsuper THEN 'YES' ELSE 'NO' END AS "SUPERUSER"
        FROM pg_roles
        WHERE rolname !~ '^pg_'
        ORDER BY rolname;
EOD
    if [ $? -ne 0 ]; then
        echo "An error occurred while querying superuser status."
        exit 1
    fi
fi

for database in $databases; do
    if ! "$dataonly"; then
        echo "Printing roles with CONNECT privileges for database $database..."
        echo
    fi

    # Display list of roles on the provided database
    psql "${psql_options[@]}" "$database" <<EOD
        SELECT rolname "ROLE"
        FROM pg_roles
        WHERE has_database_privilege(rolname, '$database', 'CONNECT')
        AND rolname !~ '^pg_'
        ORDER BY rolname;
EOD
    if [ $? -ne 0 ]; then
        echo "An error occurred while listing roles with CONNECT access to database $database."
        exit 1
    fi
done

# If the user provided the ALL input, generate a list of all roles on the instance regardless of their connect privileges
if [ "${1^^}" == "ALL" ]; then
    if ! "$dataonly"; then
        echo "All roles on current instance:"
        echo
    fi

    psql "${psql_options[@]}" <<EOD
        SELECT rolname "ROLE"
        FROM pg_roles
        WHERE rolname !~ '^pg_'
        ORDER BY rolname;
EOD
    if [ $? -ne 0 ]; then
        echo "An error occurred while listing all instance roles."
        exit 1
    fi

    if ! "$dataonly"; then
        # Getting roles without LOGIN privileges
        echo "Roles on current instance without login privileges:"
        echo

        psql "${psql_options[@]}" <<EOD
            SELECT rolname "ROLE"
            FROM pg_roles
            WHERE
                rolname !~ '^pg_'
                AND rolcanlogin = false
            ORDER BY rolname;
EOD
        if [ $? -ne 0 ]; then
            echo "An error occurred while listing roles without LOGIN privileges."
            exit 1
        fi
    fi

fi

if ! "$dataonly"; then
    echo ""
    echo "Roles successfully printed"
fi
