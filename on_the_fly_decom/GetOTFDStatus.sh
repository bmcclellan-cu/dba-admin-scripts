#!/bin/bash
#
# Purpose: This script checks if the OTFD packages are loaded, along with the 
#          existence of their requisite tables. If the packages exist, it will
#          also report the package version.
#
# Author: Robert Schmidt
#
# Created on: September 11th, 2025
################################################################################


usage="Usage: ./GetOTFDStatus.sh [ (optional) ORACLE_SID ]"
example="Example: ./GetOTFDStatus.sh ixpeprod"

# Process input options
while getopts ":h" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0;;
    \?)
        echo "Error: Invalid option"
        exit 1
    esac
done


# Check argument count
if [ $# -eq 1 ]; then
    ORACLE_SID=${1,,}
elif [ $# -gt 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I $ORACLE_SID)
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "ERROR: \$ORACLE_SID not set. Exiting..."
        exit 1
    fi
    echo "ERROR: Provided database is not open. Exiting..."
    exit 1
fi

# Get MISC schema name
misc_schema=$("$HOME/common/oracle/GetSchemaName.sh" -m "$ORACLE_SID")
if [ $? -ne 0 ]; then
    echo "$misc_schema"
    echo "An error occurred while finding MISC schema for database $ORACLE_SID. Exiting..."
    exit 1
fi

# Check if ONTHEFLYDECOM_ERRORS and ONTHEFLYDECOM_RESULTS exist.
results_table_check=$("$HOME/common/oracle/CheckIfTableExists.sh" "$misc_schema" ONTHEFLYDECOM_RESULTS)
if [ $? -ne 0 ]; then
    echo "$results_table_check"
    echo "An error occurred while checking if table ONTHEFLYDECOM_RESULTS exists. Exiting..."
    exit 1
fi

error_table_check=$("$HOME/common/oracle/CheckIfTableExists.sh" "$misc_schema" ONTHEFLYDECOM_ERRORS)
if [ $? -ne 0 ]; then
    echo "$error_table_check"
    echo "An error occurred while checking if table ONTHEFLYDECOM_ERRORS exists. Exiting..."
    exit 1
fi

# Check that the OTFD packages exist.

base_package_check=$("$HOME/common/oracle/CheckIfObjectExists.sh" "$misc_schema" ONTHEFLYDECOM)
if [ $? -ne 0 ]; then
    echo "$base_package_check"
    echo "An error occurred while checking if object ONTHEFLYDECOM exists. Exiting..."
    exit 1
fi

mission_package_check=$("$HOME/common/oracle/CheckIfObjectExists.sh" "$misc_schema" ONTHEFLYDECOMMISSIONSPECIFIC)
if [ $? -ne 0 ]; then
    echo "$mission_package_check"
    echo "An error occurred while checking if object ONTHEFLYDECOMMISSIONSPECIFIC exists. Exiting..."
    exit 1
fi

# Get version of OTFD packages

base_version=$("$ORACLE_HOME"/bin/sqlplus -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1

    set feedback off
    set heading off
    set pagesize 0

    BEGIN
    ONTHEFLYDECOM.getVersion;
    END;
    /
    SELECT message FROM ONTHEFLYDECOM_ERRORS;

    COMMIT; -- Clears the ONTHEFLYDECOM_ERRORS table for the next query

    exit;
EOD
)
error_code=$?
if [[ $base_version == *"ORA-04063"* ]]; then
    base_version="ERRORRED" # Compilation error, package inaccessible
elif [ $error_code -ne 0 ]; then
    echo "$base_version"
    echo "An error occurred while checking version of base OTFD package. Exiting..."
    exit 1
fi

mission_version=$("$ORACLE_HOME"/bin/sqlplus -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1

    set feedback off
    set heading off
    set pagesize 0

    set serveroutput on

    BEGIN
    DBMS_OUTPUT.PUT_LINE(ONTHEFLYDECOMMISSIONSPECIFIC.getVersion);
    END;
    /

    exit;
EOD
)
error_code=$?
if [[ $mission_version == *"ORA-04063"* ]]; then
    mission_version="ERRORRED" # Compilation error, package inaccessible
elif [ $error_code -ne 0 ]; then
    echo "$base_version"
    echo "An error occurred while checking version of mission-specific OTFD package. Exiting..."
    exit 1
fi

echo "Results: $results_table_check"
echo "Error: $error_table_check"
echo "Base: $base_package_check"
echo "Mission: $mission_package_check"
echo "Base Version: $base_version"
echo "Mission Version: $mission_version"