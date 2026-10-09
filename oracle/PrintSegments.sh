#!/bin/bash
# AvailabilityFlag: Public
#
# Purpose: This script prints a list of segments in the current or given database
#          along with the tablespace name and size in GB or optionally MB. The script
#          provides user-friendly segment names for complex segment types like LOBs,
#          partitioned objects, and system-generated constraints. The basis of the script
#          was taken from PrintPartitions.sh, which performs a similar task using
#          partitions rather than segments.
#
#####################################################################################

usage="Usage: PrintSegments.sh [ -m (optional, format output in MB (defaults to GB)) ] [schema|tablespace] [identifier (either schema or tablespace)] [ segment_type (optional, if segment type has 2 words enter it in quotes) ] [SID (optional)]"
example1="Example: PrintSegments.sh DB_SCHEMA001 schema \"INDEX PARTITION\""
example2="         PrintSegments.sh DB_L0 schema"

# Process input options
mb_opt=false
while getopts ":hm" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example1"
        echo "$example2"
        exit 0
        ;;
    m)
        mb_opt=true
        shift 1
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

# Check arguments
if [ $# -gt 4 ] || [ $# -lt 2 ]; then
    echo "$usage"
    echo "$example1"
    echo "$example2"
    exit 1
fi

# Set variables based on input
if [[ "${2^^}" =~ ^(S|SCHEMA)$ ]]; then
    schema=${1^^}
elif [[ "${2^^}" =~ ^(T|TBSP|TBLSP|TABLESPACE)$ ]]; then
    tablespace=${1^^}
else
    echo "Invalid identifier ${2}. Correct inputs are either 'schema' or 'tablespace'. Exiting..."
    exit 1
fi

valid_segments="|INDEX|TABLE|NESTED TABLE|TABLE PARTITION|CLUSTER|LOBINDEX|INDEX PARTITION|LOBSEGMENT|TABLE SUBPARTITION|INDEX SUBPARTITION|LOB PARTITION|LOB SUBPARTITION|ROLLBACK|TYPE2 UNDO|DEFERRED ROLLBACK|TEMPORARY|CACHE|SPACE HEADER|UNDEFINED|IOT|"

# Check parameter order if param # is greater than 2
sid_params=$("$HOME/common/oracle/PrintAllRunningDatabases.sh" -i -c)
if [ $? -ne 0 ]; then
    echo "$sid_params"
    echo "Error occurred running PrintAllRunningDatabases.sh. Exiting..."
    exit 1
fi
if [ $# -ge 3 ]; then
    # Check that segment type is valid
    if ( echo "$valid_segments" | grep -q "|${3^^}|" ); then
        segment=${3^^}
    elif [[ ${sid_params^^} =~ .*"${3^^}".* ]]; then
        sid=${3,,}
    else
        echo "Third parameter must be an Oracle SID or segment type. Exiting..."
        exit 1
    fi
fi
if [ $# -ge 4 ]; then
    if [[ ${sid_params^^} =~ .*"${4^^}".* ]]; then
        sid=${4,,}
    else
        echo "Fourth parameter must be an Oracle SID. Exiting..."
        exit 1
    fi
fi

# Use the segment clause if segment is specified
# Special case for IOT: we filter by index_type instead of segment_type
segment_clause=""
if [ -n "$segment" ]; then
    if [[ "$segment" == 'IOT' ]]; then
        segment_clause=" (di.index_type = 'IOT - TOP' OR di2.index_type = 'IOT - TOP') AND"
    else
        segment_clause=" ds.segment_type = '${segment}' AND"
    fi
fi

# Generate the sql for getting the size of the segment
if $mb_opt; then
    size_value="ds.bytes/1024/1024"
    size_label="MB"
else
    size_value="ds.bytes/1024/1024/1024"
    size_label="GB"
fi

# Set 'where' clauses in sqlplus blocks based on whether a schema or tablespace was inputted
if [ -n "$schema" ]; then
    where_order_clause="where${segment_clause} ds.owner = '${schema}'
    order by owner,
    CASE
    WHEN \"Size in $size_label\" = 'RO TBSP: Not Loaded' THEN 0
    ELSE TO_NUMBER(\"Size in $size_label\")
    END DESC NULLS LAST"
    where_clause="WHERE owner = '${schema}'"
elif [ -n "$tablespace" ]; then
    where_order_clause="where${segment_clause} ds.tablespace_name = '${tablespace}'
order by tablespace_name,
    CASE
    WHEN \"Size in $size_label\" = 'RO TBSP: Not Loaded' THEN 0
    ELSE TO_NUMBER(\"Size in $size_label\")
    END DESC NULLS LAST"
    where_clause="WHERE tablespace_name = '${tablespace}'"
fi

# Exclude SYS schema from being used. The SYS schema causes discrepancies in the output, so it isn't compatible here
if [[ "$schema" == *"SYS"* ]]; then
    echo "This script should not be run on SYS schemas (was run on $schema). Exiting..."
    exit 1
fi

# Exclude SYS tablespaces from being used.
if [[ "$tablespace" == *"SYS"* ]]; then
    echo "This script should not be run on SYS tablespaces (was run on $tablespace). Exiting..."
    exit 1
fi

# If user didn't provide a SID, check that an ORACLE_SID is set
if [ -z "$sid" ]; then
    # Check if $ORACLE_SID is set
    sid=$ORACLE_SID
else
    # Otherwise, export ORACLE_SID as provided SID
    export ORACLE_SID=$sid
fi

# Verify SID validity
sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
if [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "Error, \$ORACLE_SID not set..."
        exit 1
    fi
    echo "Error, provided \$ORACLE_SID is not open. Exiting..."
    exit 1
fi

if [ -n "$schema" ]; then
    # Check that schema exists
    schema_exists=$("$HOME/common/oracle/CheckIfSchemaExists.sh" -v "$schema")
    schema_error=$?

    if [ $schema_error -ne 0 ]; then
        echo "Error occurred while attempting to find schema $schema in $sid."
        echo "$schema_exists"
        echo "Exiting..."
        exit 1
    elif [ "$schema_exists" != "Yes" ]; then
        echo "Schema $schema does not exist in $sid. Exiting..."
        exit 1
    else
        echo "Generating segment list for schema $schema on $sid."
    fi
elif [ -n "$tablespace" ]; then
    # Check that tablespace exists
    tbsp_exists=$("$HOME/common/oracle/CheckIfTablespaceExists.sh" "$tablespace")
    tbsp_error=$?

    if [ $tbsp_error -ne 0 ]; then
        echo "Error occurred while checking if tablespace $tablespace exists in $sid."
        echo "$tbsp_exists"
        echo "Exiting..."
        exit 1
    elif [ "$tbsp_exists" != "Yes" ]; then
        echo "Tablespace $tablespace does not exist in $sid. Exiting..."
        exit 1
    else
        echo "Generating segment list for tablespace $tablespace on $sid."
    fi
fi


# Execute Oracle query
print_result=$(
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set pagesize 10000
    set linesize 175
    set feedback off
    column owner format a15
    column segment_name format a65
    COLUMN segment_type FORMAT a15
    column index_type format a10
    column tablespace_name format a30
    column 'Size in $size_label' format a19

    SELECT DISTINCT
        ds.owner,
        /* Construct SEGMENT_NAME based on the following cases */
        CASE
            /* Non partitioned LOB segment */
            WHEN ds.segment_type = 'LOBSEGMENT' THEN COALESCE(dl.table_name, dl2.table_name) ||'.'||COALESCE(dl.column_name, dl2.column_name)
            /* Non partitioned LOB index */
            WHEN ds.segment_type = 'LOBINDEX' THEN COALESCE(dl.table_name, dl2.table_name) ||'.'||COALESCE(dl.column_name, dl2.column_name)
            /* Partitioned LOB segment */
            WHEN ds.segment_type = 'LOB PARTITION' THEN COALESCE(dlp.table_name, dlp2.table_name) ||'.'||COALESCE(dlp.partition_name, dlp2.partition_name)
            /* Partitioned Tables */
            WHEN ds.segment_type = 'TABLE PARTITION' THEN ds.segment_name ||'.'||ds.partition_name
            /* Partitioned Indexes w/o LOBs */
            WHEN (ds.segment_type = 'INDEX PARTITION' AND COALESCE(di.index_type, di2.index_type)!='LOB')
                THEN ds.segment_name ||'.'||ds.partition_name
            /* Partitioned LOB index */
            WHEN (ds.segment_type = 'INDEX PARTITION' AND COALESCE(di.index_type, di2.index_type)='LOB')
                THEN COALESCE(dlp.table_name, dlp2.table_name) ||'.'||COALESCE(dlp.partition_name, dlp2.partition_name) || '.LOBINDEX'
            /* System identified Primary Key constraint */
            WHEN ds.segment_name like 'SYS_C%' THEN COALESCE(di.table_name, di2.table_name) ||'.'||COALESCE(di.index_name, di2.index_name) || '__(UNNAMED_SEGMENT)'
            ELSE ds.segment_name
        END SEGMENT_NAME,
        ds.segment_type,
        ds.tablespace_name,
        COALESCE(di.index_type, di2.index_type) as index_type,
        CASE
            WHEN ds.bytes IS NULL THEN 'RO TBSP: Not Loaded'
            ELSE TO_CHAR(round($size_value))
        END "Size in $size_label"
    FROM dba_segments ds
    /* First partitioned LOB join checks for segments that are LOB partitions. */
    LEFT OUTER JOIN dba_lob_partitions dlp
        ON (ds.segment_type IN ('LOB PARTITION','INDEX PARTITION')
        AND ds.owner = dlp.table_owner
        AND ds.partition_name = dlp.lob_partition_name)
    /* Second partitioned LOB join checks for segments that are LOB indexes. */
    LEFT OUTER JOIN dba_lob_partitions dlp2
        ON (ds.segment_type IN ('LOB PARTITION','INDEX PARTITION')
        AND ds.owner = dlp2.table_owner
        AND ds.partition_name = dlp2.lob_indpart_name)
    /* First index join checks for segments that are indexes (non-partitioned). */
    LEFT OUTER JOIN dba_indexes di
        ON (ds.segment_type = 'INDEX' AND ds.segment_name = di.index_name)
    /* Second index join checks for segments that are partitioned indexes */
    LEFT OUTER JOIN dba_indexes di2
        ON (ds.segment_type = 'INDEX PARTITION'
            AND di2.index_name = (SELECT index_name FROM dba_ind_partitions
                                WHERE index_name = ds.segment_name
                                AND partition_name = ds.partition_name
                                AND index_owner = ds.owner))
    /* First unpartitioned LOB join checks for LOB SEGMENTS */
    LEFT OUTER JOIN dba_lobs dl
        ON (ds.segment_name = dl.segment_name AND ds.segment_type = 'LOBSEGMENT' AND ds.owner = dl.owner)
    /* Second unpartitioned LOB join checks for LOB INDEXES. */
    LEFT OUTER JOIN dba_lobs dl2
        ON (ds.segment_name = dl2.index_name AND ds.segment_type = 'LOBINDEX' AND ds.owner = dl2.owner)
    ${where_order_clause};
    exit;
EOD
)
if [ $? -ne 0 ]; then
    echo "$print_result"
    echo "An error occurred while listing segments. See above output for more details. Exiting..."
    exit 1
fi

# Check if the above block produced an output
if [ -z "$print_result" ]; then
    # If not, print to the user and exit
    if [ -z "$segment" ]; then
        if [ -n "$schema" ]; then
            echo "0 segments found for schema $schema"
        elif [ -n "$tablespace" ]; then
            echo "0 segments found for tablespace $tablespace"
        fi
    else
        if [ -n "$schema" ]; then
            echo "0 segments of type '$segment' found for schema $schema"
        elif [ -n "$tablespace" ]; then
            echo "0 segments of type '$segment' found for tablespace $tablespace"
        fi
    fi
    exit 0
else
    echo "$print_result"
fi


# Reconfigure segment clause for total size calculation (simpler logic without joins),
# so the join logic needs to be introduced into the WHERE clause.
if [ -n "$segment" ]; then
    if [[ "$segment" == "IOT" ]]; then
        segment_clause="AND segment_name IN (SELECT ds.segment_name FROM dba_segments ds
        JOIN dba_indexes di ON di.index_name = ds.segment_name WHERE di.index_type='IOT - TOP')"
    else
        segment_clause="AND segment_type = '$segment'"
    fi
fi

# Calculate total size of segments
total_size=$(
    "$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever oserror exit 1
    whenever sqlerror exit 1
    set heading off
    set feedback off
    SELECT round(sum($size_value))
    FROM dba_segments ds
    ${where_clause}
    ${segment_clause};
    exit;
EOD
)
# Check exit status of Oracle query
if [ $? -ne 0 ]; then
    echo "$total_size"
    echo "Error occurred while getting total size of all segments. Exiting..."
    exit 1
else
    # Remove whitespace
    total_size=$(echo "$total_size" | xargs)
    if [ -n "$schema" ]; then
        echo "Segments successfully printed for schema ${schema} on ${sid}."
        echo ""
        echo "Total size of ${segment:-ALL} segments for schema ${schema}: ${total_size} $size_label."
    elif [ -n "$tablespace" ]; then
        echo "Segments successfully printed for tablespace ${tablespace} on ${sid}."
        echo ""
        echo "Total size of ${segment:-ALL} segments for tablespace ${tablespace}: ${total_size} $size_label."
    fi
    exit 0
fi
