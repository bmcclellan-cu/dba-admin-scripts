#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script identifies "global" indexes on specific partitioned tables, in a schema, or in an entire database.
#          Global indexes are indexes that span multiple partitions of a partitioned table.
#          Global indexes can be either partitioned or non-partitioned.
#
##########################################################################
usage="Usage: DisplayGlobalIndexesPartitionedTables.sh [ schema.table|schema|ALL ] [ identifier (table|schema) ] [ SID | ALL (optional) ]"
example="Example 1: DisplayGlobalIndexesPartitionedTables.sh MY_SCHEMA.MY_TABLE table
Example 2: DisplayGlobalIndexesPartitionedTables.sh MY_SCHEMA schema DB_SID
Example 3: DisplayGlobalIndexesPartitionedTables.sh ALL
Example 4: DisplayGlobalIndexesPartitionedTables.sh ALL schema
Example 5: DisplayGlobalIndexesPartitionedTables.sh ALL schema ALL"

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

# Verify correct number of arguments
if [ $# -lt 1 ] || [ $# -gt 3 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Verify ALL parameter set correctly
if [ $# -eq 1 ] && [ "${1^^}" != "ALL" ]; then
    echo "Error: If only one argument is provided, it must be 'ALL'."
    echo "$usage"
    echo "$example"
    exit 1
fi

# Verify second parameter set correctly
if { [ $# -eq 2 ] || [ $# -eq 3 ] ;} && [ "${2^^}" != "TABLE" ] && [ "${2^^}" != "SCHEMA" ]; then
    echo "Error: Second argument must be 'TABLE' or 'SCHEMA'."
    echo "$usage"
    echo "$example"
    exit 1
fi

if [ $# -eq 3 ] && [ "${3^^}" == "ALL" ] && [ "${1^^}" != "ALL" ]; then
    echo "Error: If third argument is 'ALL', first argument must also be 'ALL'"
    echo "$usage"
    echo "$example"
    exit 1
fi

if [ "${2^^}" == "TABLE" ]; then
    if [ "${1^^}" == "ALL" ]; then
        echo "\"ALL\" input cannot be used with the table identifier. Exiting..."
        exit 1
    fi

    if [[ $1 != *.* ]]; then
        echo "Invalid input; table parameter must look like 'SCHEMA.TABLE'. Exiting..."
        exit 1
    fi

    # Assume user entered SCHEMA.TABLE, split into variables
    schema=$(echo "${1^^}" | cut -d "." -f1)
    table=$(echo "${1^^}" | cut -d "." -f2)
elif [ "${2^^}" == "SCHEMA" ]; then
    schema="${1^^}"
fi

if [ -z "$3" ] && [ -z "$ORACLE_SID" ]; then
    echo "ERROR: \$ORACLE_SID not set and none provided."
    echo "Rerun the script and enter the target database as the first parameter."
    echo "Exiting..."
    exit 1
elif [ -n "$3" ]; then
    export ORACLE_SID=${3,,}
fi

SIDS=$("$HOME/common/oracle/VerifyAllParam.sh" "$ORACLE_SID")

if [ $? -ne 0 ]; then
    echo "Error: Failed to validate $ORACLE_SID with VerifyAllParam.sh"
    echo "$SIDS"
    exit 1
fi

# With no option, VerifyAllParam.sh prints an "Invalid SIDS: ..." line and a
# "Valid SIDS: ..." line; keep the space-separated list after each label
valid_sids=$(printf '%s\n' "$SIDS" | sed -n 's/^Valid SIDS: *//p')
invalid_sids=$(printf '%s\n' "$SIDS" | sed -n 's/^Invalid SIDS: *//p')

if [ -z "$valid_sids" ]; then
    echo "No Valid SIDS were returned from VerifyAllParam.sh."
    if [ -n "$invalid_sids" ]; then
        echo "Error: database(s) $invalid_sids are not open."
    fi
    echo "Exiting..."
    exit 1
fi

# Main logic for retrieving global indexes
get_global_indexes() {
    local where_clause=$1

    # Find non-partitioned global indexes. Both queries look only at indexes on
    # partitioned tables; where_clause narrows them to one table, one schema, or
    # (for ALL) the schemas in all_user_schemas below.
    non_partitioned_global=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        set heading off
        set feedback off

        SELECT index_name, table_owner, table_name
        FROM dba_indexes
        WHERE (table_owner, table_name) IN (
            SELECT owner, table_name FROM dba_part_tables
        )
        AND index_name NOT LIKE 'SYS\_%' ESCAPE '\'
        AND partitioned = 'NO' $where_clause;
EOD
    )
    if [ $? -ne 0 ]; then
        echo "$non_partitioned_global"
        echo "Error occurred while retrieving non-partitioned global indexes. Continuing to next SID..."
        exit_code=1
        return 1
    fi
    # Format the output to work with column command 
    non_partitioned_global=$(echo "$non_partitioned_global" | grep -v "^[[:space:]]*$")
    non_partitioned_global_formatted=""
    while read -r index_name && read -r table_owner && read -r table_name; do
        non_partitioned_global_formatted+="$table_owner $table_name $index_name NO\n"
    done <<< "$non_partitioned_global"

    # Find partitioned global indexes
    partitioned_global=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        set heading off
        set feedback off

        SELECT index_name, table_owner, table_name
        FROM dba_indexes
        JOIN dba_part_indexes USING (index_name, owner, table_name)
        WHERE (table_owner, table_name) IN (
            SELECT owner, table_name FROM dba_part_tables
        )
        AND index_name NOT LIKE 'SYS\_%' ESCAPE '\'
        AND partitioned = 'YES'
        AND locality = 'GLOBAL' $where_clause;
EOD
    )
    if [ $? -ne 0 ]; then
        echo "$partitioned_global"
        echo "Error occurred while retrieving partitioned global indexes. Continuing to next SID..."
        exit_code=1
        return 1
    fi
    # Format the output to work with column command
    partitioned_global=$(echo "$partitioned_global" | grep -v "^[[:space:]]*$")
    partitioned_global_formatted=""
    while read -r index_name && read -r table_owner && read -r table_name; do
        partitioned_global_formatted+="$table_owner $table_name $index_name YES\n"
    done <<< "$partitioned_global" 

    # Combine both non-partitioned and partitioned global indexes
    global_indexes=""
    global_indexes+="$non_partitioned_global_formatted"$'\n'"$partitioned_global_formatted"

    # Check if any global indexes were found and output them
    if [ -z "$(echo -e "$global_indexes" | grep -v '^[[:space:]]*$')" ]; then
        echo "No global indexes found."
    else
        echo -e "$global_indexes" | column -t --table-columns "Schema,Table,Index,Index Partitioned"
    fi
}

# ALL searches every schema Oracle does not maintain, the same schemas that
# CheckIfDatabaseIsPartitioned.sh counts. TABLE and SCHEMA modes search the named
# schema whoever maintains it, but only on a database that check counts as partitioned.
all_user_schemas="AND table_owner IN (SELECT username FROM dba_users WHERE oracle_maintained = 'N')"

exit_code=0
for sid in $valid_sids; do
    export ORACLE_SID=$sid
    echo "Displaying global indexes for database $sid"
    echo "--------------------------------------------------------------"

    part_check=$("$HOME/common/oracle/CheckIfDatabaseIsPartitioned.sh" -v "$sid")
    if [ $? -ne 0 ]; then
        echo "$part_check"
        echo "Error occurred while checking if database $sid is partitioned. Continuing to next SID..."
        exit_code=1
        echo
        continue
    fi
    if [ "$part_check" != "Yes" ]; then
        echo "Database $sid is not partitioned. Continuing to next SID..."
        echo
        continue
    fi

    # Determine how to call get_global_indexes and what validation is required
    if [ "${1^^}" == "ALL" ] && { [ $# -eq 1 ] || [ $# -eq 3 ]; }; then
        get_global_indexes "$all_user_schemas"
    elif [ "${2^^}" == "TABLE" ]; then
        # Check that schema exists
        schema_check=$("$HOME/common/oracle/CheckIfSchemaExists.sh" -v "$schema")
        if [ $? -ne 0 ]; then
            echo "$schema_check"
            echo "Error occurred while checking if schema $schema exists. Continuing to next SID..."
            echo
            exit_code=1
            continue
        elif [ "$schema_check" != "Yes" ]; then
            echo "Schema $schema does not exist on $sid. Continuing to next SID..."
            echo
            exit_code=1
            continue
        fi

        # Check that given table exists under given schema
        table_check=$("$HOME/common/oracle/CheckIfTableExists.sh" "$schema" "$table")
        if [ $? -ne 0 ]; then
            echo "Error occurred while checking if table $table exists. Continuing to next SID..."
            echo "$table_check"
            echo
            exit_code=1
            continue
        elif [ "$table_check" != "Yes" ]; then
            echo "Table $table does not exist under schema $schema. Continuing to next SID..."
            exit_code=1
            echo
            continue
        fi

        table_partition_check=$("$HOME/common/oracle/CheckIfTableIsPartitioned.sh" "$schema" "$table")
        if [ $? -ne 0 ]; then
            echo "$table_partition_check"
            echo "Error occurred while checking if table $table is partitioned. Continuing to next SID..."
            echo
            exit_code=1
            continue
        elif [ "$table_partition_check" != "YES" ]; then
            echo "Table $table is not partitioned and cannot have local/global indices. Continuing to next SID..."
            echo
            continue
        fi

        get_global_indexes "AND table_owner = '$schema' AND table_name = '$table'"
    elif [ "${2^^}" == "SCHEMA" ]; then
        if [ "$schema" != "ALL" ]; then
            schema_check=$("$HOME/common/oracle/CheckIfSchemaExists.sh" -v "$schema")
            if [ $? -ne 0 ]; then
                echo "$schema_check"
                echo "Error occurred while checking if schema $schema exists. Continuing to next SID..."
                echo
                exit_code=1
                continue
            elif [ "$schema_check" != "Yes" ]; then
                echo "Schema $schema does not exist on $sid. Continuing to next SID..."
                echo
                exit_code=1
                continue
            fi
        fi

        if [ "$schema" != "ALL" ]; then
            get_global_indexes "AND table_owner = '$schema'"
        else
            get_global_indexes "$all_user_schemas"
        fi
    fi
    echo
done

if [ -n "$invalid_sids" ]; then
    echo "Error: database(s) $invalid_sids are not open. Exiting..."
    exit_code=1
fi

if [ $exit_code -ne 0 ]; then
    echo "Errors occurred during execution. Please check the output above."
    exit $exit_code
else
    echo "Global indexes displayed successfully."
fi
