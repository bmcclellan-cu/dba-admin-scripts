#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script runs pg_dump to export either a provided database or the
#          default postgres database. It gives the user the option to dump only
#          the database's data, metadata, or everything in the database.
#
# Note: If all is selected, an additional file will be created with the higher-level
#       information (users, tablespaces, creation of database). Do not provide a
#       database name if ALL agument is inputted.
#
# Note: The -e option allows you to specify a directory in which you want your
#       dumpfiles to be located. Without this option, your dumpfiles will be
#       put in your current directory.
#
# Note: The -p option allows you to specify the amount of processors which
#       should be used in parallel to zip the dump with -p [##]
#       The p option is set to 4 by default if it is not specified.
#
# Data option: requires database name param, dumps one file with DATAONLY name and GLOBALOBJECTS file
#              with only metadata for the specified database
# Note: Designed to generate input files for PgLoadDatabase.sh or PgLoadInstance.sh
#
# Global option: Dump all DDL for entire instance (GLOBALOBJECTS file)
# Note: Use for manual intervention
#
# All option: Dumps all data for all databases (ALLDATABASES file) and DDL for entire instance (GLOBALOBJECTS file)
# Note: Designed to generate input files for PgLoadInstance.sh
#
# Note: Delete the err.txt at the end of the backup.
#
#############################################################################################
# This script is called by BackupPostGreSQL.sh for primary LASP backups.
# This script will dump/export the data to the calling directory of this script.
# BackupPostGreSQL.sh sets the calling/export directory to PG_BACKUP_DIR which is set in the .bashrc
#############################################################################################
#
################################################################################

usage="Usage: PgDump.sh [ -n (option for no zip)] [ -e export_dir (2 params)] [ -p num_processors (2 params, optional) ] [data|global|all] [database (required for data option)]"
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

# Ensure processor arg is a number greater than 0
if ! [[ "$parg" =~ ^[0-9]+$ ]]; then
    echo "Error: Processor argument (the arg following the -p flag) must be a number"
    exit 1
elif [ $parg -le 0 ]; then
    echo "Error: Number in processor argument (following -p flag) must be greater than 0"
    exit 1
fi

# Set the database from user input
database=$2

# Creating datestamp for output file
datestamp=$(date +%m-%d-%Y-%H-%M-%S)

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

# Set export directory
if [ -n "$earg" ]; then
    if [ -d "$earg" ]; then
        EXPORT_DIR="$earg"
    else
        echo "Export directory $earg does not exist. Attempting to create..."
        mkdir -p "$earg"
        # Check for errors from mkdir
        if [ $? -ne 0 ]; then
            echo "Unable to create directory $earg. Exiting..."
            exit 1
        fi
    fi

    # Check that user has write permission to export directory
    if [ ! -w "$earg" ]; then
        echo "Error. User does not have write permissions for output directory ${earg}. Exiting..."
        exit 1
    fi

    # Remove trailing slash from earg
    earg=$(echo "$earg" | sed 's/\/$//')
fi

rm -f $(pwd)/err.txt

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
        # Dumps all of the data from the database into a file
        # Dump to given location if e arg is provided
        if [ -n "$earg" ]; then
            pg_dump $option --disable-triggers 2>>err.txt 1>$earg/$file_name_dump
        else
            pg_dump $option --disable-triggers 2>>err.txt 1>$file_name_dump
        fi

        if [ $? -ne 0 ]; then
            echo "Error: Unable to dump data. Check err.txt for details. Exiting..."
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
        # Dump to given location if e arg is provided
        if [ -n "$earg" ]; then
            pg_dump $option --disable-triggers 2>>err.txt | pigz -p $parg >$earg/$file_name_dump
        else
            pg_dump $option --disable-triggers 2>>err.txt | pigz -p $parg >$file_name_dump
        fi
        # $PIPESTATUS is an array variable that holds return codes of all commands in the previous
        # sequence of piped commands
        if [ ${PIPESTATUS[0]} -ne 0 ]; then
            echo "Error: Unable to dump data. Check err.txt for details. Exiting..."
            exit 2
        fi
    fi
elif [ "${1^^}" == "ALL" ]; then
    if $nopt; then
        # Dumps all of the data from the instance into a file
        # Dump to given location if e arg is provided
        if [ -n "$earg" ]; then
            pg_dumpall 2>>err.txt 1>$earg/$file_name_dump
        else
            pg_dumpall 2>>err.txt 1>$file_name_dump
        fi

        if [ $? -ne 0 ]; then
            echo "Error: Unable to dump data. Check err.txt for details. Exiting..."
            exit 2
        fi
    else
        file_name_dump="$file_name_dump.gz"

        # Dump data to output file
        # Dump to given location if e arg is provided
        if [ -n "$earg" ]; then
            pg_dumpall $option 2>>err.txt | pigz -p $parg >$earg/$file_name_dump
        else
            pg_dumpall $option 2>>err.txt | pigz -p $parg >$file_name_dump
        fi
        # $PIPESTATUS is an array variable that holds return codes of all commands in the previous
        # sequence of piped commands
        if [ ${PIPESTATUS[0]} -ne 0 ]; then
            echo "Error: Unable to dump data. Check err.txt for details. Exiting..."
            exit 2
        fi
    fi
