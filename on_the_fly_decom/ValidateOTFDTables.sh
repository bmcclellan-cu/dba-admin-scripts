#!/bin/bash
#
# Purpose:  Validates OTFD Metadata tables for invalid data or inconsistencies
#           between tables.
# 
# Notes:    This script does not validate system_id or OTFD version, as that would require repeatedly updating
#           this script with a hardcoded set of values, as OTFD does not have an API to validate 
#           SID alone. If the calls to getTableName or getDecomIdentifier fail, it is most likely due to 
#           a mismatch in one of these values.
# 
# Checks:
#           - packet_length: Checks if any of the packets in L0_Packets will be too small
#                          to be decommuted by their corresponding TMDecom map. 
#                          WARNING: This test requires an almost full scan of the L0_Packets table
#                          and may take a long time to complete if the -r flag is used. Otherwise, the 
#                          test only looks at online partitions of the L0_Packets table.
# 
#           - length_gt_64: Checks that none of the individual telemetry items in TMDecom indicates
#                           a length greater than 64 bits, as this will cause OTFD to fail.
# 
#           - tsl_L0_tmdecom: Checks that TSL entries pointing to L0 also have corresponding TMDecom 
#                             rows.
# 
#           - tmdecom_L0_tsl: Checks that, for every TMDecom entry, there is a tsl entry with isInL0 set to 1.
#                             If this is not the case, the TMDecom entry will be unused by OTFD.
# 
#           - data_before_tsl: Checks if data exists before the first TSL entry which would be inaccessible
#                              to OTFD.
# 
#
# Author: Robert Schmidt
#
# Created on: May 21st, 2026
# Last Modified: June 29th, 2026 - CS
##########################################################################

usage="Usage: nohup ./ValidateOTFDTables.sh [ -d (optional, dryrun tests) ] [ -r (optional, include read-only L0 partitions) ] [ system_id ] [ ORACLE_SID ] [ tests_list (optional (default ALL), csv of tests to run, see header or check -d option) ]"
example="Example: nohup ./ValidateOTFDTables.sh 19 emadev"

# Process input options
dryrun=0
allow_readonly=0

while getopts ":hdr" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    d)
        dryrun=1
        ;;
    r)
        allow_readonly=1
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

shift "$((OPTIND - 1))"

# Check arguments
if [ $# -ne 2 ] && [ $# -ne 3 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

system_id="$1"
export ORACLE_SID="${2,,}"
tests_list="$3"

if ! [[ "$system_id" =~ ^[0-9]+$ ]]; then
    echo "Error: system_id must be a number. Exiting..."
    exit 1
fi

# Checking ORACLE_SID
sid_check=$("$HOME/common/oracle/VerifyAllParam.sh" -I)
if [ $? -ne 0 ]; then
    echo "Error occurred when checking ORACLE_SID. Exiting..."
    exit 1
elif [ -n "$sid_check" ]; then
    if [ "$sid_check" == "-1" ]; then
        echo "Error, \$ORACLE_SID not set..."
        exit 1
    fi
    echo "Error, provided ORACLE_SID $ORACLE_SID is not open. Exiting..."
    exit 1
fi

# Input validation complete, logging time
pre_validation_timestamp="$(date "+%Y-%m-%d %H:%M:%S")"
echo
echo "Input validation completed for ValidateOTFDTables at ${pre_validation_timestamp}"
echo "Starting testing:"
echo
# Get mission-specific schema names

# Gets name of MISC schema while skipping VerifyAllParam.sh input validation call
misc_schema=$("$HOME/common/oracle/GetSchemaName.sh" -m -v)
if [ $? -ne 0 ] || [ -z "$misc_schema" ]; then
    echo "$misc_schema"
    echo "Error occurred while getting MISC schema name for $ORACLE_SID. Exiting..."
    exit 1
fi

# Gets name of CT schema while skipping VerifyAllParam.sh input validation call
ct_schema=$("$HOME/common/oracle/GetSchemaName.sh" -c -v)
if [ $? -ne 0 ] || [ -z "$ct_schema" ]; then
    echo "$ct_schema"
    echo "Error occurred while getting CT schema name for $ORACLE_SID. Exiting..."
    exit 1
fi

# Call getTableName to get the correct table names. Type_in maps to tables as follows:
#  0 -> L0_Packets
#  1 -> TMAnalog
#  2 -> TMDiscrete
#  3 -> TelemetryStorageLocation
#  4 -> TMDecom
#  5 -> TelemetryItemDefinition
tableNames=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever sqlerror exit 1
    whenever oserror exit 1
    set heading off feedback off
    set serveroutput on

    BEGIN
        DBMS_OUTPUT.PUT_LINE($misc_schema.onTheFlyDecomMissionSpecific.getTableName(type_in => 0, systemId_in => $system_id));
        DBMS_OUTPUT.PUT_LINE($misc_schema.onTheFlyDecomMissionSpecific.getTableName(type_in => 1, systemId_in => $system_id));
        DBMS_OUTPUT.PUT_LINE($misc_schema.onTheFlyDecomMissionSpecific.getTableName(type_in => 2, systemId_in => $system_id));
        DBMS_OUTPUT.PUT_LINE($misc_schema.onTheFlyDecomMissionSpecific.getTableName(type_in => 3, systemId_in => $system_id));
        DBMS_OUTPUT.PUT_LINE($misc_schema.onTheFlyDecomMissionSpecific.getTableName(type_in => 4, systemId_in => $system_id));
        DBMS_OUTPUT.PUT_LINE($misc_schema.onTheFlyDecomMissionSpecific.getTableName(type_in => 5, systemId_in => $system_id));
    END;
    /
EOD
)
exit_code=$?
# Check for user defined exception error that comes from getTableName
# If more exceptions ever get added to getTableName besides invalidType
# This condition will need to be updated. 
if (echo "$tableNames" | grep -q "ORA-06510"); then
    echo "On the fly decom appears to be out of date. onTheflyDecomMissionSpecific.getTableName for $ORACLE_SID does not have entries for all tables required by this script. Upgrade OTFD and run again."
    echo "Exiting..."
    exit 1
