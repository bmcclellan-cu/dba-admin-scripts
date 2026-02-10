/*************************************************************************************************
File:       onTheFlyDecom.pkb (package body)

Purpose:    This contains the generic, non-mission-specific code used for on-the-fly decom.
            It works together with the mission-specific code in onTheFlyDecom<mission>.pkb.

            On-the-fly decom is the process of extracting telemetry point(s) from raw CCSDS
            packet(s) in the L0_Packets database table.  This is in contrast to querying
            the L1 tables: TManalog and TMdiscrete for telemetry points previously ingested
            by TDP (Telemetry Data Processing).

Revisions:
  mm/dd/yy who  description
  10/19/23 SM   Initial version.
  07/22/25 RS   Updated logging + fixed bug.
  08/27/25 RS   Updated for EMA
  11/13/25 RS   Updated logging

Methods:
  selectNumericTlm      - The main telemetry retrieval procedure;  mostly generic code, with a few
                          calls to mission-specific code.
  setOption             - End-user application calls to set options, both generic and mission-specific.
  clearOption           - End-user application calls to revert an option to its default value.
  getVersion            - Get the version of both the generic and mission-specific packages.

  queryTMDecom          - Gets the TMDecom records for a given OTFD Query
  queryTSL              - Gets the TelemetryStorageLocation records for a given OTFD query.

  narrowStartStopTimes  - Used so the data from L0/L1 queries with multiple TSL or TMD rows don't overlap.
  queryL0               - Called by selectNumericTlm, queries L0_Packets and decoms telemetry items from the
                          returned packets based on the entries in TMDecom.
  decomFromHexString    - Returns a NUMBER from a hex string, given offset, length and dataType. 
  queryL1               - Queries TManalog or TMdiscrete, inserts results into onTheFlyDecom_results.

  CSV2NestedTable       - Converts a comma separated string of values to a PL/SQL table. Is used to parse the 
                          'APID' global option.
  string_varrayToCSV    - Converts a varray of up to 3 strings into a CSV. 
  prepareDebugSQL       - Takes a mapping of bind variables to actual values as well as a query and replaces 
                          bind variables with the values, as well as compacting whitespace. For logging queries.
  logOTFD               - Logs to onTheFlyDecom_errors, as well as managing priority of logged messages based on 
                          the set 'DEBUGLEVEL'

Installation:
  Open sqlplus and run the following commands. Note: The package specs must be compiled first!
    @<full_path>/onTheFlyDecomMissionSpecific.pks     -- mission-specific package spec
    @<full_path>/onTheFlyDecom.pks                    -- generic package spec
    @<full_path>/onTheFlyDecomMissionSpecificIXPE.pkb -- mission-specific package body
    @<full_path>/onTheFlyDecom.pkb                    -- generic package body
    show errors                                       -- show compilation errors (no errors is preferable)

Usage: 
    Be sure your SQL client does *NOT* have autocommit enabled, as that will clear out ONTHEFLYDECOM_RESULTS
    and ONTHEFLYDECOM_ERRORS immediately after the procedure returns. 

    Note: All results from onTheFlyDecom are returned into either ONTHEFLYDECOM_RESULTS or ONTHEFLYDECOM_ERRORS. 
    No user-facing procedures will directly return data.

    The primary procedure used to query data is selectNumericTlm, which is used as follows. Note that all of the time
    parameters are technically optional, and can be replaced with -1 to avoid querying by them, but at least one of them
    must be set. See documentation for the mission-specific package on what time fields are required. 

    execute onTheFlyDecom.selectNumericTlm(<SID>, <TLMID>, <startERT>, <stopERT>, <startSCT>, <stopSCT>, <startASCT>, <stopASCT>);

    SELECT * FROM onTheFlyDecom_results; -- Get the results from the query
    SELECT * FROM onTheFlyDecom_errors;  -- Get errors/warnings/debug output based on 'DEBUGLEVEL' option.

    You can set optional parameters using the setOption or clearOption procedures, which allows for both generic and 
    mission-specific parameters to be set. Details on available options can be obtained by running setOption with empty parameters

    execute onTheFlyDecom.setOption(<OptionName>, <OptionValue>);
    execute onTheFlyDecom.clearOption(<OptionName>); -- Pass 'ALL' to clear all options.
Notes:
  1. Overview:
     See the OnTheFlyDecom.txt document.
     See OTFD Documentation: https://confluence.lasp.colorado.edu/spaces/MODSDB/pages/219810895/On-The-Fly-Decom+OTFD
     
  2. Uses two Oracle global temporary tables:
     Oracle global temporary tables have the same name, but different contents for each connection.
     They must be created once by a DBA, like other permanent tables.
     The code clears these tables before each invocation of selectNumericTlm.
     The code also clears OnTheFlyDecom_errors before each invocation of setOption and clearOption.
     a. The onTheFlyDecom_results table stores the results of selectNumericTlm, which the application can
        query to get the data.
     b. The onTheFlyDecom_errors table stores errors/debug messages depending on the DEBUGLEVEL, and can also be 
        queried by the end-user.

  3. Compiler Errors:
     - If the ampersand character is present in a comment, package compilation will fail and give the following prompt:
       Enter value for t:  (where t is the letter after the ampersand)

  4. Exception Handling and End-User Error Handling
     - If you let an exception propagate to the caller of the procedure, most SQL clients automatically rollback
       the global temporary table state to before the procedure was called, clearing the onTheFlyDecom_errors and 
       onTheFlyDecom_results table. All exceptions must be caught and handled so the end-user application can get
       useful error messages.
     - The end user is expected to check the onTheFlyDecom_errors table after each call to
       selectNumericTlm, setOption and clearOption.  If the user has not increased the debug level
       over the default, then zero rows means no errors.  If the user has increased the debug level,
       and there are rows in the table, then the user should query the table to find out if any
       of them start with "ERROR", "WARNING", "DEBUG", or "V-DEBUG", to determine the error status of the last called
       procedure.
     - The user-callable procedures do not return status, because output variables and function
       return values from stored procedures/functions are harder to program in some languages.

  5. ERT vs SCT:
     - ERT (Earth Received Time) is the wall clock time when the packet was received at a ground station. 
       SCT (Spacecraft Time) refers to the time embedded in telemetry packets, converted to UTC. 
       ASCT (Adjusted Spacecraft Time) is intended to be the wall-clock time the data was generated, accounting
            and adjusting for jamming Spacecraft time into the future during testing.
     - Data requests before launch often specify only an ERT range (or ASCT for EMA), or both an ERT range
       and an SCT range (for playback data). getDefinitionStartStopTimes is used to determine what time input
       to use to query the TelemetryStorageLocation and TMDecom tables. This may have issues with playback data
       because ERT is a relatively short time period during which a large time range of data may have been received
       at once. If SCT is jammed to be significantly different from ERT and queries using that SCT are made, the 
       incorrect Decom Maps may be selected. After launch, this issue is fairly minor, as SCT should accurately 
       reflect wall-clock time, and will roughly correlate with ERT.
          
    Q: What if we wanted to treat playback, real-time and EMM snorkel data differently w.r.t. ingesting
          into L0 or L1?  Possibilities:  TSL would need either more systemIds, or a new column extending
	  systemId, like VCs.
*************************************************************************************************/

CREATE OR REPLACE PACKAGE BODY onTheFlyDecom
AS

-- These options, and additional mission-specific options, are settable by calling the setOption
-- or clearOption procedure.  Mission-specific options are defined in onTheFlyDecomMissionSpecific<MSN>
-- package.  These procedures chain to similar procedures in that package.
-- A -1 value or empty string means the option won't be used in queries.  I.e. either it
-- hasn't yet been set by the user, the user reset it.
-- See the mission-specific onTheFlyDecom<mission>.pkb file for mission-specific options.

-- If debug level is above 0, the L0 and L1 queries will have the monitor flag enabled, allowing for query performance to be measured.
-- Keep in mind that this does not apply for TMDecom/TelemetryStorageLocation queries, as those are unlikely to be performance bottlenecks.
gblDebugLevel      NUMBER := 0;           /* 0=errors,  1=warning, 2=verbose debug, 3=very verbose debug */
gblApids           VARCHAR2(128) := '-1'; /* comma-separated list of apids */
gblDecomMapTimeGPS NUMBER := -1;          /* Overrides using start/stop times and TMdecom table for decom map time(s). */
gblForceIsInL0     NUMBER := -1;          /* -1 = not in effect, 0 = isInL0=0, 1 = isInL0=1 */
gblForceIsInL1     NUMBER := -1;          /* -1 = not in effect, 0 = isInL0=0, 1 = isInL0=1 */

-- Make a type for the optional apid list.
TYPE nestedTable_typ IS TABLE OF NUMBER;

TYPE curType IS REF CURSOR; -- weakly typed cursor

-- Define static row types for TMDecom and TSL records.
TYPE tmdecom_row_t IS RECORD (
    systemId    NUMBER,
    apid        NUMBER,
    startBit    NUMBER,
    bitLength   NUMBER,
    dataType    CHAR(1 BYTE),
    definitionStart NUMBER
);

TYPE tsl_row_t IS RECORD (
    definitionStart NUMBER,
    isInL0          NUMBER,
    isInL1          NUMBER,
    apid            NUMBER
);

/* sequence column (row counter) in onTheFlyDecom_errors. 
Represents a single unique message. Duplicate sequence entries indicate a split message*/
gblSequence NUMBER := 1;  

/*************************************************************************************************
Procedure:  logOTFD

Purpose:    Inserts a new row with a message to the onTheFlyDecom_errors temporary table, incrementing
            a global counter indicating the order of events. If a log message is longer than 500 characters
            (the current ONTHEFLYDECOM_ERRORS VARCHAR size), the message is split into multiple chunks and the 
            sequence counter remains the same for each chunk of the message. 

            The collateErrors function is run at the end of selectNumericTlm to compact the errors such that 
            identical sequential error messages are not repeated.

Input:      message -  VARCHAR2 The error message to log.

            priority - NUMBER   How "important" the log message is. Adds a prefix to the message and filters by gblDebugLevel:
                        0: ERROR            - Needs to be logged regardless of logging level
                        1: WARNING          - May represent a non-fatal error or issue
                        2: DEBUG            - Logs all actions taken, including all SQL run and most function calls made
                        3: VERBOSE DEBUG    - Logs all SQL, function calls, etc. (critically, this includes decomFromHexString, 
                                              which gets called for every data point, which results in extremely verbose output).

Notes:
    Rows in the onTheFlyDecom_errors temporary table are of the form sequence, message, occurrences.
*************************************************************************************************/
PROCEDURE logOTFD(msg VARCHAR2, priority NUMBER)
IS
    messageRow VARCHAR2(500);
    messagePrefix VARCHAR2(10) := '';
    rowLength  NUMBER := 500;
    rowStart     NUMBER := 1;
BEGIN
    -- Determine the appropriate prefix based on the priority
    CASE priority
        WHEN 0 THEN
            messagePrefix := 'ERROR: ';
        WHEN 1 THEN
            messagePrefix := 'WARNING: ';
        WHEN 2 THEN
            messagePrefix := 'DEBUG: ';
        WHEN 3 THEN
            messagePrefix := 'V-DEBUG: ';
        ELSE
            messagePrefix := '';
    END CASE;
    -- Only log if the logging level is high enough to allow it
    IF (priority <= gblDebugLevel) THEN
        LOOP
            EXIT WHEN rowStart >= LENGTH(msg);

            -- Get the next available 490 characters and prefix the appropriate prefix.
            messageRow := messagePrefix || SUBSTR(msg, rowStart, rowLength-10);
            rowStart := rowStart + rowLength;
            INSERT INTO ONTHEFLYDECOM_ERRORS (sequence, message, occurrences) VALUES (gblSequence, messageRow, 1);
        END LOOP;
        -- Only increase the sequence counter once per full message logged.
        gblSequence := gblSequence + 1;
    END IF;
