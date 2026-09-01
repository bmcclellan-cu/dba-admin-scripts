#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: To dynamically create RMAN scripts, that can be used to 
#          restore/recover the database at a later time.
# 
# Notes:   All read-write datafiles for a database are expected to be located under a directory
#          named /${database_name}/, and we strip out the entire path up to that point for these
#          files.
#
#########################################################################

usage="Usage: RMANCreateRestoreDynamicScripts.sh [\$ORACLE_SID | ALL] [output directory (optional)]"
example1="Example: RMANCreateRestoreDynamicScripts.sh ALL PATH/TO/BACKUP/SCRIPTS/DIR"
example2="Example: RMANCreateRestoreDynamicScripts.sh ALL"

# Process input options
while getopts ":h" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example1"
        echo "$example2"
        exit 0
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "$usage"
    echo "$example1"
    echo "$example2"
    exit 1
fi

# Check and set SIDs variable
if [ "${1^^}" == "ALL" ]; then
    sids=$("$HOME/common/oracle/VerifyAllParam.sh" -V "ALL")
    if [ $? -ne 0 ]; then
        echo "$sids"
        echo "Error, VerifyAllParam.sh failed for ALL input. Exiting..."
        exit 1
    fi
else
    sids="${1}"
    # Check oracle sid
    sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I "$sids")
    if [ $? -ne 0 ]; then
        echo "$sid_check"
        echo "Error, VerifyAllParam.sh failed while validating SID $sids. Exiting..."
        exit 1
    fi
    if [ -n "$sid_check" ]; then
        if [ "$sid_check" == "-1" ]; then
            echo "Error, \$ORACLE_SID not set..."
            exit 1
        fi
        echo "Error, database $sids is not open"
        exit 1
    fi
fi

if [ -z "$2" ]; then
    echo "Outputting scripts to current directory..."
    output_dir_root=$(pwd)
elif [ -d "$2" ]; then
        output_dir_root="$2"
else
    echo "Error, output directory $2 is not valid. Attempting to create directory..."
    mkdir_check=$(mkdir "$2" 2>&1)
    if [ -n "$mkdir_check" ]; then
        echo "Error. Unable to create directory $2. Exiting..."
        exit 1
    fi

    echo "Directory $2 successfully created. Continuing...."
    output_dir_root="$2"
fi

# If provided output directory does not end with a "/", add one
if [ "${output_dir_root: -1}" != "/" ]; then
    output_dir_root+="/"
fi

