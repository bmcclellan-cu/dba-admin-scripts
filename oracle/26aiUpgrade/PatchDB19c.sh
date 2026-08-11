#!/bin/bash
# AvailabilityFlag: Public
# 
# Purpose:  This script takes a currently running Oracle 19c database instance and patches it from the current version to
#           the latest version of Oracle Database if provided with an up-to-date ORACLE_HOME. AutoUpgrade will download
#           the necessary patches to patch_download_location, which may take 10-20GB.
# 
# Notes:    AutoUpgrade expects the target home to be the most up-to-date version of Oracle Database 19c. If the
#           version does not match, the upgrade process will fail during the AutoUpgrade Analyze step.
# 
#           This script is expected to be used during our migration to 26ai, where we update our databases to the latest RU
#           before migrating to mitigate bugs in previous versions, and as such is a part of that toolset. 
#           
#           While AutoUpgrade will be able to rollback the database in the case of most failures, Oracle recommends making a 
#           backup of a database prior to running a patch operation.
# 
######################################################

usage="Usage: PatchDB19c.sh [ -v (optional, skip database index and object validation) ] [ ORACLE_SID ] [ patch_download_location ] [ target_home ]"
example1="Example: PatchDB19c.sh sid1prod /data/patch_dl_dir /oracle/install/dir/19.32.0/dbhome_1"

# Parameters:
#   - mode: analyze or deploy
#   - log_file: File to redirect autoupgrade logs to
#   - description: Text description to display before running AutoUpgrade
run_autoupgrade(){
    mode=$1
    log_file=$2
    description=$3

    # Gets the most recent autoupgrade run error log for that particular autoupgrade log directory.
    # This only gets the surface java error, but useful error logging is sometimes present.
    AUTOUPGRADE_ERR_LOG="$ORACLE_BASE/patching/$ORACLE_SID/$timestamp/cfgtoollogs/patch/auto/autoupgrade_patching_err.log"

    # Run AutoUpgrade
    echo "$description"
    echo "Log file for AutoUpgrade $mode: $log_file"
    "$JAVA_BIN" -jar "$AUTOUPGRADE_JAR" -config "$autoupgrade_cfg" -patch -mode "$mode" -noconsole > "$log_file" 2>&1
    exit_code=$?
    if [ $exit_code -ne 0 ] && grep "No newer Oracle Database Release Update file is found" "$AUTOUPGRADE_ERR_LOG"; then
        echo "ERROR: Database is already updated to the newest Release Update, nothing to do. Exiting..."
        exit 1
    elif [ $exit_code -ne 0 ]; then
        echo "AUTOUPGRADE STDOUT LOG OUTPUT:"
        cat "$log_file"
        echo
        echo
        echo "AUTOUPGRADE GENERIC ERROR LOG OUTPUT:"
        cat "$AUTOUPGRADE_ERR_LOG"
        echo "An error occurred while running AutoUpgrade $mode. Please check above output for more details. Exiting..."
        exit 1
    fi

    # Extract the summary file from the primary log file. AutoUpgrade can return with a normal exit code while a step or prerequisite
    # check in the patching process failed.
    summary_report_file=$(grep -A3 "Please check the summary report at:" "$log_file" | grep -oE '/[^[:space:]]*status\.log' | head -1)
    if [ -z "$summary_report_file" ] || [ ! -f "$summary_report_file" ]; then
        cat "$log_file"
        echo "ERROR: Could not locate the AutoUpgrade summary report for $ORACLE_SID. Exiting..."
        exit 1
    fi
    # -E: Grep extended regex, allows '|' usage as an OR condition.
    if grep -qE "FAILURE|FAILED" "$summary_report_file"; then
        cat "$summary_report_file"
        echo "ERROR: One or more steps failed while running AutoUpgrade $mode on $ORACLE_SID. Please check above output for more details. Exiting..."
        exit 1
    fi
}

# Process input options
skip_validate_opt=0
while getopts ":hv" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example1"
        exit 0
        ;;
    v)
        skip_validate_opt=1
        ;;
    \?)
        echo "ERROR: Invalid option"
        exit 1
        ;;
    esac
done

shift $((OPTIND-1))

