#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script prints the size in GB of a given segment for partitioned segments and in MB
#          for non-partitioned segments. This script pulls this data from PrintSegments.sh for
#          partitioned segments. For non-partitioned segments the data is from dba_segments.
# 
# Note: This script only takes system defined segment names as input, giving a literal
#       segment name may produce an error
#
#####################################################################################

usage="Usage: PrintSegmentSize.sh [schema] [segment name] [segment type (optional, use quotes if type isn't one word)]"
example="Example: PrintSegmentSize.sh MY_SCHEMA MY_TABLE TABLE"

while getopts ":h" option; do
    case $option in
        h)
            echo "$usage"
            echo "$example"
            exit 0;;
        \?)
            echo "Error: Invalid option"
            exit 1
    esac
done

# Check arguments
if [ $# -lt 2 ] || [ $# -gt 3 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Checking ORACLE_SID
sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
if [ $? -ne 0 ]; then
    echo "$sid_check"
    echo "An error occurred while checking for invalid SIDs. Exiting..."
    exit 1
fi
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "Error, \$ORACLE_SID not set..."
        exit 1
    fi
    echo "Error, provided \$ORACLE_SID is not open. Exiting..."
    exit 1
fi

schema=${1^^}
segment=${2^^}
# Left empty if not given by user
segment_type=${3^^} 
valid_segments="|INDEX|TABLE|NESTED TABLE|TABLE PARTITION|CLUSTER|LOBINDEX|INDEX PARTITION|LOBSEGMENT|TABLE SUBPARTITION|INDEX SUBPARTITION|LOB PARTITION|LOB SUBPARTITION|ROLLBACK|TYPE2 UNDO|DEFERRED ROLLBACK|TEMPORARY|CACHE|SPACE HEADER|UNDEFINED|"

# If given, check that segment type is valid
if [ -n "$segment_type" ]; then
    if (! echo "$valid_segments" | grep -q "|$segment_type|" ); then
        echo "$segment_type is an invalid segment type. Exiting..."
        exit 1
    fi
    type_clause="and segment_type = '$segment_type'"
fi

# Check if schema exists
schema_check=$("$HOME/common/oracle/CheckIfSchemaExists.sh" -v "$schema")
if [ $? -ne 0 ]; then
    echo "Error occurred while attempting to run CheckIfSchemaExists.sh. Exiting..."
    echo "$schema_check"
    exit 1
elif [ "$schema_check" != "Yes" ]; then
    echo "Error, schema $schema doesn't exist in the current database $ORACLE_SID. Exiting..."
    exit 1
fi

# Check if segment is a partition, using either the user input or the naming convention for partitions
# Partition segments are handled differently 
if [[ $segment_type =~ "PARTITION" ]] || [[ $segment =~ _PART[0-9]{4}$ ]]; then
    segment_size=$("$HOME/common/oracle/PrintSegments.sh" "$schema" "SCHEMA" "$segment_type")
    if [ $? -ne 0 ]; then
        echo "Error occurred while attempting to run PrintSegments.sh. Exiting..."
        echo "$segment_size"
        exit 1
    fi

    # Isolate segment_size from output
    segment_size=$(echo "$segment_size" | grep -v "Generating segment list for" | grep -v "Segments successfully printed for" | grep -v "Total size of segments for" | awk -v segment="$segment" '$2 == segment { print $2, $NF }')

else
    # Case for non-partition segments
    segment_size=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        set heading off
        set feedback off
        select bytes / 1024 / 1024 from dba_segments
        where owner = '$schema'
        $type_clause and segment_name = '$segment';
EOD
        )

    if [ $? -ne 0 ]; then
        echo "Error occurred while attempting to get size of segment $schema.$segment. Exiting..."
        echo "$segment_size"
        exit 1
    fi

    # Remove blank lines from the output
    segment_size=$(echo "$segment_size" | sed '/^[[:space:]]*$/d')
fi

# Check if segment exists and is unique
if [ -z "$segment_size" ]; then
    if [ -n "$segment_type" ]; then
        echo "Error, $segment_type $segment doesn't exist on schema $schema. Exiting..."
        exit 1
    else
        echo "Error, segment $segment doesn't exist on schema $schema. Exiting..."
        exit 1
    fi
elif [ "$(echo "$segment_size" | wc -l)" -gt 1 ]; then    
    echo "Error, more than one segment was found with the name $segment. Input a segment type and try again. Exiting"
    exit 1
elif [[ $segment_type =~ "PARTITION" ]] || [[ $segment =~ _PART[0-9]{4}$ ]]; then
    segment_size=$(echo "$segment_size" | awk '{print $2}')
    echo "$segment_size GB"

else
    segment_size=$(echo "$segment_size" | tr -d '[:space:]')
    echo "$segment_size MB"
fi