elif [ "$exit_code" -ne 0 ]; then
    echo "$tableNames"
    echo "An error occurred while querying OTFD for table names. Ensure that you are validating a system_id OTFD supports and that OTFD is updated to the latest version. Exiting..."
    exit 1
# Check that exactly 6 items are returned from the query
elif [ "$(echo "$tableNames" | wc -w)" -ne 6 ]; then
    echo "$tableNames"
    echo "ERROR: Query for table names returned an incorrect number of results. Please check above output for more details. Exiting..."
    exit 1
fi

# Compact all whitespace so table names are space-delimited then split into variables
tableNames=$(echo "$tableNames" | xargs)

# Pipe contents of tableNames into read, which splits the variable contents using IFS into the specified variable names. 
# -r option will treat \ as literal, not escape characters.
read -r L0_packets_name tmanalog_name tmdiscrete_name tsl_name tmdecom_name telemetry_item_definition_name <<< "$tableNames"
# Get the table owner before the '.'
TABLE_OWNER_uncased="${L0_packets_name%%.*}"
# Uppercase table owner (schema)
TABLE_OWNER="${TABLE_OWNER_uncased^^}"
# Get the table name after the '.'
L0_TABLE_uncased="${L0_packets_name##*.}"
# Uppercase table name
L0_TABLE="${L0_TABLE_uncased^^}"

# Call getDecomIdentifier to get the decom identifier for the database
decom_id=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
    whenever sqlerror exit 1
    whenever oserror exit 1
    set heading off feedback off

    set serveroutput on

    BEGIN
        DBMS_OUTPUT.PUT_LINE($misc_schema.onTheFlyDecomMissionSpecific.getDecomIdentifier());
    END;
    /
EOD
)
if [ $? -ne 0 ]; then
    echo "$decom_id"
    echo "An error occurred while querying OTFD for the decom identifier. Ensure that you are validating a system_id OTFD supports and that OTFD is updated to the latest version. Exiting..."
    exit 1
fi

# Trim whitespace
decom_id=$(echo "$decom_id" | xargs)

if [[ -z "$decom_id" ]]; then
    echo "Failed to get decom identifier for the database. Exiting..."
    exit 1
fi

# Cannot call getDefinitionStartStopTimes due to requiring a timestamp input, which will vary between databases.
# Hardcoding definition_time_column into if statement. Additionally, only specify SID for ixpe.
sid_clause=""
if [[ "$ORACLE_SID" == "ixpe"* ]]; then
    definition_time_column="ERT"
    sid_clause=" AND SYSTEMID=$system_id"
    qualified_tsl_sid_clause=" AND tsl.SYSTEMID=$system_id"