EXCEPTION
    WHEN others THEN
        DBMS_OUTPUT.PUT_LINE('Error in logOTFD: ' || SQLCODE || ' -ERROR- ' || SQLERRM);
        DBMS_OUTPUT.PUT_LINE('Attempted message logged: ' || msg);
END logOTFD;


/*************************************************************************************************
Procedure:  collateErrors

Purpose:    Takes the log output in onTheFlyDecom_errors and deletes sequential duplicate log entires,
            updating the occurrences field to reflect the number of entires compacted. The lowest sequence 
            number is preserved. This is run once at the end of selectNumericTlm to compact the log output
            without losing the order of events or any log data. 

    Note:   This is significantly more efficient than validating and updating the table rows at insert time
            and has no significant performance impact during normal operations, and will only come into effect
            when errors get logged or gblDebugLevel is set.

            This procedure will NOT compact split logs any differently, and will only compact sequential split
            log messages if both halves are identical. 

Input:      None

Notes:
    Rows in the onTheFlyDecom_errors temporary table are of the form sequence, message, occurrences.
*************************************************************************************************/
PROCEDURE collateErrors IS
BEGIN
    logOTFD('collateErrors: gblDebugLevel=' || gblDebugLevel, 2);
    -- First, identify the start of each sequential group of identical messages
    -- and count how many consecutive occurrences there are
    MERGE INTO onTheFlyDecom_errors t
    USING (
        -- Get the number of identical consecutive entires.
        SELECT 
            MIN(sequence) AS sequence,
            message,
            COUNT(*) AS cnt
        FROM (
            SELECT 
                sequence,
                message,
                -- Partitions the table by message, preserving the sequence order, then gets the row number for each 
                -- item in that partition (ROW_NUMBER() resets at the beginning of each partition). Subtracting this 
                -- from the sequence, which is increasing each row, gives a single "group number" for each set of 
                -- identical rows.
                sequence - ROW_NUMBER() OVER (PARTITION BY message ORDER BY sequence) AS grp
            FROM onTheFlyDecom_errors
        )
        GROUP BY message, grp  -- Group by message in order to be able to have it in the select field.
    ) s
    -- Take the results from the above query and match them according to the following conditions.
    ON (t.sequence = s.sequence AND t.message = s.message)
    WHEN MATCHED THEN
    -- On a match, update the number of occurrences.
    UPDATE SET t.occurrences = s.cnt;

    -- Delete all rows except the first occurrence of each sequential group
    DELETE FROM onTheFlyDecom_errors t
    WHERE sequence NOT IN (
        -- Get the minimum sequence number in each message group using the same partitioning logic as 
        -- above.
        SELECT MIN(sequence)
        FROM (
            SELECT 
                sequence,
                message,
                sequence - ROW_NUMBER() OVER (PARTITION BY message ORDER BY sequence) AS grp
            FROM onTheFlyDecom_errors
        )
        GROUP BY message, grp
    );
EXCEPTION
    WHEN others THEN
        logOTFD('collateErrors: others exception ' || SQLCODE || ' -ERROR- ' || SQLERRM, 0);
END collateErrors;


/*************************************************************************************************
Procedure:  string_varrayToCSV

Purpose:    Converts the string_varray datatype to a CSV for use in query creation.

Input:      array_in - string_varray (VARRAY(3) OF VARCHAR(200)) The array to convert.
*************************************************************************************************/
FUNCTION string_varrayToCSV(array_in IN string_varray)
RETURN VARCHAR2 IS
    l_result VARCHAR2(32767);
BEGIN
    -- Unable to inline-unpack the string_varray, so logs the unpacked array once the procedure returns.
    logOTFD('string_varrayToCSV called with array_in=<not_unpackable>', 2);
    IF array_in IS NOT NULL THEN
        FOR i IN 1 .. array_in.COUNT LOOP
            IF i > 1 THEN
                l_result := l_result || ',';
            END IF;
            l_result := l_result || array_in(i);
        END LOOP;
    END IF;
    logOTFD('string_varrayToCSV completed string_varray unpack, value is ' || l_result, 2);
    RETURN l_result;
END string_varrayToCSV;

/*************************************************************************************************
Procedure:  getVersion

Purpose:    This procedure writes the version in a log message to the onTheFlyDecom_errors temporary table.
*************************************************************************************************/
PROCEDURE getVersion
IS
    missionSpecificVersion VARCHAR2(128);
BEGIN
    -- Note: Steve Monk previously had issues with the truncate command, but recent testing has not been able to duplicate those issues.
    EXECUTE IMMEDIATE 'TRUNCATE TABLE ONTHEFLYDECOM_ERRORS';
    missionSpecificVersion := onTheFlyDecomMissionSpecific.getVersion();
    logOTFD( 'INFO multimission version: 0.2.4', -1);
    logOTFD( 'INFO mission-specific version: ' || missionSpecificVersion, -1);
END getVersion;

/*************************************************************************************************
Procedure:  setOption

Purpose:    This procedure sets the specified global variable to the specified value.
            Generic option variables are in this package.  Mission-specific ones are in
	        onTheFlyDecomMissionSpecific<mission>.pkb  Once set, an option stays in effect 
            for the life of the database connection, unless it is set back to the default 
            by clearOption().

Input:      optionName  - String giving the name of the option, case insensitive.
            optionValue - String giving the value of the option; if the actual option is an integer,
	                      convert it to a string first.
*************************************************************************************************/
PROCEDURE setOption( optionName VARCHAR2, optionValue VARCHAR2)
IS
    upperCaseOptionName VARCHAR2(128) := '';
    status NUMBER;
    optionsHelp VARCHAR2(128) := '';
BEGIN
    -- Clear the temp table in which the errors are stored.
    -- Note: Steve Monk previously had issues with the truncate command, but recent testing has not been able to duplicate those issues.
    EXECUTE IMMEDIATE 'TRUNCATE TABLE ONTHEFLYDECOM_ERRORS';
    gblSequence := 1;

    upperCaseOptionName := UPPER( optionName);
    IF    (upperCaseOptionName = 'DEBUGLEVEL') THEN
        gblDebugLevel := TO_NUMBER(optionValue);
    ELSIF (upperCaseOptionName = 'APIDS') THEN
        gblApids := optionValue;
    ELSIF (upperCaseOptionName = 'DECOMMAPTIMEGPS') THEN
        gblDecomMapTimeGPS := TO_NUMBER(optionValue);
    ELSIF (upperCaseOptionName = 'FORCEISINL0') THEN
        gblForceIsInL0 := TO_NUMBER(optionValue);
    ELSIF (upperCaseOptionName = 'FORCEISINL1') THEN
        gblForceIsInL1 := TO_NUMBER(optionValue);
    ELSE
        status := onTheFlyDecomMissionSpecific.setOption(optionName, optionValue);
        IF (status != 1) THEN
            optionsHelp := onTheFlyDecomMissionSpecific.getOptionsHelp;
            logOTFD('setOption: Unsupported option: ' || optionName || chr(10) || 
                    'multimission options are: DEBUGLEVEL: 0|1|2, APIDS: "xx[,yy[,zz]]" etc., ' ||
                    'DECOMMAPTIMEGPS: nnnnnn, FORCEISINL0: 0|1, FORCEISINL1: 0|1' || chr(10) ||
                    'missionspecific options are: ' || optionsHelp, 0
            );
        END IF;
    END IF;
    RETURN;

    EXCEPTION
    WHEN INVALID_NUMBER THEN
        logOTFD('setOption: invalid number: optionName=' || optionName || ', optionValue=' || optionValue, 0);
    WHEN others THEN
        logOTFD('setOption: others exception: optionName=' || optionName || ', optionValue=' || optionValue, 0);

END setOption;

/*************************************************************************************************
Procedure:  clearOption

Purpose:    This procedure sets the specified global variable to its default value.
            Generic option variables are in this package.  Mission-specific ones are in
	        onTheFlyDecom<mission>.pkb

Input:      optionName - String giving the name of the option, case insensitive.
                         "all" means clear all the options.

*************************************************************************************************/
PROCEDURE clearOption( optionName VARCHAR2)
IS
    upperCaseOptionName VARCHAR2(128) := '';
    status NUMBER;
    optionsHelp VARCHAR2(128) := '';
BEGIN
    -- Clear the temp table in which the errors are stored.
    -- Note: Steve Monk previously had issues with the truncate command, but recent testing has not been able to duplicate those issues.
    EXECUTE IMMEDIATE 'TRUNCATE TABLE ONTHEFLYDECOM_ERRORS';
    gblSequence := 1;

    upperCaseOptionName := UPPER( optionName);
    CASE upperCaseOptionName
        WHEN 'APIDS' THEN
            gblApids := '-1';
        WHEN 'DECOMMAPTIMEGPS' THEN
            gblDecomMapTimeGPS := -1;
        WHEN 'FORCEISINL0' THEN
            gblForceIsInL0 := -1;
        WHEN 'FORCEISINL1' THEN
            gblForceIsInL1 := -1;
        WHEN 'ALL' THEN
            gblDebugLevel := 0;
            gblApids := '-1';
            gblDecomMapTimeGPS := -1;
            gblForceIsInL0 := -1;
            gblForceIsInL1 := -1;
            status := onTheFlyDecomMissionSpecific.clearOption('ALL');
        ELSE
            status := onTheFlyDecomMissionSpecific.clearOption( optionName);
            IF (status != 1) THEN
                optionsHelp := onTheFlyDecomMissionSpecific.getOptionsHelp;
                logOTFD('clearOption: Unsupported option: ' || optionName || chr(10) || 
                        'multimission options are: DEBUGLEVEL: 0|1|2, APIDS: "xx[,yy[,zz]]" etc., ' ||
                        'DECOMMAPTIMEGPS: nnnnnn, FORCEISINL0: 0|1, FORCEISINL1: 0|1' || chr(10) ||
                        'missionspecific options are: ' || optionsHelp, 0
                );
            END IF;
    END CASE;
    RETURN;
END clearOption;

/*************************************************************************************************
Function:   prepareDebugSQL

Purpose:    Replaces occurrences of a bind variable an SQL statement with the provided value.
            Does this for all the name/values provided in the associative array input.
            Additionally compacts the whitespace for the SQL statement for easier logging.
            Note that if one of the inputted array bind variables is a substring of another,
            the order of the mappings will determine which one is applied. Ensure that the first
            mapping is for the longer string to avoid partial replacements.

Example:    If query_str is: "select * from table where apid = :my_apid" and the input array
            has an element: (":my_apid","1"), then the output string is:
            "select * from table where apid = 1"

Input:      query_str      - Typically a query string with bind variables in it.
            name_value_in  - A table of name/value pairs.  The names are bind variables in a query,
                             like ":apid".  The values are the bind variable values, like "1".

            There can be names which aren't in query_str, and query_str doesn't have to have
            any of the names in the array (but it would be pointless to call it in this case).

Returns:    query_str with each name string in name_value_in replaced by the corresponding value string.

**************************************************************************************************/
FUNCTION prepareDebugSQL(
    query_str IN VARCHAR2,
    name_value IN name_value_t)
    RETURN VARCHAR2
IS
    name VARCHAR2(64);
    result VARCHAR2(1000);