# Loop through each applicable SID
exit_status=0
for sid in $sids; do
    # Check oracle sid
    sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I "$sid")
    if [ $? -ne 0 ]; then
        echo "$sid_check"
        echo "Error, VerifyAllParam.sh failed while validating SID $sid. Skipping database ${sid}..."
        exit_status=1
        continue
    fi
    if [ -n "$sid_check" ]; then
        echo "Error, database $sid is not open. Skipping database ${sid}..."
        continue
    fi

    #Set the ORACLE_SID so the scripts are generated against the correct DB
    export ORACLE_SID="$sid"
    UPPERCASE_SID=$(echo "$sid" | tr "[:lower:]" "[:upper:]")

    # Set output_dir if 1 argument is given.
    if [ $# -eq 1 ]; then
        recovery_file_dest=$("$HOME/common/oracle/PrintParamDBrecoveryFileDest.sh" "$ORACLE_SID")
        if [ $? -ne 0 ]; then
            echo "Error: Error occurred while executing helper script PrintParamDBrecoveryFileDest.sh. Skipping database $ORACLE_SID..."
            exit_status=1
            continue
        fi
        
        # Create directory and parent directories if nonexistent (no error if existing)
        # The trailing /${UPPERCASE_SID} matches the layout the restore flow looks for,
        # and keeps this default consistent with the two-argument form below.
        output_dir="${recovery_file_dest}/${UPPERCASE_SID}/scripts/${UPPERCASE_SID}"
        mkdir -p "$output_dir"
    else
        output_dir="${output_dir_root}${UPPERCASE_SID}/"
        mkdir -p "$output_dir"
    fi

    # Error check for above mkdir statements
    if [ $? -ne 0 ]; then
        echo "Error: Error occurred while creating output directory $output_dir. Skipping database $ORACLE_SID..."
        exit_status=1
        continue
    fi

    echo "Writing restore scripts for ${ORACLE_SID} to directory ${output_dir}."
    
    # Substitute d19 -> dev and p19 -> prod.
    # This is done to ensure a consistent directory name for our database
    # Ex.: sid1d19 -> sid1dev
    database_name="${ORACLE_SID,,}"
    database_name=$(echo "$database_name" | sed "s/d19\$/dev/")
    database_name=$(echo "$database_name" | sed "s/p19\$/prod/")

    creation_date=$(date "+%Y-%m-%d_%H_%M")

    # Create the script that will create the directory structure
    # and all subdirectories
    # SUBSTR (NAME, INSTR (NAME, '/${database_name}/', -1)+1, INSTR (NAME, '/', -1) - INSTR (NAME, '/${database_name}/', -1))
    #
    # Syntax: SUBSTR('string', start_position, number of bytes to read)
    #
    # INSTR (NAME, '/${database_name}/', -1) -> searching backward from the end (-1), find the position of the first '/${database_name}/' segment
    # start_position => INSTR (NAME, '/${database_name}/', -1)+1
    # +1 removes double (//) slash by starting 1 character after INSTR (NAME, '/${database_name}/', -1)
    #
    # Number of bytes to read => INSTR (NAME, '/', -1) - INSTR (NAME, '/${database_name}/', -1)
    # Start at the last '/' before the file name (.dbf) and subtract from where the location of /${database_name}/ is
    gen_output=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    set head off pages 0 feed off echo off verify off
    set linesize 1000
    whenever sqlerror exit 1
    whenever oserror exit 1
    spool RMANCreateDirStructure.sh
    select '#!/bin/bash' from dual;
    select '# Created on: ${creation_date}' from dual;
    select '' from dual;
    select '# NOTE: This should be run to generate the subdirectories for the datafile restore' from dual;
    select '' from dual;
    select '# Check arguments' from dual;
    select 'if [ \$# -ne 1 ] ; then' from dual;
    select ' echo "Input directory required!"' from dual;
    select ' exit 1' from dual;
    select 'elif [ ! -d \$1 ]; then' from dual;
    select ' echo "Directory \$1 does not exist"' from dual;
    select ' exit 1' from dual;
    select 'fi' from dual;
    select '' from dual;
    select 'echo "RMANCreateDirStructure.sh script started at: \$(date +%Y-%m-%d_%H_%M)"' from dual;
    select '' from dual;
    select '# Create the directory structure from the current ORACLE_SID' from dual;
    select distinct 'mkdir -p \${1}/' || SUBSTR (NAME, INSTR (NAME, '/${database_name}/', -1)+1, INSTR (NAME, '/', -1) - INSTR (NAME, '/${database_name}/', -1) ) as directory
        from v\$datafile
        order by 1;
    exit;
EOD
    )
    # We are spooling script in subshell and assigning output to $gen_output to suppress output to stdout.
    # Additionally, by having this exit status check, we have more control on how to alert the user.
    if [ $? -ne 0 ]; then
        echo "$gen_output"
        echo "Error, sqlplus failed while generating RMANCreateDirStructure.sh for ${ORACLE_SID}."
        rm -f RMANCreateDirStructure.sh
        exit_status=1
    fi

    # Create the script that will only restore all datafiles.
    # If read-only datafiles are present in the RMAN backups,
    # they can be restored but not recovered and rolled forward.
    # The script should only be run if all tablespace datafiles,
    # including read-only tablespaces, are available for restore.
    #
    # SUBSTR (NAME, INSTR (NAME, '/${database_name}/', -1))
    #
    # Syntax: SUBSTR('string', start_position, number of bytes to read)
    #
    # INSTR (NAME, '/${database_name}/', -1) -> searching backward from the end (-1), find the position of the first '/${database_name}/' segment
    # SUBSTR (NAME, INSTR (NAME, '/${database_name}/', -1)) -> return everything from that position (the leading '/' of /${database_name}/) to the end of NAME, dropping everything before /${database_name}/
    gen_output=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    set head off pages 0 feed off echo off verify off
    set linesize 1000
    whenever sqlerror exit 1
    whenever oserror exit 1
    spool RMANRestoreAllDatafiles.sh
    select '#!/bin/bash' from dual;
    select '# Created on: ${creation_date}' from dual;
    select '' from dual;
    select '# NOTE: This script should only be run if all datafiles are available for restore.' from dual;
    select '' from dual;
    select '# Check arguments' from dual;
    select 'if [ \$# -ne 1 ] ; then' from dual;
    select ' echo "Input directory required!"' from dual;
    select ' exit 1' from dual;
    select 'elif [ ! -d \$1 ]; then' from dual;
    select ' echo "Directory \$1 does not exist"' from dual;
    select ' exit 1' from dual;
    select 'fi' from dual;
    select '' from dual;
    select 'echo "RMANRestoreAllDatafiles.sh script started at: \$(date +%Y-%m-%d_%H_%M)"' from dual;
    select '' from dual;
    select '# Run RMAN to set read-write tablespace datafiles and copy redo logs into the new directory' from dual;
    select 'rman LOG "/tmp/rman_\${ORACLE_SID}_RMANRestoreAllDatafiles_\$(date +%Y-%m-%d_%H_%M).txt" <<EOD' from dual;
    select 'connect target /' from dual;
    select 'run {' from dual;
    select 'allocate channel ch1 type disk;' from dual;
    select 'allocate channel ch2 type disk;' from dual;
    select 'allocate channel ch3 type disk;' from dual;
    select 'allocate channel ch4 type disk;' from dual;
    select 'set newname for datafile '||file#||' to  ''\${1}'|| SUBSTR (NAME, INSTR (NAME, '/${database_name}/', -1))||''';'
        from v\$datafile
        order by file#;
    select 'restore database;' from dual;
    select 'switch datafile all;' from dual;

    select '}' from dual;
    select 'exit;' from dual;

    set linesize 3
    select 'EOD' from dual;
    set linesize 1000
    exit;
