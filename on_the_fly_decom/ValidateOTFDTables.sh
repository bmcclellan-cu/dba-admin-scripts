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
#                          and may take a long time to complete.
# 
#           - length_gt_64: Checks that none of the individual telemetry items in TMDecom indicates
#                           a length greater than 64 bits, as this will cause OTFD to fail.
# 
#           - tsl_l0_tmdecom: Checks that TSL entries pointing to L0 also have corresponding TMDecom 
#                             rows.
# 
#           - tmdecom_l0_tsl: Checks that, for every TMDecom entry, there is a tsl entry with isInL0 set to 1.
#                             If this is not the case, the TMDecom entry will be unused by OTFD.
# 
#
# Author: Robert Schmidt
#
# Created on: May 21st, 2026
# Last Modified: May 22nd, 2026 - RS
##########################################################################

usage="Usage: ./ValidateOTFDTables.sh [ -d (optional, dryrun tests) ] [ system_id ] [ ORACLE_SID ] [ tests_list (csv of tests to run, see header or check -d option) ]"
example="Example: ./ValidateOTFDTables.sh 19 emadev"

# Process input options
dryrun=0

while getopts ":hd" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    d)
        dryrun=1
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

shift $((OPTIND - 1))

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
    echo "Error, provided ORACLE_SID is not open. Exiting..."
    exit 1
fi

# Get mission prefix and schema names
mission_prefix=$("$HOME/common/oracle/GetSchemaName.sh" -v)
if [ $? -ne 0 ] || [ -z "$mission_prefix" ]; then
    echo "$mission_prefix"
    echo "Error occurred while getting mission prefix for $ORACLE_SID. Exiting..."
    exit 1
fi

misc_schema=$("$HOME/common/oracle/GetSchemaName.sh" -m -v)
if [ $? -ne 0 ] || [ -z "$misc_schema" ]; then
    echo "$misc_schema"
    echo "Error occurred while getting MISC schema name for $ORACLE_SID. Exiting..."
    exit 1
fi

ct_schema=$("$HOME/common/oracle/GetSchemaName.sh" -c -v)
if [ $? -ne 0 ] || [ -z "$ct_schema" ]; then
    echo "$ct_schema"
    echo "Error occurred while getting CT schema name for $ORACLE_SID. Exiting..."
    exit 1
fi

# Call getTableName to get the correct table names. Type_in maps to tables as follows:
#  0 -> L0_Packets
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
        DBMS_OUTPUT.PUT_LINE($misc_schema.onTheFlyDecomMissionSpecific.getTableName(type_in => 3, systemId_in => $system_id));
        DBMS_OUTPUT.PUT_LINE($misc_schema.onTheFlyDecomMissionSpecific.getTableName(type_in => 4, systemId_in => $system_id));
        DBMS_OUTPUT.PUT_LINE($misc_schema.onTheFlyDecomMissionSpecific.getTableName(type_in => 5, systemId_in => $system_id));
    END;
    /
EOD
)
if [ $? -ne 0 ]; then
    echo "$tableNames"
    echo "An error occurred while querying OTFD for table names. Ensure that you are validating a system_id OTFD supports and that OTFD is updated to the latest version. Exiting..."
    exit 1
fi

# Compact all whitespace so table names are space-delimited then split into variables
tableNames=$(echo "$tableNames" | xargs)
read -r l0_packets_name tsl_name tmdecom_name telemetry_item_definition_name <<< "$tableNames"

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

# Cannot call getDefinitionStartStopTimes due to requiring a timestamp input, which will vary between databases.
# Hardcoding definition_time_column into if statement. Additionally, only specify SID for ixpe.
sid_clause=""
tmd_systemid_select_partition=""
if [[ "$ORACLE_SID" == "ixpe"* ]]; then
    definition_time_column="ERT"
    sid_clause=" AND SYSTEMID=$system_id"
    tmd_systemid_select_partition=", SYSTEMID"
elif [[ "$ORACLE_SID" == "ema"* ]]; then
    definition_time_column="ASCT"
elif [[ "$ORACLE_SID" == "neos"* ]]; then
    definition_time_column="ERT"
else
    echo "ERROR: Database $ORACLE_SID is not supported by OnTheFlyDecom (supported: ixpe*,ema*,neos*). Exiting..."
    exit 1
fi

telemetry_item_definition_name="$ct_schema.TelemetryItemDefinition"

# The SQL in the tests defined below are all intended to be queries that return table anomalies. As such, if no rows are
# returned, the test succeeds, if any data is returned, the test fails.

exit_status=0

declare -A TEST_SQL
declare -A TEST_DESCRIPTION

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