BEGIN
    -- SQL only gets logged if debug level is 2 or greater, otherwise don't bother the string processing.
    IF(gblDebugLevel < 2) THEN
        return '';
    END IF;
    -- Do not log unless V-DEBUG is set. The whole point of the procedure is to cleanup the logged output.
    logOTFD('prepareDebugSQL: query_str=' || query_str || ', name_value=<not_unpackable>', 3);
    result := REGEXP_REPLACE(query_str, '[[:space:]]+', ' '); -- Compacts the SQL into a single line (cleans up the log output)
    name := name_value.FIRST;
    WHILE name IS NOT NULL LOOP
        -- Replace all occurrences of name by value.
        result := REPLACE(result, name, name_value(name));
	name := name_value.NEXT(name);
    END LOOP;
    return result;
    
EXCEPTION
    WHEN others THEN
        logOTFD('prepareDebugSQL: others exception: ' || SQLCODE || ' -ERROR- ' || SQLERRM, 0);
        return query_str;  -- Return original query on error
END prepareDebugSQL;

/*************************************************************************************************
Procedure: queryTMDecom

Purpose:    Given a SID, APID, TLMID, start and stop time, opens a cursor containing all relevant decom maps.
            This procedure also has to take into account differing table names, column names, etc.

Inputs:
   
    systemId_in          - The SID of the decom map.
    apid_in              - The APID of the decom map.
    TMDQueryStartTime_in - The beginning of the time period being queried for, inclusive.
    TMDQueryStopTime_in  - The end of the time period being queried for, inclusive.
    isLastTSLRow_in      - Is true if the relevant TSL row is the final one for the specific APID
                           being queried for. Indicates that the end of the TMDecom query should
                           be inclusive of the stop time, rather than exclusive. It is initially exclusive
                           to avoid duplicate decom maps if their definitionStart values are in sequential 
                           microseconds.

Outputs:

    cursor_out     - The cursor created for the query.
    
*************************************************************************************************/
PROCEDURE queryTMDecom(
    systemId_in IN NUMBER,
    apid_in IN NUMBER,
    tlmId_in IN NUMBER,
    TMDQueryStartTime_in IN NUMBER,
    TMDQueryStopTime_in IN NUMBER,
    isLastTSLRow_in IN BOOLEAN,
    cursor_out OUT curType
    )
IS 
    tmdecom_table_name VARCHAR2(50);
    decom_map_identifier VARCHAR(4);    -- dmid or apid. Note that OTFD calls it apid internally regardless
    query_sql CLOB;                     -- Practically unlimited length for query
    name_value ONTHEFLYDECOM.name_value_t;
    booleanOpString VARCHAR(2);
BEGIN
    ONTHEFLYDECOM.logOTFD('queryTMDecom: systemId_in=' || systemId_in ||
                          ', apid_in=' || apid_in ||
                          ', tlmId_in=' || tlmId_in || 
                          ', TMDQueryStartTime_in=' || TMDQueryStartTime_in ||
                          ', TMDQueryStopTime_in=' || TMDQueryStopTime_in || 
                          ', isLastTSLRow_in=' || sys.diutil.bool_to_int(isLastTSLRow_in) , 2
    );
    name_value := ONTHEFLYDECOM.name_value_t( 
        ':systemId_in' => TO_CHAR(systemId_in),
        ':apid_in' => TO_CHAR(apid_in),
        ':tlmId_in' => TO_CHAR(tlmId_in),
        ':tmdqstarttime' => TO_CHAR(TMDQueryStartTime_in),
        ':tmdqstoptime' => TO_CHAR(TMDQueryStopTime_in),
        ':tlmId2_in' => TO_CHAR(tlmId_in)
    );

    IF (isLastTSLRow_in) THEN
        booleanOpString := '<=';
    ELSE
        booleanOpString := '<';
    END IF;

    tmdecom_table_name := onTheFlyDecomMissionSpecific.getTableName(4, systemId_in);
    decom_map_identifier := onTheFlyDecomMissionSpecific.getDecomIdentifier();

    query_sql := '
        SELECT :systemId_in AS systemId, ' || decom_map_identifier || ' as apid, startBit, length, dataType, definitionStart
        FROM ' || tmdecom_table_name || '
        WHERE ' || decom_map_identifier || '     = :apid_in
          AND tlmId    = :tlmId_in
          AND definitionStart ' || booleanOpString || ' :tmdqstoptime
          AND definitionStart >= COALESCE(
                (SELECT MAX(definitionStart)
                   FROM ' || tmdecom_table_name || '
                  WHERE tlmId    = :tlmId2_in
                    AND definitionStart <= :tmdqstarttime
                ), 0)
        ORDER BY definitionStart';

    ONTHEFLYDECOM.logOTFD('queryTMDecom: ' || ONTHEFLYDECOM.prepareDebugSQL(query_sql, name_value), 2);

    OPEN cursor_out FOR query_sql
        USING systemId_in,                -- :systemId_in
              apid_in,                    -- :apid_in
              tlmId_in,                   -- :tlmId_in
              TMDQueryStopTime_in,        -- :tmdqstoptime
              tlmId_in,                   -- :tlmId2_in (subquery)
              TMDQueryStartTime_in;       -- :tmdqstarttime (subquery)
END queryTMDecom;

/*************************************************************************************************
PROCEDURE: queryTSL

Purpose:    Given a SID, APID, TLMID, start and stop time, opens a cursor containing all relevant 
            TelemetryStorageLocation entries. This procedure also has to take into account differing 
            table names, column names, etc.

            NOTE: The output from this query MUST be sorted by definitionStart, decom_map_identifier. 
                  Later logic relies on this order to properly handle a tlmid spanning multiple APIDs.

Inputs:
   
    systemId_in          - The SID of the decom map.
    apid_in              - The APID of the decom map.
    TMDQueryStartTime_in - The beginning of the time period being queried for, inclusive.
    TMDQueryStartTime_in - The end of the time period being queried for, inclusive.

Outputs:

    cursor_out     - The cursor created for the query.
    
*************************************************************************************************/
PROCEDURE queryTSL(
    systemId_in IN NUMBER,
    tlmId_in IN NUMBER,
    definitionStartTime_in IN NUMBER,
    definitionStopTime_in IN NUMBER,
    cursor_out OUT curType
)
IS
    tsl_table_name VARCHAR(50);
    decom_map_identifier VARCHAR(4);    -- dmid or apid. Note that OTFD calls it apid internally regardless
    query_sql CLOB;                     -- Practically unlimited length for query
    name_value ONTHEFLYDECOM.name_value_t;
BEGIN
    ONTHEFLYDECOM.logOTFD('queryTSL: systemId_in=' || systemId_in ||
                          ', tlmId_in=' || tlmId_in || 
                          ', definitionStartTime_in=' || definitionStartTime_in ||
                          ', definitionStopTime_in=' || definitionStopTime_in, 2
    );
    name_value := ONTHEFLYDECOM.name_value_t( 
        ':tlmId_in' => TO_CHAR(tlmId_in),
        ':definitionStartTime_in' => TO_CHAR(definitionStartTime_in),
        ':definitionStopTime_in' => TO_CHAR(definitionStopTime_in),
        ':tlmId2_in' => TO_CHAR(tlmId_in)    
    );

    tsl_table_name := onTheFlyDecomMissionSpecific.getTableName(3, systemId_in);
    decom_map_identifier := onTheFlyDecomMissionSpecific.getDecomIdentifier();

    query_sql := '
        SELECT definitionStart,
               isInL0,
               isInL1,
               ' || decom_map_identifier || ' as apid
        FROM ' || tsl_table_name || '
        WHERE tlmId = :tlmId_in
          AND definitionStart <= :definitionStopTime_in
          AND definitionStart >= COALESCE(
                (SELECT MAX(definitionStart)
                   FROM ' || tsl_table_name || '
                  WHERE tlmId    = :tlmId2_in
                    AND definitionStart <= :definitionStartTime_in
                ), 0)
        ORDER BY definitionStart, ' || decom_map_identifier;

    ONTHEFLYDECOM.logOTFD('queryTSL: ' || ONTHEFLYDECOM.prepareDebugSQL(query_sql, name_value), 2);

    OPEN cursor_out FOR query_sql
        USING tlmId_in,         -- :tlmId_in (outer query)
              definitionStopTime_in, -- :definitionStopTime_in
              tlmId_in,         -- :tlmId2_in (subquery)
              definitionStartTime_in; -- :definitionStartTime_in
END queryTSL;



/*************************************************************************************************
Function:   decomFromHexString

Purpose:    Decommutates a numeric value from a hex string.

Input:      hexString_in   - An even length string containing hex characters representing binary bits
                             The bits of the raw value to decommutate must start in the first byte
                             (in first 2 hex chars), and end in the last byte (in last 2 hex chars).
                             That is, the hex string must represent the minimum number of bytes
                             needed to contain the value.
            bitOffset_in   - The zero-based offset where the first bit of the value is located, 
                             0..7.   0 = first bit (first downlinked), 7 = last bit (last downlinked).
            bitLength_in   - The number of bits in the value to decommutate.
            dataType_in    - The supported data types are a subset of those supported by the CT DB.
                             See the CT DB User's Guide for details.
                                'F' = floating point
                                'U' = unsigned integer
                                'I' = signed integer
                                'D' = discrete, output as an unsigned integer (no negative states!)

Output:     valueAsNumber  - The decommed telemetry point. If NULL, then the decommed value was successfully
                             converted to a NUMBER, but is invalid (has magnitude greater than 1e125). It is 
                             not expected that any valid data points will be outside of this range.

Returns:    1=success, 0=failure
            Failure can be caused by trying to decom a float from a bit string which isn't a
            valid float, e.g. because there was a data hit, or it was invalid when produced on-board
            because some component was off.

History:
  mm/dd/yy Who  What
  06/07/19 SM   Initial version.
  01/15/20 JH   Comment and output reformatting.
  02/23/23 SM   Added error handling.
  03/07/25 RS   Fixed bug with BITAND, added overflow check.
  11/05/25 RS   Updated logging.

Notes:
  1. Decommutation:
     Decommutation means to extract bits from some location in a bit stream, and put them
     into an appropriate native data type.
  2. Errors:
     If there is an error with this function, the decom_error exception will be raised.
  3. Limitations:
     - Big-endian byte order is assumed for multi-byte data types.  Spacecraft or instrument
       telemetry is almost always in big-endian order.
     - Floats and doubles must start on byte boundaries, and be either 32-bits or 64-bits long.
     - Integers can be from 1..32 bits long, and do not have to start on a byte boundary.

**************************************************************************************************/
FUNCTION decomFromHexString(
    hexString_in IN VARCHAR2,
    bitOffset_in IN NUMBER,
    bitLength_in IN NUMBER,
    dataType_in IN CHAR,
    valueAsNumber OUT NUMBER)
    RETURN NUMBER
IS
    lastBitOffset NUMBER;
    shiftByBits NUMBER;
    nBytes INTEGER;
    mask NUMBER;
    bitIsSet BOOLEAN;
