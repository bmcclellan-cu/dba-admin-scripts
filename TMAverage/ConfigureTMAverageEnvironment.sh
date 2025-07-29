#!/bin/bash
#
# Purpose: This script creates the TMAverage tablespace and table in the L1A schema,
#          as well as (optionally) a user with the required permissions to populate the
#          table.
# 
# Notes: The L1A schema must exist in order for this script to work. 
#        The script defaults to assuming that the analog table is TMANALOG_SID1, but can be
#        overwritten for cases where the table is different.
#       
#        The -v option creates a venv in the same directory as the script is located with the 
#        required dependencies for the python script to run.
# 
# Author: Robert Schmidt
# Created on Jun 6, 2025
# Last modified on Jun 6, 2025 - RS
##########################################################################
usage="Usage: ./ConfigureTMAverageEnvironment.sh [ -t [ absolute path to datafile ] (optional, create TMAverage tablespace and table.) ] [ -v (optional, create venv in tmaverage script directory ) ] [ -u (optional, create TMAverage user. Requires username & password fields) ] [ -o (optional, requires -u, grant user with access to OTFD packages) ] [ username (optional) ] [ password (optional) ]"
example1="Example: ./ConfigureTMAverageEnvironment.sh -t /ssd_internal/Robert/AIMPROD_TMAVERAGE/tmaverage_table.dbf"
example2="         ./ConfigureTMAverageEnvironment.sh -u -o -v PROCESSTMIDTEST testPWD"


user_opt=0
otfd_opt=0
venv_opt=0
table_opt=0
datafile_path=""
while getopts ":huovt:" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example1"
        echo "$example2"
        exit 0
        ;;
    u)
        user_opt=1
        ;;
    o)
        otfd_opt=1
        ;;
    v)
        venv_opt=1
        ;;
    t)
        table_opt=1
        datafile_path=$OPTARG
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

shift $(($OPTIND -1))

username=""
password=""

# Set static values. These are used so that exceptions can be easily managed (aim).
tablespace_name="TMAVERAGE"
table_name="TMAVERAGE_SID1"
tmanalog_table_name="TMANALOG_SID1"

