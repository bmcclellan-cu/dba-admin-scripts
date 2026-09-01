#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: The purpose of this script is to derive the schema name or project from
#	   the current or given SID. The script will use sqlplus to take the db_name
#	   in v$parameter related to the SID.
#
#      The -m and -c options are mutually exclusive.
#
#      The -v option only applies to the ORACLE_SID already set in the
#      environment, so it cannot be combined with an ORACLE_SID argument.
#
#####################################################################################

usage="Usage: GetSchemaName.sh [ -m (optional, get MISC schema)] [ -c (optional, get CT schema) ] [ -v (optional, skip VerifyAllParam.sh call, cannot be used with an ORACLE_SID argument)] [ORACLE_SID (optional)]"
example="Example: GetSchemaName.sh mydbprod"

misc_opt=false
skip_verify_opt=false
ct_opt=false
# Process input options
while getopts ":hmvc" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    m)
        misc_opt=true
        ;;
    v)
        skip_verify_opt=true
        ;;
    c)
        ct_opt=true
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

shift $((OPTIND - 1))

if [ $# -gt 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

if $misc_opt && $ct_opt; then
    echo "The -m and -c options are mutually exclusive. Exiting..."
    exit 1
fi

# Set ORACLE_SID to user-provided input or set SID variable to current ORACLE_SID
if [ -z "$1" ] && [ -z "$ORACLE_SID" ]; then
    echo "ERROR: \$ORACLE_SID not set and none provided."
    echo "Rerun the script and enter the target database as the first parameter."
    echo "Exiting..."
    exit 1
elif [ -n "$1" ]; then
    if $skip_verify_opt ; then
        echo "-v option cannot be used with \$ORACLE_SID input. Exiting..."
        exit 1
    fi
    # Lowercase the SID. Oracle SIDs are lowercase and CheckDatabaseOpenStatus.sh
    # compares them literally, so GetSchemaName.sh MYDBPROD would otherwise be
    # reported as not open.
    export ORACLE_SID="${1,,}"
fi

# Check for valid ORACLE_SID
if ! $skip_verify_opt ; then
    sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I "$ORACLE_SID")
    if [ $? -ne 0 ]; then
        echo "$sid_check"
        echo "Error occurred while running VerifyAllParam.sh for $ORACLE_SID. Exiting..."
        exit 1
    fi
    if [ -n "$sid_check" ]; then
        if [ "$sid_check" == "-1" ]; then
            echo "Error, \$ORACLE_SID not set..."
            exit 1
        fi
        echo "Error, provided ORACLE_SID is not open. Exiting..."
        exit 1

    fi
fi

# Take the db_name of the current SID from v$parameter
check_param=$(
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set heading off
    set feedback off
    select value from v\$parameter where name = 'db_name';
EOD
)

# Check for errors
sql_error=$?

# Check if result was found and exit accordingly.
# This has to happen before check_param is truncated below, otherwise the
# sqlplus diagnostic is cut to three characters before it can be displayed.
if [ $sql_error -ne 0 ]; then
    echo "$check_param"
    echo "Error occurred while checking db_name parameter."
    exit 1
fi

# Remove the leading newline from check_param and set to first three characters
check_param=${check_param:1:3}
# Set check_param to uppercase
check_param=${check_param^^}

schema_option=""

if $ct_opt; then
    schema_option="CT"
elif $misc_opt; then
    schema_option="MISC"
fi

# If a schema is being requested, then query for it.
if [ -n "$schema_option" ]; then
    find_schema=$("$ORACLE_HOME"/bin/sqlplus -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        set feedback off
        set heading off
        set pagesize 0
        select distinct username from dba_users where username like '%_${schema_option}' AND username not like '%SYNC%';
        exit;
EOD
    )

    if [ $? -ne 0 ]; then
        echo "$find_schema"
        echo "Error occurred while checking for existence $schema_option of schema on $ORACLE_SID."
        exit 1
    elif [ -z "$find_schema" ]; then
        echo "No *_${schema_option} schema found on database $ORACLE_SID"
        exit 1
    else
        echo "$find_schema"
    fi
else
    echo "$check_param"
fi