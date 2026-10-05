#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script creates a new blank 19c database from scratch, as opposed to our usual approach of cloning a pre-existing database.
#
# Note: The database created is a NON-CDB. It is also created WITHOUT the default database components,
#       so features that rely on them (Oracle Text, for one) are absent unless installed explicitly.
#       -t installs Oracle Text, which is required if the database will use JSON indexes.
#       -p installs the SQLPlus Product Profile table (SYSTEM.PRODUCT_USER_PROFILE). That table only
#       matters to legacy sqlplus clients, which read it to block commands per-user; nothing we run
#       depends on it, so -p is normally unnecessary.
#
# Note: While dbca can be used to create a database, it defaults to using OMF (Oracle Managed Files) and installs all database components
#        by default, and requires non-trivial configuration to prevent. As such, this script simply uses the requisite SQL directly.
#
#####################################################################################
usage="Usage: Create19cDatabase.sh [ -p (Install the Oracle profile table, used in legacy versions of sqlplus to allow for client-side blocking of commands) ] [ -t (Install the Oracle Text component, required if using JSON indexes) ] [ORACLE_SID] [base_restore_dir] [db_sys_password] [db_system_password]"
example="Example: Create19cDatabase.sh mydb1 /export/home/oracle/ pwd123# pwd123#"
text_install=0
profile_install=0
# Process input options
while getopts ":hpt" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    p)
        profile_install=1
        ;;
    t)
        text_install=1
        ;;
    \?)
        echo "Error: Invalid option -$OPTARG"
        exit 1
        ;;
    esac
done

shift "$((OPTIND - 1))"