EOD
    )
    # We are spooling script in subshell and assigning output to $gen_output to suppress output to stdout.
    # Additionally, by having this exit status check, we have more control on how to alert the user. 
    if [ $? -ne 0 ]; then
        echo "$gen_output"
        echo "Error, sqlplus failed while generating RMANRestoreAllDatafiles.sh for ${ORACLE_SID}."
        rm -f RMANRestoreAllDatafiles.sh
        exit_status=1
    fi

    # Create the script that will copy all read only data files
    # to a backup directory.
    #
    # Syntax: SUBSTR('string', start_position, number of bytes to read)
    #
    # Source: SUBSTR (NAME, INSTR (NAME, '/', 2))
    # INSTR (NAME, '/', 2) -> starting the search at character 2, find the position of the first '/' (the slash after the top-level directory)
    # SUBSTR (NAME, INSTR (NAME, '/', 2)) -> return everything from that slash to the end of NAME, dropping only the first directory component
    # 
    # Destination: SUBSTR (NAME, INSTR (NAME, '/${database_name}/', -1))
    # INSTR (NAME, '/${database_name}/', -1) -> searching backward from the end (-1), find the position of the first '/${database_name}/' segment
    # SUBSTR (NAME, INSTR (NAME, '/${database_name}/', -1)) -> return everything from that position (the leading '/' of /${database_name}/) to the end of NAME, dropping everything before /${database_name}/
    gen_output=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    set head off pages 0 feed off echo off verify off
    set linesize 1000
    whenever sqlerror exit 1
    whenever oserror exit 1
    spool RMANCopyREADonlyDatafiles.sh
    select '#!/bin/bash' from dual;
    select '# Created on: ${creation_date}' from dual;
    select '# Note: the cp commands from this script are not complete.' from dual;
    select '' from dual;
    select '# Check arguments' from dual;
    select 'if [ \$# -ne 2 ] ; then' from dual;
    select ' echo "Error, user must enter source and destination directory!"' from dual;
    select ' exit 1' from dual;
    select 'fi' from dual;
    select '' from dual;
    select '# remove trailing slashes since these will be present in the variable "datafiles"' from dual;
    select 'source=\$(echo \$1 | sed "s#/\\\$##g")' from dual;
    select 'destination=\$(echo \$2 | sed "s#/\\\$##g")' from dual;
    select '' from dual;
    select 'if [ ! -d \$source ]; then' from dual;
    select '   echo "Error, source directory not found. Exiting..."' from dual;
    select '   exit 1' from dual;
    select 'fi' from dual;
    select '' from dual;
    select 'if [ ! -d \$destination ]; then' from dual;
    select '   echo "Error, destination directory not found. Exiting..."' from dual;
    select '   exit 1' from dual;
    select 'fi' from dual;
    select '' from dual;
    select 'echo "RMANCopyREADonlyDatafiles.sh script started at: \$(date +%Y-%m-%d_%H_%M)"' from dual;
    select '' from dual;
    select 'datafiles="' from dual;
    select 'cp -pr ' || '''\$source'|| SUBSTR (NAME, INSTR (NAME, '/', 2))||'' || ''' ''\$destination'|| SUBSTR (NAME, INSTR (NAME, '/${database_name}/', -1))||''''
        from v\$datafile
        where enabled = 'READ ONLY'
        order by NAME;
    select '"' from dual;
    select '' from dual;
    select 'echo "\$datafiles" | tee /tmp/$sid/RMANCopyREADonlyDatafilesRUN.sh' from dual;
    select '' from dual;

    set linesize 1000
    exit;
EOD
    )
    # We are spooling script in subshell and assigning output to $gen_output to suppress output to stdout.
    # Additionally, by having this exit status check, we have more control on how to alert the user.
    if [ $? -ne 0 ]; then
        echo "$gen_output"
        echo "Error, sqlplus failed while generating RMANCopyREADonlyDatafiles.sh for ${ORACLE_SID}."
        rm -f RMANCopyREADonlyDatafiles.sh
        exit_status=1
    fi

    # Create the script that will restore and recover all datafiles.
    # The script should only be run if all tablespace datafiles,
    # including read-only tablespaces, are available for restore.
    #
    # Syntax: SUBSTR('string', start_position, number of bytes to read)
    #
    # SUBSTR (NAME, INSTR (NAME, '/${database_name}/', -1))
    # INSTR (NAME, '/${database_name}/', -1) -> searching backward from the end (-1), find the position of the first '/${database_name}/' segment
    # SUBSTR (NAME, INSTR (NAME, '/${database_name}/', -1)) -> return everything from that position (the leading '/' of /${database_name}/) to the end of NAME, dropping everything before /${database_name}/
    gen_output=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    set head off pages 0 feed off echo off verify off
    set linesize 1000
    whenever sqlerror exit 1
    whenever oserror exit 1
    spool RMANRestoreRecoverAllDatafiles.sh
    select '#!/bin/bash' from dual;
    select '# Takes in two parameters: Source directory (example: /path/to/mysid/) and output directory.' from dual;
    select '# Created on: ${creation_date}' from dual;
    select '' from dual;
    select '# NOTE: This script should only be run if all datafiles are available for restore.' from dual;
    select '' from dual;
    select '# Check arguments' from dual;
    select 'if [ \$# -ne 1 ] ; then' from dual;
    select ' echo "Input directory required!"' from dual;
    select ' exit 1' from dual;
    select 'elif [ ! -d \$1 ]; then' from dual;
    select ' echo "Directory \$1 does not exist"' from dual;
    select ' exit 1' from dual;
    select 'fi' from dual;
    select '' from dual;
    select 'echo "RMANRestoreRecoverAllDatafiles.sh script started at: \$(date +%Y-%m-%d_%H_%M)"' from dual;
    select '' from dual;
    select '# Run RMAN to set read-write tablespace datafiles and copy redo logs into the new directory' from dual;
    select 'rman LOG "/tmp/rman_\${ORACLE_SID}_RMANRestoreRecoverAllDatafiles_\$(date +%Y-%m-%d_%H_%M).txt" <<EOD' from dual;
    select 'connect target /' from dual;
    select 'run {' from dual;
    select 'allocate channel ch1 type disk;' from dual;
    select 'allocate channel ch2 type disk;' from dual;
    select 'allocate channel ch3 type disk;' from dual;
    select 'allocate channel ch4 type disk;' from dual;
    select 'set newname for datafile '||file#||' to  ''\${1}'|| SUBSTR (NAME, INSTR (NAME, '/${database_name}/', -1))||''';'
        from v\$datafile
        order by file#;
    select 'restore database;' from dual;
    select 'switch datafile all;' from dual;
    select 'recover database;' from dual;

    select '}' from dual;
    select 'exit;' from dual;

    set linesize 3
    select 'EOD' from dual;
    set linesize 1000
    exit;
