#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script acts as a helper script for other scripts to check whether
#	   an index exists or doesn't exist in the current database. It checks
#	   dba_ind_columns for the index and returns 'Yes' if found or 'No'.
#      If columns are provided, this script can also return 'Index X exists on given
#      columns, but given index Y does not'. Columns must be in index column order with no spaces.
#
#####################################################################################

usage="Usage: CheckIfIndexExists.sh [index_name] [schema] [table (optional, required with column)] [column (optional, csv list)]"
example="Example: CheckIfIndexExists.sh MY_TABLE_IDX MY_SCHEMA MY_TABLE"

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
if [ $# -lt 2 ] || [ $# -gt 4 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Check oracle sid
sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
if [ $? -ne 0 ]; then
    echo "$sid_check"
    echo "An error occurred while checking for invalid SIDs. Exiting..."
    exit 1
fi
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "Error, \$ORACLE_SID not set..."
        exit 1
    fi
    echo "Error, provided \$ORACLE_SID is not open. Exiting..."
    exit 1
fi

index=${1^^}
schema=${2^^}
table=${3^^}
columns=${4^^}

index_clause="and index_name = '$index'"

# Check if schema exists
schema_check=$("$HOME/common/oracle/CheckIfSchemaExists.sh" -v "$schema")

if [ $? -ne 0 ]; then
    echo "Error occurred while attempting to run CheckIfSchemaExists.sh. Exiting..."
    echo "$schema_check"
    exit 1
elif [ "$schema_check" != "Yes" ]; then
    echo "ERROR: Schema $schema doesn't exist in the current database $ORACLE_SID. Exiting..."
    exit 1
fi

# Check if table exists on current database
if [ -n "$table" ]; then
    table_check=$("$HOME/common/oracle/CheckIfTableExists.sh" "$schema" "$table")

    if [ $? -ne 0 ]; then
        echo "Error occurred while attempting to run CheckIfTableExists.sh. Exiting..."
        echo "$table_check"
        exit 1
    elif [ "$table_check" != "Yes" ]; then
        echo "ERROR: Table $table doesn't exist in the current database $ORACLE_SID under schema $schema. Exiting..."
        exit 1
    fi

    # This will be added to the SQL query below
    given_table="and table_name = '$table'"

    if [ -n "$columns" ]; then
        # Set the IFS to a comma (,) to split the CSV columns
        IFS=','

        # check that all columns in csv list exist
        for col in $columns; do
            col_check=$("$HOME/common/oracle/CheckIfColumnExists.sh" -v "$schema" "$table" "$col")
            if [ $? -ne 0 ]; then
                echo "Error occurred while attempting to run CheckIfColumnExists.sh. Exiting..."
                echo "$col_check"
                exit 1
            elif [ "$col_check" != "Yes" ]; then
                echo "ERROR: Column $col doesn't exist in the current database $ORACLE_SID under table $schema.$table. Exiting..."
                exit 1
            fi
        done
        unset IFS

        given_column="where indexed_columns = '$columns'"
        index_clause=""
    fi 
fi

# Check if index exists
index_check=$(
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set heading off
    set feedback off
    set pagesize 0
    select index_name
    from (
        select index_name, LISTAGG(column_name, ',') WITHIN GROUP (order by column_position) as indexed_columns
        from dba_ind_columns
        where index_owner = '$schema'
        ${given_table:-} /* Will use given_table if set, nothing if not set */
        ${index_clause:-} /* Will use if columns not given as input */
        group by index_name
    ) 
    ${given_column:-} /* Will use given_column if set, nothing if not set */
    ;
EOD
)

bash_error=$?
ora_error=$(echo "$index_check" | grep "ORA-")

# Check if index was found
if [ $bash_error -ne 0 ] || [ -n "$ora_error" ]; then
    echo "Error occurred checking if index $index exists under schema $schema. Exiting..."
    echo "$index_check"
    exit 1
fi

if [[ "$index_check" == "$index" ]]; then
    echo "Yes"
    exit 0
elif [ -z "$index_check" ]; then
    echo "No"
    exit 0
else
    echo "Index $index_check exists on given columns, but given index $index does not"
    exit 0
fi