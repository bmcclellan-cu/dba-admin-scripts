#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose:  This script restores a database from an RMAN backup to a different filesystem 
#           structure on a new server. You must have a target database and a valid RMAN
#	        backup in order to restore. 
# 
# NOTE: This is DESIGNED to fail when RMAN runs out of archive logs
#	    to restore.
#
#	    In any case, it is useful to verify that all archive logs that should
#	    have been loaded were actually loaded. To do this, compare the last
#	    archive log entry in the restore log, make note of the filepath reported,
#	    and then review that location on disk and ensure things line up.
#
# Note: Estimated completion time is 1 hour per 1TB.
#
# NOTE: If initial restore fails, the following cleanup steps are required:
#       1. shutdown_oracle.sh $ORACLE_SID
#       2. smon (copy smon PID)
#       3. kill -9 PID
#       4. rm -rf $base_db_recovery_file_dest/*
#
#       May need to remove any new autobackups created in this directory:
#         $base_db_recovery_file_dest/autobackup
#       The controlfile restore step that runs the RMANRestoreControlfile.sh script
#       uses the most recent backup rather than the last full RMAN backup
#
# NOTE: To view RMAN metadata:
#         rman target /
#         To view datafile locations: report schema;
#         To report archive logs: list archivelog all;
#         To view redo log locations: SQL "select member from v$logfile";
#
# NOTE: If RMAN-06026 occurs and a previous open database resetlogs has been performed
#       on the database, check and update incarnation going back one at a time
#       list incarnation;
#       reset database to incarnation X;
#
# NOTE: If 'ORA-01547: warning: RECOVER succeeded but OPEN RESETLOGS would get error below',
#       this requires incomplete recovery
#       Step 1: Run script RMANOfflineDropREADonlyDatafiles.sh
#       Step 2: recover database using backup controlfile until cancel;
#               AUTO
#       Step 3: alter database open resetlogs;
#
# NOTE: 'RMAN-11003/ORA-01523' indicates that the redo log already has the correct directory
#       specified, manually log in to sqlplus and run 'alter database open resetlogs'.
#
# NOTE: 'RMAN-11003/ORA-00392' if 'log X of thread 1 is being cleared, operation not allowed',
#       try 'ALTER DATABASE CLEAR LOGFILE GROUP X' and 'alter database open resetlogs'.
#       If database still won't open, clear logfile on all groups and then open resetlogs.
#
# NOTE: 'RMAN-11003/ORA-01511/ORA-01516' indicates that the source location is invalid in rename
#       statement. To find the correct source location, run 'select member from v$logfile;'
#       and rerun RMANRestoreRedoLogsNewDirectory.sh with correct source.
#
# NOTE: To view datafile backups/errors:
#       list backup of datafile 1;
#       list failure;
#
# NOTE: 'ORA-01190/ORA-01110' if encountered during an online tablespace command, indicates
#       that the datafile is most likely empty.
#
# NOTE: If read-only datafiles are not available, the Oracle health check will
#       continuously fill up the alert log with notifications. To suppress these
#       messages until the read-only tablespaces are either available or dropped
#       run the following command:
#         SQL: alter system set "_disable_health_check" = TRUE scope=spfile ;
#         shutdown_oracle.sh $ORACLE_SID
#         startup_oracle.sh $ORACLE_SID
#
# NOTE: RMAN-06956, ORA-01119: error in creating database file, ORA-27040: file create error, unable to create file
#       This may indicate that a datafile/tablespace was added after the backup was taken. A new backup
#       should be taken, then try the restore again.
# 
# NOTE:     The script requires that RMAN restore dynamic scripts are present in db_recovery_file_dest. 
#           These are populated when backups are made using RMANCreateRestoreDynamicScripts.sh.
#
# NOTE:     Exit status of 2 indicates that the script finished with errors that the DBA should investigate
#
################################################################################
usage="Usage: RMANPrimaryRestoreScript.sh [ -s (optional, suppress email output) ] [ORACLE_SID] [db_recovery_file_dest that stores backup] [new database filesystem structure]"
example="Example: RMANPrimaryRestoreScript.sh  <ORACLE_SID> /ORACLE_BACKUP/July21 /restore/July21"

mail_opt=1 # Defaults to sending emails
# Set to 1 if all archive logs were not processed by RMAN restore, or no 
# archive logs were applied/found on disk.
# When set to 1, the email subject changes.
exit_status=0
# Process input options
while getopts ":hs" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    s)
        mail_opt=0
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

shift "$((OPTIND-1))"