EOD
    )
    # We are spooling script in subshell and assigning output to $gen_output to suppress output to stdout.
    # Additionally, by having this exit status check, we have more control on how to alert the user.
    if [ $? -ne 0 ]; then
        echo "$gen_output"
        echo "Error, sqlplus failed while generating RMANRestoreRecoverAllDatafiles.sh for ${ORACLE_SID}."
        rm -f RMANRestoreRecoverAllDatafiles.sh
        exit_status=1
    fi

    # Create a script that just updates the location for the redo files and
    # rebuilds them by opening the resetlogs on the new database
    #
    # Syntax: SUBSTR('string', start_position, number of bytes to read)
    #
    # SUBSTR (member, INSTR (member, '/', -1)) -> searching backward from the end (-1) for a forward slash, take everything from the '/' to the end of the string
    # Ex. something/something_else/redo10a.log -> /redo10a.log
    gen_output=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    set head off pages 0 feed off echo off verify off
    set linesize 1000
    whenever sqlerror exit 1
    whenever oserror exit 1
    spool RMANRestoreRedoLogsNewDirectory.sh
    select '#!/bin/bash' from dual;
    select '# Created on: ${creation_date}' from dual;
    select '' from dual;
    select '# Check arguments' from dual;
    select 'if [ \$# -ne 1 ] ; then' from dual;
    select ' echo "Input directory required!"' from dual;
    select ' exit 1' from dual;
    select 'elif [ ! -d \$1 ]; then' from dual;
    select ' echo "Directory \$1 does not exist"' from dual;
    select ' exit 1' from dual;
    select 'fi' from dual;
    select '' from dual;
    select 'echo "RMANRestoreRedoLogsNewDirectory.sh script started at: \$(date +%Y-%m-%d_%H_%M)"' from dual;
    select '' from dual;
    select '# Run RMAN to restore the template redo files into the new database directory' from dual;
    select 'rman LOG "/tmp/rman_\${ORACLE_SID}_RMANRestoreRedoLogsNewDirectory_\$(date +%Y-%m-%d_%H_%M).txt" <<EOD' from dual;
    select 'connect target /' from dual;
    select 'run {' from dual;
    select 'SQL "ALTER DATABASE RENAME FILE '''''||member||''''' to ''''\${1}'|| SUBSTR (member, INSTR (member, '/', -1) )||'''''  ";'
        from v\$logfile
        order by 1;
    select 'SQL "alter database open resetlogs";' from dual;
    select '}' from dual;
    select 'exit;' from dual;

    set linesize 3
    select 'EOD' from dual;
    set linesize 1000
    exit;
