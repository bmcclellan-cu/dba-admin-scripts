#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: Print views on a database with the optional parameter schema.view_name.
#          Queries the database and returns the view name and associated SQL
#          statement.
#
#####################################################################################

usage="Usage: PrintViews.sh [schema.view_name (optional)]"
example="Example: PrintViews.sh MYSCHEMA.MYTABLE"

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
if [ $# -gt 1 ]; then
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
    echo "Error, \$ORACLE_SID is not open. Exiting..."
    exit 1
fi

# If view_name is provided
if [ $# -eq 1 ]; then
    # Selecting schema
    schema=$(echo "$1" | tr '.' ' ' | awk '{print $1}')
    view_name=$(echo "$1" | tr '.' ' ' | awk '{print $2}')
    view_check=$(
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        SELECT view_name FROM dba_views WHERE owner = '$schema' AND view_name='$view_name';
EOD
    )

    # Error checking
    if [ $? -ne 0 ]; then
        echo "Error occured while checking for view_name $view_name. Exiting..."
        exit 1
    elif [[ "$view_check" =~ "no rows selected" ]]; then
        echo "Specified view $schema.$view_name does not exist."
        echo "Reminder: formatting should be schema.view_name."
        exit 1
    else
        # SQL query
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        set heading on
        set pagesize 10000
        set linesize 200
        COLUMN owner FORMAT A20
        COLUMN view_name FORMAT A35
        COLUMN text_vc FORMAT A98
        SELECT owner,view_name,text_vc FROM dba_views where owner = '${schema}' AND view_name = '${view_name}';
EOD
    fi

    # Checking for errors in the above SQL command
    if [ $? -ne 0 ]; then
        echo "Error occurred while finding views. Exiting..."
        exit 1
    else
        echo
        exit 0
    fi
fi

# Schema from helper script
schema=$("$HOME/common/oracle/GetSchemaName.sh" -v)

# Selecting views where owner = GetSchemaName.sh
"$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set heading on
    set pagesize 10000
    set linesize 200
    COLUMN owner FORMAT A20
    COLUMN view_name FORMAT A35
    COLUMN text_vc FORMAT A98
    SELECT owner,view_name,text_vc from dba_views where owner like '${schema}%' order by 1,2,3;
EOD

# Checking for errors in the above SQL command
if [ $? -ne 0 ]; then
    echo "Error occurred while finding views. Exiting..."
    exit 1
else
    echo
    exit 0
fi