if [ $# -ne 3 ]; then
    echo "ERROR: Wrong number of inputs."
    echo "$usage"
    echo "$example1"
    exit 1
fi

# Get the current location of the bash script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export ORACLE_SID=${1,,}
patch_download_location=$2
target_home=$3

timestamp="$(date "+%Y-%m-%d_%H_%M_%S")"

# Validate that destination oracle_home is valid and get version.
# '2>&1' redirects stderr to stdout so we capture the whole message in the event of an error
sqlplus_version=$("$target_home/bin/sqlplus" -v 2>&1)  
if [ $? -ne 0 ]; then
    echo "$sqlplus_version"
    echo "An error occurred while checking target_home version. Exiting..."
    exit 1
fi

# -o: Only return matching string
# -P: Perl-compatible regex, allows for the usage of \K and \S
# Gets a line that starts with "Version ", reset the captured buffer (\K, removed "Version " from the 
# returned output), and match all the next non-whitespace characters.
version_number=$(echo "$sqlplus_version" | grep -oP "Version \K\S+")
if [ $? -ne 0 ]; then
    echo "$sqlplus_version"
    echo "Could not find version number from sqlplus output. See sqlplus output above. Exiting..."
    exit 1
fi

# We separate logs by ORACLE_SID, version_number, and timestamp to avoid accidentally overwriting log files.
LOG_DIR="/dba/oracle/upgrades/${ORACLE_SID}/${version_number}/${timestamp}"
mkdir -p "$LOG_DIR"
if [ $? -ne 0 ]; then
    echo "Could not create log file destination $LOG_DIR. Exiting..."
    echo "Could not create log file destination $LOG_DIR. Exiting..." | mailx -s "$HOSTNAME - $ORACLE_SID - PatchDB19c.sh Failed to Create Log File Destination" "$ALL_DBA_EMAIL_LIST"
    exit 1
fi

# Configure logging to $LOG_DIR for automated email sending.
LOGFILE="$LOG_DIR/PatchDB19c-Script.log"
source "$HOME/common/general/Logging.sh"
if [ $? -ne 0 ]; then
    echo "An error occurred while sourcing Logging Library from $HOME/common/general/Logging.sh. Exiting..."
    echo "An error occurred while sourcing Logging Library from $HOME/common/general/Logging.sh. Exiting..." | mailx -s "$HOSTNAME - $ORACLE_SID - PatchDB19c.sh Failed to source Logging Library" "$ALL_DBA_EMAIL_LIST"
    exit 1
fi
# Sends everything printed to stdout and stderr to a logfile as well as the terminal.
set_general_logging "$LOGFILE"
if [ $? -ne 0 ]; then
    echo "An error occurred while setting general logging file to $LOGFILE. Exiting..."
    echo "An error occurred while setting general logging file to $LOGFILE. Exiting..." | mailx -s "$HOSTNAME - $ORACLE_SID - PatchDB19c.sh Failed to Set General Logging" "$ALL_DBA_EMAIL_LIST"
    exit 1
fi

# Setup trap to send an email whenever the script exits for any reason.
exit_handler(){
    if [[ $? -ne 0 ]]; then
        echo "PatchDB19c.sh Failed... Sending email to $ALL_DBA_EMAIL_LIST."
        close_logs
        mailx -s "$HOSTNAME - $ORACLE_SID - PatchDB19c.sh Failed" "$ALL_DBA_EMAIL_LIST" < "$LOGFILE"
        exit 1
    else
        echo "PatchDB19c.sh ran successfully... Sending email to $ALL_DBA_EMAIL_LIST."
        close_logs
        mailx -s "$HOSTNAME - $ORACLE_SID - PatchDB19c.sh Ran Successfully" "$ALL_DBA_EMAIL_LIST" < "$LOGFILE"
        exit 0
    fi
}
trap 'exit 1' INT TERM   # route signals through a single non-zero EXIT
trap exit_handler EXIT

# Default to finding the java binary in the target_home installation. If it does not exist/is not executable,
# find the one in the path. Fail if none is found.
JAVA_BIN="$target_home/jdk/bin/java"
if [ ! -x "$JAVA_BIN" ]; then
    JAVA_BIN="$(command -v java)"
fi
if [ -z "$JAVA_BIN" ]; then
    echo "ERROR: java not found (checked $target_home/jdk/bin/java and PATH). Exiting..."
    exit 1
fi

AUTOUPGRADE_JAR="$SCRIPT_DIR/autoupgrade.jar"
# Check that the autoupgrade jar file exists.
if [ ! -f "$AUTOUPGRADE_JAR" ]; then
    echo "ERROR: AutoUpgrade binary ($AUTOUPGRADE_JAR) not found, please download using:"
    echo "          wget -O $AUTOUPGRADE_JAR https://download.oracle.com/otn-pub/otn_software/autoupgrade.jar"
    echo "Exiting..."
    exit 1
fi


# Finds the ORACLE_HOME of a database and determines if it is online.
get_db_version=$("$HOME/common/oracle/GetOracleDBVersion.sh" "$ORACLE_SID")
if [ $? -ne 0 ]; then
    echo "$get_db_version"
    echo "An error occurred while getting Oracle Database Version. Exiting..."
    exit 1
fi

# Extracts the ORACLE_HOME path from the script output.
# Grep flags:
# -o: Only return matching string
# -P: Use perl-compatible syntax required for \K
# The pattern finds the line starting with `ORACLE_HOME=` (^ORACLE_HOME=), resets the start point of the match (\K)
# and matches the rest of the line (.*)
db_oracle_home=$(echo "$get_db_version" | grep -oP '^ORACLE_HOME=\K.*')
if [ $? -ne 0 ]; then
    echo "$get_db_version"
    echo "ERROR: Failed to extract ORACLE_HOME from results of GetOracleDBVersion.sh. Exiting..."
    exit 1
fi

export ORACLE_HOME=$db_oracle_home
source_home=$db_oracle_home

# Check that the source and destination ORACLE_HOMEs, patch download location, and ORACLE_BASE all exist.
for dir_path in "$source_home" "$target_home" "$patch_download_location" "$ORACLE_BASE"; do
    if [ ! -d "$dir_path" ]; then
        echo "ERROR: Required directory '$dir_path' does not exist. Exiting..."  
        exit 1
    fi
done

if [ "$skip_validate_opt" -ne 1 ]; then
    # Check for invalid indexes
    # Use full path for DisplayInvalidIndexes.sh, this script is duplicated between oracle and postgres.
    invalid_indexes=$("$HOME/common/oracle/DisplayInvalidIndexes.sh" "$ORACLE_SID")
    if [ $? -ne 0 ]; then
        echo "$invalid_indexes"
        echo "An error occurred while displaying invalid indexes. Exiting..."
        exit 1
    # Check that DisplayInvalidIndexes.sh returned no rows.
    # -i: Case-insensitive grep.
    elif ! echo "$invalid_indexes" | grep -qi "no rows selected"; then
        echo "$invalid_indexes"
        echo "ERROR: One or more indexes on database $ORACLE_SID is invalid, this may interfere with the patch operation. Exiting..."
        exit 1
    fi

    # Recompile all objects before patch
    recompile_objects=$("$HOME/common/oracle/RecompileAllObjects.sh" "$ORACLE_SID")
    if [ $? -ne 0 ]; then
        echo "$recompile_objects"
        echo "An error occurred while recompiling all objects. Exiting..."
        exit 1
    # Check that RecompileAllObjects.sh's final query returned no rows. 
    # -i: Case-insensitive grep.
    elif ! echo "$recompile_objects" | grep -qi "no rows selected"; then
        echo "$recompile_objects"
        echo "ERROR: Invalid objects present in database after package recompile, this may interfere with the patch operation. Exiting..."
        exit 1
    fi
fi

echo "Target database is using ORACLE_HOME=$source_home, using as source_home."

# Create AutoUpgrade patch config.
autoupgrade_cfg="$LOG_DIR/AutoUpgrade-Patch-19c.cfg"

echo "Writing AutoUpgrade config to $autoupgrade_cfg."

# Create an AutoUpgrade config for the database.
cat << EOD > "$autoupgrade_cfg"
global.global_log_dir=$ORACLE_BASE/patching/$ORACLE_SID/$timestamp/
global.keystore=$ORACLE_BASE/keystore

# This flag tells AutoUpgrade to generate a GRP (Guaranteed Restore Point) and to attempt to rollback on failure.
# Note: To avoid the chance of a rollback failure, Oracle recommends that you back up your database before patching.
global.restoration=yes

patch1.sid=$ORACLE_SID
patch1.source_home=$source_home
patch1.target_home=$target_home
patch1.folder=$patch_download_location
EOD
if [ $? -ne 0 ]; then
    echo "An error occurred while writing AutoUpgrade config to $autoupgrade_cfg. Exiting..."
    exit 1
fi

# We run AutoUpgrade analyze to ensure that all the prerequisite checks have passed before we attempt to deploy
run_autoupgrade analyze "$LOG_DIR/Patch-19c-AutoUpgrade-Analyze.log" "Running AutoUpgrade Analyze to check for issues requiring manual intervention..."

# Once checks have been completed, perform deploy
run_autoupgrade deploy "$LOG_DIR/Patch-19c-AutoUpgrade-Deploy.log" "Running AutoUpgrade Deploy to patch database..."

echo "Successfully patched database $ORACLE_SID. Exiting..."