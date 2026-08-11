#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose:  This script acts as a helper script for updating the pfile of a database.
#           Using the initXXXX.ora or initXXXX26.ora as a template, the script updates the pfile of
#           a database, updating the db_recovery_file_dest, compatible, and database name parameters.
#
#
# Notes:    This script does not run VerifyAllParam.sh because it may be run on databases that are in
#           NOMOUNT, MOUNTED, or CLOSED states.
#
#####################################################################################

usage="Usage: UpdateInitTemplateFile.sh [ORACLE_SID] [parent folder of backup] [control files directory]"
example="Example: UpdateInitTemplateFile.sh sid1dev /BACKUPS /TEST1/sid1dev"

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
if [ $# -ne 3 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

source_init_file="$HOME/common/oracle/initXXXX.ora"

# Determine oracle version this is being run as
# If ORACLE_HOME is on version 19, save 19.0.0 in $version_compatible
if [[ $ORACLE_HOME == *"19."* ]]; then
    version_compatible="19.0.0"
# If not, use 12.2.0
elif [[ $ORACLE_HOME == *"12."* ]]; then
    version_compatible="12.2.0"
# If this is being run for Oracle 26, we want to use the appropriate init template file.
elif [[ $ORACLE_HOME == *"26"* ]]; then
    version_compatible="23.6.0"
    source_init_file="$HOME/common/oracle/initXXXX26.ora"
# Otherwise, $ORACLE_HOME isn't set properly
else
    echo "Error: Could not determine Oracle version (valid versions are 12, 19, or 26) from \$ORACLE_HOME. Exiting..."
    exit 1
fi

# Check given paths
if [ ! -d "$2" ]; then
    echo "$2 is not an existing directory. Check input and try again."
    exit 1
elif [ ! -d "$3" ]; then
    echo "$3 is not an existing directory. Check input and try again."
    exit 1
fi

# Setup the variables and replace each '/' in the directory variables with '\/'
# The latter step is required since the sed command uses '/' to separate the find/replace
# strings, but since the directory will also contain '/', they have to be replaced with '\/'
# so that the sed command only reads them as part of the string.
sid=$1
parent_backup_dir=${2//'/'/'\/'}
ctrl_file_dir=${3//'/'/'\/'}

# Remove trailing slash from directories if it exists. We remove 2 characters because the above command
# escapes all /'s, so we need to remove \/
if [ "${parent_backup_dir: -1}" == "/" ]; then
    parent_backup_dir=${parent_backup_dir::-2}
fi
if [ "${ctrl_file_dir: -1}" == "/" ]; then
    ctrl_file_dir=${ctrl_file_dir::-2}
fi

# Backup old template file
if [ -f "$ORACLE_HOME/dbs/init${sid}.ora" ]; then
    # Generate timestamp
    timestamp=$(date +%Y%m%d_%H%M)
    # Copy file with timestamp
    cp "$ORACLE_HOME/dbs/init${sid}.ora" "$ORACLE_HOME/dbs/init${sid}_${timestamp}.ora"
    echo "An Existing template file for the given database was found, so the following backup with timestamp was created:"
    echo "$ORACLE_HOME/dbs/init${sid}_${timestamp}.ora"
else
    echo "An Existing template file for the given database was not found, so no backup was created."
fi

# Setup the file to be located in the given ORACLE_SID's directory
init_file=$ORACLE_HOME/dbs/init${sid}.ora

# Copy init template to ORACLE_HOME location based on current database
cp "$source_init_file" "$init_file"
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to copy template $source_init_file to $init_file. Exiting..."
    exit 1
fi

# Strip the _cdb suffix for the db_name and truncate to 8 characters long.
db_name=${sid%_cdb}
db_name=${db_name:0:8}

# Update the control file paths
sed -i "s/'.\+ctl_01\.ctl'/'$ctrl_file_dir\/ctl_01.ctl'/g" "$init_file"
sed -i "s/,'.\+ctl_02\.ctl'/,'$ctrl_file_dir\/ctl_02.ctl'/g" "$init_file"

# Replace template SIDs with SID given by user
sed -i "s/db_unique_name='XXXX/db_unique_name='$sid/g" "$init_file"
sed -i "s/SERVICE=XXXX/SERVICE=${sid}/g" "$init_file"

# Update db_name with only the first 8 chars of the SID
sed -i "s/db_name='XXXX'/db_name='${db_name}'/g" "$init_file"

# Replace parent folder of backup
sed -i "s/db_recovery_file_dest='\/XXXX'/db_recovery_file_dest='$parent_backup_dir'/g" "$init_file"


# Replace compatible version with determined $version_compatible value
sed -i "s/compatible='.\+'/compatible='$version_compatible'/g" "$init_file"

# Verify that no placeholder remain in the newly created pfile.
if grep -q 'XXXX' "$init_file"; then
    echo "ERROR: $init_file still contains unsubstituted XXXX placeholders:"
    grep -n 'XXXX' "$init_file"
    echo "Exiting..."
    exit 1
fi

# Verify that new file is present in the appropriate directory
if [ -f "$ORACLE_HOME/dbs/init${sid}.ora" ]; then
    echo "New file $ORACLE_HOME/dbs/init${sid}.ora created successfully."
    exit 0
else
    echo "Error occurred while creating file $ORACLE_HOME/dbs/init${sid}.ora"
    exit 1
fi

