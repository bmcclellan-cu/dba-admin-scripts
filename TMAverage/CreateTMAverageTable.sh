#!/bin/bash
#
# Purpose: This script creates the TMAverage tablespace and table in the L1A schema,
#          as well as (optionally) a user with the required permissions to populate the
#          table.
# 
# Notes: The L1A schema must exist in order for this script to work. 
# 
# Author: Robert Schmidt
# Created on Jun 6, 2025
# Last modified on Jun 6, 2025 - RS
##########################################################################
usage="Usage: ./CreateTMAverageTableUser.sh [ -u (optional, create TMAverage user. Requires username & password fields) ] [ absolute path to datafile ] [ username (optional) ] [ password (optional) ]"
example="Example: ./CreateTMAverageTable.sh "


uopt=0
while getopts ":hu" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    u)
        uopt=1
        shift 1
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

# Check arguments
if [ $uopt -eq 0 ] && [ $# -ne 1 ]; then
    echo "Incorrect parameters."
    echo "$usage"
    echo "$example"
    exit 1
elif [ $uopt -ne 0 ] && [ $# -ne 3 ]; then
    echo "Incorrect parameters. The -u option requires username and password."
    echo "$usage"
    echo "$example"
    exit 1
fi

# Set input parameters
datafile_path="$1"
username="$2"
password="$3"

# Set static values
tablespace_name="TMAVERAGE"
table_name="TMAVERAGE"

# Check that username and password are oracle standard, if they need to be provided
if [ "$uopt" -ne 0 ] && [[ ! "$username" =~ ^[A-Za-z][A-Za-z0-9_$#]{0,29}$ ]]; then
    echo "Invalid username. Username must fit the regex '^[A-Za-z][A-Za-z0-9_$#]{0,29}$' Exiting..."
    exit 1
fi
if [ "$uopt" -ne 0 ] && [[ ! "$password" =~ ^[A-Za-z][A-Za-z0-9_$#]{0,29}$ ]]; then
    echo "Invalid password. Password must fit the regex '^[A-Za-z][A-Za-z0-9_$#]{0,29}$'. Exiting..."
    exit 1
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

# Get the project name from $ORACLE_SID
if [[ $ORACLE_SID == *"dev" ]]; then
    project_name="${ORACLE_SID::-3}"
elif [[ $ORACLE_SID == *"prod" ]]; then
    project_name="${ORACLE_SID::-4}"
else
    echo "Failed to parse project name from database name. Database name must end in 'dev' or 'prod'. Exiting..."
    exit 1
fi

schema_name="${project_name^^}_L1A"

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
check_table_exists=#("$HOME/common/oracle/CheckIfTableExists" "$schema_name" "$table_name")
if [ $? -ne 0 ]; then
    echo "$check_table_exists"
    echo "An error occurred while running CheckIfTableExists. Existing..."
    exit 1
fi

# Create TMAverage table
create_table=$("$ORACLE_HOME"/bin/sqlplus -s / as sysdba <<EOD
    set heading off
    set feedback off
    whenever oserror exit 1
    whenever sqlerror exit 1

    CREATE TABLE "$schema_name"."$table_name"
    ( "TMID" NUMBER(7,0) NOT NULL ENABLE,
    "SCT_VTCW" NUMBER(16,0) NOT NULL ENABLE,
    "AVERAGE_VALUE" FLOAT(126) NOT NULL ENABLE,
    "MINIMUM_VALUE" FLOAT(126) NOT NULL ENABLE,
    "MAXIMUM_VALUE" FLOAT(126) NOT NULL ENABLE,
    "VALUE_COUNT" NUMBER(7,0) NOT NULL ENABLE,
    PRIMARY KEY(TMID, SCT_VTCW)
    ) TABLESPACE "$tablespace_name"
    exit;
EOD
)
if [ $? -ne 0 ]; then
    echo "$create_table"
    echo "An error occurred while creating table $table_name. Exiting..."
    exit 1
fi


if [ $uopt -eq 0 ]; then
    echo "Not creating user for TMAverage. All done!"
    exit 0
fi


# GrantNewPermissions.sh ROBERT_TEST.TMAverage table ALL PROCESSTMIDTEST Y
# GrantNewPermissions.sh GOLD_L1A.TMAnalog_SID1,GOLD_CT.TelemetryItemDefinition,GOLD_CT.TelemetryAnalogConversions table SELECT PROCESSTMIDTEST Y
# GrantNewPermissions.sh TSIS_L1A.TMAnalog_SID1,TSIS_CT.TelemetryItemDefinition,TSIS_CT.TelemetryAnalogConversions table SELECT PROCESSTMIDTEST Y
# GrantNewPermissions.sh IXPE_L1A.TMAnalog_SID1,IXPE_CT.TelemetryItemDefinition,IXPE_CT.TelemetryAnalogConversions table SELECT PROCESSTMIDTEST Y
