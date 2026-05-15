#!/bin/bash
#
# Purpose:  This script checks if the OTFD packages are loaded, along with the 
#           existence of their requisite tables. If the packages exist, it will
#           also report the package version. It will also check for duplicates of
#           any of these in any schema that is not the MISC schema.
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
# Last updated: May 13th, 2026 - RS
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

exit_status=0

sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
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

# Check if ONTHEFLYDECOM_ERRORS, ONTHEFLYDECOM_RESULTS, and MIGRATION_STATUS tables exist.
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

migration_table_check=$("$HOME/common/oracle/CheckIfTableExists.sh" "$misc_schema" MIGRATION_STATUS)
if [ $? -ne 0 ]; then
    echo "$migration_table_check"
    echo "An error occurred while checking if table MIGRATION_STATUS exists. Exiting..."
    exit 1
fi

# Only check database version if MIGRATION_STATUS table exists.
if [ "$migration_table_check" == "Yes" ]; then
    # Get the status and version of OTFD DB Tables
    migration_status=$("$ORACLE_HOME"/bin/sqlplus -s / as sysdba <<EOD
        set heading off
        set feedback off
        whenever oserror exit 1
        whenever sqlerror exit 1

        set linesize 10000

        SELECT STATUS_TIMESTAMP || '|' || UPDATE_VERSION || '|' || UPDATE_SUCCESS 
        FROM $misc_schema.MIGRATION_STATUS
        WHERE SOFTWARE_NAME = 'OTFD (Tables)' ORDER BY STATUS_TIMESTAMP DESC FETCH NEXT 1 ROWS ONLY;
EOD
    )
    if [ $? -ne 0 ]; then
        echo "$migration_status"
        echo "An error occurred while fetching version of OTFD Tables. Exiting..."
        exit 1
    fi

    # If a record exists in migration_status, extract timestamp, version, and status from it.
    if [ -n "$migration_status" ]; then
        migration_status=$(echo "$migration_status" | tr -d '\n')
        IFS='|' read -r update_timestamp db_version update_status <<< "$migration_status"
        # Only display status if not successful.
        if [[ "$update_status" == "Success" ]]; then
            update_status_formatted=""
        else
            update_status_formatted="($update_status)"
        fi
    fi
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
        $misc_schema.ONTHEFLYDECOM.getVersion;
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

        base_version="${base_version#INFO: multimission version: }"
        mission_version="${mission_version#INFO: mission-specific version: }"
    fi
fi

if [ "$base_package_check" != "Yes" ]; then
    base_version="Not Loaded"
fi
if [ "$mission_package_check" != "Yes" ]; then
    mission_version="Not Loaded"
fi

if [ -n "$migration_status" ]; then
    echo "DB Last Updated:          $update_timestamp"
    echo "DB Version:               $db_version $update_status_formatted"
else
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
fi
echo "Base OTFD Package:        $base_version"
echo "Mission-specific Package: $mission_version"

additional_packages_tables=$("$ORACLE_HOME"/bin/sqlplus -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1

        set feedback off
        set heading off
        set pagesize 0

        SELECT OWNER || '.' || NAME FROM DBA_PLSQL_OBJECT_SETTINGS where NAME = 'ONTHEFLYDECOM' AND OWNER != '$misc_schema' AND TYPE = 'PACKAGE';
        SELECT OWNER || '.' || TABLE_NAME FROM DBA_TABLES WHERE (TABLE_NAME = 'ONTHEFLYDECOM_RESULTS' OR TABLE_NAME = 'ONTHEFLYDECOM_ERRORS') AND OWNER != '$misc_schema';

        exit;
EOD
)
if [ $? -ne 0 ]; then
    echo "$additional_packages_tables"
    echo "An error occurred while checking for additional ONTHEFLYDECOM packages and tables under other schemas."
    exit 1
fi

if [ -n "$additional_packages_tables" ]; then
    echo
    echo "WARNING: The ONTHEFLYDECOM Package and/or ONTHEFLYDECOM tables were found outside of the MISC schema. Tables and Packages are listed below: "
    echo "$additional_packages_tables"
    echo
fi

temp_undo_enabled=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1

    set feedback off
    set heading off
    set pagesize 0
    select value from v\$parameter where name = 'temp_undo_enabled';
EOD
)
if [ $? -ne 0 ]; then
    echo "$temp_undo_enabled"
    echo "An error occurred while checking 'temp_undo_enabled' parameter. Exiting..."
    exit 1
elif [ "$temp_undo_enabled" != "TRUE" ]; then
    exit_status=1
    echo "ERROR: Database parameter 'temp_undo_enabled' must be 'TRUE', currently is '$temp_undo_enabled'. Setting this prevents Oracle from "
    echo "       writing redo/undo logs for Global Temp Tables, and this being unset causes a significant performance bottleneck for OTFD."
    echo "       Please run the below SQL to update the parameter:"
    echo "           ALTER SYSTEM SET TEMP_UNDO_ENABLED = TRUE scope=both;"
    echo
fi

# Only perform validation on MIGRATION_STATUS results if data was returned.
if [ -n "$migration_status" ]; then
    if [ "$update_status" == "Success" ] && { [ "$results_table_check" != "Yes" ] || [ "$error_table_check" != "Yes" ]; }; then
        exit_status=1
        echo "ERROR: $misc_schema.MIGRATION_STATUS reports that the DB is currently on version $db_version, but"
        echo "       ONTHEFLYDECOM_ERRORS and/or ONTHEFLYDECOM_RESULTS are missing. These tables must be created"
        echo "       for OnTheFlyDecom to function. "
        echo
    elif [ "$update_status" != "Success" ]; then
        exit_status=1
        echo "ERROR: $misc_schema.MIGRATION_STATUS reports that the last update did not succeed (Status=$update_status). "
        echo "       Please update the database and update $misc_schema.MIGRATION_STATUS once this is completed. "
        echo
    fi

    # Check that the major version numbers of the database and the OTFD package match. 
    # Major version number changes indicate an interface or table change, and should always match
    db_major_v=$(echo "$db_version" | awk -F '.' '{print $2}')
    otfd_major_v=$(echo "$base_version" | awk -F '.' '{print $2}')

    if [ "$db_major_v" -ne "$otfd_major_v" ]; then
        exit_status=1
        echo "ERROR: Database and software have mismatched major versions. Please update the database or software to prevent compatibility issues."
        echo "       Update $misc_schema.MIGRATION_STATUS once the database is updated."
        echo
    fi
else
    echo "WARNING: Unable to determine database version from $misc_schema.MIGRATION_STATUS. Either $misc_schema.MIGRATION_STATUS"
    echo "         does not exist or has no rows. Skipping database version validation."
fi

if [ "$exit_status" -ne 0 ]; then
    echo "One or more errors with OTFD were detected. See above output for more details."
else
    echo "Script finished successfully, no errors detected!"
fi

exit $exit_status