EOD
    )
    # We are spooling script in subshell and assigning output to $gen_output to suppress output to stdout.
    # Additionally, by having this exit status check, we have more control on how to alert the user.
    if [ $? -ne 0 ]; then
        echo "$gen_output"
        echo "Error, sqlplus failed while generating RMANRestoreRedoLogsNewDirectory.sh for ${ORACLE_SID}."
        rm -f RMANRestoreRedoLogsNewDirectory.sh
        exit_status=1
    fi

    # Create the script that will drop offline read-only datafiles.
    # This should be run after the restore and prior to the recovery of the database.
    gen_output=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    set head off pages 0 feed off echo off verify off
    set linesize 1000
    whenever sqlerror exit 1
    whenever oserror exit 1
    spool RMANOfflineDropREADonlyDatafiles.sh
    select '#!/bin/bash' from dual;
    select '# Created on: ${creation_date}' from dual;
    select '' from dual;
    select '# NOTE: Run script after the restore and prior to recovery.' from dual;
    select '' from dual;
    select 'echo "RMANOfflineDropREADonlyDatafiles.sh script started at: \$(date +%Y-%m-%d_%H_%M)"' from dual;
    select '' from dual;
    select '# Drop all offline read-only datafiles' from dual;
    select '# If none are found, this query will be empty, and the script will exit after logging into sqlplus' from dual;
    select 'sqlplus / as sysdba<<EOD' from dual;
    select 'whenever sqlerror exit 1' from dual;
    select 'whenever oserror exit 1' from dual;
    select 'spool /tmp/rman_\${ORACLE_SID}_RMANOfflineDropREADonlyDatafiles_\$(date +%Y-%m-%d_%H_%M).txt' from dual;
    select 'alter database datafile ' || file# || ' offline drop;'
    from v\$datafile where enabled = 'READ ONLY'
    order by 1;

    select 'alter database datafile ' || file# || ' offline drop;'
    from v\$datafile where TS# IN
    (select TS# from v\$tablespace where name = 'STAGING')
    order by 1;

    select 'exit;' from dual;

    set linesize 3
    select 'EOD' from dual;
    set linesize 1000
    exit;
EOD
    )
    # We are spooling script in subshell and assigning output to $gen_output to suppress output to stdout.
    # Additionally, by having this exit status check, we have more control on how to alert the user.
    if [ $? -ne 0 ]; then
        echo "$gen_output"
        echo "Error, sqlplus failed while generating RMANOfflineDropREADonlyDatafiles.sh for ${ORACLE_SID}."
        rm -f RMANOfflineDropREADonlyDatafiles.sh
        exit_status=1
    fi

    # Create the script that will set the tablespaces online after the read-only
    # datafiles have been restored. This script should only be ran after the
    # read-only datafiles have been restored to the correct location.
    #
    # Syntax: SUBSTR('string', start_position, number of bytes to read)
    #
    # SUBSTR (NAME, INSTR (NAME, '/${database_name}/', -1))
    # INSTR (NAME, '/${database_name}/', -1) -> searching backward from the end (-1), find the position of the first '/${database_name}/' segment
    # SUBSTR (NAME, INSTR (NAME, '/${database_name}/', -1)) -> return everything from that position (the leading '/' of /${database_name}/) to the end of NAME, dropping everything before /${database_name}/
    gen_output=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    set head off pages 0 feed off echo off verify off
    set linesize 1000
    whenever sqlerror exit 1
    whenever oserror exit 1
    spool RMANOnlineREADonlyTablespaces.sh
    select '#!/bin/bash' from dual;
    select '# Created on: ${creation_date}' from dual;
    select '' from dual;
    select '# NOTE: Run only after the read-only datafiles have been restored to the correct location.' from dual;
    select '' from dual;
    select '# Check arguments' from dual;
    select 'if [ \$# -ne 1 ] ; then' from dual;
    select ' echo "Input directory required!"' from dual;
    select ' exit 1' from dual;
    select 'elif [ ! -d \$1 ]; then' from dual;
    select ' echo "Directory \$1 does not exist"' from dual;
    select ' exit 1' from dual;
    select 'fi' from dual;
    select '' from dual;
    select 'echo "RMANOnlineREADonlyTablespaces.sh script started at: \$(date +%Y-%m-%d_%H_%M)"' from dual;
    select '' from dual;
    select '# Add read-only datafiles back into the database.' from dual;
    select '# If none are found, this query will be empty, and the script will exit after logging into sqlplus' from dual;
    select 'sqlplus / as sysdba<<EOD' from dual;
    select 'ALTER DATABASE RENAME FILE '''||name||''' to  ''\${1}'|| SUBSTR (NAME, INSTR (NAME, '/${database_name}/', -1))||''';'
        from v\$datafile
        where enabled = 'READ ONLY'
        order by file#;

    select '-- ORA-01511 errors can be ignored - indicates that file was already in correct location' from dual;

    select distinct 'ALTER TABLESPACE '||name||' ONLINE;'
        from v\$tablespace where TS# IN
        (select TS# from v\$datafile
        where enabled = 'READ ONLY')
        order by 1;                                                                                                                                                                     
    select 'exit;' from dual;                                                                                                                                                                                                   

    set linesize 3
    select 'EOD' from dual;
    set linesize 1000
    exit;