elif [[ "$ORACLE_SID" == "ema"* ]]; then
    definition_time_column="ASCT"
elif [[ "$ORACLE_SID" == "neos"* ]]; then
    definition_time_column="ERT"
else
    echo "ERROR: Database $ORACLE_SID is not supported by OnTheFlyDecom (supported: ixpe*,ema*,neos*). Exiting..."
    exit 1
fi

# The SQL in the tests defined below are all intended to be queries that return table anomalies. As such, if no rows are
# returned, the test succeeds, if any data is returned, the test fails.

exit_status=0

# Dictionaries that map test names to: The SQL being run, a description of the test, and a relative ranking of duration, 
# with longer duration being a lower rank to ensure the quicker tests run first by default (duplicate ranks are acceptable).
declare -A TEST_SQL
declare -A TEST_DESCRIPTION
declare -A TEST_WEIGHT

# Check for invalid TMDecom entries (LENGTH > 64)
TEST_SQL[length_gt_64]=$(cat <<SQL
    SELECT '    TLMID ' || tlmid || ' (' || '${decom_id}' || ' ' || ${decom_id} || ', SID=$system_id): Decom map length ' || length || ' exceeds 64 bits.'
    FROM ${tmdecom_name}
    WHERE length > 64 $sid_clause
    GROUP BY tlmid, ${decom_id}, length
    ORDER BY tlmid, ${decom_id};
SQL
)
TEST_DESCRIPTION[length_gt_64]="Checks if any entries in TMDecom have LENGTH values greater than 64 bits, as such decom maps will cause OTFD to fail."
TEST_WEIGHT[length_gt_64]=1

# This variable is a space-delimited string that tracks the online L0 partitions, defaults to NONE
online_L0_partitions_and_tables="NONE"

# We will only find online partitions if the packet_length test is specified to run, either because 'tests_list' is empty 
# implying that ALL tests will run or 'packet_length' is specified in 'tests_list'
if [ -z "$tests_list" ] || [[ "$tests_list" == *packet_length* ]]; then

    # The default behavior is to enter this conditional when the packet_length test is specified to run
    # We only skip this conditional when -r flag is set, which means we include read-only partitions in our packet_length search
    if [ "$allow_readonly" -eq 0 ]; then
        
        # Get the L0_PACKET partition names that have owner (schema) as 'TABLE_OWNER' which comes from 'L0_packets_name'
        # The L0_PACKET partitions must be online (not read-only).
        # Querying for partitions with 'L0_PACKETS' in their name and are owned by the schema 'TABLE_OWNER'. We are doing this because 'L0_TABLE' name does not always match with
        # 'TABLE_NAME' from dba_lob_partitions when 'L0_TABLE' is a view.
        online_L0_partitions_and_tables_raw=$("$ORACLE_HOME"/bin/sqlplus -s / as sysdba <<EOD
            whenever oserror exit 1
            whenever sqlerror exit 1

            set feedback off
            set heading off
            set pagesize 0
            set linesize 2000

            SELECT tp.PARTITION_NAME,tp.TABLE_NAME FROM dba_lob_partitions tp JOIN DBA_TABLESPACES dba ON dba.TABLESPACE_NAME = tp.TABLESPACE_NAME WHERE dba.STATUS = 'ONLINE' 
            AND tp.TABLE_OWNER='${TABLE_OWNER}' 
            AND tp.PARTITION_NAME like '%L0_PACKETS%' AND tp.table_name NOT LIKE 'SYS_IOT_OVER%'
            ORDER BY tp.partition_name;

            exit;
EOD
)

        if [ $? -ne 0 ]; then
            echo "$online_L0_partitions_and_tables_raw"
            echo "An error occurred while finding online L0 packet partitions and tables"
            exit 1
        fi

        online_L0_partitions_and_tables=$(echo "$online_L0_partitions_and_tables_raw" | xargs)

        # If there are no online partitions, then default to a full L0_Packet search
        if [ -z "$online_L0_partitions_and_tables" ]; then
            online_L0_partitions_and_tables="NONE"
        fi

    fi
fi

# Array that stores partition specific queries for testing L0_packet length
declare -a LENGTH_TEST_QUERY

partition_template=""
table_template="$L0_TABLE"

