#!/bin/bash
# AvailabilityFlag: Public
#
#  Purpose: The purpose of this script is to delete the old public synonyms
#      on a database provided by the user with the schema parameter. This
#      script is a helper script for RefreshSynonyms.sh and RMANCloneLiveDB.sh.
#
##########################################################################

usage="Usage: DeleteOldSynonyms.sh [schema]"
example="Example: DeleteOldSynonyms.sh MY_SCHEMA"

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

if [[ $# -ne 1 ]]; then
    echo "$usage"
    echo "$example"
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

# Set schema to capitalized input
schema=${1^^}

# Display start of deletion process
echo "Deleting old public synonyms on ${schema}"
echo ""

# Runs sqlplus commands to refresh the public synonyms
result=$(
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set feedback off
    set serveroutput on
    DECLARE
    err_num NUMBER;
    err_msg VARCHAR2(100);
    BEGIN
    FOR MySchema IN
    (select owner,synonym_name,table_name from dba_synonyms where owner = 'PUBLIC' and table_owner like '${schema}%'
    )
    LOOP
    dbms_output.put_line('DROP PUBLIC SYNONYM '|| MySchema.synonym_name);
    EXECUTE IMMEDIATE
    'DROP PUBLIC SYNONYM '|| MySchema.synonym_name;
    dbms_output.put_line('Dropped synonym table '||MySchema.synonym_name);
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

sql_error=$?
ora_error=$(echo "$result" | grep -E "ORA-|SP2-")

# If the output is empty, alert the user
if [ -z "$result" ]; then
    echo "No old public synonyms found on ${schema}."
    exit 0
fi

# Show user the result of sqlplus block
echo "$result"
echo ""

# Checks for errors from the sqlplus output
if [ $sql_error -ne 0 ] || [ ! -z "$ora_error" ]; then
    echo "Error occurred when deleting public synonyms for ${schema}:"
    echo "$ora_error"
    echo "Exiting..."
    exit 1
else
    echo "Successfully deleted public synonyms for ${schema}"
    exit 0
fi