# Check arguments
if [ $# -ne 4 ]; then
    echo "Invalid number of arguments, Create19cDatabase.sh requires 4 arguments"
    echo "$usage"
    echo "$example"
    exit 1
fi

if [ -f "$HOME/.bashrc" ]; then
    source "$HOME/.bashrc"
fi

if [ -z "$ORACLE_BACKUP_DIR" ]; then
    echo "\$ORACLE_BACKUP_DIR is not set. It is expected to come from .bashrc."
    echo "Check .bashrc: $HOME/.bashrc"
    echo "Exiting..."
    exit 1
fi

export ORACLE_SID=${1,,}
# Base directory to create DB in, not including SID-derived prefix.
base_restore_dir=$2
# This will be the password for the SYS schemas
db_sys_password=$3
# This will be the password for the SYSTEM schemas
db_system_password=$4

if [ -z "$ORACLE_SID" ]; then
    echo "ORACLE_SID is not set"
    echo "Check first parameter"
    echo "Exiting..."
    exit 1
fi

# Print how to finish a database whose core creation succeeded but whose optional component
# install failed. The trap shuts the instance down, but the datafiles are intact, so the operator
# can complete it by hand instead of rebuilding - catpcat.sql alone is several minutes.
# Arguments:
#   $1 - the sqlplus commands needed to install the component that failed
print_recovery_steps()
{
    echo
    echo "The database itself was created successfully and its datafiles are intact."
    echo "The instance has been shut down. To finish it without rebuilding:"
    echo
    echo "  export ORACLE_SID=$ORACLE_SID"
    echo "  \$HOME/common/oracle/startup_oracle.sh $ORACLE_SID"
    echo "  sqlplus / as sysdba"
    echo "$1"
    echo "  \$HOME/common/oracle/RecompileAllObjects.sh $ORACLE_SID"
    echo
    echo "The drop errors above (ORA-04043, ORA-01432, ORA-00942) are expected on a fresh database."
    echo "To start over instead, remove $restore_directory and re-run this script."
    echo
}

# This script creates a 19c database specifically - the CREATE DATABASE block, the initXXXX.ora
# template and catpcat.sql all assume it. Fail early if $ORACLE_HOME points somewhere else, which is
# easy to do on a server hosting more than one Oracle version. Matching "Release 19." rather than
# bare "19" so a path or a date in the banner cannot satisfy it.
sqlplus_version=$("$ORACLE_HOME/bin/sqlplus" -v 2>&1)
if ! [[ "$sqlplus_version" =~ Release[[:space:]]+19\. ]]; then
    echo "$sqlplus_version"
    echo "Error: \$ORACLE_HOME does not appear to be a 19c home ($ORACLE_HOME)."
    echo "Exiting..."
    exit 1
fi

db_status=$("$HOME/common/oracle/CheckDatabaseOpenStatus.sh" "$ORACLE_SID")
if [ $? -ne 0 ]; then
    echo "$db_status"
    echo "Error occurred while checking if database $ORACLE_SID already exists. Exiting..."
    exit 1
fi
if [ "$db_status" != "CLOSED" ]; then
    echo "Error: \$ORACLE_SID $ORACLE_SID is already running (status=$db_status). Exiting..."
    exit 1
fi

if [[ "$base_restore_dir" != /* ]]; then
    echo "Error: base_restore_dir must be an absolute path."
    echo "Exiting..."
    exit 1
fi
if [ ${#ORACLE_SID} -gt 8 ]; then
    echo "\$ORACLE_SID is longer than 8 characters."
    echo "Please choose an ORACLE_SID that does not exceed 8 characters."
    echo "Exiting..."
    exit 1
fi

db_dir_name=$ORACLE_SID
# Replace any instance of d19 with dev or p19 with prod in $db_dir_name
db_dir_name=$(echo "$db_dir_name" | sed "s/d19/dev/g")
db_dir_name=$(echo "$db_dir_name" | sed "s/p19/prod/g")

restore_directory=$(echo "$base_restore_dir/$db_dir_name" | sed 's#//#/#g')

if [ -d "$restore_directory" ]; then
    # ls -A lists entries including dotfiles but excluding . and .. , so this is
    # "is the directory non-empty" rather than "does it contain visible files".
    if [ -n "$(ls -A "$restore_directory")" ]; then
        echo "Error: restore directory ($restore_directory) is not empty"
        echo "Exiting..."
        exit 1
    fi
fi

# Create restore directory data directory
mkdir -p "$restore_directory/data"
if [ $? -ne 0 ]; then
    echo "Error: Failed to create directory: $restore_directory/data"
    exit 1
fi

# Make logging directory. catpcat.sql writes its per-step logs here.
log_directory="/tmp/db_populate_$ORACLE_SID"
mkdir -p "$log_directory"
if [ $? -ne 0 ]; then
    echo "Error: Failed to create directory: $log_directory"
    exit 1
fi

# Tee everything from here on to a log beside the catpcat output. This run takes several minutes,
# and without this the only record of it is the terminal - a dropped connection loses the entire
# diagnostic trail even though the database itself was created fine.
script_log="$log_directory/Create19cDatabase.log"
exec > >(tee -a "$script_log") 2>&1
echo "Logging this run to $script_log"

# Build the pfile. UpdateInitTemplateFile.sh copies initXXXX.ora into
# $ORACLE_HOME/dbs/init<sid>.ora itself (:100) and backs up any existing one first (:85-91),
# and CreateSpfileFromPfile.sh renames an existing spfile before writing a new one (:117),
# so neither the copy nor the spfile rename needs doing here.
echo "Updating init file..."
update_pfile=$("$HOME/common/oracle/UpdateInitTemplateFile.sh" "$ORACLE_SID" "$ORACLE_BACKUP_DIR" "$restore_directory")
if [ $? -ne 0 ]; then
    echo "$update_pfile"
    echo "An error occurred while updating pfile of $ORACLE_SID. Exiting..."
    exit 1
fi

# Startup the target DB in nomount mode
nomount_status=$("$HOME/common/oracle/StartupOracleNoMount.sh" "$ORACLE_SID" "$ORACLE_HOME/dbs/init$ORACLE_SID.ora")
if [ $? -ne 0 ]; then
    echo "Error occurred while starting up the target DB in nomount mode"
    echo "$nomount_status"
    exit 1
else
    echo "$ORACLE_SID database successfully started in nomount mode"
fi

# From here on an instance is running. Every failure path below exits without shutting it down,
# which leaves the SID in NOMOUNT - and the CheckDatabaseOpenStatus.sh guard near the top of this
# script, plus StartupOracleNoMount.sh:86, then both refuse to run again for that SID until someone
# shuts it down by hand. Shut it down on any non-zero exit so a failed attempt can simply be retried.
# The datafiles are deliberately left in place for inspection.
trap 'trap_status=$?; if [ $trap_status -ne 0 ]; then
        echo "Creation failed; shutting down the $ORACLE_SID instance so the attempt can be retried."
        "$HOME/common/oracle/shutdown_oracle.sh" "$ORACLE_SID" abort >/dev/null 2>&1
      fi' EXIT INT TERM HUP

# Create spfile from pfile
echo "Creating spfile from pfile init${ORACLE_SID}.ora..."
create_spfile=$("$HOME/common/oracle/CreateSpfileFromPfile.sh" "$ORACLE_HOME/dbs/init${ORACLE_SID}.ora")
if [ $? -ne 0 ]; then
    echo "$create_spfile"
    echo "Error occurred while running CreateSpfileFromPfile.sh. Exiting..."
    exit 1
fi

db_framework=$(
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    SET DEFINE OFF
    CREATE DATABASE $ORACLE_SID
    USER SYS IDENTIFIED BY "$db_sys_password"
    USER SYSTEM IDENTIFIED BY "$db_system_password"
    CHARACTER SET AL32UTF8
    NATIONAL CHARACTER SET AL16UTF16
    -- These are the only 2 Controlfile parameters that matter for us, the rest are either for RAC deployments
    -- or automatically adjust as needed.
    -- MAXLOGFILES: Maximum # of log files the database can have, determines how much space the Controlfile allocates for filenames
    -- MAXLOGMEMBERS: Maximum # of log file members (copies) the database can have, determines how much space the Controlfile allocates for filenames.
    -- These match the values on our existing databases. They only size the controlfile's
    -- filename space, so they are cheap to set generously and awkward to raise later.
    MAXLOGFILES 16
    MAXLOGMEMBERS 3
    -- Determines the filename structure for redo logs and default starting size. SIZE and BLOCKSIZE were pulled from mydb1 Controlfile
    -- Each filename per log group is a redundant copy of the redo log.
    LOGFILE 
        GROUP 1 (
            '$restore_directory/redo1a.log',
            '$restore_directory/redo1b.log'
        ) SIZE 200M,
        GROUP 2 (
            '$restore_directory/redo2a.log',
            '$restore_directory/redo2b.log'
        ) SIZE 200M,
        GROUP 3 (
            '$restore_directory/redo3a.log',
            '$restore_directory/redo3b.log'
        ) SIZE 200M
    -- Tells Oracle to create a locally managed SYSTEM tablespace, as opposed to dictionary-managed. This is currently set on 
    -- our DBs, so it is mirrored here.
    EXTENT MANAGEMENT LOCAL
    -- Specifies datafile name for the SYSTEM tablespace.
    DATAFILE '$restore_directory/data/system_01.dbf' SIZE 500M AUTOEXTEND ON NEXT 10240K MAXSIZE UNLIMITED
    -- Specifies datafile name for the SYSAUX tablespace.
    SYSAUX DATAFILE '$restore_directory/data/sysaux_01.dbf' SIZE 500M AUTOEXTEND ON NEXT 10240K MAXSIZE UNLIMITED
    -- Specifies the datafile name for the USERS tablespace
    DEFAULT TABLESPACE USERS
        DATAFILE '$restore_directory/data/users_01.dbf' SIZE 20M AUTOEXTEND ON NEXT 10240K MAXSIZE UNLIMITED
    -- Specifies the datafile name for the TEMP tablespace
    DEFAULT TEMPORARY TABLESPACE TEMP
        TEMPFILE '$restore_directory/temp_01.dbf' SIZE 20M AUTOEXTEND ON NEXT 640K MAXSIZE UNLIMITED
    -- Specifies the name and datafile path for the UNDO tablespace.
    UNDO TABLESPACE UNDOTBS1
        DATAFILE '$restore_directory/undo_01.dbf' SIZE 200M AUTOEXTEND ON NEXT 5120K MAXSIZE UNLIMITED;
EOD
)

# Check for SQL errors
if [ $? -ne 0 ]; then
    echo "An error occurred while creating required database components."
    echo "$db_framework"
    echo "Exiting..."
    exit 1
fi

# Perl and sqlplus are assumed to be installed because they are all part of Oracle software install
# 2>&1 so catctl.pl's progress output is captured rather than flooding the terminal; it is
# echoed below only if the run fails. Per-step logs are written under $log_directory regardless.
data_dictionary=$("$ORACLE_HOME/perl/bin/perl" "$ORACLE_HOME/rdbms/admin/catctl.pl" -d "$ORACLE_HOME/rdbms/admin" -n 4 -l "$log_directory" catpcat.sql 2>&1)
if [ $? -ne 0 ]; then 
    echo "Error: failed to run catpcat.sql"
    echo "See log files for more details: $log_directory"
    echo "$data_dictionary"
    echo "Exiting..."
    exit 1
fi
# The cleanup trap stays armed through the optional component installs. Conrad suggested disarming
# it here so a failed Oracle Text or product-profile install would leave the built database up,
# since catpcat.sql is the expensive part of the run. Brian's call is to keep cleaning up: a run that
# exits non-zero should not leave an instance running. Datafiles are still left in place, so a failed
# attempt can be inspected before the restore directory is cleared and the run retried.
if [ "$text_install" -eq 1 ]; then

    # No `whenever sqlerror exit 1` here: catctx.sql emits "Failed to drop ..." errors on a fresh
    # database, where the objects it tries to drop do not exist yet. Aborting on those made -t fail
    # every time. Real failures are caught by the end-state check after this block.
    #
    # catctx.sql takes <password> <tablespace> <temp tablespace> <lock flag>. The password argument
    # is unused - the CTXSYS account is created locked - but it is positional, so it must be present
    # or every later argument shifts left. That shift is what produced
    # "ORA-12910: cannot specify temporary tablespace as default tablespace".
    oracle_text=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1

        @$ORACLE_HOME/ctx/admin/catctx.sql UNUSED SYSAUX TEMP NOLOCK;
        show errors
        -- Configure for US English text
        @$ORACLE_HOME/ctx/admin/defaults/drdefus.sql;
        show errors

        exit 0;
EOD
        )
    # Do not scan the output for "ORA-". catctx.sql drops objects that do not exist yet on a fresh
    # database, so it legitimately emits ORA-04043 (object does not exist), ORA-01432 (public
    # synonym to be dropped does not exist) and similar. There is no reliable list of benign codes
    # to exclude, so check the end state instead: CTXSYS must exist and own the CONTEXT indextype,
    # which is the thing an Oracle Text install exists to produce.
    # Deliberately not asserting "no invalid CTXSYS objects" - RecompileAllObjects.sh runs later in
    # this script, so objects may still be invalid at this point.
    text_check=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        set heading off
        set feedback off
        set pagesize 0

        SELECT (SELECT COUNT(*) FROM dba_users WHERE username = 'CTXSYS')
               || '|' ||
               (SELECT COUNT(*) FROM dba_indextypes WHERE owner = 'CTXSYS' AND indextype_name = 'CONTEXT')
        FROM dual;
        exit;
EOD
    )
    if [ $? -ne 0 ]; then
        echo "$text_check"
        echo "Error: Failed to verify the Oracle Text installation. Exiting..."
        exit 1
    fi
    ctxsys_present=$(echo "$text_check" | tr -d '[:space:]' | cut -d'|' -f1)
    context_indextype=$(echo "$text_check" | tr -d '[:space:]' | cut -d'|' -f2)
    if [ "$ctxsys_present" != "1" ] || [ "$context_indextype" != "1" ]; then
        echo "$oracle_text"
        echo "Error: Failed to install Oracle Text (CTXSYS present=$ctxsys_present, CONTEXT indextype=$context_indextype)."
        print_recovery_steps "    @?/ctx/admin/catctx.sql UNUSED SYSAUX TEMP NOLOCK
    @?/ctx/admin/defaults/drdefus.sql"
        echo "Exiting..."
        exit 1
    fi
    echo "Oracle Text installed."
fi
if [ $profile_install -eq 1 ]; then

    # Same as Oracle Text above: pupbld.sql drops objects that do not exist on a fresh database,
    # so `whenever sqlerror exit 1` would abort on benign errors. Real failures are caught by the
    # end-state check after this block.
    profile_table=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1

        ALTER SESSION SET CURRENT_SCHEMA=SYSTEM;
        @?/sqlplus/admin/pupbld.sql;

        exit 0;
EOD
        )
    # Same reasoning as Oracle Text above: pupbld.sql drops objects that do not exist on a fresh
    # database, so verify the end state rather than scanning for ORA- codes.
    # pupbld.sql creates a view (PRODUCT_PRIVS) and synonyms, with the profile itself living in
    # SQLPLUS_PRODUCT_PROFILE - PRODUCT_USER_PROFILE is a synonym for it, not a table, so do not
    # look for it in dba_tables. Query dba_objects without asserting an object type or owner, and
    # report both counts so a failure says which half is missing.
    pup_check=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        set heading off
        set feedback off
        set pagesize 0

        SELECT (SELECT COUNT(*) FROM dba_objects
                 WHERE object_name = 'PRODUCT_PRIVS' AND object_type = 'VIEW')
               || '|' ||
               (SELECT COUNT(*) FROM dba_objects
                 WHERE object_name IN ('SQLPLUS_PRODUCT_PROFILE', 'PRODUCT_USER_PROFILE'))
        FROM dual;
        exit;
EOD
    )
    if [ $? -ne 0 ]; then
        echo "$pup_check"
        echo "Error: Failed to verify the SQLPlus Product Profile table. Exiting..."
        exit 1
    fi
    pup_view=$(echo "$pup_check" | tr -d '[:space:]' | cut -d'|' -f1)
    pup_profile=$(echo "$pup_check" | tr -d '[:space:]' | cut -d'|' -f2)
    if [ "${pup_view:-0}" -lt 1 ] || [ "${pup_profile:-0}" -lt 1 ]; then
        echo "$profile_table"
        echo "Error: Failed to create SQLPlus Product Profile table (PRODUCT_PRIVS view=$pup_view, profile objects=$pup_profile)."
        echo "Objects matching PRODUCT% currently present:"
        "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
            set heading off
            set feedback off
            set pagesize 0
            SELECT owner || '.' || object_name || ' (' || object_type || ')'
            FROM dba_objects WHERE object_name LIKE 'PRODUCT%' OR object_name LIKE 'SQLPLUS%';
            exit;
EOD
        print_recovery_steps "    ALTER SESSION SET CURRENT_SCHEMA=SYSTEM;
    @?/sqlplus/admin/pupbld.sql"
        echo "Exiting..."
        exit 1
    fi
    echo "SQLPlus Product Profile table created."
fi

echo "Recompiling all objects..."
recompile=$("$HOME/common/oracle/RecompileAllObjects.sh" "$ORACLE_SID")
if [ $? -ne 0 ]; then
    echo "$recompile"
    echo "An error occurred while recompiling all objects. Exiting..."
    exit 1
fi
echo "Objects recompiled successfully!"
echo
echo "Successfully created database $ORACLE_SID in $restore_directory."
exit 0