BEGIN
    -- This gets called especially often and WILL clog up debugging, so it has priority 3.
    logOTFD('decomFromHexString: hexString_in=' || hexString_in || ', bitOffset_in=' || bitOffset_in || ', bitLength_in=' || bitLength_in || ', dataType_in=' || dataType_in, 3);

    -- First, the inputs are validated -----------------------------------------------------------
    IF hexString_in = '' THEN
        logOTFD('decomFromHexString: Input hex string is empty!', 0);
        return 0;
    END IF;

    nBytes := LENGTH( hexString_in)/2; -- Get the number of bytes in hexString_in

    IF MOD( LENGTH( hexString_in), 2) != 0 THEN
        logOTFD('decomFromHexString: Input hexString_in (' || hexString_in || ') does not have an even number of characters', 0);
        return 0;
    END IF;

    IF nBytes > 8 THEN
        logOTFD('decomFromHexString: Input nBytes(' || nBytes || ') greater than 8 bytes!', 0);
        return 0;
    END IF;

    IF bitOffset_in < 0 or bitOffset_in > (nBytes*8 - 1) THEN
        logOTFD('decomFromHexString: Input bitOffset(' || bitOffset_in || ') is invalid', 0);
        return 0;
    END IF;

    IF (bitOffset_in + bitLength_in) > (nBytes*8) THEN
        logOTFD('decomFromHexString: Input bitOffset(' || bitOffset_in || ') + bitLength(' || bitLength_in || ')  exceeds length of hex string(' || nBytes*8 || ')', 0);
        return 0;
    END IF;

    IF (dataType_in != 'F') and (dataType_in != 'I') and (dataType_in != 'U') and (dataType_in != 'D') THEN
        logOTFD('decomFromHexString: Unsupported input dataType(' || dataType_in || ')', 0);
        return 0;
    END IF;

    IF (dataType_in = 'F') THEN
        IF (bitLength_in != 32) and (bitLength_in != 64) THEN
            logOTFD('decomFromHexString: Invalid bitLength(' || bitLength_in || ') for dataType=F', 0);
            return 0;
        END IF;
        IF bitOffset_in != 0 THEN
            logOTFD('decomFromHexString: Input bitOffset(' || bitOffset_in || ') must be 0 for dataType=F', 0);
            return 0;
        END IF;
    END IF;

    -- Start of decommutation --------------------------------------------------------------------

    IF dataType_in = 'F' and bitLength_in = 32 and nBytes = 4 THEN
        -- This matches a float telemetered on a byte boundary, as they always have been on past missions.
        -- The 2nd parameter specifies that raw value (1st parameter) is in big-endian byte order.
        BEGIN
            valueAsNumber := TO_NUMBER( UTL_RAW.CAST_TO_BINARY_FLOAT( HEXTORAW( hexString_in), 1));
   	    EXCEPTION
	    WHEN others THEN
            logOTFD('decomFromHexString: Failed to convert bits to FLOAT', 0);
	        return 0;
	END;
    ELSIF dataType_in = 'F' and bitLength_in = 64 and nBytes = 8 THEN
        -- This matches a double telemetered on a byte boundary, as they always have been on past missions
        -- The 2nd parameter specifies that the raw value (1st parameter) is in big-endian byte order.
        BEGIN
            valueAsNumber := TO_NUMBER( UTL_RAW.CAST_TO_BINARY_DOUBLE( HEXTORAW( hexString_in), 1));
	    EXCEPTION
	    WHEN others THEN
            logOTFD('decomFromHexString: Failed to convert bits to DOUBLE', 0);
	        return 0;
	END;
    ELSE
        -- Decomming of integer values as long as 32-bits are supported  
        -- To support these on any bit boundary, we need up to 5 bytes of raw data, 
        --     to insure all the bits are contained within the raw bytes
        -- First we bit-shift to the right, so that all the bits we're interested in
        --     are in the lower 4 bytes
        BEGIN
            valueAsNumber := TO_NUMBER( hexString_in, 'XXXXXXXXXXXXXXXX');
        EXCEPTION
        WHEN others THEN
            logOTFD('decomFromHexString: Failed to convert bits directly to NUMBER', 0);
            return 0;
        END;
        -- 'valueAsNumber' can be thought of as a 64-bit unsigned integer

        lastBitOffset := bitOffset_in + bitLength_in - 1;

        -- The following assumes big-endian values, 
        --     where the least-significant bit is transmitted last
        -- If the least-significant bit isn't located at the LSB location of a byte
        --     (lastBitOffset = 7), then right-shift the value (same as dividing by some factor
        --     of 2) so that it is  
        -- This shifts zero bits into the vacated bits
        -- There still may be non-zero bits to the left of the item which don't belong to it
        -- The FLOOR function removes any fractional part shifted right of the decimal point

        IF lastBitOffset != (nBytes*8)-1 THEN
            shiftByBits := nBytes*8 - lastBitOffset - 1;
            valueAsNumber := FLOOR( valueAsNumber / POWER( 2, shiftByBits));
        END IF;

        -- Now all the bits we're interested in are in the lower 4 bytes  
        -- If there was a 5th byte, zero it out
        
        IF nBytes = 5 THEN
            valueAsNumber := BITAND( valueAsNumber, TO_NUMBER( '00FFFFFFFF', 'XXXXXXXXXX'));
        END IF;

        -- Zero out any bits before (left of) the value's start bit
        IF MOD( bitLength_in, 8) != 0 THEN
            -- Shift a mask of 1's to the right, so there (32 - length_in) zero bits in the MSB
            -- locations and 1's where the value is.
            mask := FLOOR( TO_NUMBER( 'FFFFFFFF', 'XXXXXXXX') / POWER( 2, (32 - bitLength_in)));
            valueAsNumber := BITAND( valueAsNumber, mask);                  
        END IF;
    END IF;

    -- Checks if the outputted number value is approaching the maximum for an oracle NUMBER datatype. 
    -- If so, then return a NULL value, which is dropped later on. Any values of this magnitude are assumed
    -- to be invalid, and are discarded.
    IF valueAsNumber > 1e125 OR valueAsNumber < -1e125 THEN
        IF gblDebugLevel > 0 THEN
            logOTFD('decomFromHexString: Numeric overflow detected, dropping record with hex ' || hexString_in, 1);
        END IF;
        valueAsNumber := NULL;
        return 0;
    END IF;

    -- The bits are now set correctly for an unsigned integer
    -- If dataType is signed integer, and the MSB bit is set, then we want to interpret the bits as a negative number
    -- The correct negative value is returned by the expression:  (valueAsNumber - 2^bitLength_in)
    IF dataType_in = 'I' THEN
        -- Only attempt to BITAND if the value is an int, otherwise the operation may fail.
        bitIsSet := (BITAND(valueAsNumber, POWER(2,bitLength_in-1)) != 0);
        IF bitIsSet THEN
            valueAsNumber := valueAsNumber - POWER( 2, bitLength_in); 
        END IF;
    END IF;

    RETURN 1;

    EXCEPTION
    WHEN others THEN
        logOTFD('decomFromHexString: others exception: ' || SQLCODE || ' -ERROR- ' || SQLERRM, 0);
        return 0;

END decomFromHexString;

/*************************************************************************************************
Function:   CSV2NestedTable    

Purpose:    Converts a string containing a comma separated series of integers,
            into a nested table of integers.

Inputs:      
    p_list - VARCHAR2 The comma separated list to convert.

Returns:
    A table of nestedTable_typ containing the elements of the inputted string.

History:
  mm/dd/yy Who  What
  11/06/19 JH   Initial version.        

Notes:
    Source: https://www.oratechinfo.co.uk/delimited_lists_to_collections.html
*************************************************************************************************/
FUNCTION CSV2NestedTable
    (p_list IN VARCHAR2)
    RETURN nestedTable_typ
IS
    l_string       VARCHAR2(32767) := p_list || ',';
    l_comma_index  PLS_INTEGER;
    l_index        PLS_INTEGER := 1;
    l_tab          nestedTable_typ := nestedTable_typ();
    l_element      VARCHAR2(100);
BEGIN
    logOTFD('CSV2NestedTable: p_list=' || p_list, 2);
    
    -- Validate input is not empty, whitespace, or '-1'
    IF p_list IS NULL OR TRIM(p_list) = '' OR p_list = '-1' THEN
        logOTFD('CSV2NestedTable: Empty or invalid input list, returning default', 2);
        l_tab.EXTEND;
        l_tab(1) := -1;
        RETURN l_tab;
    END IF;
    
    LOOP
        l_comma_index := INSTR(l_string, ',', l_index);
        EXIT WHEN l_comma_index = 0;
        l_tab.EXTEND;
        l_element := SUBSTR(l_string, l_index, l_comma_index - l_index);
        BEGIN
            l_tab(l_tab.COUNT) := TO_NUMBER(l_element);
        EXCEPTION
            WHEN VALUE_ERROR OR INVALID_NUMBER THEN
                logOTFD('CSV2NestedTable: Failed to convert element "' || l_element || '" to number', 0);
                CONTINUE;
        END;
        l_index := l_comma_index + 1;
    END LOOP;
    RETURN l_tab;
    
EXCEPTION
    WHEN others THEN
        logOTFD('CSV2NestedTable: others exception: ' || SQLCODE || ' -ERROR- ' || SQLERRM, 0);
        RETURN nestedTable_typ(-1);
END CSV2NestedTable;

/*************************************************************************************************
PROCEDURE: narrowStartStopTimes

Purpose:    Given ERT or SCT start/stop times, and TelemetryStorageLocation start/stop times,
            narrows the ERT or SCT times to within the TelemetryStorageLocation times.
Inputs:
   
    startTime      - A ERT or SCT start time.
    stopTime       - A ERT or SCT stop time.
    TSLStartTime   - A time from the TelemetryStorageLocation table, -1 if invalid.
    TSLStopTime    - A time from the TelemetryStorageLocation table, -1 if invalid.

Outputs:

    queryStartTime - TSLStartTime if TSLStartTime > startTime and TSLStartTime is not -1,
                     startTime otherwise.
    queryStopTime  - TSLStopTime if TSLStopTime < stopTime, and TSLStopTime is not -1,
                     stopTime otherwise
*************************************************************************************************/
PROCEDURE narrowStartStopTimes(
    startTime    IN NUMBER,
    stopTime     IN NUMBER,
    TSLStartTime IN NUMBER,
    TSLStopTime  IN NUMBER,
    queryStartTime OUT NUMBER,
    queryStopTime  OUT NUMBER)
IS
BEGIN
    logOTFD('narrowStartStopTimes: startTime=' || startTime ||
            ', stopTime=' || stopTime ||
            ', TSLStartTime=' || TSLStartTime ||
            ', TSLStopTime=' || TSLStopTime, 2
    );

    IF (TSLStartTime = -1) THEN
        queryStartTime := startTime;
    ELSIF (TSLStartTime > startTime) THEN
        queryStartTime := TSLStartTime;
    ELSE
        queryStartTime := startTime;
    END IF;

    IF (TSLStopTime = -1) THEN
        queryStopTime := stopTime;
    ELSIF (TSLStopTime < stopTime) THEN
        queryStopTime := TSLStopTime;
    ELSE
        queryStopTime := stopTime;
    END IF;

END narrowStartStopTimes;

/*************************************************************************************************
PROCEDURE: queryL0

Purpose:    Does on-the-fly decom for one telemetry item over a time-range, with a single decom record.
            The steps involved in retrieving and decomming are as follows:
                1. Generate the SQL for the appropriate L0 query
                    - The generated query selects all relevant packets in L0_Packets, extracting a range of hexadecimal characters
                    using Oracle's built-in 'rawtohex' function.
                2. Open a cursor for the query (Note: This does not query the data, data is only queried in the next step)
                3. BULK COLLECT the data into a buffer table in memory up to a maximum of n_batch_rows rows
                4. Loop through all rows and collect SCT, ERT, ASCT, and the decommuted value into temporary arrays
                    - Decommutates the hex data into an oracle NUMBER datatype, using the offset (a bit shift off the hex range)
                    length, and data type. (decomFromHexString).
                5. Use a FORALL loop to insert all of the decommuted data into ONTHEFLYDECOM_RESULTS table as a bulk INSERT.

Inputs:
   
    decomMap            - PL/SQL table based record containing one row from the TMDecom table.
    startERT_in         - Starting earth received time in GPS microseconds.         -1 if not used.
    stopERT_in          - Stopping earth received time in GPS microseconds.         -1 if not used.
    startSCT_in         - Starting spacecraft in GPS microseconds.                  -1 if not used.
    stopSCT_in          - Stopping spacecraft in GPS microseconds.                  -1 if not used.
    startASCT_in        - Starting adjusted spacecraft time in GPS microseconds.    -1 if not used.
    stopASCT_in         - Stopping adjusted spacecraft time in GPS microseconds.    -1 if not used.
    doInclusiveQuery    - true = include stop time, false = don't include stop time
    definitionColumn    - Column that is being scanned along with decom maps.       (0: SCT, 1: ERT, 2: ASCT)
*************************************************************************************************/
PROCEDURE queryL0
    (decomMap IN tmdecom_row_t,
    startSCT_in IN NUMBER,         -- optional (-1 if not used)
    stopSCT_in IN NUMBER,          -- optional (-1 if not used)
    startERT_in IN NUMBER,         -- optional (-1 if not used)
    stopERT_in IN NUMBER,          -- optional (-1 if not used)
    startASCT_in IN NUMBER,         -- optional (-1 if not used)
    stopASCT_in IN NUMBER,          -- optional (-1 if not used)
    doInclusiveQuery IN BOOLEAN,
    definitionColumn IN NUMBER)    -- Column to apply doInclusiveQuery on.
