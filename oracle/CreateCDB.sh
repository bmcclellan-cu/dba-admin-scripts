#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose:  This script creates a CDB which is intended to be used during the 26ai migration process. This CDB is
#           created using the initXXXX26.ora init template file, and the name is suffixed with _cdb.
#
# Notes:    The script requires environment variables to be set containing the SYS and SYSTEM passwords for the newly
#           created database:
#               - DB_SYS_PASSWORD: Password for the SYS schema
#               - DB_SYSTEM_PASSWORD: Password for the SYSTEM schema
#
#           The dryrun option will generate the scripts DBCA uses to create the database in the specified directory. The entrypoint
#           for the database creation is <create_script_path>/${ORACLE_SID}.sh
#
#           DBCA writes entries to /etc/oratab when a database is created, so if the database is deleted and re-created, this
#           entry must be reset before DBCA will allow for the database to be created again.
#
#           This script defaults to setting the backup directory of the CDB to $ORACLE_BACKUP_DIR, which must be set and exist.
#
#           Because the CDB this script creates is intended to be used during the 26ai migration process, it must be created with
#           almost every optional Oracle feature installed to be able to support our current DBs. As such, while a suitable CDB can be
#           created using the CREATE DATABASE statement for finer control and transparency, doing so requires this script to handle
#           installing every optional Oracle feature, which becomes rapidly impractical.
#
######################################################
usage="Usage: CreateCDB.sh [ -d <dryrun_dest_path> (optional, dryrun database creation, see header)] [ new_db_name (not including the _cdb suffix) ] [ restore_base_directory ]"
example1="Example: DB_SYS_PASSWORD=pwd123# DB_SYSTEM_PASSWORD=pwd123# CreateCDB.sh sid1prod /ssd_internal/restore_cdb/"
example2="         DB_SYS_PASSWORD=pwd123# DB_SYSTEM_PASSWORD=pwd123# CreateCDB.sh -d /home/oracle/testdb_create_scripts testdb /path/to/restore/dir/"

# Process input options
dryrun_opt=0
while getopts ":hd:" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example1"
        echo "$example2"
        exit 0
        ;;
    d)
        dryrun_opt=1
        dryrun_dest_path=$(realpath "$OPTARG")
        if ! [ -d "$dryrun_dest_path" ]; then
            echo "ERROR: Provided dryrun_dest_path $dryrun_dest_path does not exist. Exiting..."
            exit 1
        fi
        ;;
    \?)
        echo "ERROR: Invalid option"
        exit 1
        ;;
    esac
done

shift $((OPTIND-1))

