#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: To check if the Oracle db_recovery_file_dest_size parameter
#          is safe to proceed with a backup.
#
# Explanation: This script is called by 'OraclePrimaryRMANBackupScript.sh' to verify there is enough
#              diskspace in the backup directory to house a backup.
#
# Notes: db_recovery_file_dest_size is set to 100TB on these databases deliberately. We do not
#        use it to restrict how much data is written to disk, so it is set high enough never to
#        be the binding constraint. The meaningful check is filesystem space (the df check
#        below); the parameter check further down is a backstop in case that changes.
#####################################################################################

# Process input options
while getopts ":h" option; do
    case $option in
    h)
        echo "Usage: CheckDBRecoveryFileDestSize.sh"
        exit 0;;
    \?)
        echo "Error: Invalid option"
        exit 1
    esac
done
shift "$((OPTIND-1))"

# This script takes no positional arguments; it operates on $ORACLE_SID.
if [ $# -ne 0 ]; then
    echo "Error: CheckDBRecoveryFileDestSize.sh takes no arguments. Got $#. Exiting..."
    echo "Usage: CheckDBRecoveryFileDestSize.sh"
    exit 1
fi

# Check for valid ORACLE_SID
sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
       echo "Error, \$ORACLE_SID not set..."
       exit 1
    fi
    echo "Error, provided ORACLE_SID is not open. Exiting..."
    exit 1
fi

# Check OS. GNU df wraps long device names onto a second line, which shifts the columns the
# awk below reads. -P forces the single-line POSIX output format. BSD/Solaris df already
# behaves that way, so the alias is Linux-only.
os=$(uname -s)
if [ "$os" == "Linux" ]; then
    shopt -s expand_aliases
    alias df='df -P'
fi
echo "SID: $ORACLE_SID"

# Find database recovery file destination
fileSystemName=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever sqlerror exit 1;
    set heading off
    set feedback off
    select value from v\$parameter where name = 'db_recovery_file_dest';
    exit;
EOD
)

if [ $? -ne 0 ]; then
    echo "Error occurred while querying for database recovery file destination."
    exit 1
fi

# Trim off new line character from query return
backupLocation=$(echo "$fileSystemName/${ORACLE_SID^^}" | tr -d '\n')

# The backup set directory only exists if an RMAN backup has already been taken to that location
if [ -d "$backupLocation/backupset" ]; then
    backupLocation="$backupLocation/backupset"
fi

echo "Backup location: $backupLocation"
echo

# Check how much space is currently used for all RMAN backup files
fileSystemUsed=$(du -s "$backupLocation")
if [ $? -ne 0 ] || [ -z "$fileSystemUsed" ]; then
    echo "Error: could not determine space used under $backupLocation. Exiting..."
    exit 1
fi
fileSystemUsed=$(echo "$fileSystemUsed" | awk '{printf "%.0f \n", $1/1024/1024}')

echo "Total space used by backups: $fileSystemUsed GB"

# For raw space needed, multiply total by 2 to account for an extra copy of the database
# Extra copy exists since the new backup must be complete prior to the removal of the previous database backup
# For raw space needed, multiply total further (by 2.25 total) to account for any new data taken in over the week
backupSizeDoubledraw=$(echo "$fileSystemUsed * 2.25" | bc)
# Round value to an integer
backupSizeDoubled=$(echo "($backupSizeDoubledraw+0.5)/1" | bc)

echo "Total space needed (2.25x space used by RMAN backup files): $backupSizeDoubled GB"

fileSystemAvail=$(df -k "$backupLocation")
if [ $? -ne 0 ] || [ -z "$fileSystemAvail" ]; then
    echo "Error: could not determine space available under $backupLocation. Exiting..."
    exit 1
fi
fileSystemAvail=$(echo "$fileSystemAvail" | grep -iv avail | awk '{printf "%.0f \n", $4/1024/1024}')

echo "Filesystem space available: $fileSystemAvail GB"

if [ "$backupSizeDoubled" -gt "$fileSystemAvail" ]; then
    echo " "
    echo "**Error: Not enough space for backup within directory $backupLocation"
    echo " "
    exit 1
else
    echo "Sufficient space for backups on disk"
fi

# Check total recovery space upper limit as set as a parameter within the database
recoverySpace=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever sqlerror exit 1;
    set numwidth 20
    set heading off
    set feedback off
    SELECT ceil( space_limit / 1024 / 1024 / 1024 ) USED_G
    FROM v\$recovery_file_dest;
    exit;
EOD
)

if [ $? -ne 0 ]; then
    echo "Error occurred while querying for total recovery space as parameter within the database."
    exit 1
fi

# Trim off new line character from query return
recoverySpace=$(echo "$recoverySpace" | tr -d '\n')

echo
echo "Total recovery space allocated (as parameter within the database): $recoverySpace GB"

# Verify that total recovery space parameter is set high enough for backup
if [ "$backupSizeDoubled" -gt "$recoverySpace" ]; then
    echo " "
    echo "Error: db_recovery_file_dest_size parameter is set lower than required size of backup (2.25x space used by RMAN backup files)"
    echo " "
    exit 1
else
    echo "db_recovery_file_dest_size parameter as set within database provides enough space for backups"
fi