IS
    tableName VARCHAR2(200); 
    
    -- The following are set from the 'decomMap' input argument:
    apid      NUMBER;   -- The apid of the packets in the L0_Packets table to query from.
    tlmId     NUMBER;   -- The tlmId of the desired telemetry item.
    startBit  NUMBER;   -- The zero-based offset where the first bit of the desired telemetry value
                        -- is located.  0 = first bit of packet header.
    bitLength NUMBER;   -- The number of bits in the telemetry item.
    dataType  CHAR;     -- The supported data types are a subset of those supported by the CT DB.
                        -- See the CT DB User's Guide for details.
                        -- 'F' = floating point
                        -- 'U' = unsigned integer
                        -- 'I' = signed integer
                        -- 'D' = discrete, output as an unsigned integer (no negative states!)
    
    -- Used to stitch together the query for L0_PACKETS.
    exeString        VARCHAR2(1000);
    exeStringPart1   VARCHAR2(500);
    exeStringPart2   VARCHAR2(500);

    -- Is set based on if doInclusiveQuery is set. True: <=, False: <
    booleanOpString  VARCHAR2(10);

    name_value name_value_t;    -- Mapping of name to value for each of the bind variables in the query.
    monitor_value VARCHAR2(20); -- This string is set to inject the monitor flag into SQL queries made.
    status NUMBER;              -- Temp variable for status checks

    -- Number of rows per BULK COLLECT
    n_batch_rows CONSTANT NUMBER := 100;

    -- Row structure returned by the query for times and hex string from the L0_Packets table.
    TYPE result_row_t IS RECORD( SCT NUMBER(16),
                                 ERT NUMBER(16),
                                 ASCT NUMBER(16),
                                 hexString VARCHAR(16));

    -- PL/SQL table to hold the L0_Packets query results before decomming.
    row result_row_t;
    TYPE result_table_t IS TABLE OF result_row_t INDEX BY PLS_INTEGER;
    result_table result_table_t;

    -- Cursor for the L0_Packets query.
    c curType;

    -- Temporary variables used to hold values during runtime
    hexString VARCHAR2(16);
    i NUMBER;
    byteOffset NUMBER;
    hexCharOffset NUMBER;
    bitOffsetInSubstring NUMBER;
    lastBitOffset NUMBER;
    nBytes NUMBER;
    nHexChars NUMBER;
    valueAsNumber NUMBER;

    -- Arrays for SCT, ERT, ASCT, and decommed values. These are populated once each BULK COLLECT
    -- and inserted in a single context switch.
    TYPE value_arr_t IS VARRAY(n_batch_rows) OF NUMBER;
    value_arr value_arr_t := value_arr_t();
    ert_arr value_arr_t := value_arr_t();
    sct_arr value_arr_t := value_arr_t();
    asct_arr value_arr_t := value_arr_t();

    -- Summary Statistics
    nRows NUMBER := 0;          -- # of rows successfully inserted
    nValues NUMBER := 0;        -- # of values returned for each BULK COLLECT
    nFailedDecom NUMBER := 0;   -- # of failed decommutations

    -- Determines what columns get retrieved from L0 and what placeholder to use if they are not present. 
    -- Expects to get them in the order SCT, ERT, ASCT.
    select_time_columns string_varray; -- Note: string_varray is a custom datatype that supports a max of 3 items.
    select_time_columns_string VARCHAR2(200);
    sct_time_column VARCHAR2(20);
    ert_time_column VARCHAR2(20);
    asct_time_column VARCHAR2(20);

    decom_identifier VARCHAR2(10); -- Designates whether APID or DMID is being used for queries
BEGIN
    logOTFD('queryL0: tmdecom_row_t=<not_unpackable>, startSCT_in=' || startSCT_in || 
            ', stopSCT_in=' || stopSCT_in || 
            ', startERT_in=' || startERT_in || 
            ', stopERT_in=' || stopERT_in || 
            ', startASCT_in=' || startASCT_in || 
            ', stopASCT_in=' || stopASCT_in, 2
    );

    -- Get the table name
    tableName := onTheFlyDecomMissionSpecific.getTableName(0, decomMap.systemId);

    -- Get the mapping of time columns onto SCT, ERT, and ASCT. This varies mission-to-mission, as column names may vary 
    -- or not exist at all. If a column is not queryable, a 'null AS column_name' is expected, and querying by that column 
    -- will fail before queryL0 is called.
    select_time_columns := onTheFlyDecomMissionSpecific.getTimeColumnsL0;
    select_time_columns_string := string_varrayToCSV(select_time_columns);

    sct_time_column := select_time_columns(1);
    ert_time_column := select_time_columns(2);
    asct_time_column := select_time_columns(3);

    -- Determine if dmid or apid are being used to identify the packet structure
    decom_identifier := ONTHEFLYDECOMMISSIONSPECIFIC.getDecomIdentifier;

    apid      := decomMap.apid;
    startBit  := decomMap.startBit;
    bitLength := decomMap.bitLength;
    dataType  := decomMap.dataType;

    -- Get location in binary packet of desired telemetry item from inputs.
    -- Convert to location in hex string.
    byteOffset    := FLOOR( startBit / 8);
    lastBitOffset := startBit + bitLength - 1;
    nBytes        := FLOOR( lastBitOffset / 8) + 1 - byteOffset;

    bitOffsetInSubstring := startBit - byteOffset*8;
    byteOffset := byteOffset + 1;  -- starts with 1 for dbms_lob.substr()
    
    IF (gblDebugLevel >= 1) THEN
        -- Make an associative array to tell prepareDebugSQL the variable names to replace with actual values
        -- in the query. This is used only for debugging
        name_value := name_value_t( ':nBytes'      => TO_CHAR(nBytes),
                                    ':byteOffset'  => TO_CHAR(byteOffset),
                                    ':apid'        => TO_CHAR(apid));
        
        monitor_value := ' /*+ monitor */ ';
    END IF;
    -- Formulate invariant parts of the query string.

    -- A call like this to retrieve_eng will produce a query like this:
    -- setenv,'IXPE_OTFD=1'
    -- retrieve_eng, 'EP PWMCLASIDST', [2024,100], [2024,110], forceIsInL0=1, forceIsInL1=0   (TMID=1706)
    -- The query is:  select /*+ parallel */ ERT, SCT_VTCW, rawtohex(dbms_lob.substr(packet,8,77))
    --                from L0_Packets_SID1 where apid=120 and SCT_VTCW >= 1396656018000000 and
    --                SCT_VTCW <= 1397520018000000 length >= 85 order by ERT, SCT_VTCW
    -- We found that the parallel flag has no noticeable impact on queries we expect to see, and as such has been removed.

    -- The following determines if the end point of the time query is included or not.
    -- Only the last of a series of abutted queries uses inclusive, the others are exclusive.
    -- This prevent duplicate data. This is only applied for the axis that is being iterated over, 
    -- which is passed through definitionColumn (0: SCT, 1: ERT, 2: ASCT).
    IF (doInclusiveQuery) THEN
        booleanOpString := '<=';
    ELSE
        booleanOpString := '<';
    END IF;

    exeStringPart1 := 'select ' || monitor_value || select_time_columns_string ||
                      ', rawtohex(dbms_lob.substr(packet, :nBytes, :byteOffset)) ' ||
                      'from ' || tableName || ' where ' || decom_identifier || '=:apid and ';
    exeStringPart2 := 'length >= (:byteOffset-1 + :nBytes)';

    -- I am forgoing bind variables currently due to how many permutations of queries are possible 
    -- (6 permutations of timestamps, and 3 possible definitionColumn values), which makes using bind variables verbose
    -- and confusing. Testing indicates that this implementation does not significantly reduce performance.
    CASE definitionColumn
        WHEN 0 THEN
            exeStringPart2 := exeStringPart2 || ' AND ' || sct_time_column || ' >= ' || startSCT_in ||' AND ' || sct_time_column || booleanOpString || stopSCT_in;
            IF startERT_in != -1 THEN
                exeStringPart2 := exeStringPart2 || ' AND ' || ert_time_column || ' BETWEEN ' || startERT_in || ' AND ' || stopERT_in;
            END IF;
            IF startASCT_in != -1 THEN
                exeStringPart2 := exeStringPart2 || ' AND ' || asct_time_column || ' BETWEEN ' || startASCT_in || ' AND ' || stopASCT_in;
            END IF;
        WHEN 1 THEN
            exeStringPart2 := exeStringPart2 || ' AND ' || ert_time_column || ' >= ' || startERT_in ||' AND ' || ert_time_column || booleanOpString || stopERT_in;
            IF startSCT_in != -1 THEN
                exeStringPart2 := exeStringPart2 || ' AND ' || sct_time_column || ' BETWEEN ' || startSCT_in || ' AND ' || stopSCT_in;
            END IF;
            IF startASCT_in != -1 THEN
                exeStringPart2 := exeStringPart2 || ' AND ' || asct_time_column || ' BETWEEN ' || startASCT_in || ' AND ' || stopASCT_in;
            END IF;
        WHEN 2 THEN 
            exeStringPart2 := exeStringPart2 || ' AND ' || asct_time_column || ' >= ' || startASCT_in || ' AND ' || asct_time_column || booleanOpString || stopASCT_in;
            IF startSCT_in != -1 THEN
                exeStringPart2 := exeStringPart2 || ' AND ' || sct_time_column || ' BETWEEN ' || startSCT_in || ' AND ' || stopSCT_in;
            END IF;
            IF startERT_in != -1 THEN
                exeStringPart2 := exeStringPart2 || ' AND ' || ert_time_column || ' BETWEEN ' || startERT_in || ' AND ' || stopERT_in;
            END IF;
    END CASE;

    -- Add anything mission-specific to the query.
    onTheFlyDecomMissionSpecific.addToL0Query( exeStringPart1, decomMap.systemId);
    exeString := exeStringPart1 || exeStringPart2;

    -- Replace the bind variables and log the finished query if debug level is high enough
    IF (gblDebugLevel >= 2) THEN
        logOTFD('queryL0: ' || prepareDebugSQL(exeString, name_value), 2);
    END IF;

    open c for exeString using nBytes, byteOffset, apid, byteOffset, nBytes;
    
    -- BULK COLLECT and FORALL greatly reduce the number of context switches which happen when data
    -- is passed between the Oracle PL/SQL engine and the SQL engine.  This improves performance.
    -- BULK COLLECT has a row limit of 'n_batch_rows' for each bulk collect fetch and insert.
    -- For large queries, this limits the memory required in PL/SQL so the max isn't exceeded.

    -- Make the VARRAYs big enough for the batch size.
    value_arr.EXTEND(n_batch_rows);
    ert_arr.EXTEND(n_batch_rows);
    sct_arr.EXTEND(n_batch_rows);
    asct_arr.EXTEND(n_batch_rows);

    LOOP
        -- Fetch a batch from the cursor.
        FETCH c BULK COLLECT INTO result_table LIMIT n_batch_rows;

        EXIT WHEN result_table.COUNT = 0;
        nValues := 0;
	    FOR i IN 1 .. result_table.COUNT
        LOOP
	        -- Decomm the telemetry item from the hex string in this row into a number.
            -- decomFromHexString will sometimes fail on invalid floating point numbers in the raw data.
            -- Therefore the number of valid values (and ERTs and SCTs) may be less than result_table.COUNT.
            row := result_table(i);
            status := decomFromHexString( row.hexString, bitOffsetInSubstring, bitLength, dataType,
	    	      			  valueAsNumber);
            IF (status = 1) AND (valueAsNumber IS NOT NULL) THEN
                nValues := nValues + 1;
                value_arr(nValues) := valueAsNumber;
                ert_arr(nValues)   := row.ERT;
                sct_arr(nValues)   := row.SCT;
                asct_arr(nValues)   := row.ASCT;
            ELSIF (valueAsNumber IS NULL) THEN
                -- Ignore any null values, which are a result of near-infinite values/invalid floating point values.
                -- The selectNumericTlm function will log an appropriate warning. This is not a failure of OTFD, and replicates
                -- the behavior of ingestion into L1 tables.
                CONTINUE;
	        ELSE
	            logOTFD('queryL0: ' || 'Error occurred with apid=' || TO_CHAR(apid) || ', offset=' || TO_CHAR(byteOffset) ||
		               ':' || TO_CHAR(bitOffsetInSubstring) || ', dataType=' || dataType, 0);
	            nFailedDecom := nFailedDecom + 1;
	        END IF;
        END LOOP;

        -- Formulate rows and insert them into the temporary table.
	    -- Note: FORALL is *not* a loop; it is a declarative statement to the PL/SQL engine which says:
	    -- "Generate all the DML statements that would have been executed one row at a time,
        --  and send them all across to the SQL engine with one context switch."

        -- We skip inserting all rows that violate the unique index in case
        -- the view this query comes from has duplicate data.
        FORALL indx IN 1 .. nValues
            INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(ONTHEFLYDECOM_RESULTS, ONTHEFLYDECOM_RESULTS_IDX1) */
                INTO onTheFlyDecom_results (SCT, ERT, ASCT, VALUE) VALUES 
                (sct_arr(indx), ert_arr(indx), asct_arr(indx), value_arr(indx));

        nRows := nRows + nValues; -- Increment the row counter 
    END LOOP;    
    CLOSE c;

    logOTFD('queryL0: inserted ' || nRows || ' rows into onTheFlyDecom_results table.', 2);
    
    IF nFailedDecom > 0 THEN
        logOTFD('queryL0: ' || nFailedDecom || ' decommutations failed or returned invalid values', 0);
    END IF;

    RETURN;

    EXCEPTION
    WHEN others THEN
        logOTFD('queryL0: others exception: ' || SQLCODE || ' -ERROR- ' || SQLERRM, 0);
        RETURN;