if [ $# -ne 2 ]; then
    echo "Incorrect number of parameters"
    echo "$usage"
    echo "$example1"
    echo "$example2"
    exit 1
fi

new_db_name=${1,,}
restore_base_directory=${2}

export ORACLE_SID=${new_db_name}_cdb

# Substitute d19 -> dev and p19 -> prod.
# This is done to ensure a consistent directory name for our database
new_db_folder_name=$(echo "$ORACLE_SID" | sed "s/d19/dev/")
new_db_folder_name=$(echo "$new_db_folder_name" | sed "s/p19/prod/")

# Compute directory name and collapse duplicate slashes into a single slash.
restore_directory=$(echo "${restore_base_directory}/$new_db_folder_name" | sed 's#//*#/#g')

# Get directory the script is located in
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Timestamp in format ComputeTimeGap.sh accepts
start_timestamp="$(date "+%Y-%m-%d %H:%M:%S")"

echo "CreateCDB.sh started at $start_timestamp."

db_status=$("$HOME/common/oracle/CheckDatabaseOpenStatus.sh" "$ORACLE_SID")
if [ $? -ne 0 ]; then
    echo "$db_status"
    echo "ERROR: An error occurred while checking if database exists. Exiting..."
    exit 1
fi
if [ "$db_status" != "CLOSED" ]; then
    echo "ERROR: \$ORACLE_SID $ORACLE_SID is running (status=$db_status). Exiting..."
    exit 1
fi

if [ -d "$restore_directory" ]; then
    echo "ERROR: Restore destination $restore_directory already exists. Exiting..."
    exit 1
fi

# Verify that $ORACLE_BACKUP_DIR exists
if [ ! -d "$ORACLE_BACKUP_DIR" ]; then
    echo "ERROR: \$ORACLE_BACKUP_DIR $ORACLE_BACKUP_DIR does not exist."
    exit 1
fi

# Verify that script caller passed SYS and SYSTEM passwords via environment variables
if [ -z "$DB_SYS_PASSWORD" ] || [ -z "$DB_SYSTEM_PASSWORD" ]; then
    echo "ERROR: DB_SYS_PASSWORD AND DB_SYSTEM_PASSWORD environment variables must be set prior to running this script. See header for more details. Exiting..."
    exit 1
fi

# Check through sqlplus that the current ORACLE_HOME is for 26ai.
if ! [[ $("$ORACLE_HOME/bin/sqlplus" -v) =~ "23.26" ]]; then
    echo "ERROR: ORACLE_HOME must be pointing to 26ai binaries"
    exit 1
fi

# Check that the base database name isn't too long
if [ ${#new_db_name} -gt 8 ]; then
    echo "ERROR: new_db_name cannot be greater than 8 characters long. Exiting..."
    exit 1
fi

if [ $dryrun_opt -eq 1 ]; then
    dbca_opt="-generateScripts -scriptDest $dryrun_dest_path"
else
    dbca_opt="-createDatabase"
fi

echo "Creating CDB Using DBCA"

# We have to pass some command line parameters to dbca due to the fact that dbca ignores/mistreats
# some of these parameters when specified in the template file:
# - variables:
#   - RESTORE_DIR: DBCA Templates flatten the directory structure when using -datafileDestination, so we
#                  use a custom variable to substitute in our base path into the template.
# -initParams:
#   - cpu_count: DBCA ignores cpu_count when passed via the DBCA Template, so we override it here
#   - db_name:   DBCA will default to taking the first 8 characters from ORACLE_SID, which sometimes ends up
#                with ugly trailing underscores in db_name, so we override that
#   - db_recovery_file_dest: We want to set db_recovery_file_dest at create-time, so we don't hardcode it in the
#                            template.
# -honorControlFileInitParam: By default, DBCA will silently override every other filename you specify for the controlfile
#                             destination and override every second entry to point to a location in
#                             db_recovery_file_dest. This flag disables that default behavior.
# Note: -honorControlFileInitParam is a completely undocumented flag, both in the dbca help menu or in official
#       Oracle documentation. This flag was found through a blog post linked below, and behavior can be manually verified
#       by removing it and watching the fireworks: https://www.spotonoracle.com/?cat=14
# $dbca_opt is intentionally unquoted so that the parameters passed to it are word-split when passed to dbca.
create_cdb=$("$ORACLE_HOME/bin/dbca" -silent \
    $dbca_opt \
    -sid "$ORACLE_SID" \
    -gdbName "$ORACLE_SID" \
    -templateName "$SCRIPT_DIR/admin/26AI_DBCA_Base_Template.dbc" \
    -variables "RESTORE_DIR=$restore_directory" \
    -initParams "cpu_count=10,db_name=$new_db_name,db_recovery_file_dest=$ORACLE_BACKUP_DIR" \
    -sysPassword "$DB_SYS_PASSWORD" \
    -systemPassword "$DB_SYSTEM_PASSWORD" \
    -honorControlFileInitParam)
exit_code=$?
# DBT-10317: Specified SID Name already exists.
if [ $exit_code -ne 0 ] && echo "$create_cdb" | grep -q "DBT-10317"; then
    echo "ERROR: The specified database name is already registered in /etc/oratab. Please remove the $ORACLE_SID entry from /etc/oratab. Exiting..."
    exit 1
elif [ $exit_code -ne 0 ]; then
    echo "$create_cdb"
    echo "An error occurred while creating database. See above output for more details. Exiting..."
    exit 1
fi

echo

if [ $dryrun_opt -eq 1 ]; then
    echo "Dryrun complete, please check $dryrun_dest_path for dbca-generated scripts. "
    echo "Entrypoint for scripts is ${dryrun_dest_path}/${ORACLE_SID}.sh Exiting..."
    exit 0
fi

# DBCA does not copy a pfile to $ORACLE_HOME/dbs by default, only a spfile. Additionally, we cannot
# set certain values as desired (see template file for more details) due to DBCA's over-strict input
# validation. As such, we have to shutdown the database, update the pfile, and start it up again.

echo "DB Created, running post-create pfile update..."

# Shutdown database.
shutdown_db=$("$HOME/common/oracle/shutdown_oracle.sh" "$ORACLE_SID")
if [ $? -ne 0 ]; then
    echo "$shutdown_db"
    echo "An error occurred while shutting down $ORACLE_SID. Exiting..."
    exit 1
fi

# Update the pfile with our desired values.
update_pfile=$("$HOME/common/oracle/UpdateInitTemplateFile.sh" "$ORACLE_SID" "$ORACLE_BACKUP_DIR" "$restore_directory")
if [ $? -ne 0 ]; then
    echo "$update_pfile"
    echo "An error occurred while updating pfile of $ORACLE_SID. Exiting..."
    exit 1
fi

# Create a server parameter file from our parameter file.
create_spfile_from_pfile=$("$HOME/common/oracle/CreateSpfileFromPfile.sh" "$ORACLE_HOME/dbs/init${ORACLE_SID}.ora")
if [ $? -ne 0 ]; then
    echo "$create_spfile_from_pfile"
    echo "An error occurred while creating spfile from pfile. Exiting..."
    exit 1
fi

# Startup the database.
startup_db=$("$HOME/common/oracle/startup_oracle.sh" "$ORACLE_SID")
if [ $? -ne 0 ]; then
    echo "$startup_db"
    echo "An error occurred while starting $ORACLE_SID. Exiting..."
    exit 1
fi

# Compute how long the script took to execute.
end_timestamp="$(date "+%Y-%m-%d %H:%M:%S")"
time_diff=$("$HOME/common/general/ComputeTimeGap.sh" "$start_timestamp" "$end_timestamp")
if [ $? -ne 0 ]; then
    echo "$time_diff"
    echo "An error occurred while computing time difference. Continuing..."
    time_diff="unknown"
fi

echo "CreateCDB.sh successfully completed at $end_timestamp, script duration $time_diff."