# Indicates if the loop variable is a partition or a table
# partition_or_table=0 -> Loop variable is partition
# partition_or_table=1 -> Loop variable is table
# This is important because 'online_L0_partitions_and_tables' holds the names of the tables that are partitioned as well as the partitions
# By specifying the table and the partition we avoid the possibility of using partition-extended name syntax with objects which are not tables (ORA-14109)
partition_or_table=0

# If there are no online partitions, or a full scan of L0 packets was requested, then online_L0_partitions_and_tables=NONE
# In that case where online_L0_partitions_and_tables=NONE, we create one query in the loop for the whole L0 packets table
for object in $online_L0_partitions_and_tables; do

    if [[ "$object" != "NONE" ]]; then
        if [ $partition_or_table -eq 0 ]; then
            partition_template="PARTITION (${object})"
            partition_or_table=1
            continue
        else
            table_template="$object"
            partition_or_table=0
        fi
    fi

    # Scan L0_Packets for packets that are not long enough, accounting for time-variant TMDecom entries.
    # Does not take into account whether the TMDecom entry is accessible through TSL or not.
    # Appending this query to a list separated by '~' for later execution
    LENGTH_TEST_QUERY+=( "$(cat <<SQL
    -- CTE (Common Table Expression) returning each decom map, along with when it becomes superseded by the next map.
    WITH tmdecom_with_ranges AS (
        SELECT
            TLMID,
            ${decom_id},
            STARTBIT,
            LENGTH,
            DEFINITIONSTART,
            -- This gets the value of DEFINITIONSTART of the next decom map, identified by TLMID + DMID.
            LEAD(DEFINITIONSTART) OVER (
                PARTITION BY TLMID, ${decom_id}
                ORDER BY DEFINITIONSTART ASC
            ) AS DEFINITIONSTOP
        FROM ${tmdecom_name}
        -- 1=1 ensures that we don't have an extra leading AND in the query
        WHERE 1=1 $sid_clause
    )
    SELECT /*+ PARALLEL */ '    TLMID ' || d.TLMID || ' (${decom_id} ' || d.${decom_id} || ', SID=$system_id' ||
    '): Datatype=' || t.DATATYPE || ', Startbit=' || d.STARTBIT || ', Length=' || d.LENGTH || 
    ' out of range of min packet length ' || min(p.LENGTH * 8) || '. Max packet length is ' || max(p.LENGTH * 8)
    FROM (
        tmdecom_with_ranges d
        JOIN ${TABLE_OWNER}.${table_template} ${partition_template} p ON p.${decom_id} = d.${decom_id}
            -- Join packets only to decom maps valid at the packet timestamp.
            AND p.${definition_time_column} >= d.DEFINITIONSTART
            AND (d.DEFINITIONSTOP IS NULL OR p.${definition_time_column} < d.DEFINITIONSTOP)
    )
    LEFT JOIN ${telemetry_item_definition_name} t ON t.TLMID=d.TLMID
    -- Flag packets too small to contain the decom map definition.
    WHERE p.LENGTH * 8 < (d.STARTBIT + d.LENGTH)
    GROUP BY d.tlmid, d.${decom_id}, d.STARTBIT, d.LENGTH, t.DATATYPE
    ORDER BY d.tlmid, d.${decom_id};
SQL
)~" )

done

# Key-value pair, all the queries testing packet_length are matched to the 'packet_length' key
temp_length="${LENGTH_TEST_QUERY[*]}"
# Remove the trailing '~'
TEST_SQL[packet_length]="${temp_length::-1}"

TEST_DESCRIPTION[packet_length]="Checks if any of the packets in L0_Packets will be too small to be decommuted by their corresponding TMDecom map. 
Test failure indicates one of the following:
    1. The STARTBIT column for the TMDecom entry is too large.
    2. The LENGTH column for the TMDecom entry is too large.
    3. One or more of the packets in L0_Packets for that DMID is too small.

WARNING: This test requires a full scan of the L0_Packets table if the -r flag is provided. This may take some time to complete"

if [[ $online_L0_partitions_and_tables == "NONE" ]] && [ "$allow_readonly" -eq 0 ]; then
    TEST_DESCRIPTION[packet_length]="Checks if any of the packets in L0_Packets will be too small to be decommuted by their corresponding TMDecom map. 