EOD
    )
    # We are spooling script in subshell and assigning output to $gen_output to suppress output to stdout.
    # Additionally, by having this exit status check, we have more control on how to alert the user.
    if [ $? -ne 0 ]; then
        echo "$gen_output"
        echo "Error, sqlplus failed while generating RMANOnlineREADonlyTablespaces.sh for ${ORACLE_SID}."
        rm -f RMANOnlineREADonlyTablespaces.sh
        exit_status=1
    fi

    # Create an RMAN restore script that will exclude READ ONLY tablespaces
    #
    # Syntax: SUBSTR('string', start_position, number of bytes to read)
    #
    # SUBSTR (NAME, INSTR (NAME, '/${database_name}/', -1))
    # INSTR (NAME, '/${database_name}/', -1) -> searching backward from the end (-1), find the position of the first '/${database_name}/' segment
    # SUBSTR (NAME, INSTR (NAME, '/${database_name}/', -1)) -> return everything from that position (the leading '/' of /${database_name}/) to the end of NAME, dropping everything before /${database_name}/
    gen_output=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    set head off pages 0 feed off echo off verify off
    set linesize 1000
    whenever sqlerror exit 1
    whenever oserror exit 1
    spool RMANRestoreReadWriteTablespacesOnly.sh
    select '#!/bin/bash' from dual;
    select '# Created on: ${creation_date}' from dual;
    select '' from dual;
    select '# Check arguments' from dual;
    select 'if [ \$# -ne 1 ] ; then' from dual;
    select ' echo "Input directory required!"' from dual;
    select ' exit 1' from dual;
    select 'elif [ ! -d \$1 ]; then' from dual;
    select ' echo "Directory \$1 does not exist"' from dual;
    select ' exit 1' from dual;
    select 'fi' from dual;
    select '' from dual;
    select 'echo "RMANRestoreReadWriteTablespacesOnly.sh script started at: \$(date +%Y-%m-%d_%H_%M)"' from dual;
    select '' from dual;
    select '# Run RMAN to set and restore ONLY the read-write tablepaces' from dual;
    select '# This means that the reado-only tablespaces will be excluded' from dual;
    select 'rman LOG "/tmp/rman_\${ORACLE_SID}_RMANRestoreReadWriteTablespacesOnly_\$(date +%Y-%m-%d_%H_%M).txt" <<EOD' from dual;
    select 'connect target /' from dual;
    select 'run {' from dual;
    select 'allocate channel ch1 type disk;' from dual;
    select 'allocate channel ch2 type disk;' from dual;
    select 'allocate channel ch3 type disk;' from dual;
    select 'allocate channel ch4 type disk;' from dual;
    select 'configure device type disk parallelism 4;' from dual;
    select 'set newname for datafile '||file#||' to  ''\${1}'|| SUBSTR (NAME, INSTR (NAME, '/${database_name}/', -1))||''';'
        from v\$datafile
        where enabled = 'READ WRITE'
        order by file#;

    set linesize 20000
    set long 200000
    column datafiles format a20000
        SELECT 'restore datafile ' ||
    rtrim(xmlagg(XMLELEMENT(e,text,',').EXTRACT('//text()')).GetClobVal(),',') 
    || ';' datafiles
    from
    (select file#  text
    from v\$datafile
    where enabled = 'READ WRITE'
    order by 1); 
    set linesize 1000
    select 'switch datafile all;' from dual;
    select '}' from dual;
    select 'exit;' from dual;

    set linesize 3
    select 'EOD' from dual;
    set linesize 1000
    exit;
