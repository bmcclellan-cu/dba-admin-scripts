#!/bin/bash
# AvailabilityFlag: Public
# Purpose: Prints the permissions of an object queried from dba_tab_privs.
#          The user inputs the schema with object name being an optional
#          parameter. The script outputs the object name(s), grantee, and
#          privileges for each object.
#
##########################################################################

usage="Usage: PrintObjectPermissions.sh [schema] [object_name (optional)]"
example="Example: PrintObjectPermissions.sh MY_SCHEMA MY_OBJECT"

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
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Checking ORACLE_SID
sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
if [ $? -ne 0 ]; then
    echo "$sid_check"
    echo "Error occurred when checking ORACLE_SID. Exiting..."
    exit 1
elif [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "Error, \$ORACLE_SID not set..."
        exit 1
    fi
    echo "Error, provided ORACLE_SID is not open. Exiting..."
    exit 1
fi

# Assigning variables
schema=${1^^}
object_name=${2^^}

# Check if schema exists
schema_check=$("$HOME/common/oracle/CheckIfSchemaExists.sh" -v "$schema")
if [ $? -ne 0 ]; then
    echo
    echo "Error occurred while attempting to run CheckIfSchemaExists.sh. Exiting..."
    echo "$schema_check"
    exit 1
elif [ "$schema_check" != "Yes" ]; then
    echo
    echo "ERROR: Schema $schema doesn't exist in the current database $ORACLE_SID"
    echo
    exit 1
fi

if [ $# -eq 1 ]; then
    # Notes on SQL functions:
    #   NVL(expression,replacement_val) - replaces null values with replacement_val
    object_permissions=$(
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        set linesize 100
        set pagesize 10000
        column object_name format a30
        column grantee format a30
        column privilege format a30
        SELECT b.segment_name object_name, NVL(a.grantee, 'N/A') grantee, NVL(a.privilege, 'No explicit privileges.') privilege
        FROM (
            select table_name,grantee,listagg(privilege, ',') as "PRIVILEGE" 
            from dba_tab_privs where owner like '${schema}' group by table_name, grantee order by 1,2,3
        ) a
        RIGHT OUTER JOIN (
            SELECT segment_name FROM (
                SELECT segment_name FROM dba_segments WHERE owner LIKE '${schema}' AND segment_type NOT LIKE 'LOB%'
                UNION
                SELECT object_name FROM dba_objects WHERE owner LIKE '${schema}' AND object_type NOT LIKE 'LOB%') a
            WHERE segment_name NOT IN (SELECT index_name FROM dba_indexes WHERE owner LIKE '${schema}' AND index_type = 'LOB')
        ) b
        ON b.segment_name = a.table_name;
EOD
    )
    if [ $? -ne 0 ]; then
        echo "$object_permissions"
        echo "Error occurred when printing object permissions for schema $schema. Exiting..."
        exit 1
    elif [[ "$object_permissions" =~ "no rows selected" ]]; then
        echo "There are no objects found under the schema $schema. Exiting..."
        exit 0
    else
        # Remove blank lines here, not in the query's command substitution: a pipe
        # there would make the $? check above report sed's status instead of sqlplus's
        echo "$object_permissions" | sed '/^$/d'
        exit 0
    fi
else
    # Running helper script
    object_check=$("$HOME/common/oracle/CheckIfObjectExists.sh" "$schema" "$object_name")

    # Check exit status
    if [ $? -ne 0 ]; then
        echo "$object_check"
        echo "Error occurred while checking if object exists. Exiting..."
        exit 1
    fi

    # Returning rows if found
    if [ "$object_check" == "Yes" ]; then
        # Notes on SQL functions:
        #   NVL(expression,replacement_val) - replaces null values with replacement_val
        #   listagg(column,',') - turn column into string separated by ','
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD | sed '/^$/d'
        whenever oserror exit 1
        whenever sqlerror exit 1
        set linesize 100
        set pagesize 10000
        column object_name format a30
        column grantee format a30
        column privilege format a30
        SELECT b.segment_name object_name, NVL(a.grantee, 'N/A') grantee, NVL(a.privilege, 'No explicit privileges.') privilege
        FROM (
            select table_name,grantee,listagg(privilege, ',') as "PRIVILEGE" 
            from dba_tab_privs where owner like '${schema}' and table_name='$object_name' group by table_name, grantee order by 1,2,3
        ) a
        RIGHT OUTER JOIN (
            SELECT segment_name FROM (
                SELECT segment_name FROM dba_segments WHERE owner LIKE '${schema}' AND segment_type NOT LIKE 'LOB%'
                    UNION
                SELECT object_name FROM dba_objects WHERE owner LIKE '${schema}' AND object_type NOT LIKE 'LOB%'
                ) a
            WHERE segment_name NOT IN (
                SELECT index_name FROM dba_indexes WHERE owner LIKE '${schema}' AND index_type = 'LOB'
            )
            AND segment_name = '${object_name}'
        ) b
        ON b.segment_name = a.table_name;
EOD
    elif [ "$object_check" == "No" ]; then
        echo
        echo "Object $object_name not found in database $ORACLE_SID"
        echo
        exit 1
    else
        echo "Error when finding object $object_name. Exiting..."
        exit 1
    fi
fi