Test failure indicates one of the following:
    1. The STARTBIT column for the TMDecom entry is too large.
    2. The LENGTH column for the TMDecom entry is too large.
    3. One or more of the packets in L0_Packets for that DMID is too small.

WARNING: ${L0_packets_name} does not have online partitions. Continuing...
Defaulting to searching all of ${L0_packets_name}"

fi

TEST_WEIGHT[packet_length]=5

# Check that every TSL row with isInL0=1 has a corresponding TMDecom row (tlmid + dmid foreign key)
TEST_SQL[tsl_L0_tmdecom]=$(cat <<SQL
    SELECT '        TLMID ' || TLMID || '($decom_id ' || $decom_id || ', SID=$system_id): TSL Entry (DefinitionStart=' || DEFINITIONSTART || 
    ', SID=$system_id' || ', isInL0=1) No matching TMDecom entry found for L0 TSL Entry.'
    FROM
    $tsl_name tsl
    WHERE isInL0=1 AND NOT EXISTS (
        SELECT 1 FROM $tmdecom_name tmd WHERE tmd.TLMID=tsl.TLMID AND tmd.$decom_id=tsl.$decom_id AND tmd.DEFINITIONSTART <= tsl.DEFINITIONSTART
    ) $sid_clause;
SQL
)
TEST_DESCRIPTION[tsl_L0_tmdecom]="Checks for TSL (TelemetryStorageLocation) entries with isInL0=1 without corresponding TMDecom rows (rows that
come into effect at the same time or before the TSL entry). If such a row is not present, then OTFD will not return data for that TLMID until such
a row comes into effect."
TEST_WEIGHT[tsl_L0_tmdecom]=2


# Check that every TMDecom row has a corresponding TSL row with isInL0=1 (tlmid + dmid foreign key)
TEST_SQL[tmdecom_L0_tsl]=$(cat <<SQL
    SELECT '        TLMID ' || TLMID || '($decom_id ' || $decom_id || ', SID=$system_id): TMDecom Entry (DefinitionStart=' || DEFINITIONSTART || 
    ', SID=$system_id) No matching L0 TSL Entry found for TMDecom row.'
    FROM
    $tmdecom_name tmd
     -- Get the most recent TSL Entry applicable for this decom map and check if it is pointing to L0.
     -- If query returns NULL, then flag TSL row.
    WHERE NVL((
        SELECT tsl.isInL0 FROM $tsl_name tsl WHERE 
        tsl.TLMID=tmd.TLMID AND tsl.$decom_id=tmd.$decom_id AND tsl.DEFINITIONSTART <= tmd.DEFINITIONSTART
        ORDER BY DEFINITIONSTART DESC
        FETCH NEXT 1 ROW ONLY
    ), 0) != 1
    $sid_clause;
SQL
)

TEST_DESCRIPTION[tmdecom_L0_tsl]="Checks for TMDecom entries without corresponding TSL (TelemetryStorageLocation) rows (rows that
come into effect at the same time or before the TMDecom entry). If such a row is not present, then OTFD will never access the TMDecom
entry and will never utilize that decom map until such a TSL row comes into effect."
TEST_WEIGHT[tmdecom_L0_tsl]=2

# Get the earliest TSL (TelemetryStorageLocation) rows for each TMID + DMID and check if data exists before that TSL row comes into effect. 
# Only checks for data from where the TSL row already maps to:

# TSL Rows are evaluated as follows:
# isInL1:
#   Datatype='D'                -> TMDiscrete
#   Datatype in ('F', 'I', 'U') -> TMAnalog
# isInL0:
#   Always -> L0_Packets
TEST_SQL[data_before_tsl]=$(cat <<SQL
     -- CTE (Common Table Expression) which returns all TSL rows, as well as "indexing" them by order of earliest to latest
    WITH earliest_tsl AS (
            SELECT
                tsl.TLMID,
                tsl.${decom_id},
                tsl.DEFINITIONSTART,
                tsl.isInL1,
                tsl.isInL0,
                t.DATATYPE,
                 -- Returns the index for each row when partitioned by TLMID and DMID and sorted by 
                 -- DEFINITIONSTART, from earliest TSL entry to latest.
                 -- Note: The WHERE clause is evaluated before this function gets computed, so filtering
                 --       must be done in a separate CTE.
                ROW_NUMBER() OVER (
                        PARTITION BY tsl.TLMID, tsl.${decom_id}
                        ORDER BY tsl.DEFINITIONSTART ASC
                ) AS rn
            FROM $tsl_name tsl
            LEFT JOIN $telemetry_item_definition_name t ON t.TLMID = tsl.TLMID
             -- 1=1 ensures we don't have a leading AND in the query.
            WHERE 1=1 $qualified_tsl_sid_clause
    ),
     -- Filter the TSL rows such that we are only left with the earliest, partitioned by TLMID and DMID.
    first_tsl AS (
            SELECT * FROM earliest_tsl WHERE rn = 1
    )
     -- Check TMDiscrete for any data before the earliest TSL rows that map to TMDiscrete.
    SELECT /*+ PARALLEL */ '        TLMID ' || f.TLMID || '(${decom_id} ' || f.${decom_id} || ', SID=$system_id): Data exists in ${tmdiscrete_name} before earliest TSL (DefinitionStart=' || f.DEFINITIONSTART || ').'
    FROM first_tsl f
    WHERE f.isInL1 = 1
        AND f.DATATYPE = 'D'
        AND EXISTS (
                SELECT 1 FROM ${tmdiscrete_name} tmdiscrete
                WHERE tmdiscrete.TMID = f.TLMID
                    AND tmdiscrete.${definition_time_column} < f.DEFINITIONSTART
        )
    UNION ALL
    -- Check TMAnalog for any data before the earliest TSL rows that map to TMAnalog
    SELECT /*+ PARALLEL */ '        TLMID ' || f.TLMID || '(${decom_id} ' || f.${decom_id} || ', SID=$system_id): Data exists in ${tmanalog_name} before earliest TSL (DefinitionStart=' || f.DEFINITIONSTART || ').'
    FROM first_tsl f
    WHERE f.isInL1 = 1
        AND (f.DATATYPE in ('F', 'I', 'U'))
        AND EXISTS (
                SELECT 1 FROM ${tmanalog_name} tmanalog
                WHERE tmanalog.TMID = f.TLMID
                    AND tmanalog.${definition_time_column} < f.DEFINITIONSTART
        )
     -- Check L0_Packets for any data before the earliest TSL rows that map to L0_Packets
    UNION ALL
    SELECT /*+ PARALLEL */ '        TLMID ' || f.TLMID || '(${decom_id} ' || f.${decom_id} || ', SID=$system_id): Data exists in ${L0_packets_name} before earliest TSL (DefinitionStart=' || f.DEFINITIONSTART || ').'
    FROM first_tsl f
    WHERE f.isInL1 != 1
        AND f.isInL0 = 1
        AND EXISTS (
                SELECT 1 FROM ${TABLE_OWNER}.${L0_TABLE} L0
                WHERE L0.${decom_id} = f.${decom_id}
                    AND L0.${definition_time_column} < f.DEFINITIONSTART
        );
SQL
)

TEST_DESCRIPTION[data_before_tsl]="Checks if data (L0_Packets, TMDiscrete, or TMAnalog rows) is present before the first 
TSL (TelemetryStorageLocation) entry for a given TLMID+DMID combination. For example, if the first TSL entry points to 
L0_Packets and has DEFINITIONSTART=01-JAN-25, then any data present in L0_Packets before that timestamp will be invisible
to OTFD and queries to those times will return no rows."
TEST_WEIGHT[data_before_tsl]=4

declare -a tests_to_run

# Check that inputted tests actually correspond to known tests. If no input was given, run all tests.
if [ -n "$tests_list" ]; then
    # Read the contents of tests_list and comma-split into the array tests_to_run.
    IFS=',' read -r -a tests_to_run <<< "$tests_list"
    for test_name in "${tests_to_run[@]}"; do
        if [ -z "${TEST_SQL[$test_name]}" ]; then
            echo "Test $test_name does not exist. Exiting..."
            exit 1
        fi
    done
else
    # Iterate through all tests and store a newline-separated string prefixing them with their weights.
    temp_weights=""
    for k in "${!TEST_WEIGHT[@]}"; do
        temp_weights+="${TEST_WEIGHT[$k]} $k
"
    done
    # Sort the results from smallest to largest numerically (-n option) and then remove the weights
    # and compact to be space-separated.
    tests_list_sorted=$(echo "$temp_weights" | sort -n | awk '{print $2}' | xargs)
    # Read results into an array, using default bash IFS separation.
    read -r -a tests_to_run <<< "$tests_list_sorted"
fi

