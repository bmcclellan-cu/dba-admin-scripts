#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script acts as a helper script for other scripts to check whether
#	   a role does or does not exist on the server. It checks the pg_roles table
#	   for the role and returns 'Yes' if found or 'No' if not.
#
# NOTE: If the optional database param is provided, the script will check that the role
#      has BOTH "can login" and "Has Connect Privilege" specifically for that database
#
#####################################################################################

usage="Usage: CheckIfRoleExists.sh [role] [database (optional)]"
example="Example 1: CheckIfRoleExists.sh pg_monitor
Example 2: CheckIfRoleExists.sh postgres pg_db"

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
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Set user input to lowercase
role=$(echo "$1" | tr '[:upper:]' '[:lower:]')

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

# If no database argument was provided check if role exists on entire server
if [ -z $2 ]; then
    # Store the role in $role_check if found in pg_roles
    role_check=$(psql -q -v ON_ERROR_STOP=on <<EOD
    \pset tuples_only on
    select rolname from pg_roles where rolname = '$role';
EOD
    )

    # Check if role was found
    if [ $? -ne 0 ]; then
        echo "The following error occurred while checking if the role ${role} exists:"
        echo "$role_check"
        echo "Exiting..."
        exit 1
    elif [ -z "$role_check" ]; then
        echo "No"
        exit 0
    else
        echo "Yes"
        exit 0
    fi
else
    db=${2,,}

    # Checks that database exists
    db_exists=$("$HOME/common/postgres/CheckIfDatabaseExists.sh" "$db")
    if [ $? -ne 0 ]; then
        echo "Error occurred while checking if $db database exists"
        echo "$db_exists"
        exit 1
    elif [ "$db_exists" != "Yes" ]; then
        echo "ERROR: $db database does not exist on the server. Exiting..."
        exit 1
    fi

    # Getting table of databases and their roles
    role_list=$(psql -q -v ON_ERROR_STOP=on <<EOD
    SELECT
    d.datname as "Database",
    r.rolname as "Role",
    r.rolcanlogin as "Can Login",
    has_database_privilege(r.rolname, d.datname, 'connect') as "Has Connect Privilege"
    FROM
    pg_database d
    CROSS JOIN
    pg_roles r
    ORDER BY
    r.rolname, d.datname;
EOD
    )
    # Checking query status
    if [ $? -ne 0 ]; then
        echo "The following error occurred while checking if the role ${role} exists on ${db}:"
        echo "$role_list"
        echo "Exiting..."
        exit 1
    else
        # Checks that the "Can Login" and "Has Connect Privilege" fields are both set to T.
        # The ^\s* anchors the database name to the start of the row, so checking database
        # "dbdev" does not match a row for "mydbdev". The role is already bounded by "|" on both sides.
        res=$(echo "$role_list" | grep "^\s*$db\s\+|\s\+$role\s\+|\s\+t\s\+|\s\+t")
        if [ -z "$res" ]; then
            echo "No"
            exit 0
        else
            echo "Yes"
            exit 0
        fi
    fi
fi