END queryL0;



/*************************************************************************************************
Procedure:  queryL1

Purpose:    Queries the appropriate L1 table (TManalog or TMdiscrete) for the L1 data, and
            inserts the data into the temporary table.
            The steps involved in retrieving the data are as follows:
                1. Determine what table to query based on data type and mission-specific table names.
                2. Use the passed definitionColumn parameter to to narrow the start and stop times to 
                   the TSL start and stop times, as well as determine which column to apply doInclusiveQuery
                   to.
                3. Run the INSERT INTO - SELECT query to return the results to onTheFlyDecom_results.

Inputs:    These are mostly the same inputs as selectNumericTlm.

    systemId_in         - NUMBER SID or schemaId, depending on mission.     
    tlmId_in            - NUMBER Same as TMID.       
    startERT_in         - NUMBER Starting earth received time in GPS microseconds.      -1 if not used.
    stopERT_in          - NUMBER Stopping earth received time in GPS microseconds.      -1 if not used.
    startSCT_in         - NUMBER Starting spacecraft time in GPS microseconds.          -1 if not used.
    stopSCT_in          - NUMBER Stopping spacecraft time in GPS microseconds.          -1 if not used.
    startASCT_in        - NUMBER Starting adjusted spacecraft time in GPS microseconds. -1 if not used.
    stopASCT_in         - NUMBER Stopping adjusted spacecraft time in GPS microseconds. -1 if not used.
    TSLRowStartTime     - NUMBER TelemetryStorageLocation start time
    TSLRowStopTime      - NUMBER TelemetryStorageLocation stop time
    dataType            - VARCHAR
    doInclusiveQuery    - BOOLEAN
    definitionColumn    - Column that is being scanned along with decom maps. (0: SCT, 1: ERT, 2: ASCT)
*************************************************************************************************/
PROCEDURE queryL1
    (systemId_in IN NUMBER,
    tlmId_in IN NUMBER,
    startERT_in IN NUMBER,       -- optional (-1 if not used)
    stopERT_in IN NUMBER,        -- optional (-1 if not used)
    startSCT_in IN NUMBER,       -- optional (-1 if not used)
    stopSCT_in IN NUMBER,        -- optional (-1 if not used)
    startASCT_in IN NUMBER,       -- optional (-1 if not used)
    stopASCT_in IN NUMBER,        -- optional (-1 if not used)
    TSLRowStartTime IN NUMBER,   -- optional (-1 if not used)
    TSLRowStopTime IN NUMBER,    -- optional (-1 if not used)
    dataType IN VARCHAR2,
    doInclusiveQuery IN BOOLEAN,
    definitionColumn IN NUMBER)  -- Column to apply doInclusiveQuery on, as well as the column to narrow to TSL record.
IS
    exeString VARCHAR2(500); -- This string contains sql commands to be executed
    tableName VARCHAR2(200); -- Name of the L1 table. This varies between missions and is pulled from the mission-specific code.
    name_value name_value_t; -- Mapping of bind variable names to values for debug output.

    -- Is set based on if doInclusiveQuery is set. True: <=, False: <
    booleanOpString VARCHAR(2);

    -- Contain the bounds for the definition column.
    queryStart NUMBER;
    queryStop NUMBER; 

    -- Determines what columns get retrieved from L0 and what placeholder to use if they are not present. 
    -- Expects to get them in the order SCT, ERT, ASCT.
    select_time_columns string_varray; -- Note: string_varray is a custom datatype that supports a max of 3 items.
    select_time_columns_string VARCHAR2(200);
    sct_time_column VARCHAR2(20);
    ert_time_column VARCHAR2(20);
    asct_time_column VARCHAR2(20);

    -- Contains either a monitor flag or an empty string based on debug level.
    monitor_value VARCHAR2(20); 
BEGIN
    logOTFD('queryL1: systemId_in=' || systemId_in || 
            ', tlmId_in=' || tlmId_in ||
            ', startERT_in=' || startERT_in || 
            ', stopERT_in=' || stopERT_in ||
            ', startSCT_in=' || startSCT_in || 
            ', stopSCT_in=' || stopSCT_in ||
            ', startASCT_in=' || startASCT_in || 
            ', stopASCT_in=' || stopASCT_in ||
            ', TSLRowStartTime=' || TSLRowStartTime ||
            ', TSLRowStopTime=' || TSLRowStopTime ||
            ', dataType=' || dataType ||
            ', doInclusiveQuery=' || sys.diutil.bool_to_int(doInclusiveQuery) ||
            ', definitionColumn=' || definitionColumn, 2
    );

    IF (datatype != 'D') THEN
        -- Query TManalog
        tableName := onTheFlyDecomMissionSpecific.getTableName(1, systemId_in);
    ELSE 
        -- Query TMdiscrete
        tableName := onTheFlyDecomMissionSpecific.getTableName(2, systemId_in);
        -- TManalog.Value is defined as NUMBER, but TMdiscrete.Value is 
        -- defined as NUMBER(20). This is not a problem because 
        -- onTheFlyDecom_results has the default precision of 38.
    END IF;

    IF (gblDebugLevel >= 1) THEN
        -- Make an associative array to tell prepareDebugSQL the variable names to replace with actual values
        -- in the query.  This is for a debug string.  Query start/stop times are added later.
        name_value := name_value_t( ':tlmId_in' => TO_CHAR(tlmId_in));  -- This is the only bind var in use currently. Everything else is string-concatenated in.

        monitor_value := ' /*+ monitor */ ';
    END IF;		

    select_time_columns := onTheFlyDecomMissionSpecific.getTimeColumnsL1;
    select_time_columns_string := string_varrayToCSV(select_time_columns);

    sct_time_column := select_time_columns(1);
    ert_time_column := select_time_columns(2);
    asct_time_column := select_time_columns(3);    

    -- Define the invariant part of the query. We skip inserting all rows that violate the unique index in case
    -- the view this query comes from has duplicate data.
    exeString := ' INSERT /*+ IGNORE_ROW_ON_DUPKEY_INDEX(ONTHEFLYDECOM_RESULTS, ONTHEFLYDECOM_RESULTS_IDX1) */
                   INTO onTheFlyDecom_results (SCT, ERT, ASCT, Value) ' ||
                 ' SELECT ' || monitor_value || select_time_columns_string || ', Value from ' || tableName ||
		         ' WHERE TMID = :tlmId_in';

    IF doInclusiveQuery THEN
        booleanOpString := '<=';
    ELSE
        booleanOpString := '<';
    END IF;

    -- Narrow by the definition column used for TSL fetch, and query by the rest if provided.
    CASE definitionColumn
        WHEN 0 THEN
            narrowStartStopTimes(startSCT_in, stopSCT_in, TSLRowStartTime, TSLRowStopTime, queryStart, queryStop);
            exeString := exeString || ' AND ' || sct_time_column || ' >= ' || queryStart ||' AND ' || sct_time_column || booleanOpString || queryStop;
            IF startERT_in != -1 THEN
                exeString := exeString || ' AND ' || ert_time_column || ' BETWEEN ' || startERT_in || ' AND ' || stopERT_in;
            END IF;
            IF startASCT_in != -1 THEN
                exeString := exeString || ' AND ' || asct_time_column || ' BETWEEN ' || startASCT_in || ' AND ' || stopASCT_in;
            END IF;
        WHEN 1 THEN
            narrowStartStopTimes(startERT_in, stopERT_in, TSLRowStartTime, TSLRowStopTime, queryStart, queryStop);
            exeString := exeString || ' AND ' || ert_time_column || ' >= ' || queryStart ||' AND ' || ert_time_column || booleanOpString || queryStop;
            IF startSCT_in != -1 THEN
                exeString := exeString || ' AND ' || sct_time_column || ' BETWEEN ' || startSCT_in || ' AND ' || stopSCT_in;
            END IF;
            IF startASCT_in != -1 THEN
                exeString := exeString || ' AND ' || asct_time_column || ' BETWEEN ' || startASCT_in || ' AND ' || stopASCT_in;
            END IF;
        WHEN 2 THEN 
            narrowStartStopTimes(startASCT_in, stopASCT_in, TSLRowStartTime, TSLRowStopTime, queryStart, queryStop);
            exeString := exeString || ' AND ' || asct_time_column || ' >= ' || queryStart || ' AND ' || asct_time_column || booleanOpString || queryStop;
            IF startSCT_in != -1 THEN
                exeString := exeString || ' AND ' || sct_time_column || ' BETWEEN ' || startSCT_in || ' AND ' || stopSCT_in;
            END IF;
            IF startERT_in != -1 THEN
                exeString := exeString || ' AND ' || ert_time_column || ' BETWEEN ' || startERT_in || ' AND ' || stopERT_in;
            END IF;
    END CASE;

    -- Add anything mission-specific to the query, such as testId or tlmFileName.
    onTheFlyDecomMissionSpecific.addToL1Query(exeString, systemId_in);

    logOTFD('queryL1: ' || prepareDebugSQL(exeString, name_value), 2);

    -- Insert the values.
    EXECUTE IMMEDIATE exeString USING IN tlmId_in;

    logOTFD('queryL1: inserted ' || sql%Rowcount || ' rows into onTheFlyDecom_results table.', 2);

    -- Warn if no rows were returned
    IF sql%Rowcount = 0 THEN
        logOTFD('queryL1: Warning - Query returned 0 rows for tlmId=' || tlmId_in || 
                ', systemId=' || systemId_in || 
                ', queryStart=' || queryStart || 
                ', queryStop=' || queryStop, 1);
    END IF;
    
    RETURN;
    