EOD
    )
    # We are spooling script in subshell and assigning output to $gen_output to suppress output to stdout.
    # Additionally, by having this exit status check, we have more control on how to alert the user.
    if [ $? -ne 0 ]; then
        echo "$gen_output"
        echo "Error, sqlplus failed while generating RMANRestoreReadWriteTablespacesOnly.sh for ${ORACLE_SID}."
        rm -f RMANRestoreReadWriteTablespacesOnly.sh
        exit_status=1
    fi

    # Check for script creation and make scripts executable.
    if [ -f "RMANRestoreAllDatafiles.sh" ]; then
        chmod 644 RMANRestoreAllDatafiles.sh
        mv RMANRestoreAllDatafiles.sh "$output_dir"
    else
        echo "Error, File RMANRestoreAllDatafiles.sh not created."
        exit_status=1
    fi

    if [ -f "RMANRestoreRecoverAllDatafiles.sh" ]; then
        chmod 644 RMANRestoreRecoverAllDatafiles.sh
        mv RMANRestoreRecoverAllDatafiles.sh "$output_dir"
    else
        echo "Error, File RMANRestoreRecoverAllDatafiles.sh not created."
        exit_status=1
    fi

    if [ -f "RMANCopyREADonlyDatafiles.sh" ]; then
        chmod 644 RMANCopyREADonlyDatafiles.sh
        mv RMANCopyREADonlyDatafiles.sh "$output_dir"
    else
        echo "Error, File RMANCopyREADonlyDatafiles.sh not created."
        exit_status=1
    fi

    if [ -f "RMANOfflineDropREADonlyDatafiles.sh" ]; then
        chmod 644 RMANOfflineDropREADonlyDatafiles.sh
        mv RMANOfflineDropREADonlyDatafiles.sh "$output_dir"
    else
        echo "Error, File RMANOfflineDropREADonlyDatafiles.sh not created."
        exit_status=1
    fi
    
    if [ -f "RMANOnlineREADonlyTablespaces.sh" ]; then
        chmod 644 RMANOnlineREADonlyTablespaces.sh
        mv RMANOnlineREADonlyTablespaces.sh "$output_dir"
    else
        echo "Error, File RMANOnlineREADonlyTablespaces.sh not created."
        exit_status=1
    fi

    if [ -f "RMANCreateDirStructure.sh" ]; then
        chmod 644 RMANCreateDirStructure.sh
        mv RMANCreateDirStructure.sh "$output_dir"
    else
        echo "Error, File RMANCreateDirStructure.sh not created."
        exit_status=1
    fi

    if [ -f "RMANRestoreRedoLogsNewDirectory.sh" ]; then
        chmod 644 RMANRestoreRedoLogsNewDirectory.sh
        mv RMANRestoreRedoLogsNewDirectory.sh "$output_dir"
    else
        echo "Error, File RMANRestoreRedoLogsNewDirectory.sh not created."
        exit_status=1
    fi

    if [ -f "RMANRestoreReadWriteTablespacesOnly.sh" ]; then
        chmod 644 RMANRestoreReadWriteTablespacesOnly.sh
        mv RMANRestoreReadWriteTablespacesOnly.sh "$output_dir"
    else
        echo "Error, File RMANRestoreReadWriteTablespacesOnly.sh not created."
        exit_status=1
    fi 
done

if [ $exit_status -eq 1 ]; then
    echo "Script completed but errors occurred"
else
    echo "Script completed successfully."
fi

exit "$exit_status"