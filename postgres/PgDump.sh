#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose:  This script runs pg_dump to export either a provided database or the
#           default postgres database. It gives the user the option to dump only
#           the database's data, metadata, or everything in the database.
#           Options:
#               DATA: Requires database name param, dumps one GLOBALOBJECTS file with
#                     the DDL for the whole instance and one DATAONLY file with
#                     the actual data contents for the database. Database can be restored
#                     using PgLoadDatabase.sh and PgLoadInstance.sh, which extract the DDL for
#                     the single target database from the dumped instance DDL.
#               GLOBAL: Dumps all DDL for the entire instance as a GLOBALOBJECTS file.
#                     For use in manual recovery/archiving.
#               ALL:  Dumps all DDL for the entire instance into a GLOBALOBJECTS file and
#                     all the data for all databases into a single ALLDATABASES file.
#                     Instance can be restored with PgLoadInstance.sh.
#
# Notes:    DATA also writes a databasename_ROLES file listing the roles and tablespaces of the
#           database. Do not provide a database name if ALL argument is inputted.
#
#           The -e option selects the export directory. Without it, files are written
#           to the current directory. A timestamped PgDump log is kept there as well.
#
#           SIZE_<timestamp>.txt records each database's size in bytes and an "all"
#           total. Restore scripts use it to check available space.
#
#           The -p option allows you to specify the amount of processors which
#           should be used in parallel to zip the dump with -p [##]
#           The p option is set to 4 by default if it is not specified.
#
#############################################################################################
# This script is called by BackupPostGreSQL.sh for primary LASP backups.
# BackupPostGreSQL.sh changes directories to PG_BACKUP_DIR before calling this script.
################################################################################

usage="Usage: PgDump.sh [ -n (option for no zip) ] [ -e export_dir (sets directory to dump data to, defaults to PWD) ] [ -p num_processes (# of processes to compress dump file with, default: 4) ] [ data|global|all ] [ database (required for data option) ]"
example1="Example #1: PgDump.sh -n data data_dev"
example2="Example #2: PgDump.sh -e /tmp/test/postgres_dumps -n -p 4 ALL"

nopt=false
parg=4
# Process input options
while getopts ":hne:p:" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example1"
        echo "$example2"
        exit 0
        ;;
    n)
        nopt=true
        ;;
    e)
        earg="$OPTARG"
        ;;
    p)
        parg="$OPTARG"
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

# Shift arguments based on provided options
shift $((OPTIND - 1))

# Check arguments
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "$usage"
    echo "$example1"
    echo "$example2"
    exit 1
