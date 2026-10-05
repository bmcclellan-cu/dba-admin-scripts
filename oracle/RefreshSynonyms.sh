#!/bin/bash
# AvailabilityFlag: Public
#
#  Purpose: The purpose of this script is to refresh the public synonyms
#	    of the current database that correlate with a given schema or schema 
#       base name. Uses DeleteOldSynonyms.sh as a helper script.
#
##########################################################################

usage="Usage: RefreshSynonyms.sh [schema name | schema base name]"
example1="Example #1: RefreshSynonyms.sh MYDB_USERS"
example2="Example #2: RefreshSynonyms.sh MYDB"

# Process input options
while getopts ":h" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example1"
        echo "$example2"
        exit 0
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

# display usage and example if parameter is not given
if [[ $# -ne 1 ]]; then
    echo "$usage"
    echo "$example1"
    echo "$example2"
    exit 1
fi

# Checking ORACLE_SID
sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "Error, \$ORACLE_SID not set..."
        exit 1
    fi
    echo "Error, provided \$ORACLE_SID is not open. Exiting..."
    exit 1
fi

# Set schema to capitalized input for schema name
schema=${1^^}

# Check to see if any schemas match the input
schema_check=$(
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD | xargs
    set heading off
    set feedback off
    whenever oserror exit 1
    whenever sqlerror exit 1
    select * from dba_users where username like '${schema}%';
    exit;
EOD
)

# Check for errors
if [ $? -ne 0 ]; then 
    echo "An error occurred while trying to fcheck if the provided schema/base name exists. Exiting..."
    exit 1
elif [ -z "$schema_check" ]; then 
    echo "Error. There are no schema names like ${schema} on database ${ORACLE_SID}. Exiting..."
    exit 1
fi

# Display start of refresh process
echo "Refreshing public synonyms on ${schema}"
echo ""

# Delete old public synonyms for schema
result=$("$HOME/common/oracle/DeleteOldSynonyms.sh" "$schema")

# Checks for errors with helper script
if [ $? -ne 0 ]; then
    echo "Error occurred while deleting old synonyms. Exiting..."
    exit 1
fi

# Use grep to see if there were no synonyms to refresh from DeleteOldSynonyms.sh
synonyms_to_refresh=$(echo "$result" | grep "No old public synonyms found on")

# If there were old synonyms to delete, print the result from DeleteOldSynonyms.sh
if [ -z "$synonyms_to_refresh" ]; then
    echo "$result"
# If there were no old synonyms to delete, alert the user
else 
    echo "No old Synonyms to refresh on ${schema}. Continuing..."
fi

# Runs sqlplus commands to refresh the public synonyms
result="
$(
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    set serveroutput on
    DECLARE
    err_num NUMBER;
    err_msg VARCHAR2(100);
    BEGIN
    FOR MySchema IN
    (select table_name as name,owner as owner from dba_tables where owner like '%${schema}%'
    UNION select sequence_name as name,sequence_owner as owner from dba_sequences where sequence_owner like '%${schema}%'
    UNION select trigger_name as name,owner from dba_triggers where owner like '%${schema}%'
    UNION SELECT UNIQUE(OBJECT_NAME)as name,owner FROM DBA_PROCEDURES WHERE owner like '%${schema}%'
    UNION SELECT view_name as name,owner as owner from dba_views where owner like '%${schema}%'
    UNION select object_name as name, owner from dba_objects where owner like '%${schema}%' and object_type = 'TYPE'
    )
    LOOP
    dbms_output.put_line('CREATE PUBLIC SYNONYM '|| MySchema.name);
    EXECUTE IMMEDIATE
    'CREATE OR REPLACE PUBLIC SYNONYM '|| MySchema.name || ' for '||MySchema.owner || '.'|| MySchema.name;
    dbms_output.put_line('CREATED PUBLIC SYNONYM '||MySchema.name);
    END LOOP;
    EXCEPTION
    WHEN OTHERS THEN
    err_num := SQLCODE;
    err_msg := SUBSTR(SQLERRM, 1, 100);
    dbms_output.put_line('Error '|| err_num || '- ' || err_msg);
    RAISE;
    END;
    /
EOD
)
"
sql_error=$?
ora_error=$(echo "$result" | grep -E "ORA-|SP2-")

# Show user the result of sqlplus block
echo "$result"
echo ""

# Checks for errors from the sqlplus output
if [ $sql_error -ne 0 ] || [ ! -z "$ora_error" ]; then
    echo "Error occurred when refreshing public synonyms for ${schema}:"
    echo "$ora_error"
    echo "Exiting..."
    exit 1
elif [ -z "$result" ]; then
    echo "Script completed successfully. No public synonyms found to refresh/create on schema ${schema}"
    exit 0
else
    echo "Successfully refreshed public synonyms for ${schema}"
    exit 0
fi
