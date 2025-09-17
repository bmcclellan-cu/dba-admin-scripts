#!/bin/bash
#
# Purpose:  This script checks if the OTFD packages are loaded, along with the 
#           existence of their requisite tables. If the packages exist, it will
#           also report the package version. 
#           Packages: ONTHEFLYDECOM, ONTHEFLYDECOMMISSIONSPECIFIC
#           Tables: ONTHEFLYDECOM_ERRORS, ONTHEFLYDECOM_RESULTS.
# 
# Notes:    If either one of the packages has a compilation error, this script will
#           report that BOTH have failed because the getVersion function for the base
#           package will fail if the mission-specific package has a compilation error.
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
    export ORACLE_SID=${1,,}
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

if [ "$base_package_check" == "Yes" ] && [ "$mission_package_check" == "Yes" ]; then
    # Get versions of both OTFD packages. 
    package_versions=$("$ORACLE_HOME"/bin/sqlplus -s / as sysdba <<EOD
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

        COMMIT; -- Clears the ONTHEFLYDECOM_ERRORS table

        exit;
EOD
    )
    error_code=$?
    if [[ $package_versions == *"ORA-04063"* ]]; then
        base_version="Compilation Error" # Compilation error, package inaccessible
        mission_version="Compilation Error"
    elif [ $error_code -ne 0 ]; then
        echo "$package_versions"
        echo "An error occurred while checking version of base OTFD package. Exiting..."
        exit 1
    else
        base_version="$(echo "$package_versions" | sed -n '1 p')"
        mission_version="$(echo "$package_versions" | sed -n '2 p')"

        base_version="${base_version#INFO multimission version: }"
        mission_version="${mission_version#INFO mission-specific version: }"
    fi
fi

if [ "$base_package_check" != "Yes" ]; then
    base_version="Not Loaded"
fi
if [ "$mission_package_check" != "Yes" ]; then
    mission_version="Not Loaded"
fi

if [ "$results_table_check" == "Yes" ]; then
    echo "ONTHEFLYDECOM_RESULTS:    Exists"
else
    echo "ONTHEFLYDECOM_RESULTS:    Does Not Exist"
fi

if [ "$error_table_check" == "Yes" ]; then
    echo "ONTHEFLYDECOM_ERRORS:     Exists"
else
    echo "ONTHEFLYDECOM_ERRORS:     Does Not Exist"
fi

echo "Base OTFD Package:        $base_version"
echo "Mission-specific Package: $mission_version"

exit 0