elif [ $# -eq 2 ] && [ "${1^^}" == "ALL" ]; then
    echo "Do not provide a database name if first input is \"ALL\""
    echo ""
    echo "$usage"
    echo "$example1"
    echo "$example2"
    exit 1
fi

# Deletes a dump file left by a failed run.
# Inputs:
#   dump_file: The file to delete.
cleanup_dump(){
    local dump_file=$1
    echo "Removing dump file $dump_file..."
    rm -f "$dump_file"
    if [ $? -ne 0 ]; then
        echo "WARNING: Failed to cleanup partial dump file $dump_file!"
    fi

}

# Ensure processor arg is a number greater than 0
if ! [[ "$parg" =~ ^[0-9]+$ ]]; then
    echo "Error: Processor argument (the arg following the -p flag) must be a number"
    exit 1
elif [ "$parg" -le 0 ]; then
    echo "Error: Number in processor argument (following -p flag) must be greater than 0"
    exit 1
fi

# Set the database from user input
database=${2,,}

# Set one export destination for dumps, metadata, and the run log.
datestamp=$(date +%m-%d-%Y-%H-%M-%S)
EXPORT_DIR="${earg:-$(pwd)}"
# If EXPORT_DIR doesn't already exist, attempt to create it and its parents.
if [ ! -d "$EXPORT_DIR" ] && ! mkdir -p "$EXPORT_DIR"; then
    echo "Unable to create export directory $EXPORT_DIR. Exiting..."
    exit 1
fi
if [ ! -w "$EXPORT_DIR" ]; then
    echo "Error: User does not have write permissions for export directory $EXPORT_DIR. Exiting..."
    exit 1
fi
if ! EXPORT_DIR=$(cd "$EXPORT_DIR" && pwd); then
    echo "Unable to resolve export directory $EXPORT_DIR. Exiting..."
    exit 1
fi

# mktemp adds a random suffix, so two dumps started in the same second get separate logs.
if ! log_file=$(mktemp "$EXPORT_DIR/PgDump_${datestamp}.XXXXX.log"); then
    echo "Unable to create a log file in $EXPORT_DIR. Exiting..."
    exit 1
fi
# Log to the file and the caller concurrently using the repository logging library.
source "$HOME/common/general/Logging.sh"
if [ $? -ne 0 ]; then
    echo "An error occurred while sourcing the logging library. Exiting..."
    exit 1
fi
set_general_logging "$log_file"
if [ $? -ne 0 ]; then
    echo "Unable to start PgDump logging in $log_file. Exiting..."
    exit 1
fi

# Close logs before exiting.
exit_handler(){
    result=$?
    trap - EXIT
    close_logs
    exit "$result"
}
trap exit_handler EXIT
echo "PgDump log: $log_file"

# Set GLOBALOBJECTS file name
if [ -n "$database" ]; then
    file_name_dump_all="$database"_GLOBALOBJECTS_"$datestamp".sql
else
    file_name_dump_all=GLOBALOBJECTS_"$datestamp".sql
fi

# Set option and data dump filename based on user's first input
if [ "${1^^}" == "DATA" ]; then
    if [ -n "$database" ]; then
        file_name_dump="$database"_DATAONLY_"$datestamp".sql
    else
        echo "Database parameter required for data option. Exiting..."
        exit 1
    fi
    # -a: data only
    option="-a $database"
elif [ "${1^^}" == "ALL" ]; then
    if [ -n "$database" ]; then
        file_name_dump="$database"_ALLDATABASES_"$datestamp".sql
    else
        file_name_dump=ALLDATABASES_"$datestamp".sql
    fi
    option="$database"
elif [ "${1^^}" == "GLOBAL" ]; then
    if [ -n "$database" ]; then
        file_name_dump_all="$database"_GLOBALOBJECTS_"$datestamp".sql
    else
        file_name_dump_all=GLOBALOBJECTS_"$datestamp".sql
    fi
    option="$database"
else
    echo "Invalid first input '$1', input must be 'data', 'global', or 'all'. Exiting..."
    exit 1
fi

# Check that instance is running.
instance_check=$("$HOME/common/postgres/CheckInstanceOpenStatus.sh")
if [ $? -ne 0 ]; then
    echo "$instance_check"
    echo "Error occurred while checking open status of instance on port $PGPORT."
    exit 1
elif [ "$instance_check" != "open" ]; then
    echo "No instance open on port $PGPORT"
    exit 1
fi

# Ensure that database exists if set
if [ -n "$database" ]; then
    db_exists=$("$HOME/common/postgres/CheckIfDatabaseExists.sh" "$database")
    if [ $? -ne 0 ]; then
        echo "Error occurred while checking if $database database exists"
        echo "$db_exists"
        exit 1
    elif [ ! "$db_exists" == "Yes" ]; then
        echo "ERROR: $database database does not exist on the server. Exiting..."
        exit 1
    fi
else
    database="postgres"
fi

# Write the SIZE file before dumping. The restore scripts need a SIZE file beside each dump, so a failure
# here must stop the run before a dump exists.
echo "Outputting sizes to $EXPORT_DIR/SIZE_$datestamp.txt"

# Get a list of all databases and their sizes (-s) in terms of bytes (-r).
database_sizes=$("$HOME/common/postgres/PrintDatabases.sh" -sr)
if [ $? -ne 0 ]; then
    echo "$database_sizes"
    echo "Error occurred while printing database info for SIZE file. Exiting..."
    exit 1
fi

# Extract just the lines with actual database-size mappings
database_sizes=$(echo "$database_sizes" | grep -E "[|][[:space:]].*[0-9]+[[:space:]]*$")
# First sed: Strip leading whitespace on each line
# Second sed: Replace the whitespace and | before the size number with a comma, formatting it as CSV.
database_sizes=$(echo "$database_sizes" | sed -E 's/^[[:space:]]*//' | sed -E "s/[[:space:]]*[|][[:space:]]*([0-9]+)[[:space:]]*$/,\1/")
# Without this check an empty result would be written as "all,0", and PgLoadInstance.sh would pass its
# space check against a size of 0.
if [ -z "$database_sizes" ]; then
    echo "Error: Unable to read database sizes from PrintDatabases.sh output for SIZE file. Exiting..."
    exit 1
fi

# Compute the size of all databases combined:
all_size=$(echo "$database_sizes" | sed "s/\,/ /g" | awk '{print $NF}' | awk '{sum += $1} END {print sum}')

# Write the results to the SIZE file.
size_file="$EXPORT_DIR/SIZE_$datestamp.txt"
echo "$database_sizes
all,$all_size" > "$size_file"
if [ $? -ne 0 ]; then
    echo "An error occurred while writing to SIZE file $size_file. Exiting..."
    exit 1
fi

if [ "${1^^}" == "DATA" ]; then
    # Write the ROLES file (the database's roles and tablespaces) before dumping, for the same reason as the
    # SIZE file: PgLoadInstance.sh and PgLoadDatabase.sh read it beside each DATAONLY dump.
    role_file="$EXPORT_DIR/${database}_ROLES_${datestamp}.txt"
    db_roles=$("$HOME/common/postgres/PrintRoles.sh" "-d" "$database")
    if [ $? -ne 0 ]; then
        echo "$db_roles"
        echo "Error, PrintRoles.sh failed. Exiting..."
        exit 1
    fi

    db_tbsp=$("$HOME/common/postgres/PrintTablespaces.sh" "-d" "$database")
    if [ $? -ne 0 ]; then
        echo "$db_tbsp"
        echo "Error, PrintTablespaces.sh failed. Exiting..."
        exit 1
    fi
    echo "Outputting roles and tablespaces for database $database to $role_file"
    echo -e "----- Roles ----- \n$db_roles\n----- Tablespaces -----\n$db_tbsp" >"$role_file"
    if [ $? -ne 0 ]; then
        echo "An error occurred while writing to ROLES file $role_file. Exiting..."
        exit 1
    fi
fi

# Alert user that a dump is being performed, and tell them the proper file name
if [ "${1^^}" != "GLOBAL" ]; then
    # Run pg_dump to export to $file_name_dump
    echo "Performing $1 dump on $database to $file_name_dump..."
    echo
else
    # Run pg_dump to export to $file_name_dump_all
    echo "Performing $1 dump on $database to $file_name_dump_all..."
    echo
fi

if [ "${1^^}" == "DATA" ]; then

    if $nopt; then
        # Dumps all of the data from the database into a file.
        # $option is intentionally left unquoted so it word-splits into separate arguments.
        pg_dump $option --disable-triggers >"$EXPORT_DIR/$file_name_dump"

        if [ $? -ne 0 ]; then
            echo "Error: Unable to dump data. Check $log_file for details. Exiting..."
            cleanup_dump "$EXPORT_DIR/$file_name_dump"
            exit 2
        fi
    else
        file_name_dump="$file_name_dump.gz"

        # Dump data to output file
        # NOTE: Piping to gzip/pigz compresses the output file as it is being created which prevents the
        # full size file from being created. Running pg_dump, then zipping the full-size output
        # file uses far more space
        # NOTE: --compress=gzip option is available in postgres version 16. Could be worth looking
        # into in the future to make code cleaner, but may be slower due to lack of parallelization
        # $option is intentionally left unquoted so it word-splits into separate arguments.
        pg_dump $option --disable-triggers | pigz -p "$parg" >"$EXPORT_DIR/$file_name_dump"
        # Capture both pipeline statuses before the if statement replaces PIPESTATUS.
        pipeline_status=("${PIPESTATUS[@]}")
        if [ "${pipeline_status[0]}" -ne 0 ] || [ "${pipeline_status[1]}" -ne 0 ]; then
            echo "Error: Unable to dump or compress data. Check $log_file for details. Exiting..."
            cleanup_dump "$EXPORT_DIR/$file_name_dump"
            exit 2
        fi
    fi
elif [ "${1^^}" == "ALL" ]; then
    if $nopt; then
        # Dumps all of the data from the instance into a file
        pg_dumpall >"$EXPORT_DIR/$file_name_dump"
        if [ $? -ne 0 ]; then
            echo "Error: Unable to dump data. Check $log_file for details. Exiting..."
            cleanup_dump "$EXPORT_DIR/$file_name_dump"
            exit 2
        fi
    else
        file_name_dump="$file_name_dump.gz"

        # $option is intentionally left unquoted so it word-splits into separate arguments.
        pg_dumpall $option | pigz -p "$parg" >"$EXPORT_DIR/$file_name_dump"
        # Capture both pipeline statuses before the if statement replaces PIPESTATUS.
        pipeline_status=("${PIPESTATUS[@]}")
        if [ "${pipeline_status[0]}" -ne 0 ] || [ "${pipeline_status[1]}" -ne 0 ]; then
            echo "Error: Unable to dump or compress data. Check $log_file for details. Exiting..."
            cleanup_dump "$EXPORT_DIR/$file_name_dump"
            exit 2
        fi
    fi
fi

# Dumping the global data
if $nopt; then
    # Dumps all of the schema-level data from the instance into a file
    pg_dumpall -s >"$EXPORT_DIR/$file_name_dump_all"
    schema_status=$?
else
    file_name_dump_all="$file_name_dump_all.gz"

    pg_dumpall -s | pigz -p "$parg" >"$EXPORT_DIR/$file_name_dump_all"
    # Capture both pipeline statuses before the next command replaces PIPESTATUS.
    pipeline_status=("${PIPESTATUS[@]}")
    schema_status=0
    if [ "${pipeline_status[0]}" -ne 0 ] || [ "${pipeline_status[1]}" -ne 0 ]; then
        schema_status=1
    fi
fi
if [ "$schema_status" -ne 0 ]; then
    echo "Error: Unable to dump or compress schema. Check $log_file for details. Exiting..."
    cleanup_dump "$EXPORT_DIR/$file_name_dump_all"
    # The restore scripts pick the newest data dump and need its GLOBALOBJECTS file, so remove the data dump too.
    if [ -n "$file_name_dump" ]; then
        cleanup_dump "$EXPORT_DIR/$file_name_dump"
    fi
    exit 2
fi

if [ "${1^^}" != "GLOBAL" ]; then
    echo "Dump of $database to $file_name_dump was successful"
fi
echo "Dump of $database global objects to $file_name_dump_all was successful"
echo "Export directory: $EXPORT_DIR"

exit 0
