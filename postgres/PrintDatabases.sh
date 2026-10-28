#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script prints a list of databases and roles with access privileges
#          to the databases on the postgres server.
#
# Note: Database access privileges are displayed in the format:
#       Grantee_Role :
#         PERMISSIONS granted by Grantor_Role
#
################################################################################

usage="Usage: PrintDatabases.sh [-d (Optional, prints database names only, excluding those starting with 'template', with no formatting)] [-s (Optional, prints size and db name only)] [-r (Optional, prints sizes and the total in bytes instead of converted)]"
example="Example: PrintDatabases.sh -d"

dataonly=false
sizeonly=false
bytes=false
pg_size_pretty="pg_size_pretty(pg_database_size(d.datname))"
# Process input options
while getopts ":hdsr" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    d)
        dataonly=true
        ;;
    s)
        sizeonly=true
        ;;
    r)
        pg_size_pretty="pg_database_size(d.datname)::text"
        bytes=true
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

# Check arguments
if [ $# -gt 3 ] ; then
    echo "$example"
    echo "$usage"
    exit 1
fi

# Check that only one of -d or -r options were invoked, if any
if $dataonly && $bytes; then
    echo "Error: The -d and -r options are mutually exclusive. This script can only be called with one of these options. Exiting..."
    echo "$usage"
    echo "$example"
    exit 1
fi

# Check that only one of -d or -s options were invoked, if any
if $dataonly && $sizeonly; then
    echo "Error: The -d and -s options are mutually exclusive. This script can only be called with one of these options. Exiting..."
    echo "$usage"
    echo "$example"
    exit 1
fi

if ! $dataonly; then
    if $sizeonly; then
        echo ""
        psql -q -v ON_ERROR_STOP=on <<EOD
        SELECT datname as "Name",
        $pg_size_pretty as "Size"
        FROM pg_database d 
        ORDER BY 1;
EOD
        # Check exit status of psql query
        if [ $? -ne 0 ]; then
            echo "PrintDatabases.sh failed while attempting to print database sizes. Exiting..."
            exit 1
        fi
    else
        echo "Printing databases..."
        echo
        echo "Possible database access privileges:
CONNECT: This permission allows a role to connect to the specified database. Without this permission, users won't be able to establish a connection to the database.
CREATE: This permission allows a role to create new schemas within the specified database. It grants the ability to create new objects within those schemas, such as tables, views, functions, etc.
TEMPORARY: This permission allows a role to create temporary tables within the specified database. Temporary tables are session-specific and are automatically dropped at the end of the session or transaction.
"

        # Substitutions for following sql statement
        C="'=C/',' : 
  CREATE granted by ','g')"
        T="'=T/',' : 
  TEMPORARY granted by ','g')"
        c="'=c/',' : 
  CONNECT granted by ','g')"
        Tc="'=Tc/',' : 
  TEMPORARY and CONNECT granted by ','g')"
        CT="'=CT/',' : 
  CREATE and TEMPORARY granted by ','g')"
        Cc="'=Cc/',' : 
  CREATE and CONNECT granted by ','g')"
        CTc="'=CTc/',' : 
  CREATE, TEMPORARY, and CONNECT granted by ','g')"

        # Variables for replacing the common parts of the following statement
        REGEX_PREFIX="regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace("
        REGEX_SUFFIX=",$CTc,$Tc,$CT,$Cc,$c,$T,$C"

        # Display list of databases on the instance
        psql -q -v ON_ERROR_STOP=on <<EOD
        SELECT d.datname as "Name",
        pg_get_userbyid(d.datdba) as "Owner", pg_encoding_to_char(d.encoding) as "Encoding",
        d.datcollate as "Collate", d.datctype as "Ctype",
        --PUBLIC has an empty grantee name, so its entries are the only lines of the ACL that start with '='. It has
        --one entry per grantor and they can be anywhere in the ACL, so the 'n' flag makes ^ match at the start of any
        --line and 'g' labels every match.
        $REGEX_PREFIX regexp_replace(array_to_string(d.datacl, E'\n'), '^=', 'Public=', 'gn')$REGEX_SUFFIX AS "Access privileges",
        CASE
            WHEN has_database_privilege(d.datname, 'CONNECT')
            THEN $pg_size_pretty
            ELSE 'No Access'
        END as "Size", t.spcname as "Tablespace"
        FROM pg_database d JOIN pg_tablespace t on d.dattablespace = t.oid
        ORDER BY 1;
EOD
        # Check exit status of psql query
        if [ $? -ne 0 ]; then
            echo "PrintDatabases.sh failed while attempting to print database information. Exiting..."
            exit 1
        fi
    fi
else
    # Display list of databases on the instance without formatting
    output="$(psql -q -v ON_ERROR_STOP=on <<EOD
    \pset tuples_only on
    SELECT datname
    FROM pg_database 
    WHERE datname NOT LIKE 'template%'
    ORDER BY 1;
EOD
    )"
    # Check exit status of psql query
    if [ $? -ne 0 ]; then
        echo "$output"
        echo "PrintDatabases.sh failed while attempting to print database names. Exiting..."
        exit 1
    fi
fi

if $dataonly; then
    # Print one database name per line: sed strips the whitespace psql pads each name with and drops blank lines
    echo "$output" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d'
    exit 0
fi

# Calculating total size for all databases
total_size=$(psql -q -v ON_ERROR_STOP=on <<EOD
SELECT pg_database_size(d.datname) as size
FROM pg_database d;
EOD
)

if [ $? -ne 0 ]; then
    echo "$total_size"
    echo "Error occurred when calculating total size of all databases, exiting..."
    exit 1
fi

total_size=$(echo "$total_size" | awk '{total_size += $1} END {print total_size}')
# PgDump.sh's SIZE file parser sums the last field of every line it keeps, including this one, so this line must
# not end in a number.
if $bytes; then
    echo "Total size of all databases on the instance: $total_size bytes"
else
    gigabytes=$(echo "scale=2; $total_size / 1024^3" | bc)
    echo "Total size of all databases on the instance: $gigabytes GB"
fi

echo "Databases successfully printed"
exit 0