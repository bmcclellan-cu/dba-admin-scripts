#!/bin/bash
# AvailabilityFlag: Public
#
#  Purpose: The purpose of this script is to refresh the public synonyms
#	    of the current database that correlate with a given schema or schema 
#       base name. Individual objects (tables, packages, views, etc.) can be
#       given as a csv list to refresh only the
#       public synonyms for those objects in the given schema.
#
#  Note: Synonyms are created or replaced before any stale synonyms are dropped, so a
#        failure partway through never removes the synonym of an object that still
#        exists. Rerunning the script once the error is fixed completes the refresh.
#
##########################################################################

usage="Usage: RefreshSynonyms.sh [ -c <csv of object names> ] [schema name | schema base name] "
example1="Example #1: RefreshSynonyms.sh MYDB_USERS"
example2="Example #2: RefreshSynonyms.sh MYDB"
example3="Example #3: RefreshSynonyms.sh -c 'MY_TABLE,MY_PACKAGE,MY_VIEW' MYDB_MISC"
object_list=""
object_filter=""
name_regex='^[A-Z][A-Z0-9_$#]*$' 
# Process input options
while getopts ":hc:" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example1"
        echo "$example2"
        echo "$example3"
        exit 0
        ;;
    c)
        # Gather the optional object names from the user provided csv list.
        # Names must be unquoted Oracle identifiers (a letter followed by letters, digits, _, $ or #)
        IFS=, read -r -a object_names <<< "$OPTARG"
        for object in "${object_names[@]}"; do
            if ! [[ "${object^^}" =~ $name_regex ]]; then
                echo "Error. '$object' does not match $name_regex pattern. Exiting..." 
                exit 1
            fi
            # Quote each object name for a SQL list. Example: "MY_TABLE,MY_VIEW" -> 'MY_TABLE','MY_VIEW',
            # Note there is a trailing comma that we will have to remove
            object_list+="'${object^^}',"
        done
        # Get everything before the last comma
        object_list=${object_list%,*}

        if [ -z "$object_list" ]; then  
            echo "Error. -c requires at least one object name. Exiting..."  
            exit 1  
        fi  
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

shift "$((OPTIND - 1))"