if [ $# -ne 3 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

#Set environmental variables
export ORACLE_SID="$1"

# This guard exists to keep the restored database compatible with our other scripts.
# Many of our scripts lowercase the input SID which would cause incompatibility with a DB that has any uppercase characters.
if ! [[ "$ORACLE_SID" =~ ^[a-z0-9]+$ ]]; then
    echo "ERROR: ORACLE_SID input must be lowercase and alphanumeric. Exiting..."
    exit 1
fi

# Static input checks are done, begin logging to file.
curr_date=$(date +%Y-%m-%d_%H_%M_%S)
log_file="/tmp/${ORACLE_SID}_${curr_date}.out"
touch "$log_file"

# For every line of output in stderr and stdout, display it to the user and add it to the log_file 
exec > >(tee -a "$log_file") 2>&1
echo "RMANPrimaryRestoreScript.sh is logging to file $log_file."
echo "Script is being run with parameters: ($0 $1 $2 $3)"

# Setup trap to send an email whenever the script exits.
exit_handler(){
    exit_code=$?
    trap - EXIT INT TERM
    end_time=$(date "+%Y-%m-%d %H:%M:%S")
    echo "Script finished at $end_time"
    if [ -n "$start_time" ]; then
        time_diff=$("$HOME/common/general/ComputeTimeGap.sh" "$start_time" "$end_time")
        if [ $? -ne 0 ]; then
            echo "$time_diff"
            echo "An error occurred when computing the time elapsed. Continuing..."
        else
            time_diff="Elapsed time: $time_diff"
        fi
    fi

    
    if [[ "$exit_code" -eq 0 ]]; then
        # Only send email if mail_opt == 1. Bash short-circuits && conditionals.
        if [[ "$exit_status" -ne 0 ]]; then
            [[ "$mail_opt" -eq 1 ]] && mailx -s "$HOSTNAME - RMANPrimaryRestoreScript.sh - Script completed with errors - $time_diff" "$ALL_DBA_EMAIL_LIST" < "$log_file"
            exit 2
        else
            [[ "$mail_opt" -eq 1 ]] && mailx -s "$HOSTNAME - RMANPrimaryRestoreScript.sh - Script completed successfully - $time_diff" "$ALL_DBA_EMAIL_LIST" < "$log_file"
            exit 0
        fi
    else
        [[ "$mail_opt" -eq 1 ]] && mailx -s "$HOSTNAME - RMANPrimaryRestoreScript.sh - Script failed" "$ALL_DBA_EMAIL_LIST" < "$log_file"
        exit 1
    fi

}
trap exit_handler EXIT INT TERM # On exit, call exit_handler.

# Verify that $ORACLE_BACKUP_DIR exists. $ORACLE_BACKUP_DIR is set in .bashrc 
if [ ! -d "$ORACLE_BACKUP_DIR" ]; then
    echo "\$ORACLE_BACKUP_DIR $ORACLE_BACKUP_DIR does not exist. Exiting..."
    exit 1
fi

# Current location of RMAN backup
base_db_recovery_file_dest="$2"
if ! [ -d "$base_db_recovery_file_dest" ]; then
    echo "Directory $base_db_recovery_file_dest does not exist. Exiting..."
    exit 1
fi

# Substitute d19 -> dev and p19 -> prod.
# This is done to ensure a consistent directory name for our database
# Ex.: sid1d19 -> sid1dev
database_name="${ORACLE_SID,,}"
database_name=$(echo "$database_name" | sed "s/d19\$/dev/")
database_name=$(echo "$database_name" | sed "s/p19\$/prod/")

# Location we are restoring the backup
fileSystem="$3"

# Normalize away any trailing slashes so the suffix checks below are reliable  
fileSystemWithoutSID=$(echo "$fileSystem" | sed 's#/*$##')

# If the caller already included the database name in the directory or Oracle SID, drop it so exactly one gets appended below. 
# s#/$ORACLE_SID\$##I -> removes instances of /$ORACLE_SID at the end of the string regardless of casing
# s#/$database_name\$##I -> removes instances of /$database_name at the end of the string regardless of casing
# NOTE: Order matters; $ORACLE_SID must be stripped before $database_name, otherwise a path like /ssd/sid1dev/sid1d19 ends up with a duplicated database directory
fileSystemWithoutSID=$(echo "$fileSystemWithoutSID" | sed "s#/$ORACLE_SID\$##I")
fileSystemWithoutSID=$(echo "$fileSystemWithoutSID" | sed "s#/$database_name\$##I")

# Derived from fileSystemWithoutSID rather than computed separately, so the two  
# can never disagree. The generated restore scripts append /$database_name/ to  
# fileSystemWithoutSID, so this must stay equal to that result.  
fileSystemWithSID="$fileSystemWithoutSID/$database_name" 

# Normalize away any trailing slashes 
db_recovery_file_normalized=$(echo "$base_db_recovery_file_dest" | sed 's#/*$##')  


db_recovery_file_dest="$db_recovery_file_normalized/${ORACLE_SID^^}" 

# Create directory in /tmp to store copies of dynamically generated restore scripts for execution
mkdir -p "/tmp/$ORACLE_SID"

# Verify RMAN backup directory exists
if [ ! -d "$db_recovery_file_dest" ]; then
    echo "RMAN backup directory ${db_recovery_file_dest} does not exist. Exiting..."
    exit 1
fi

# Check for existence of dynamically generated restore scripts
scripts_needed=(RMANCreateDirStructure.sh RMANRestoreReadWriteTablespacesOnly.sh RMANOfflineDropREADonlyDatafiles.sh RMANRestoreRedoLogsNewDirectory.sh)
for script in "${scripts_needed[@]}"; do
    if [ ! -f "${db_recovery_file_dest}/scripts/${ORACLE_SID^^}/${script}" ]; then
        echo "Required file ${db_recovery_file_dest}/scripts/${ORACLE_SID^^}/${script} not found. Exiting..."
        exit 1
    fi  
done

# Copy dynamically generated restore scripts to /tmp/$ORACLE_SID
cp "${db_recovery_file_dest}/scripts/${ORACLE_SID^^}/"* "/tmp/${ORACLE_SID}"
chmod 755 "/tmp/${ORACLE_SID}/"*

# Create directory we are restoring into
mkdir -p "$fileSystemWithSID"
if [ $? -ne 0 ]; then
    echo "Error occurred while making directory $fileSystemWithSID. Exiting..."
    echo "We need an empty directory to restore an RMAN backup into."
    exit 1
fi

#Verify SID is not already running
db_status=$("$HOME/common/oracle/CheckDatabaseOpenStatus.sh" "$ORACLE_SID")
if [ $? -ne 0 ]; then 
    echo "$db_status"
    echo "Error occurred while running CheckDatabaseOpenStatus.sh on database $ORACLE_SID. Exiting..."
    exit 1
elif [ "$db_status" != "CLOSED" ]; then
    echo "Error: database is already running in ${db_status} status. Exiting..."
    exit 1
fi

start_time=$(date "+%Y-%m-%d %H:%M:%S")
echo "Starting script...$start_time"

# Iteratively backtrack through directories if current directory doesn't exist
dir_check="$fileSystemWithoutSID"
while [ ! -d "$dir_check" ]; do
   dir_check=$(dirname "$dir_check")
done

# Calculate free space of restore location to ensure enough space exists
filesystem_size=$(df "$dir_check" | tail -1 | xargs | cut -d " " -f4)

# Calculate space used by backup files
recovery_dir_size=$(du -s "$db_recovery_file_dest" | xargs | cut -d " " -f1)
# Required space is equal to 110% of the backup file size.
# This calculation is done by piping the floating point equation into bc, command line calculator
required_space=$(echo "$recovery_dir_size * 1.1" | bc)

# Checking that the size of directory where RMAN backup files are is larger than 2GB
if ! [ "$recovery_dir_size" -gt 2000000 ]; then
    echo "RMAN backup files under 2GB in size within directory ${db_recovery_file_dest}. Exiting..."
    exit 1
fi

# Floating point comparison must also be piped through bc, which returns 1 if true and 0 if false
# If true, the filesystem is not large enough, so the script exits
if (($(echo "$filesystem_size < $required_space" | bc))); then
    echo "$dir_check restore directory is not large enough for the backup files. Restore location must be 10% larger."
    echo "Restore directory size: $filesystem_size KB"
    # Display required space without decimal by cutting off remainder using cut command
    echo "Required space: $(echo "$required_space" | cut -d "." -f1) KB. Exiting..."
    exit 1
fi

# Check that the user has read permissions for the initial recovery directory
test -r "$db_recovery_file_dest"
if [ $? -ne 0 ]; then
    echo "User does not have read access to filesystem $db_recovery_file_dest. Exiting..."
    exit 1
fi

# Check if oracle listener is running. Start it up if it's not running.
listener_running=$("$HOME/common/oracle/CheckIfListenerIsRunning.sh")
if [ $? -ne 0 ]; then
    echo "$listener_running" 
    echo "Error occurred while checking if Oracle listener is running. Exiting..." 
    exit 1
elif [ "$listener_running" != "Yes" ]; then
    echo "Oracle listener is not running. Starting Oracle listener..." 

    # Start listener
    start_listener=$("$HOME/common/oracle/StartOracleListener.sh")
    if [ $? -ne 0 ]; then
        echo "$start_listener" 
        echo "Error occurred while starting oracle listener. Exiting..." 
        exit 1
    fi
fi

create_dir_structure=$("/tmp/$ORACLE_SID/RMANCreateDirStructure.sh" "$fileSystemWithoutSID")
if [ $? -ne 0 ]; then
    echo "$create_dir_structure"
    echo "Error occurred while running /tmp/$ORACLE_SID/RMANCreateDirStructure.sh. Exiting..."
    exit 1
fi

# Delete copied RMANCreateDirStructure.sh script
rm -f "/tmp/$ORACLE_SID/RMANCreateDirStructure.sh"

# If an spfile for the database already exists, rename it with the current date appended so that a new spfile can replace it
if [ -f "$ORACLE_HOME/dbs/spfile${ORACLE_SID}.ora" ]; then
    mv "$ORACLE_HOME/dbs/spfile${ORACLE_SID}.ora" "$ORACLE_HOME/dbs/spfile${ORACLE_SID}_${curr_date}.ora"
fi

# Update initXXX.ora file based on input
echo "Updating init file..."
cp "$HOME/common/oracle/initXXXX.ora" "$ORACLE_HOME/dbs/init${ORACLE_SID}.ora"
# update param
update_init_template=$("$HOME/common/oracle/UpdateInitTemplateFile.sh" "$ORACLE_SID" "${base_db_recovery_file_dest}" "$fileSystemWithSID")
if [ $? -ne 0 ]; then
    echo "$update_init_template"
    echo "Error occurred while running UpdateInitTemplateFile.sh. Exiting..."
    exit 1
fi

# Startup database in nomount mode
echo "Starting up $ORACLE_SID in nomount mode..."
startup_oracle=$("$HOME/common/oracle/StartupOracleNoMount.sh" "$ORACLE_SID")
if [ $? -ne 0 ]; then
    echo "$startup_oracle"
    echo "Error occurred while running StartupOracleNoMount.sh. Exiting..."
    exit 1
fi

# Restore controlfile
# The absolute path of the control file is defined in the init${ORACLE_SID}.ora pfile that is 
# created above
echo "Restoring RMAN control file for ${ORACLE_SID}..."
restore_control_file=$("$HOME/common/oracle/RMANRestoreControlfile.sh" 100 "$ORACLE_SID")
if [ $? -ne 0 ]; then
    echo "$restore_control_file"
    echo "Error occurred while running RMANRestoreControlfile.sh. Exiting..."
    exit 1
fi

# During the mount process the DB attempts to write an empty archive log directory
# with the current date. Therefore we need to temporarily change the db_recovery_file_dest to a directory we absolutely know we can write to.
update_db_recovery_file=$("$HOME/common/oracle/UpdateDBrecoveryFileDest.sh" -o "$ORACLE_BACKUP_DIR" "$ORACLE_SID" memory)
if [ $? -ne 0 ]; then
    echo "$update_db_recovery_file"
    echo "Error occurred while running UpdateDBrecoveryFileDest.sh. Exiting..."
    exit 1
fi

# Mount database
echo "Mounting $ORACLE_SID database..."
mount_oracle_db=$("$HOME/common/oracle/MountOracleDatabase.sh" "$ORACLE_SID")
if [ $? -ne 0 ]; then
    echo "$mount_oracle_db"
    echo "Error occurred while running MountOracleDatabase.sh. Exiting..."
    exit 1
fi

# We reset this directory to point back to where the RMAN backup files are
update_db_recovery_file=$("$HOME/common/oracle/UpdateDBrecoveryFileDest.sh" -o "$base_db_recovery_file_dest" "$ORACLE_SID" memory)
if [ $? -ne 0 ]; then
    echo "$update_db_recovery_file"
    echo "Error occurred while running UpdateDBrecoveryFileDest.sh. Exiting..."
    exit 1
fi

# Create spfile from pfile
echo "Creating spfile from pfile init${ORACLE_SID}.ora..."
create_spfile=$("$HOME/common/oracle/CreateSpfileFromPfile.sh" "$ORACLE_HOME/dbs/init${ORACLE_SID}.ora")
if [ $? -ne 0 ]; then
    echo "$create_spfile"
    echo "Error occurred while running CreateSpfileFromPfile.sh. Exiting..."
    exit 1
fi

# Begin restore process
echo "Starting RMAN restore..."

# Run CheckIfReadOnlyTablespacesExist.sh, store status in contains_readonly_datafiles
contains_readonly_datafiles=$("$HOME/common/oracle/CheckIfReadOnlyTablespacesExist.sh" "$ORACLE_SID")

if [ $? -ne 0 ]; then
    echo "$contains_readonly_datafiles"
    echo "Error occurred while running CheckIfReadOnlyTablespacesExist.sh. Exiting..."
    exit 1
elif [[ ! "$contains_readonly_datafiles" =~ (Yes|No)$ ]]; then  
    echo "$contains_readonly_datafiles"  
    echo "Unexpected output from CheckIfReadOnlyTablespacesExist.sh. Exiting..."  
    exit 1  
fi 

echo "Restoring read-write tablespaces"
# Step 1: Restore read-write tablespaces
"/tmp/$ORACLE_SID/RMANRestoreReadWriteTablespacesOnly.sh" "$fileSystemWithoutSID"
# Store the return code and name of the script
success_check=$?
prev_script="RMANRestoreReadWriteTablespacesOnly"

# Find latest rman output log file, multiple runs can create multiple files
temp_file=$(ls -lrt /tmp/rman_"${ORACLE_SID}"_${prev_script}*.txt | tail -1 | awk '{print $NF}')

if [ -z "$temp_file" ] || ! [ -f "$temp_file" ]; then 
    echo "${prev_script}.sh exited with status ${success_check} and produced no RMAN output log."
    echo "Expected RMAN output log /tmp/rman_${ORACLE_SID}_${prev_script}*.txt not found. Exiting..."
    exit 1
fi

# Catch possible incarnation error, where some of the files specified for restore could not be found.
if [[ $(cat "$temp_file") == *RMAN-06026* ]]; then
    echo "Error: datafiles not found within backup sets."
    echo "Error may be attributed to incarnation mismatch between control files and data files"
    echo "Run 'list incarnation;' to verify"
    echo "Otherwise, look at temp file ${temp_file} for details. Exiting..."
    exit 1
elif [ "$success_check" -ne 0 ]; then
    echo "RMANRestoreReadWriteTablespacesOnly.sh failed."
    echo "Look at temp file ${temp_file} for details. Exiting..."
    exit 1
else
    echo "Successfully restored all read-write tablespaces"
fi

# Step 2: drop any references to read-only datafiles
# If there are no read-only datafiles, RMANOfflineDropREADonlyDatafiles.sh still always drops STAGING datafiles; read-only drops only occur if read-only datafiles exist
"/tmp/$ORACLE_SID/RMANOfflineDropREADonlyDatafiles.sh"
# Store the return code and name of the script
success_check=$?
prev_script="RMANOfflineDropREADonlyDatafiles"

# Find latest rman output log file
temp_file=$(ls -lrt /tmp/rman_"${ORACLE_SID}"_${prev_script}*.txt | tail -1 | awk '{print $NF}')

if [ -z "$temp_file" ] || ! [ -f "$temp_file" ]; then 
    echo "${prev_script}.sh exited with status ${success_check} and produced no RMAN output log."
    echo "Expected RMAN output log /tmp/rman_${ORACLE_SID}_${prev_script}*.txt not found. Exiting..."
    exit 1
fi

if [ "${success_check}" -ne 0 ]; then
    echo "${prev_script}.sh failed."
    echo "Look at temp file ${temp_file} for details. Exiting..."
    exit 1
else
    echo "Successfully dropped references to read-only datafiles"
fi

# Step 3: recover read-write datafiles to latest archive log

# 'ORA-00278 log file no longer needed for this recovery' is not an error
# but indicates the redo log was either successfully applied or
# the datafiles already contain that data
# This sqlplus block will always fail, as there are only a limited number of archive logs
"$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
spool /tmp/rman_${ORACLE_SID}_AUTORECOVERY_${curr_date}.txt
set linesize 200
alter session set nls_date_format = 'yyyy-mm-dd hh24:mi:ss';
recover database using backup controlfile until cancel;
AUTO
EOD

# Only catches sqlplus failing to launch; recovery errors are checked via the spool file below
if [ $? -ne 0 ]; then
    echo "sqlplus failed during AUTORECOVERY. Exiting..."
    exit 1
fi

prev_script="AUTORECOVERY"

temp_file=$(ls -lrt /tmp/rman_"${ORACLE_SID}"_${prev_script}*.txt | tail -1 | awk '{print $NF}')

if [ -z "$temp_file" ] || ! [ -f "$temp_file" ]; then 
    echo "Expected RMAN output log /tmp/rman_${ORACLE_SID}_${prev_script}*.txt not found. Exiting..."
    exit 1
fi

# ORA-01119 indicates that a file specified in RMAN restore script is not
# physically present in either backup set or as a read-only datafile in
# the backup directory $db_recovery_file_dest
if [[ $(cat "$temp_file") == *"ORA-01119"* ]]; then
    echo "Backup sets/directory is missing files. Review $temp_file temp file for details. Exiting..."
    exit 1
fi

# We now need to verify that all archive logs were processed!
echo "All archive logs that are available:"
archive_logs=$("$HOME/common/general/list_files.sh" "$db_recovery_file_dest/archivelog")
if [ $? -ne 0 ]; then
    echo "$archive_logs"
    echo "Error occurred while running list_files.sh. Exiting..."
    exit 1
fi
echo "$archive_logs"
echo ""
echo "Checking processed archive logs..."

last_sequence_on_disk=0
last_rman_sequence=0

#Example:
# archive_logs ="
# /DATABASE/recover_dest/SID/archivelog/2026_07_31/o1_mf_1_4252_o6rqfdbh_.arc - Last Modified 07/31/26 08:32
# /DATABASE/recover_dest/SID/archivelog/2026_07_31/o1_mf_1_4253_o6rqggdl_.arc - Last Modified 07/31/26 08:33
# "
# last_sequence_on_disk = 4253

# Find lines that have archive log paths and do not have 'Finished processing files' in the line
archive_logs=$(echo "$archive_logs" | grep "\.arc" | grep -v "Finished processing files")
# Take the Archive file names and get the file path
# If there are archive logs, then get the file name from the path with basename.
# Next get the 4th item in the Archive log name separated by '_' which is the sequence number, treat those sequences as numbers (-n) and sort them from low to high.
# Finally take the last sequence number (the highest seq. number). This will be the highest archive log sequence number on disk.

if [ -n "$archive_logs" ]; then
    last_sequence_on_disk=$(echo "$archive_logs" | cut -d " " -f1 | xargs -n1 basename | cut -d "_" -f4 | sort -n | tail -n1)
else
    echo "Error: No Archive logs were found on disk."
    exit_status=1
fi

# Verify last_sequence_on_disk is an integer
if [[ ! "$last_sequence_on_disk" =~ ^[0-9]+$ ]]; then
    echo "Last archive log sequence found on disk is not an integer!"
    exit 1
fi

# Find last sequence applied by SQLPLUS RMAN restore by grabbing highest applied sequence number
# There are two greps, the first filters for lines with "no longer".
# The second grep is Perl-Compatible (-P) and gets the full .arc file path
#   Ex: log file '/DATABASE_BACKUP_DB1/.../o1_mf_1_4235_o69dv98o_.arc' no longer needed for this recovery
#   Result from second grep: /DATABASE_BACKUP_DB1/.../o1_mf_1_4235_o69dv98o_.arc
rman_archive_logs=$(grep "no longer" "$temp_file" | grep -oP "log file '\K[^']+")
# rman_archive_logs ="
# /DATABASE/recover_dest/SID/archivelog/2026_07_31/o1_mf_1_4252_o6rqfdbh_.arc
# /DATABASE/recover_dest/SID/archivelog/2026_07_31/o1_mf_1_4253_o6rqggdl_.arc
# "
# last_rman_sequence = 4253

if [ -n "$rman_archive_logs" ]; then
    # If there were archive logs applied, then get the file name from the path with basename.
    # Next get the 4th item in the Archive log name separated by '_' which is the sequence number, treat those sequences as numbers (-n) and sort them from low to high.
    # Finally take the last sequence number (the highest seq. number). This will be the highest archive log sequence number applied by RMAN.
    last_rman_sequence=$(echo "$rman_archive_logs" | xargs -n1 basename | cut -d "_" -f4 | sort -n | tail -n1)
else
    echo "Error: No Archive logs were applied."
    exit_status=1
fi

# Verify last_rman_sequence is an integer
if [[ ! "$last_rman_sequence" =~ ^[0-9]+$ ]]; then
    echo "Last applied archive log sequence is not an integer!"
    exit 1
fi

ORA_00308_error=$(grep "cannot open archived log" "$temp_file" | cut -d "'" -f2)

# Assuming initially that all archive logs were processed
diff=1

if [ -n "$ORA_00308_error" ]; then
    # Find sequence number from $ORA_00308_error
    error_sequence=$(echo "$ORA_00308_error" | xargs -n1 basename | cut -d "_" -f4)

    # Verify error_sequence is an integer
    if [[ ! "$error_sequence" =~ ^[0-9]+$ ]]; then
        echo "First failed archive log application sequence is not an integer"
        exit 1
    fi

    # Check that the sequence not found is one more than the last existing sequence in the archive log directory
    # Also check that the last sequence found by RMAN is equal to the last sequence in the archive log directory
    # If all archive logs were not processed, alert user and set exit_status=1
    # If difference is 1, then all the archive logs on disk were applied
    diff=$((error_sequence - last_sequence_on_disk))
fi

# This condition cannot tell a real gap in the archive logs apart from a log that was
# created after the recovery pass already stopped, so it issues a info message instead of exiting.
# Setting exit_status=1 lets the restore continue and alerts the user via the email subject ("completed with errors").
# If there is a real difference in the archive logs applied and the archive logs needed, all the datafiles would not be recovered to a common SCN.
# That would result in ALTER DATABASE OPEN RESETLOGS failing with an ORA error below. We would catch this below and exit immediately.
if [ "$diff" -ne 1 ]; then
    echo "Error: Not all archive logs were processed by RMAN restore."
    echo "Last archive log sequence processed by RMAN: $last_rman_sequence"
    echo "Latest archive log sequence on disk: $last_sequence_on_disk"
    echo "Script failed to find/process sequence $error_sequence"
    echo "This archive log may have been created while the script was running!"
    echo "Review temp file $temp_file for details."
    exit_status=1
elif [ "$last_sequence_on_disk" -ne "$last_rman_sequence" ]; then
    echo "Error: Not all archive logs were processed by RMAN restore."
    echo "Last archive log sequence processed by RMAN: $last_rman_sequence"
    echo "Latest archive log sequence on disk: $last_sequence_on_disk"
    echo "This archive log may have been created while the script was running!"
    echo "Review temp file $temp_file for details."
    exit_status=1
elif [ "$exit_status" -eq 0 ]; then
    echo "All archive logs were successfully processed by RMAN restore!"
fi

# At this time, we need to check if the backup location that RMAN was reading from is the same
# backup location that the current server has access to write to. There are scenarios where
# a read-only filesystem is used for reading backups, which will not allow writes.
# If this is not done, we cannot open the database.

echo "Printing out current db_recovery_file_dest param:"
"$HOME/common/oracle/PrintParamDBrecoveryFileDest.sh"
if [ $? -ne 0 ]; then
    echo "Error occurred while running PrintParamDBrecoveryFileDest.sh. Exiting..."
    exit 1
fi

echo "Checking if the backup location we are reading from is the same backup location this server is configured to write to."
# $db_recovery_file_normalized is equal to $(echo "$base_db_recovery_file_dest" | sed 's#/*$##')
# $db_recovery_file_normalized does not have trailing slash which agrees with $ORACLE_BACKUP_DIR format in .bashrc
if [ "$db_recovery_file_normalized" != "$ORACLE_BACKUP_DIR" ]; then
    echo "Backup location is different, updating db_recovery_file_dest in pfile/spfile/memory to server location."
    # If an spfile for the database already exists, rename it with the current date appended so that a new spfile can replace it
    if [ -f "$ORACLE_HOME/dbs/spfile${ORACLE_SID}.ora" ]; then
        mv "$ORACLE_HOME/dbs/spfile${ORACLE_SID}.ora" "$ORACLE_HOME/dbs/spfile${ORACLE_SID}_${curr_date}.ora"
    fi

    # Update initXXX.ora file with new backup location
    echo "Updating init file..."
    cp "$HOME/common/oracle/initXXXX.ora" "$ORACLE_HOME/dbs/init${ORACLE_SID}.ora"
    # Update paths
    "$HOME/common/oracle/UpdateInitTemplateFile.sh" "$ORACLE_SID" "$ORACLE_BACKUP_DIR" "$fileSystemWithSID"
    if [ $? -ne 0 ]; then
        echo "Init file update failed. Exiting..."
        exit 1
    else
        echo "Init file update succeeded!"
    fi

    # Regenerating spfile from pfile
    echo "Regenerating spfile with new backup directory init${ORACLE_SID}.ora..."
    "$HOME/common/oracle/CreateSpfileFromPfile.sh" "$ORACLE_HOME/dbs/init${ORACLE_SID}.ora"
    if [ $? -ne 0 ]; then
        echo "Spfile creation failed. Exiting..."
        exit 1
    else
        echo "Spfile creation succeeded!"
    fi

    #Update the db_recovery_file_dest in memory, the current instance was started with static pfile
    "$HOME/common/oracle/UpdateDBrecoveryFileDest.sh" -o "$ORACLE_BACKUP_DIR" "$ORACLE_SID" memory
    if [ $? -ne 0 ]; then
        echo "Error occurred while running UpdateDBrecoveryFileDest.sh. Exiting..."
        exit 1
    fi

    echo "Printing out current db_recovery_file_dest param:"
    "$HOME/common/oracle/PrintParamDBrecoveryFileDest.sh"
    if [ $? -ne 0 ]; then
        echo "Error occurred while running PrintParamDBrecoveryFileDest.sh. Exiting..."
        exit 1
    fi
fi

# Next step: update the REDO log location and open the database
# Oracle database creates new redo logs from scratch and this code only
# specifies where the redo logs will be created

"/tmp/$ORACLE_SID/RMANRestoreRedoLogsNewDirectory.sh" "$fileSystemWithSID"
# Store the return code and name of the script
success_check=$?
prev_script="RMANRestoreRedoLogsNewDirectory"

temp_file=$(ls -lrt /tmp/rman_"${ORACLE_SID}"_${prev_script}*.txt | tail -1 | awk '{print $NF}')

if [ -z "$temp_file" ] || ! [ -f "$temp_file" ]; then 
    echo "${prev_script}.sh exited with status ${success_check} and produced no RMAN output log."
    echo "Expected RMAN output log /tmp/rman_${ORACLE_SID}_${prev_script}*.txt not found. Exiting..."
    exit 1
fi

# Check success of redo logs update
if [[ $(cat "$temp_file") == *ORA-01511* ]] || [[ $(cat "$temp_file") == *ORA-01523* ]]; then
    echo "Redo logs are already assigned to the correct directory"
    echo "Opening database..."
    res=$(
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set heading off
    set feedback off
    ALTER DATABASE OPEN RESETLOGS;
EOD
    )
    if [ $? -ne 0 ] || [[ "$res" =~ "ORA-" ]]; then
        echo "$res"
        echo "Failed to open database during open RESETLOGS. Exiting..."
        exit 1
    fi
    db_status=$("$HOME/common/oracle/CheckDatabaseOpenStatus.sh" "$ORACLE_SID")
    if [ $? -ne 0 ]; then
        echo "Error occurred while running CheckDatabaseOpenStatus.sh:"
        echo "$db_status"
        echo "Exiting..."
        exit 1
    elif [ "$db_status" != "OPEN" ]; then
        echo "Error: database did not open"
        echo "Need to review status, open database manually, and run 'CreateTempTablespace.sh -d $fileSystemWithSID/temp_01.dbf'. Exiting..."
        exit 1
    else
        # Temp tablespace creation will occur during the code block below
        echo "Redo logs updated and database is now OPEN!!"
    fi
elif [ $success_check -ne 0 ]; then
    echo "Error occurred while running $prev_script.sh. Check $temp_file for more details. Exiting..."
    exit 1
else
    db_status=$("$HOME/common/oracle/CheckDatabaseOpenStatus.sh" "$ORACLE_SID")

    if [ $? -ne 0 ]; then
        echo "$db_status"
        echo "Error occurred while running CheckDatabaseOpenStatus.sh. Exiting..."
        exit 1
    elif [ "$db_status" == "OPEN" ]; then
        echo "Redo logs updated and database is now OPEN!!"
        echo "RMAN restore script complete! $(date)"
    else
        echo "Error: database did not open"
        echo "Need to open database manually and run 'CreateTempTablespace.sh -d $fileSystemWithSID/temp_01.dbf'. Exiting..."
        exit 1
    fi
fi

# Setup a temp tablespace in the new filesystem directory and drop any old references
echo "Setting up temp tablespace on the new database..."

new_temp_file="$fileSystemWithSID/temp_01.dbf"

# If new temp file already exists, iteratively increment and recheck existence
while [ -f "$new_temp_file" ]; do
    # These two awk statements extract the number suffix from temp_01.dbf regardless of the number size (Ex. temp_12051.dbf -> 12051)
    num_suffix=$(echo "$new_temp_file" | awk -F ".dbf" '{print $1}' | awk -F "_" '{print $NF}')
    new_file_num=$((10#$num_suffix + 1))

    # Check if we need to prepend a 0
    if [ $new_file_num -le 9 ]; then
        new_file_num="0${new_file_num}"
    fi

    new_temp_file="$fileSystemWithSID/temp_${new_file_num}.dbf"
done

# Create new temp tablespace and drop (-d) all other temp tablespaces
"$HOME/common/oracle/CreateTempTablespace.sh" -d "$new_temp_file"

if [ $? -ne 0 ]; then
    echo "Error occurred while creating new temp tablespace. Check above output for details. Exiting..."
    exit 1
else
    echo "New temp tablespace created successfully."
fi

echo "RMAN restore successful!"

if [[ "$contains_readonly_datafiles" =~ "Yes" ]]; then
    echo "Read-only tablespaces were identified during restore."
    echo "User must run AddBackInReadOnlyTablespaces.sh $ORACLE_SID <archive dir csv> $base_db_recovery_file_dest"
fi

exit 0