# Resolve the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check and set parameters
if [[ $user_opt -ne 0 && $# -eq 2 ]]; then
    username="$1"
    password="$2"
elif [[ $user_opt -eq 0 && $# -eq 0 ]]; then
    : # No parameters to set
else    
    echo "Invalid parameters."
    echo "$usage"
    echo "$example1"
    echo "$example2"
    exit 1
fi

# Check that username and password are oracle standard, if they need to be provided
if [ "$user_opt" -ne 0 ] && [[ ! "$username" =~ ^[A-Za-z][A-Za-z0-9_$#]{0,29}$ ]]; then
    echo "Invalid username. Username must fit the regex '^[A-Za-z][A-Za-z0-9_$#]{0,29}$' Exiting..."
    exit 1
fi
if [ "$user_opt" -ne 0 ] && [[ ! "$password" =~ ^[A-Za-z][A-Za-z0-9_$#]{0,29}$ ]]; then
    echo "Invalid password. Password must fit the regex '^[A-Za-z][A-Za-z0-9_$#]{0,29}$'. Exiting..."
    exit 1
fi

if [[ "$otfd_opt" -ne 0 && "$user_opt" -eq 0 ]]; then
    echo "Invalid, the -o option requires the -u option. Exiting..."
fi

# Checking $ORACLE_SID
sid_check=$("$HOME"/common/oracle/VerifyAllParam.sh -I)
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "Error: \$ORACLE_SID not set..."
        exit 1
    fi
    echo "Error: provided \$ORACLE_SID is not open. Exiting..."
    exit 1
fi

# Gets the MISC schema, then truncate the _MISC from it. 
project_name=$("$HOME/common/oracle/GetSchemaName.sh" -m -v)
if [ $? -ne 0 ]; then
    echo "$project_name"
    echo "An error occurred while running GetSchemaName.sh. Exiting..."
    exit 1
fi
if [[ "$project_name" != *"_MISC" ]]; then
    echo "Attempted to retrieve MISC schema, got $project_name instead. Schema name must match glob *'_MISC'. Exiting..."
    exit 1
else
    project_name="${project_name::-5}"
fi
project_name="${project_name^^}"


# Check project name and set static variables accordingly
if [[ "$project_name" == "AIM" ]]; then
    ct_schema_name="AIM_CT_SC"
    tmanalog_table_name="TMANALOG_TABLE"
elif [[ "$project_name" == "EVE" ]]; then
    ct_schema_name="EVE_CT"
    tmanalog_table_name="TMANALOG"
else
    ct_schema_name="${project_name}_CT"
fi

schema_name="${project_name^^}_L1A"

# Create the TMAverage table if desired.
if [ $table_opt -ne 0 ]; then
    # Check that L1A schema exists.
    l1a_schema_check=$("$HOME/common/oracle/CheckIfSchemaExists.sh" "$schema_name")
    if [ $? -ne 0 ]; then
        echo "$l1a_schema_check"
        echo "An error occurred while running CheckIfSchemaExists.sh. Exiting... "
        exit 1
    fi
    if [[ "$l1a_schema_check" != "Yes" ]]; then
        echo "Schema ${schema_name} does not exist. Exiting..."
        exit 1
    fi

    # Create tablespace for TMAverage
    echo "Creating tablespace $tablespace_name..."
    create_tablespace=$("$HOME/common/oracle/CreateNewTablespace.sh" "$tablespace_name" "$datafile_path")
    status_code=$?
    if [ $status_code -ne 0 ] && [[ "$create_tablespace" == *"already exists in the current database"* ]]; then
        echo "Tablespace $tablespace_name already exists. Continuing..."
    elif [ $status_code -ne 0 ]; then
        echo "$create_tablespace"
        echo "An error occurred while running CreateNewTablespace.sh. Exiting..."
        exit 1
    fi

    # Check if TMAverage table already exists
    check_table_exists=$("$HOME/common/oracle/CheckIfTableExists.sh" "$schema_name" "$table_name")
    if [ $? -ne 0 ]; then
        echo "$check_table_exists"
        echo "An error occurred while running CheckIfTableExists.sh Existing..."
        exit 1
    fi

    # Create TMAverage table
    echo "Creating table $schema_name.$table_name in tablespace $tablespace_name..."
    create_table=$("$ORACLE_HOME"/bin/sqlplus -s / as sysdba <<EOD
        set heading off
        set feedback off
        whenever oserror exit 1
        whenever sqlerror exit 1

        CREATE TABLE "$schema_name"."$table_name"
        (
            TMID NUMBER(7,0) NOT NULL ENABLE,
            SCT_VTCW NUMBER(16,0) NOT NULL ENABLE,
            AVERAGE_VALUE FLOAT(126) NOT NULL ENABLE,
            MINIMUM_VALUE FLOAT(126) NOT NULL ENABLE,
            MAXIMUM_VALUE FLOAT(126) NOT NULL ENABLE,
            VALUE_COUNT NUMBER(7,0) NOT NULL ENABLE,
            CONSTRAINT PK_TMAVERAGE_SID1 PRIMARY KEY (TMID, SCT_VTCW) ENABLE
        )
        ORGANIZATION INDEX PCTFREE 0 LOGGING
        TABLESPACE "$tablespace_name";

EOD
    )
    status_code=$?
    if [ $status_code -ne 0 ] && [[ "$create_table" == *"ORA-00955"* ]]; then
        echo "Table already exists, continuing..."
    elif [ $status_code -ne 0 ]; then
        echo "$create_table"
        echo "An error occurred while creating table $table_name. Exiting..."
        exit 1
    fi
fi

# Create the requested user for TMAverage
if [ $user_opt -ne 0 ]; then
    echo "Creating user $username with password $password..."
    create_user=$("$HOME/common/oracle/CreateNewSchema.sh" "$username" "$password" "USERS")
    status_code=$?
    if [ $status_code -ne 0 ] && [[ $create_user == *"already exists"* ]]; then
        echo "User with username $username already exists on database $ORACLE_SID. Continuing..."
    elif [ $status_code -ne 0 ]; then
        echo "$create_user"
        echo "An error occurred while creating user $username with password $password. Exiting..."
        exit 1
    fi

    echo "Creating .username and .passwd files..."
    file_create_failed=0
    echo "$username" > "$SCRIPT_DIR/.username" || file_create_failed=1
    echo "$password" > "$SCRIPT_DIR/.passwd" || file_create_failed=1

    if [ $file_create_failed -ne 0 ]; then
        echo "An error occurred while creating .username and .passwd files. Exiting..."
        exit 1
    fi

    echo "Granting required permissions to user $username:"
    read_write_permissions=$("$HOME/common/oracle/GrantNewPermissions.sh" "$schema_name.$table_name" table ALL "$username" Y)
    if [ $? -ne 0 ]; then
        echo "$read_write_permissions"
        echo "An error occurred while granting read-write permissions to table $schema_name.$table_name on $username. Exiting..."
        exit 1
    fi

    table1="${project_name}_L1A.$tmanalog_table_name"
    table2="${ct_schema_name}.TelemetryItemDefinition"
    table3="${ct_schema_name}.TelemetryAnalogConversions"

    read_only_permissions=$("$HOME/common/oracle/GrantNewPermissions.sh" "$table1,$table2,$table3" table SELECT "$username" Y)
    if [ $? -ne 0 ]; then
        echo "$read_only_permissions"
        echo "An error occurred while granting read-only permission to the below tables. Exiting..."
        exit 1
    fi

    if [ $otfd_opt -ne 0 ]; then
        echo "Granting user access to OTFD package & tables..."
        otfd_execute=$("$ORACLE_HOME"/bin/sqlplus -s / as sysdba <<EOD
            set heading off
            set feedback off
            whenever oserror exit 1
            whenever sqlerror exit 1

            GRANT EXECUTE ON ${project_name}_MISC.ONTHEFLYDECOM TO $username;
            GRANT EXECUTE ON ${project_name}_MISC.ONTHEFLYDECOMMISSIONSPECIFIC TO $username;
EOD
        )
        if [ $? -ne 0 ]; then
            echo "$otfd_execute"
            echo "An error occurred while granting access to the OTFD package to $username. Exiting..."
            exit 1
        fi

        results="${project_name}_MISC.ONTHEFLYDECOM_RESULTS"
        errors="${project_name}_MISC.ONTHEFLYDECOM_ERRORS"

        otfd_tables=$("$HOME/common/oracle/GrantNewPermissions.sh" "$results,$errors" table ALL "$username" Y)
        if [ $? -ne 0 ]; then
            echo "$otfd_tables"
            echo "An error occurred while granting read-only permissions. Exiting..."
            exit 1
        fi
    fi
    echo "Successfully created user $username and granted appropriate permissions."
fi


# Create a virtual environment in the current directory and install needed dependencies.
if [ $venv_opt -ne 0 ]; then
    newest_python=$(ls /usr/bin/python3* | grep -oP 'python3\.\d+' | sort -V | tail -n 1)
    if [ $? -ne 0 ] || [ -z "$newest_python" ]; then
        echo "$newest_python"
        echo "Failed to find newest version of python in order to create virtual environment. Exiting..."
        exit 1
    fi

    create_venv=$("$newest_python" -m venv "$SCRIPT_DIR/venv")
    if [ $? -ne 0 ]; then
        echo "$create_venv"
        echo "Error occurred while creating python venv in $SCRIPT_DIR/venv. Exiting..."
        exit 1
    fi
    # Activate venv
    source "$SCRIPT_DIR/venv/bin/activate"
    if [ $? -ne 0 ]; then
        echo "An error occurred while activating venv environment. Exiting..."
        exit 1
    fi

    # Install needed dependencies.
    install_requirements=$(pip install -r "$SCRIPT_DIR/requirements.txt")
    if [ $? -ne 0 ]; then
        echo "$install_requirements"
        echo "Error occurred while installing requirements at $SCRIPT_DIR/requirements.txt. Exiting..."
        exit 1
    fi

    echo "Successfully created venv at $SCRIPT_DIR/venv."
fi


echo "Script completed successfully"
exit 0