# Scan L0_Packets for packets that are not long enough, accounting for time-variant TMDecom entries.
TEST_SQL[packet_length]=$(cat <<SQL
    WITH tmdecom_with_ranges AS (
        -- Compute validity windows for each decom map using the next DEFINITIONSTART.
        SELECT
            TLMID,
            ${decom_id},
            STARTBIT,
            LENGTH,
            DEFINITIONSTART${tmd_systemid_select_partition},
            LEAD(DEFINITIONSTART) OVER (
                PARTITION BY TLMID, ${decom_id} ${tmd_systemid_select_partition}
                ORDER BY DEFINITIONSTART ASC
            ) AS DEFINITIONSTOP
        FROM ${tmdecom_name}
        WHERE 1=1 $sid_clause
    )
    SELECT /*+ PARALLEL */ '    TLMID ' || d.TLMID || ' (${decom_id} ' || d.${decom_id} || ', SID=$system_id' ||
    '): Datatype=' || t.DATATYPE || ', Startbit=' || d.STARTBIT || ', Length=' || d.LENGTH || 
    ' out of range of min packet length ' || min(p.LENGTH * 8) || '. Max packet length is ' || max(p.LENGTH * 8)
    FROM (
        tmdecom_with_ranges d
        JOIN ${l0_packets_name} p ON p.${decom_id} = d.${decom_id}
            -- Join packets only to decom maps valid at the packet timestamp.
            AND p.${definition_time_column} >= d.DEFINITIONSTART
            AND (d.DEFINITIONSTOP IS NULL OR p.${definition_time_column} < d.DEFINITIONSTOP)
    )
    LEFT JOIN ${telemetry_item_definition_name} t ON t.TLMID=d.TLMID
    -- Flag packets too small to contain the decom map definition.
    WHERE p.LENGTH * 8 < (d.STARTBIT + d.LENGTH) $sid_clause
    GROUP BY d.tlmid, d.${decom_id}, d.STARTBIT, d.LENGTH, t.DATATYPE
    ORDER BY d.tlmid, d.${decom_id};
SQL
)
TEST_DESCRIPTION[packet_length]="Checks if any of the packets in L0_Packets will be too small to be decommuted by their corresponding TMDecom map. 
Test failure indicates one of the following:
    1. The STARTBIT column for the TMDecom entry is too large.
    2. The LENGTH column for the TMDecom entry is too large.
    3. One or more of the packets in L0_Packets for that DMID is too small.

WARNING: This test requires a full scan of the L0_Packets table. This may take some time to complete"

# Check that every TSL row with isInL0=1 has a corresponding TMDecom row (tlmid + dmid foreign key)
TEST_SQL[tsl_l0_tmdecom]=$(cat <<SQL
    SELECT '        TLMID ' || TLMID || '($decom_id ' || $decom_id || ', SID=$system_id): TSL Entry (DefinitionStart=' || DEFINITIONSTART || 
    ', SID=$system_id' || ', isInL0=1) No matching TMDecom entry found for L0 TSL Entry.'
    FROM
    $tsl_name tsl
    WHERE isInL0=1 AND NOT EXISTS (
        SELECT 1 FROM $tmdecom_name tmd WHERE tmd.TLMID=tsl.TLMID AND tmd.$decom_id=tsl.$decom_id AND tmd.DEFINITIONSTART <= tsl.DEFINITIONSTART
    ) $sid_clause;
SQL
)
TEST_DESCRIPTION[tsl_l0_tmdecom]="Checks for TSL (TelemetryStorageLocation) entries with isInL0=1 without corresponding TMDecom rows (rows that
come into effect at the same time or before the TSL entry). If such a row is not present, then OTFD will not return data for that TLMID until such
a row comes into effect."


# Check that every TMDecom row has a corresponding TSL row with isInL0=1 (tlmid + dmid foreign key)
TEST_SQL[tmdecom_l0_tsl]=$(cat <<SQL
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
TEST_DESCRIPTION[tmdecom_l0_tsl]="Checks for TMDecom entries without corresponding TSL (TelemetryStorageLocation) rows (rows that
come into effect at the same time or before the TMDecom entry). If such a row is not present, then OTFD will never access the TMDecom
entry and will never utilize that decom map until such a TSL row comes into effect."


# Check that inputted tests actually correspond to known tests. If no input was given, run all tests.
declare -a tests_to_run
if [ -n "$tests_list" ]; then
    IFS=',' read -r -a tests_to_run <<< "$tests_list"
    for test_name in "${tests_to_run[@]}"; do
        if [ -z "${TEST_SQL[$test_name]}" ]; then
            echo "Test $test_name does not exist. Exiting..."
            exit 1
        fi
    done
    unset IFS
else
    tests_to_run=("${!TEST_SQL[@]}")
fi


for test_name in "${tests_to_run[@]}"; do
    echo "Running test $test_name."
    echo "${TEST_DESCRIPTION[$test_name]}"
    echo

    if [ "$dryrun" -eq 1 ]; then
        echo "DRYRUN: Query for test $test_name:"
        echo "${TEST_SQL[$test_name]}"
        echo
        continue
    fi

    test_output=$("$ORACLE_HOME/bin/sqlplus" -s / as sysdba <<EOD
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
        echo "$test_output"
        echo "An error occurred while running test $test_name. See error output and test description above. Continuing to next test..."
    fi

    if [ -n "$test_output" ]; then
        exit_status=1
        echo "$test_output"
        echo "FAILURE: Test $test_name returned one or more anomalies, see test output and description above. Continuing to next test..."
    else
        echo "SUCCESS: Test $test_name found no anomalies. Continuing to next test..."
    fi
    echo
done

if [ "$dryrun" -eq 1 ]; then
    echo "Dryrun completed successfully, no queries executed. Exiting..."
    exit 0
fi

if [ "$exit_status" -ne 0 ]; then
    echo "One or more tests failed/errored, please see above output for more details. Exiting..."
    exit 1
else
    echo "Script completed successfully, no anomalies or errors encountered. Exiting..."
    exit 0
fi