EXCEPTION
    WHEN others THEN
        logOTFD('queryL1: others exception: ' || SQLCODE || ' -ERROR- ' || SQLERRM || 
                ' for tlmId=' || tlmId_in || ', systemId=' || systemId_in, 0);
        RETURN;
END queryL1;


/*************************************************************************************************
Procedure:  selectNumericTlm  

Purpose:    Primary end-user interface for onTheFlyDecom. Gets requested data from either the L0 table,
            the L1 table, or both, depending on the entries in TSL and TMDecom. Stores this data into 
            onTheFlyDecom_results.

Inputs:      
    systemId_in     - NUMBER SID or schemaId, depending on mission.     
    tlmId_in        - NUMBER Same as TMID.       
    startERT_in     - NUMBER Starting earth received time in GPS microseconds.      -1 if not used.
    stopERT_in      - NUMBER Stopping earth received time in GPS microseconds.      -1 if not used.
    startSCT_in     - NUMBER Starting spacecraft time in GPS microseconds.          -1 if not used.
    stopSCT_in      - NUMBER Stopping spacecraft time in GPS microseconds.          -1 if not used.
    startASCT_in    - NUMBER Starting adjusted spacecraft time in GPS microseconds. -1 if not used.
    stopASCT_in     - NUMBER Stopping adjusted spacecraft time in GPS microseconds. -1 if not used.

Notes:
    1. Input Times:
        Any combination of ERT time, SCT time, or ASCT time can be used to query OTFD, depending on
        mission-specific compatibility requirements. Some mission-specific options can allow for queries
        to be performed on other parameters, such as testId and filename.
  2. Algorithm:
    A. Initialization
        Clear Global Temporary Tables, determine what time range to use to query TelemetryStorageLocation 
        and TMDecom, get datatype for TLMID, and parse the 'APID' optional parameter if set.
    
    B. Get TelemetryStorageLocation rows and process them
        Using the results from getDefinitionStartStopTimes, retrieve all relevant TSL rows. If none are
        returned, call queryL1 as a fallback.
        Iterate through each row, determining what time range each is valid for, and retrieve
        the relevant TMDecom rows if applicable. If the row indicates the data is located in an L1 table, 
        call queryL1.

    C. Get TMDecom rows and process them
        After getting all relevant TMDecom rows for a given TSL entry, iterate through each, determine
        the effective time range, and call queryL0 for each.

*************************************************************************************************/
PROCEDURE selectNumericTlm
    (systemId_in IN NUMBER,
    tlmId_in IN NUMBER,
    startERT_in IN NUMBER DEFAULT -1,
    stopERT_in IN NUMBER DEFAULT -1,
    startSCT_in IN NUMBER DEFAULT -1,
    stopSCT_in IN NUMBER DEFAULT -1,
    startASCT_in IN NUMBER DEFAULT -1,
    stopASCT_in IN NUMBER DEFAULT -1
    )
IS
    -- Determined from the query input, is based on what time column to use to query TSL and TMDecom
    -- EMA uses ASCT as the timestamp for their column, while most other missions use ERT with SCT as 
    -- a fallback.
    definitionStartTime NUMBER;
    definitionStopTime NUMBER;
    definitionColumn NUMBER;    -- 1: SCT, 2: ERT, 3: ASCT

    -- An array of APIDs set by the gblAPIDs flag.
    apidArray nestedTable_typ;
    -- Custom exception if mission-specific code is unable to determine the correct definition time column.
    -- or if user did not input a required time field.
    definition_error EXCEPTION;
    -- Datatype of the TLMID. Supported: U, I, F, D
    dataType VARCHAR2(1);
    -- Temp variable to get returned status of helper functions
    status NUMBER;

    -- Cursors for TMDecom and TelemetryStorageLocation queries.
    tmd_cursor curType;
    tsl_cursor curType;