# display usage and example if parameter is not given
# An empty schema is a usage error, since it would match every schema on the database
if [[ $# -ne 1 ]] || [ -z "$1" ]; then
    echo "$usage"
    echo "$example1"
    echo "$example2"
    echo "$example3"
    exit 1
fi

# Checking ORACLE_SID
sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)

if [ $? -ne 0 ]; then
    echo "$sid_check"
    echo "Error, call to VerifyAllParam.sh -I failed. Exiting..."
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

# Set schema to capitalized input for schema name
schema=${1^^}

# Only accept plain identifiers, so '%', a quote or '&' (SQL*Plus substitution) can't change the queries below
if ! [[ $schema =~ $name_regex ]]; then
    echo "Error, schema: $schema does not match ^[A-Z][A-Z0-9_\$#]*\$ pattern. Exiting..."
    exit 1
fi

if [ ${#object_list} -eq 0 ]; then
    # Refresh every schema whose name starts with the given name, and drop stale synonyms
    # Replace wildcard characters ('_') in schema name  with '\_' which Oracle will then treat as a literal '_' because of the escape clause
    owner_filter="like '${schema//_/\\_}%' ESCAPE '\\'"
    drop_stale_synonyms=TRUE
else
    # Only refresh the given objects in exactly the given schema. Nothing is dropped, since every
    # given object is checked to exist below.
    owner_filter="= '${schema}'"
    object_filter="where name in (${object_list})"
    drop_stale_synonyms=FALSE
fi

# Check to see if any schemas match the input
schema_check=$(
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    set heading off
    set feedback off
    whenever oserror exit 1
    whenever sqlerror exit 1
    select username from dba_users where username ${owner_filter} and oracle_maintained = 'N';
    exit;
EOD
)

# Check for errors
if [ $? -ne 0 ]; then 
    echo "$schema_check"
    echo "An error occurred while trying to check if the provided schema/base name exists. Exiting..."
    exit 1
fi

schema_check=$(echo "$schema_check" | xargs)
if [ -z "$schema_check" ]; then 
    if [ ${#object_list} -eq 0 ]; then
        echo "Error. There are no schema names like ${schema} on database ${ORACLE_SID} which are not Oracle maintained. Exiting..."
    else
        echo "Error. There is no schema named ${schema} on database ${ORACLE_SID} which is not Oracle maintained. A full schema name is required when object names are given. Exiting..."
    fi
    exit 1
fi

owner_filter="IN ("
read -r -a valid_schema_names <<< "$schema_check"
for valid_schema in "${valid_schema_names[@]}"; do
    owner_filter+="'${valid_schema}',"
done
owner_filter="${owner_filter%,})"

# Objects that get a public synonym of the same name. Used to create the synonyms, to check that
# given objects exist, and to find stale synonyms to drop.
synonym_objects="select table_name as name,owner as owner from dba_tables where owner ${owner_filter}
    UNION select sequence_name as name,sequence_owner as owner from dba_sequences where sequence_owner ${owner_filter}
    UNION select trigger_name as name,owner from dba_triggers where owner ${owner_filter}
    UNION SELECT UNIQUE(OBJECT_NAME)as name,owner FROM DBA_PROCEDURES WHERE owner ${owner_filter}
    UNION SELECT view_name as name,owner as owner from dba_views where owner ${owner_filter}
    UNION select object_name as name, owner from dba_objects where owner ${owner_filter} and object_type = 'TYPE'"

# Check that every given object exists before changing any synonyms
if [ ${#object_list} -ne 0 ]; then
    # sys.odcivarchar2list stores varrays of VARCHAR2s. This predefined collection allows us to pass in the object names and define a varray.
    # The TABLE() lets us treat the collection as a standard table.
    # The MINUS removes the names of existing objects.
    # [Take user provided object names] - [existing objects where owner is $owner_filter]  = user provided names that fall through, i.e. they are not in $synonym_objects
    missing_objects=$(
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        set heading off
        set feedback off
        set pagesize 0
        whenever oserror exit 1
        whenever sqlerror exit 1
        select column_value from TABLE(sys.odcivarchar2list(${object_list}))
        MINUS
        select name from (${synonym_objects});
        exit;
EOD
    )
    if [ $? -ne 0 ] || echo "$missing_objects" | grep -qE "ORA-|SP2-"; then
        echo "$missing_objects"
        echo "An error occurred while checking that the given objects exist in ${schema}. Exiting..."
        exit 1
    elif [ -n "$missing_objects" ]; then
        echo "Error. The following objects do not exist in ${schema}, or are not a type that gets a public synonym:"
        echo "$missing_objects"
        echo "No synonyms were changed. Exiting..."
        exit 1
    fi
fi

# Display start of refresh process
echo "Refreshing public synonyms on ${schema}"
echo ""

# Runs sqlplus commands to refresh the public synonyms. All synonyms are created or replaced first, and
# only then are stale ones dropped.
# CREATE OR REPLACE swaps a synonym in place, so no synonym is missing while the refresh runs, and an
# error stops the block before anything is dropped.
# Stale synonyms are dropped only on a full refresh (no -c), and only when the synonym has the same  
# name as its target, is not a database link, and its target no longer exists in dba_objects.

result="
$(
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    set serveroutput on
    DECLARE
    err_num NUMBER;
    err_msg VARCHAR2(100);
    BEGIN
    FOR MySchema IN
    (select name, owner from (${synonym_objects}) ${object_filter}
    )
    LOOP
    dbms_output.put_line('CREATE PUBLIC SYNONYM '|| MySchema.name);
    EXECUTE IMMEDIATE
    'CREATE OR REPLACE PUBLIC SYNONYM '|| MySchema.name || ' for '||MySchema.owner || '.'|| MySchema.name;
    dbms_output.put_line('CREATED PUBLIC SYNONYM '||MySchema.name);
    END LOOP;
    IF ${drop_stale_synonyms} THEN
    FOR OldSynonym IN
    (select s.synonym_name from dba_synonyms s where s.owner = 'PUBLIC' and s.table_owner ${owner_filter}
    and s.synonym_name = s.table_name and s.db_link is null and not exists (select 1 from dba_objects o where o.owner = s.table_owner and o.object_name = s.table_name)
    )
    LOOP
    dbms_output.put_line('DROP PUBLIC SYNONYM '|| OldSynonym.synonym_name);
    EXECUTE IMMEDIATE
    'DROP PUBLIC SYNONYM '|| OldSynonym.synonym_name;
    dbms_output.put_line('Dropped synonym '||OldSynonym.synonym_name);
    END LOOP;
    END IF;
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