fi

# Dumping the global data
if $nopt; then
    # Dumps all of the schema-level data from the instance into a file
    # Dump to given location if e arg is provided
    if [ -n "$earg" ]; then
        pg_dumpall -s 2>>err.txt 1>$earg/$file_name_dump_all
    else
        pg_dumpall -s 2>>err.txt 1>$file_name_dump_all
    fi
    if [ $? -ne 0 ]; then
        echo "Error: Unable to dump schema. Check err.txt for details. Exiting..."
        exit 2
    fi
else
    file_name_dump_all="$file_name_dump_all.gz"

    # Dump data to output file
    if [ -n "$earg" ]; then
        pg_dumpall -s 2>>err.txt | pigz -p $parg >$earg/$file_name_dump_all
    else
        pg_dumpall -s 2>>err.txt | pigz -p $parg >$file_name_dump_all
    fi

    # $PIPESTATUS is an array variable that holds return codes of all commands in the previous
    # sequence of piped commands
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo "Error: Unable to dump schema. Check err.txt for details. Exiting..."
        exit 2
    fi
fi

res=$(cat err.txt)

if [ -n "$earg" ]; then
    echo "Dump of $database to $earg/$file_name_dump was successful"
    echo "Dump of $database global objects to $earg/$file_name_dump_all was successful"
    echo "Outputting size of $file_name_dump to $earg/SIZE_$datestamp.txt"
else
    echo "Dump of $database to $file_name_dump was successful"
    echo "Dump of $database global objects to $file_name_dump_all was successful"
    echo "Outputting size of $file_name_dump to SIZE_$datestamp.txt"
fi

database_output=$($HOME/common/postgres/PrintDatabases.sh -r)
if [ $? -ne 0 ]; then
    echo "Error occurred while printing database info for SIZE file"
    echo "$database_output"
    echo "Exiting..."
    exit 1
fi

# First tail removes all lines from output that come before '--+--+--+--' line at top of table
# Second tail removes the '--+--+--+--' line
# The two grep -v commands remove unneeded info that appears below the table
# awk tokenizes the table by using the '|' character as the delimiter and extracts the 1st (db name) and 7th (size) columns
# sed removes extra whitespace
# tr changes each row from space seperated to csv format.
size_prefix="."
if [ -n "$earg" ]; then
    size_prefix="$earg"
fi
echo "$database_output" | tail -n +$(echo "$database_output" | egrep -n '^-+\+' | cut -d: -f1) | tail -n +2 | grep -v 'Databases successfully printed' | egrep -v '([0-9]+ rows)' | awk -F '|' '{print $1 $7}' | sed '/^[[:space:]]*$/d;s/^ //;s/[[:space:]]*$//;s/[[:space:]]\{1,\}/ /' | tr ' ' ',' >$size_prefix/SIZE_$datestamp.txt
all_size=$(cat "$size_prefix/SIZE_$datestamp.txt" | sed "s/\,/ /g" | awk '{print $NF}' | awk '{sum += $1} END {print sum}')
echo "all,$all_size">>$size_prefix/SIZE_$datestamp.txt

if [ "${1^^}" == "DATA" ]; then
    # Creating a file that holds all the roles and tablesspaces on the database being dumped
    if [ -n "$earg" ]; then
        role_file="$earg/$database"_ROLES_"$datestamp".txt
    else
        role_file="$database"_ROLES_"$datestamp".txt
    fi
    db_roles=$($HOME/common/postgres/PrintRoles.sh "-d" "$database")
    if [ $? -ne 0 ]; then
        echo "$db_roles"
        echo "Error, PrintRoles.sh failed. Exiting..."
        exit 1
    fi

    db_tbsp=$($HOME/common/postgres/PrintTablespaces.sh "-d" "$database")
    if [ $? -ne 0 ]; then
        echo "$db_tbsp"
        echo "Error, PrintTablespaces.sh failed. Exiting..."
        exit 1
    fi
    echo "Outputting roles and tablespaces for database $database to $role_file"
    echo -e "----- Roles ----- \n$db_roles\n----- Tablespaces -----\n$db_tbsp">$role_file
fi

exit 0
