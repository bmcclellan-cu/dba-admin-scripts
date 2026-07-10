#!/bin/bash
#
# Purpose:  This script updates the OTFD packages for a database and validates that the
#           requested OTFD version is compatible with the database version. This script is 
#           intended for use both for initial OTFD package installations and package updates.
# 
# Notes:    This script DOES NOT handle database updates themselves, documentation for database migrations
#           can be found here: https://confluence.lasp.colorado.edu/spaces/MODSDB/pages/315831384/Database+Version+Upgrades
#           
#           This script does not currently account for mission-specific database upgrades.
#           As of now, no such upgrades have been necessary, but this may change in the future.
# 
#           Database version corresponds to the state of the tables OTFD relies on to operate. As of now, each database 
#           update has directly corresponded to a generic package update and is identified by the version the package was
#           as of the update.
#
#####################################################################################

usage="Usage: UpdateOTFD.sh [ ORACLE_SID ] [ update_type (Can be Generic, IXPE, EMA, or NEOS) ] [ target_version (Must be formatted X.X.X) ] [ repo_path (optional, path to db_tools. Defaults to \$HOME/db_tools/) ]"
example="Example: UpdateOTFD.sh ixpeprod Generic 0.2.5 /home/oracle/db_tools/"

# Static Associative Array (dictionary) mapping generic package versions to required database version.
# Database version corresponds with an update to the OTFD tables, as opposed to the package. As of now
# each database update corresponds with a specific generic package update, and is numbered as such.
# This will be replaced with querying the OTFD package in the future.
declare -A required_db_versions=(
    ["0.2.4"]="0.2.4"
    ["0.2.5"]="0.2.4"
)

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
if [ $# -ne 4 ] && [ $# -ne 3 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

export ORACLE_SID="${1,,}"
update_type="${2^^}"
target_version="$3"
repo_root="${4:-$HOME/db_tools}"

repo_package_dir="$repo_root/src/on_the_fly_decom"


if ! [[ "$target_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Version must be formatted X.X.X. Exiting..."
    exit 1
fi

if ! [[ "$update_type" =~ ^(GENERIC|IXPE|EMA|NEOS)$ ]]; then
    echo "ERROR: Supplied update_type $update_type not valid (valid options: GENERIC,IXPE,EMA,NEOS). Exiting..."
    exit 1
fi

# Check that package directory exists.
if [ ! -d "$repo_package_dir" ]; then
    echo "ERROR: OTFD subdirectory $repo_package_dir not found in $repo_root. Exiting..."
    exit 1
fi

sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
if [ $? -ne 0 ]; then
    echo "$sid_check"
    echo "An error occurred while running VerifyAllParam.sh. Exiting..."
    exit 1
fi
if [ -n "$sid_check" ]; then
    if [ "$sid_check" = "-1" ]; then
        echo "ERROR: \$ORACLE_SID not set. Exiting..."
        exit 1
    fi
    echo "ERROR: Provided database is not open. Exiting..."
    exit 1
fi

# -m flag returns the misc schema, -v disables input validation for speed
misc_schema=$("$HOME/common/oracle/GetSchemaName.sh" -m -v)
if [ $? -ne 0 ] || [ -z "$misc_schema" ]; then
    echo "$misc_schema"
    echo "ERROR: An error occurred while finding MISC schema for database $ORACLE_SID. Exiting..."
    exit 1
fi

# Derive project prefix from the mission schema to select the correct mission-specific package file.
# Parameter expansion removes the trailing _MISC suffix from the schema name.
project="${misc_schema%_MISC}"
if [ -z "$project" ] || [ "$project" = "$misc_schema" ]; then
    echo "ERROR: Unable to derive project name from $misc_schema. Exiting..."
    exit 1
fi
project="${project^^}"

if [ "$update_type" != "GENERIC" ] && [ "$update_type" != "$project" ]; then
    echo "ERROR: Mission-specific update_type $update_type does not match database prefix $project. Exiting..."
    exit 1
fi

# Grep for the multimission version in the procedure code
generic_version_line=$(grep "multimission" "$repo_package_dir/onTheFlyDecom.pkb")
# -o only prints the matching string instead of the whole line
# -E enables extended regex syntax.
# -m 1 returns only the first line matched
generic_version=$(echo "$generic_version_line" | grep -oE -m 1 '[0-9]+(\.[0-9]+){2}')
if [ -z "$generic_version" ]; then
    echo "ERROR: Unable to determine the generic OTFD version from onTheFlyDecom.pkb. Exiting..."
    exit 1
fi
# The first grep extracts the getVersion procedure code, and the second grep narrows the search to the mission-specific project line
# -A 10 includes the 10 lines after grep finds a match,
# -m 1 returns only the first line matched
mission_version_line=$(grep -A 10 "getVersion" "$repo_package_dir/onTheFlyDecomMissionSpecific$project.pkb" | grep -m 1 "$project")
# -o only prints the matching string instead of the whole line
# -E enables extended regex syntax.
# -m 1 returns only the first line matched
mission_version=$(echo "$mission_version_line" | grep -oE -m 1 '[0-9]+(\.[0-9]+){2}')
if [ -z "$mission_version" ]; then
    echo "ERROR: Unable to determine the mission-specific OTFD version from onTheFlyDecomMissionSpecific$project.pkb. Exiting..."
    exit 1
fi

required_db_version="${required_db_versions[$generic_version]}"
if [ -z "$required_db_version" ]; then
    echo "ERROR: Unable to determine required database version for target_version $target_version. Please populate required_db_versions. Exiting..."
    exit 1
fi

echo "Starting UpdateOTFD.sh for $ORACLE_SID"
echo "Update type: $update_type"
echo "Target version: $target_version"
echo "Required database version: $required_db_version"
echo "Repository path: $repo_root"
echo

# Validate the version string in the package against the requested version before proceeding with the installation.
if [ "$update_type" = "GENERIC" ] && [ "$generic_version" != "$target_version" ]; then
    echo "ERROR: Generic version of code in $repo_package_dir ($generic_version) does not match requested version $target_version. Exiting..."
    exit 1
fi
if [ "$update_type" != "GENERIC" ] && [ "$mission_version" != "$target_version" ]; then
    echo "ERROR: Mission-specific version of code ($mission_version) does not match requested version $target_version. Exiting..."
    exit 1
fi

echo "Confirmed code version in repository matches target_version."
echo "Checking OTFD Status before updating package..."
echo
# Validate that there are no OTFD anomalies before upgrading. We do not check for exit status here due to how GetOTFDStatus.sh reports
# errors. GetOTFDStatus.sh reports all errors or anomalies with one of the these prefixes: 'ERROR:', 'WARNING:', or 'An error occurred'. This script will exit with status 1 in these cases.
# As such, we manually scan for errors or anomalies instead of relying on the exit code.
pre_update_status=$("$HOME/common/oracle/GetOTFDStatus.sh" "$ORACLE_SID")
# Ignore version-mismatch errors and filter for any errors or warnings.
# The -E flag enables extended regex.
pre_update_status_errors=$(echo "$pre_update_status" | grep -v "mismatched major versions" | grep -E "ERROR:|WARNING:|An error occurred")
if [ -n "$pre_update_status_errors" ]; then
    echo "$pre_update_status"
    echo "ERROR: GetOTFDStatus.sh reported non-version-mismatch database/package anomalies/encountered an error. See above output for more details. Exiting..."
    exit 1
fi
echo "$pre_update_status"
echo

# Extract database version from GetOTFDStatus.sh output.
# -o only prints the matching string instead of the whole line
# -E enables extended regex syntax.
# -m 1 returns only the first line matched
pre_update_db_version=$(echo "$pre_update_status" | grep "DB Version: " | grep -oE -m 1 '[0-9]+(\.[0-9]+){2}')
if [ -z "$pre_update_db_version" ]; then
    echo "$pre_update_status"
    echo "ERROR: Unable to extract the database version from GetOTFDStatus.sh output. Exiting..."
    exit 1
fi

if [ "$pre_update_db_version" != "$required_db_version" ]; then
    echo "ERROR: Database version $pre_update_db_version does not match required version $required_db_version for OTFD $generic_version. Exiting..."
    exit 1
fi

echo "Database compatible with target package version, continuing..."
echo "Verifying objects compile before update."
pre_recompile_output=$("$HOME/common/oracle/RecompileAllObjects.sh" "$ORACLE_SID")
if [ $? -ne 0 ]; then
    echo "$pre_recompile_output"
    echo "ERROR: An error occurred while running RecompileAllObjects.sh. Exiting..."
    exit 1
fi
# Ensure that script doesn't return invalid objects. -i is a case-insensitive check.
if ! echo "$pre_recompile_output" | grep -qi "no rows selected"; then
    echo "$pre_recompile_output"
    echo "ERROR: Invalid objects present in database, see above output for more details. Exiting..."
    exit 1
fi

echo
echo "Installing OTFD packages for version $update_type $target_version."
# Note: The package specs (.pks files) should be loaded before the package bodies (.pkb files)
#       in order to prevent a mismatch in the expected function definitions during compilation.
load_output=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1

    set feedback off
    set heading off
    set pagesize 0

    -- Switch into the mission schema before loading the package specs and bodies.
    -- This automatically prefixes the package names with the misc schema name.
    ALTER SESSION SET CURRENT_SCHEMA = $misc_schema;
    SELECT SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') FROM DUAL;

    @$repo_package_dir/onTheFlyDecom.pks
    show errors
    @$repo_package_dir/onTheFlyDecomMissionSpecific.pks
    show errors
    @$repo_package_dir/onTheFlyDecom.pkb
    show errors
    @$repo_package_dir/onTheFlyDecomMissionSpecific${project}.pkb
    show errors

    exit;
EOD
)
if [ $? -ne 0 ] || echo "$load_output" | grep -E "ORA-|SP2-|PLS-"; then
    echo "$load_output"
    echo "ERROR: An error occurred while loading OTFD packages. Exiting..."
    exit 1
fi

echo
echo "Recompiling objects after package load"
post_recompile_output=$("$HOME/common/oracle/RecompileAllObjects.sh" "$ORACLE_SID")
if [ $? -ne 0 ]; then
    echo "$post_recompile_output"
    echo "ERROR: An error occurred while running RecompileAllObjects.sh. Exiting..."
    exit 1
fi
# Ensure that script doesn't return invalid objects. -i is a case-insensitive check.
if ! echo "$post_recompile_output" | grep -qi "no rows selected"; then
    echo "$post_recompile_output"
    echo "ERROR: Invalid objects present in database after OTFD packages were installed. See above output for more details. Exiting..."
    exit 1
fi

echo "Running final OTFD status check"
final_status_output=$("$HOME/common/oracle/GetOTFDStatus.sh" "$ORACLE_SID")
if [ $? -ne 0 ]; then
    echo "$final_status_output"
    echo "ERROR: GetOTFDStatus.sh reported a problem after the update. Exiting..."
    exit 1
fi
echo "$final_status_output"

echo
echo "UpdateOTFD.sh completed successfully for $ORACLE_SID"