BEGIN 
    logOTFD('selectNumericTlm: systemId_in=' || systemId_in || 
            ', tlmId_in=' || tlmId_in || 
            ', startSCT_in=' || startSCT_in || 
            ', stopSCT_in=' || stopSCT_in || 
            ', startERT_in=' || startERT_in || 
            ', stopERT_in=' || stopERT_in || 
            ', startASCT_in=' || startASCT_in || 
            ', stopASCT_in=' || stopASCT_in, 2
    );
    -- A: Initialize procedure: Clear tables, validate inputs, handle APID logic.

    -- Note: Steve Monk previously had issues with the truncate command, but recent testing has not been able to duplicate those issues.
    EXECUTE IMMEDIATE 'TRUNCATE TABLE onTheFlyDecom_results';
    EXECUTE IMMEDIATE 'TRUNCATE TABLE onTheFlyDecom_errors';
    gblSequence := 1;
    
    -- Determines which field to use for the time range, and returns which column to iterate over for
    -- TelemetryStorageLocation and TMDecom rows. This is typically the ERT range of the query, but 
    -- may also be an SCT range or altered by options such as testID. This function will fail cleanly on
    -- unsupported time inputs.
    status := onTheFlyDecomMissionSpecific.getDefinitionStartStopTimes( 
        systemId_in,
        startSCT_in, stopSCT_in,
        startERT_in, stopERT_in,
        startASCT_in, stopASCT_in,

        definitionStartTime,
        definitionStopTime,
        definitionColumn
    );

    IF (status != 1) THEN
        raise definition_error;
    END IF;
    
    logOTFD('selectNumericTlm: definitionStartTime=' || definitionStartTime || 
            ', definitionStopTime=' || definitionStopTime || 
            ', definitionColumn=' || definitionColumn, 2);

    IF (gblDecomMapTimeGPS != -1) THEN
        logOTFD( 'selectNumericTlm: gblDecomMapTimeGPS = ' || TO_CHAR( gblDecomMapTimeGPS), 2);
    END IF;

    -- Initialize apidArray
    apidArray := CSV2NestedTable( gblApids);

    -- Determine the datatype and check validity. This is static. 
    EXECUTE IMMEDIATE 'SELECT dataType from TelemetryItemDefinition WHERE tlmId = ' || tlmId_in
        INTO dataType;
    
    logOTFD('selectNumericTlm: Retrieved dataType=' || dataType || ' for tlmId=' || tlmId_in, 2);

    -- Check that dataType is in the supported set: unsigned or signed int, float or discrete.
    -- We don't support strings by design.
    IF (NOT ((dataType = 'U') OR (dataType = 'I') OR (dataType = 'F') OR (dataType = 'D'))) THEN
        logOTFD('selectNumericTlm: unsupported dataType for tlmId=' || tlmId_in || ': ' || dataType, 0);
        RETURN;
    END IF;

    -- B: Get TelemetryStorageLocation rows:

    -- Subsequent logic depends on order by clause including apid, for when multiple apids are present.

    -- PL/SQL block for iterating through TSL and TMDecom rows
    DECLARE 
        -- Define a table for the above query's results.
        TYPE TSL_typ IS TABLE OF tsl_row_t INDEX BY PLS_INTEGER;
        TSLRows TSL_typ;

        TSLRowStartTime NUMBER;
        TSLRowStopTime NUMBER;
        TMDRowStartTime NUMBER;
        TMDRowStopTime NUMBER;
        TMDQueryStartTime NUMBER;
        TMDQueryStopTime NUMBER;
        isInL1 BOOLEAN;
        isInL0 BOOLEAN;
        isLastTSLRow BOOLEAN;
        isLastTMDRow BOOLEAN;
        doInclusiveQuery BOOLEAN;
    BEGIN
        -- Creates a cursor for the TelemetryStorageLocation table using the mission-specific code. This is primarily because
        -- EMA has a different decom-id system which needs to be accounted for. Note that this MUST return a cursor with the 
        -- ORDER BY clause 'ORDER BY definitionStart, apid'. 
        queryTSL(systemId_in, tlmId_in, definitionStartTime, definitionStopTime, tsl_cursor);
        FETCH tsl_cursor BULK COLLECT INTO TSLRows;
        CLOSE tsl_cursor;
        
        logOTFD('selectNumericTlm: Fetched ' || TSLRows.COUNT || ' TelemetryStorageLocation rows', 2);

        IF TSLRows.COUNT = 0 THEN
            -- No TSL rows exist, so must be a derived item or other non-packetized item, which are only stored in the L1 tables.
            logOTFD('selectNumericTlm: No TSL rows exist, must be a derived item; querying L1...', 2);
            queryL1( systemId_in, tlmId_in, startERT_in, stopERT_in, startSCT_in, stopSCT_in, startASCT_in, stopASCT_in,
	             -1, -1, dataType, true, definitionColumn);
	        RETURN;
        END IF;

        FOR i IN 1 .. TSLRows.COUNT LOOP
            -- NOTE: PL/SQL arrays and tables start at index one, not zero
            logOTFD('selectNumericTlm: Processing TSL row ' || i || ' of ' || TSLRows.COUNT || 
                    ', definitionStart=' || TSLRows(i).definitionStart || 
                    ', apid=' || TSLRows(i).apid || 
                    ', isInL0=' || TSLRows(i).isInL0 || 
                    ', isInL1=' || TSLRows(i).isInL1, 2);

            -- If an option is in effect to override isInL0 and/or isInL1, do so.
	        -- This is only used in testing.
            IF (gblForceIsInL0 != -1) THEN
	            IF (TSLRows(i).isInL0 != gblForceIsInL0) THEN
		            logOTFD('selectNumericTlm: changing TSLRows(' || TO_CHAR(i) || ').isInL0 to ' || TO_CHAR( gblForceIsInL0), 2);
		        END IF;
	            TSLRows(i).isInL0 := gblForceIsInL0;
	        END IF;
            IF (gblForceIsInL1 != -1) THEN
	            IF (TSLRows(i).isInL1 != gblForceIsInL1) THEN
		            logOTFD('selectNumericTlm: changing TSLRows(' || TO_CHAR(i) || ').isInL1 to ' || TO_CHAR( gblForceIsInL1), 2);
		        END IF;
	            TSLRows(i).isInL1 := gblForceIsInL1;
	        END IF;

            -- Set variables for where telemetry points are: in the L0 or L1 tables.
            If (TSLRows(i).isInL0 = 1) THEN
                isInL0 := TRUE;
            ELSE
                isInL0 := FALSE;
            END IF;

            IF (TSLRows(i).isInL1 = 1) THEN
                isInL1 := TRUE;
            ELSE
                isInL1 := FALSE;
            END IF;

            -- Skip this row and warn if both isInL0=0 and isInL1=0.
            IF (isInL0 = false AND isInL1 = false) THEN
                logOTFD('selectNumericTlm: TSL Row starting at ' || TSLRows(i).definitionStart || ' reports false for isInL0 and isInL1. Skipping...', 1);
                CONTINUE;
            END IF;

            -- Set isLastTSLRow to true if this is the last TSL row for this apid.
            -- This controls whether the end time of the query is inclusive or exclusive.
            -- a. We want exclusive for all except the last row, so that we don't get duplicates in the
            --    onTheFlyDecom_results or TMDecom table.
            -- b. We want exclusive for an end marker too, so we don't decom from a packet whose ERT
            --    exactly equals the definitionStart of the end marker.
            --    An end marker (isInL0=0, isInL1=0) exists for a telemetry item which is no longer
            --    in this apid after its definitionStart, but it used to be in this apid.  There could
            --    also could be a row *after* the end marker, if the telemetry item was re-instated.

            IF (i = TSLRows.COUNT) THEN
	            isLastTSLRow := true;
            ELSE
	            -- Determine if this is the last row for this apid.  If a row with the same apid follows,
                -- even if it's a end marker, then we don't flag it as the last row, since we want an
                -- exclusive end time for the query.
                isLastTSLRow := true;
                FOR j IN i+1 .. TSLRows.COUNT LOOP
                    IF TSLRows(j).apid = TSLRows(i).apid THEN
                        isLastTSLRow := false;
                        EXIT;
                    END IF;
                END LOOP;
            END IF;
	    
            -- Set adjusted start and stop times for this TSL row.
            -- If a row's start or stop time is outside the user's time range,
    	    -- force it to be within the user's time range.

            -- Set TSLRowStartTime = definitionStartTime, if it is outside the user's range.
            IF (TSLRows(i).definitionStart < definitionStartTime) THEN
                TSLRowStartTime := definitionStartTime;
            ELSE
                TSLRowStartTime := TSLRows(i).definitionStart;
            END IF;

            -- Set TSLRowStopTime = definitionStopTime, if it is outside the user's range
            IF (i = TSLRows.COUNT) THEN
                TSLRowStopTime := definitionStopTime;
            ELSE
	        -- Set TSLRowStopTime to the definitionStart of the next TSL record with this apid,
            -- or to the user's definitionStopTime if there is no next TSL record with this apid.
            TSLRowStopTime := definitionStopTime;
            FOR j IN i+1 .. TSLRows.COUNT LOOP
                IF TSLRows(j).apid = TSLRows(i).apid THEN
                    TSLRowStopTime := TSLRows(j).definitionStart;
                    EXIT;
                END IF;
            END LOOP;
        END IF;
        
        logOTFD('selectNumericTlm: TSL row ' || i || ' adjusted times: ' || 
                'TSLRowStartTime=' || TSLRowStartTime || 
                ', TSLRowStopTime=' || TSLRowStopTime, 2);

         -- C: Get the decom rows applicable to this tlmId and to the time range of the TSL row.

        -- Normally the TSL row start/stop times are used as the end points of the following query.
        -- But if the user specified gblDecomMapTimeGPS, then that time is used for both end points,
        -- and the query yields the record whose definitionStart is closest to gblDecomMapTimeGPS
        -- but before or equal to gblDecomMapTimeGPS.
        IF (gblDecomMapTimeGPS = -1) THEN
            TMDQueryStartTime := TSLRowStartTime;
            TMDQueryStopTime  := TSLRowStopTime;
        ELSE
            TMDQueryStartTime := gblDecomMapTimeGPS;
            TMDQueryStopTime  := gblDecomMapTimeGPS;
            logOTFD('selectNumericTlm: Using gblDecomMapTimeGPS override for TMD query times', 2);
        END IF;

        -- In order to prevent duplicate TMDecom rows from being retrieved, only the final TMD query is inclusive of the end time. 
        -- The rest of the queries are only inclusive on the start timestamp, which is the same as the end timestamp for the previous query.
        IF isLastTSLRow THEN
            logOTFD('selectNumericTlm: Reached final TSL row for APID ' || TSLRows(i).apid || ' TMDecom query now includes end of range.', 2);
        END IF;
        
        logOTFD('selectNumericTlm: Querying TMDecom with times: ' || 
                'TMDQueryStartTime=' || TMDQueryStartTime || 
                ', TMDQueryStopTime=' || TMDQueryStopTime, 2);
        

        -- Make a table of tmdecom rows.
        DECLARE 
            TYPE TMD_typ IS TABLE OF tmdecom_row_t INDEX BY PLS_INTEGER;
            TMDRows TMD_typ;

            -- Declare all other variables
            TSLRowApid NUMBER;
            tmpRowsWritten NUMBER;

        BEGIN
            -- Get data from TMDecom.  For L0 queries, this gives the offset and size of the telemetry item
            -- (datatype is ignored, TelemetryItemDefinition is used).
            queryTMDecom(systemId_in, TSLRows(i).apid, tlmId_in, TMDQueryStartTime, TMDQueryStopTime, isLastTSLRow, tmd_cursor);
            FETCH tmd_cursor BULK COLLECT INTO TMDRows; 
            CLOSE tmd_cursor;
            
            logOTFD('selectNumericTlm: Fetched ' || TMDRows.COUNT || ' TMDecom rows for apid=' || TSLRows(i).apid, 2);

            IF (isInL1 = true) THEN
                logOTFD('selectNumericTlm: Taking L1 path for TSL row ' || i || ', querying L1 tables', 2);
		        queryL1(systemId_in, tlmId_in, startERT_in, stopERT_in, startSCT_in, stopSCT_in, startASCT_in, stopASCT_in,
		             TSLRowStartTime, TSLRowStopTime, dataType, isLastTSLRow, definitionColumn);
                CONTINUE;  -- to next TSL row
            END IF;  -- isInL1 = true

            -- If not in L1 and no TMDecom rows found, skip TSL row.
            IF (TMDRows.COUNT = 0) THEN
                logOTFD('selectNumericTlm: No TMDecom rows returned for Start Time ' || TMDQueryStartTime || ' and End Time ' || TMDQueryStopTime, 1);
                CONTINUE;
            END IF;

		    -- If we got this far, then we're querying from L0 and doing on-the-fly decom.
		    logOTFD('selectNumericTlm: Taking L0 path for TSL row ' || i || ', performing on-the-fly decom', 2);
		    
            TSLRowApid := TSLRows(i).apid;

            FOR j in 1 .. TMDRows.COUNT LOOP
            -- Continue with the next row if startBit=-1 (an end marker)
		    -- This shouldn't happen because is should be true that isInL0=0 and isInL1=0.
		    -- This is just for extra robustness in case TSL and TMD don't both have end markers.
		    
                logOTFD('selectNumericTlm: Processing TMD row ' || j || ' of ' || TMDRows.COUNT || 
                        ' for TSL row ' || i || ', definitionStart=' || TMDRows(j).definitionStart, 2);
		    
                IF (TMDRows(j).startBit = -1) THEN
                    logOTFD('selectNumericTlm: TMDecom row Starting at ' || TMDRows(i).definitionStart || ' is an end marker (startBit -1). Skipping...', 2);
                    CONTINUE;
                END IF;

                -- Set isLastTMDRow to true if this is the last TMD row.  This contributes to whether
                -- the end time of the query is inclusive or exclusive.  We want exclusive for all
	            -- except the last TSL and TMD rows, so that we don't get duplicates in the onTheFlyDecom_results
                -- table.  Both isLastTMDRow and isLastTSLRow must be true for the query to be inclusive
                -- of the end time;  otherwise we are still piecing together multiple abutting queries,
                -- and want them to be exclusive of the end time until the last one.
	            IF (j = TMDRows.COUNT) THEN
	                isLastTMDRow := true;
	            ELSE
		            isLastTMDRow := false;
                END IF;
                doInclusiveQuery := (isLastTSLRow AND isLastTMDRow);

                logOTFD('selectNumericTlm: isLastTSLRow = ' || sys.diutil.bool_to_int(isLastTSLRow) ||
                        ', isLastTMDRow = ' || sys.diutil.bool_to_int(isLastTMDRow) ||
                        ', doInclusiveQuery = ' || sys.diutil.bool_to_int(doInclusiveQuery), 
                2);
			     
                -- Get start and stop times for this TMD row.  Adjust these times so they're within the range
                -- of the TSL record, because we don't want to query outside the TSL record's range.
                -- Also if this is the last TMD record, widen the stop time to be the TSL stop time, because
                -- the TMD record is valid until at least then. If the user specified gblDecomMapTimeGPS, 
                -- then set the one and only TMD row's start time to the TSL start time.
                IF (TMDRows(j).definitionStart < TSLRowStartTime) THEN
                    TMDRowStartTime := TSLRowStartTime;
                ELSE
                    IF (gblDecomMapTimeGPS = -1) THEN
                        TMDRowStartTime := TMDRows(j).definitionStart;
                    ELSE
                        TMDRowStartTime := TSLRowStartTime;
                    END IF;
                END IF;

                -- TMDRowsStopTime = definitionStopTime if it is outside the range
                IF (j = TMDRows.COUNT) THEN
                    TMDRowStopTime := TSLRowStopTime;
			        -- This is applied for the last of multiple rows, and if user specified gblDecomMapTimeGPS.
                ELSE
                    TMDRowStopTime := TMDRows(j+1).definitionStart;
                END IF;
                
                logOTFD('selectNumericTlm: TMD row ' || j || ' adjusted times: ' || 
                        'TMDRowStartTime=' || TMDRowStartTime || 
                        ', TMDRowStopTime=' || TMDRowStopTime, 2);

                -- This makes a call back to the mission-specific code.

                IF ((apidArray(1) = -1) OR ((apidArray(1) != -1) AND (TSLRowApid MEMBER OF apidArray))) THEN
                    -- Use definitionColumn to determine which time column to restrict by decom map and which ones to 
                    -- 'loosely bound' the query (0: SCT, 1: ERT, 2: ASCT). 
                    
                    logOTFD('selectNumericTlm: Calling queryL0 for apid=' || TSLRowApid || 
                            ', definitionColumn=' || definitionColumn, 2);

                    CASE definitionColumn
                        WHEN 0 THEN
                            queryL0(TMDRows(j), TMDRowStartTime, TMDRowStopTime, startERT_in, stopERT_in, startASCT_in, stopASCT_in, doInclusiveQuery, definitionColumn);
                        WHEN 1 THEN
                            queryL0(TMDRows(j), startSCT_in, stopSCT_in, TMDRowStartTime, TMDRowStopTime, startASCT_in, stopASCT_in, doInclusiveQuery, definitionColumn);
                        WHEN 2 THEN 
                            queryL0(TMDRows(j), startSCT_in, stopSCT_in, startERT_in, stopERT_in, TMDRowStartTime, TMDRowStopTime, doInclusiveQuery, definitionColumn);
                    END CASE;
                ELSE
                    logOTFD('selectNumericTlm: Skipping apid=' || TSLRowApid || ' due to apid filter', 2);
                END IF;
            END LOOP;  -- end loop through TMdecom rows
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    logOTFD('selectNumericTlm: ' || 'No TMDecom rows found for time range ' || TSLRowStartTime || ' - ' || TSLRowStopTime, 0);
                WHEN others THEN
                    logOTFD('selectNumericTlm: fetch block: others exception: ' || SQLCODE || ' -ERROR- ' || SQLERRM, 0);
            END;    
        END LOOP;  -- end loop through TelemetryStorageLocation rows

        logOTFD('selectNumericTlm: Completed processing all TSL rows, calling collateErrors', 2);
        collateErrors();

        RETURN;

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            logOTFD('selectNumericTlm: No telemetryStorageLocation rows found for time range ' || definitionStartTime || ' - ' || definitionStopTime, 0);
            collateErrors();
            RETURN;
    END;

    EXCEPTION
        WHEN definition_error THEN
            logOTFD('selectNumericTlm: Definition Error. Input parameters invalid.', 0);
            collateErrors();
            RETURN;
        WHEN others THEN
            logOTFD('selectNumericTlm: others exception: ' || SQLCODE || ' -ERROR- ' || SQLERRM, 0);
            collateErrors();
            RETURN;

END selectNumericTlm;
END onTheFlyDecom;
/