for test_name in "${tests_to_run[@]}"; do
    
    loop_error=0
    echo "Running test $test_name."
    echo "${TEST_DESCRIPTION[$test_name]}"
    echo

    if [ "$dryrun" -eq 1 ]; then
        echo "DRYRUN: Query for test $test_name:"
        if [ "$test_name" == "packet_length" ] && [[ "$online_L0_partitions_and_tables" != "NONE" ]]; then
            # Restoring indexed array from '~' separated string (-d '' reads until the null byte)
            IFS="~" read -r -d '' -a RESTORED <<< "${TEST_SQL[$test_name]}"
            for query in "${RESTORED[@]}"; do
                echo "${query}"
            done
        else
            echo "${TEST_SQL[$test_name]}"
            echo
        fi

        continue
    fi

    save_test_output=""
    # When the packet_length test is testing by partition, enter this conditional
    if [ "$test_name" == "packet_length" ] && [[ "$online_L0_partitions_and_tables" != "NONE" ]]; then
        # Restoring indexed array from '~' separated string (-d '' reads until the null byte)
        IFS="~" read -r -d '' -a RESTORED <<< "${TEST_SQL[$test_name]}"
        for query in "${RESTORED[@]}"; do
            test_output=""
            # get the partition name from the PARTITION (....) by matching on 'PARTITION ( ' and then 
            # reset the match and get the partition name which is one or more characters that are not space
            get_partition=$(echo "$query" | grep -oP 'PARTITION \(\s*\K[^)\s]+')
            echo "Running $test_name for partition $get_partition"
            test_output=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
            whenever oserror exit 1
            whenever sqlerror exit 1
            set heading off
            set feedback off
            set pagesize 0
            set linesize 2000

            ${query}
EOD
    )
            if [ $? -ne 0 ]; then
                exit_status=1
                loop_error=1
                echo "$test_output"
                echo "An error occurred while running test $test_name on partition $get_partition. See error output and test description above. Continuing to next partition..."
                continue
            fi

            if [[ -n "$test_output" ]]; then
                exit_status=1
                loop_error=1
                echo "FAILURE: $test_name failed for partition $get_partition see below for details"
                echo "$test_output"
                echo
            fi

        done
    else 
        save_test_output=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
        whenever oserror exit 1
        whenever sqlerror exit 1
        set heading off
        set feedback off
        set pagesize 0
        set linesize 2000

        ${TEST_SQL[$test_name]}
EOD
)
        if [ $? -ne 0 ]; then
            exit_status=1
            loop_error=1
            echo "$save_test_output"
            echo "An error occurred while running test $test_name. See error output and test description above."
            continue
        fi

        if [[ -n "$save_test_output" ]]; then
            exit_status=1
            loop_error=1
            echo "$save_test_output"
        fi
    fi

    if [ "$loop_error" -ne 0 ]; then
        echo
        echo "FAILURE: Test $test_name returned one or more anomalies, see test output and description above. Continuing to next test..."
    else
        echo
        echo "SUCCESS: Test $test_name found no anomalies. Continuing to next test..."
    fi
done

# Record timestamp to be used to calculate time elapsed during validation
post_validation_timestamp="$(date "+%Y-%m-%d %H:%M:%S")"

# Calculate elapsed time
time_elapsed=$("$HOME/common/general/ComputeTimeGap.sh" "$pre_validation_timestamp" "$post_validation_timestamp")
if [ $? -ne 0 ]; then
    echo
    echo "Error occurred while computing time gap between $pre_validation_timestamp and $post_validation_timestamp:" 
    echo "$time_elapsed" 
    exit 1
fi

if [ "$dryrun" -eq 1 ]; then
    echo
    echo "Dryrun completed successfully at ${post_validation_timestamp}"
    echo "Time taken for dryrun:${time_elapsed}"
    echo "No queries executed. Exiting..."
    exit 0
fi

if [ "$exit_status" -ne 0 ]; then
    echo
    echo "Script completed with errors at ${post_validation_timestamp}"
    echo "Time taken for validation:${time_elapsed}"
    echo "One or more tests failed/errored, please see above output for more details. Exiting..."
    exit 1
else
    echo
    echo "Script completed successfully at ${post_validation_timestamp}"
    echo "Time taken for validation:${time_elapsed}"
    echo "No anomalies or errors encountered. Exiting..."
    exit 0
fi