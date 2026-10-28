#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: The purpose of this script is to print the table privileges
#          for a user, both implicit and explicit.
#
# Note:     This script will filter out all permissions acting on objects in the pg_* and
#           information_schema schemas.
#
#####################################################################################################
usage="Usage: PrintTablePrivileges.sh [database | ALL] [user | ALL]"
example="Example: PrintTablePrivileges.sh mydb myuser"

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

# Check arguments
if [ $# -ne 2 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Set input parameters
db_list="${1,,}"
user="${2,,}"

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

# Based on first input parameter: either gather ALL databases or verify given database exists
if [ "${1^^}" == "ALL" ]; then
    db_list=$("$HOME/common/postgres/PrintDatabases.sh" "-d")
    if [ $? -ne 0 ]; then
        echo "$db_list"
        echo "Error occurred when running PrintDatabases.sh. Exiting..."
        exit 1
    fi
else
    # Ensure that database exists on instance
    db_exists=$("$HOME/common/postgres/CheckIfDatabaseExists.sh" "$db_list")
    if [ $? -ne 0 ]; then
        echo "Error occurred while checking if $db_list database exists. Exiting..."
        echo "$db_exists"
        exit 1
    elif [ "$db_exists" != "Yes" ]; then
        echo "ERROR: $db_list database does not exist on the server. Exiting..."
        exit 1
    fi
fi

# Verify that user exists on instance
if [[ "$user" == "all" ]]; then
    users=$("$HOME/common/postgres/PrintRoles.sh" "-d" "ALL")
    if [ $? -ne 0 ]; then
        echo "$users"
        echo "Error, PrintRoles.sh failed. Exiting..."
        exit 1
    fi
    users=$(echo "$users" | awk '{print "'"'"'"$0"'"'"'"}' | paste -sd, -) #converting to quoted csv list
    user="ALL roles"
    where_clause="where grantee in ($users)"
else
    check_role=$("$HOME/common/postgres/CheckIfRoleExists.sh" "$user")
    if [ $? -ne 0 ]; then
        echo "Error occurred while checking if role $user already exists. Exiting..."
        exit 1
    elif ! [[ $check_role = *Yes* ]]; then
        echo "Role $user does not exist on the current instance. Exiting..."
        exit 1
    fi
    role="WHERE rolname = '$user'"
    where_clause="where grantee = '$user'"
    users="'$user'"
fi

# Regardless of input, we want to filter out all tables in the pg_* and information_schema schemas.
# A regex is used rather than LIKE 'pg_%', because LIKE treats _ as a wildcard and would also
# hide user schemas such as pgbouncer or pgagent. The IMPLICIT query below uses the same filter.
where_clause="$where_clause
AND table_schema !~ '^pg_'
AND table_schema <> 'information_schema'"


for database in $db_list; do
    # Display EXPLICIT table privileges
    echo "EXPLICIT TABLE privileges for $user on database $database:"
    explicit_tb_access=$(
        psql -q -v ON_ERROR_STOP=on "$database" <<EOD
        select  grantee "Grantee", table_schema "Schema", table_name "Table", STRING_AGG(privilege_type, ', ' ORDER BY privilege_type) AS "Privileges" from information_schema.role_table_grants
        $where_clause
        GROUP BY grantee, table_schema, table_name
        ORDER BY grantee, table_schema, table_name;
EOD
    )
    if [ $? -ne 0 ]; then
        echo "Error occurred while querying for explicit table privileges for user $user on database $database. Exiting..."
        exit 1
    fi

    # Check if table privileges were found
    if (echo "$explicit_tb_access" | grep -q "(0 rows)"); then
        echo "No explicit table privileges found on database $database."
        echo
    else
        echo
        echo "$explicit_tb_access"
        echo
    fi

    # Display IMPLICIT table privileges
    echo "IMPLICIT TABLE privileges for $user on database $database:"
    sql_script=""
    first_user=true
    IFS=','
    for u in $users; do
        user_query="(
        -- $u

        WITH explicit AS (
            SELECT table_schema, table_name
            FROM information_schema.role_table_grants
            WHERE grantee = $u
        ),
        all_privs AS (
            SELECT
                n.nspname AS table_schema,
                c.relname AS table_name,
                unnest(ARRAY[
                    CASE WHEN has_table_privilege($u, c.oid, 'SELECT') THEN 'SELECT' END,
                    CASE WHEN has_table_privilege($u, c.oid, 'INSERT') THEN 'INSERT' END,
                    CASE WHEN has_table_privilege($u, c.oid, 'UPDATE') THEN 'UPDATE' END,
                    CASE WHEN has_table_privilege($u, c.oid, 'DELETE') THEN 'DELETE' END,
                    CASE WHEN has_table_privilege($u, c.oid, 'TRUNCATE') THEN 'TRUNCATE' END,
                    CASE WHEN has_table_privilege($u, c.oid, 'REFERENCES') THEN 'REFERENCES' END,
                    CASE WHEN has_table_privilege($u, c.oid, 'TRIGGER') THEN 'TRIGGER' END
                ]) AS privilege
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind = 'r'
            -- Same system-schema filter as the EXPLICIT query (all pg_* schemas, including pg_temp_*)
            AND n.nspname !~ '^pg_'
            AND n.nspname <> 'information_schema'
        )
        SELECT
            $u AS grantee,
            table_schema AS schema,
            table_name AS table,
            STRING_AGG(privilege, ', ' ORDER BY privilege) AS privileges
        FROM all_privs
        WHERE privilege IS NOT NULL
        AND (table_schema, table_name) NOT IN (
                SELECT table_schema, table_name FROM explicit
        )
        GROUP BY table_schema, table_name
        )"

        # Add UNION ALL between queries
        if [ "$first_user" = true ]; then
            sql_script="$user_query"
            first_user=false
        else
            sql_script+="
            UNION ALL
            $user_query"
        fi
    done

    # Add final ORDER BY to whole result
    sql_script+="
    ORDER BY grantee, schema, \"table\";"

    implicit_tb_access=$(echo "$sql_script" | psql -q -v ON_ERROR_STOP=on "$database")
    if [ $? -ne 0 ]; then
        echo "Error occurred while querying for implicit table privileges for user $user on database $database. Exiting..."
        exit 1
    fi

    # Check if table privileges were found
    if (echo "$implicit_tb_access" | grep -q "(0 rows)"); then
        echo "No implicit table privileges found on database $database."
        echo
    else
        echo
        echo "$implicit_tb_access"
        echo
    fi
done
