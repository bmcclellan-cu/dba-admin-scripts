/*************************************************************************************************
File:       onTheFlyDecomMissionSpecificEMA.pkb (package body for package: onTheFlyDecomMissionSpecific

Purpose:    EMA-specific code for on-the-fly decom, called by the core package.
  
Revisions:
  mm/dd/yy who  description
  08/27/25 RS   Initial Version
  
Usage: 
  1. In sqlplus:
     @<full_path>/onTheFlyDecomMissionSpecific.pks      -- compile the package spec
     @<full_path>/onTheFlyDecomMissionSpecificEMA.pkb  -- compile the package body

Notes:
  1. Contents (In order of appearance)          
     FUNCTION  getVersion
     PROCEDURE setOption
     PROCEDURE clearOption
     FUNCTION  getTableName
     FUNCTION  getTimeColumnsL0
     FUNCTION  getTimeColumnsL1
     PROCEDURE addToL0Query
     PROCEDURE addToL1Query
     PROCEDURE getDecomMapCur
     PROCEDURE getTSLCur
     PROCEDURE getDefinitionStartStopTimes
     
  2. Mission Specific Global Variables:
     These are optional inputs which can be set by calling setOption or clearOption.
     
  3. Compiler Errors:
     - A login.sql file can cause compiler errors.
     - If the ampersand character is present in a comment, in sqlplus will get this prompt
       upon compiling, and some error messages:
       Enter value for t:  (where t is the letter after the ampersand)

*************************************************************************************************/


CREATE OR REPLACE PACKAGE BODY EMA_MISC.onTheFlyDecomMissionSpecific
AS

-- These options are settable by calling the setOption or clearOption procedure.
-- A -1 value or empty string means the option won't be used in queries.  I.e. either it
-- hasn't yet been set by the user, the user reset it.  These variables may be different
-- for different missions, as may the options which selectNumericTlm supports.
-- Each mission has its own instance of this code, although it may be identical for missions
-- with the same options.  We do not support a generalized code base which supports all options.
gblTlmFileName   VARCHAR2(128) := '';

-- TODO: Add global flag for RT/PBK data.

/*************************************************************************************************
Function:  getVersion

Purpose:    This procedure will return version string.

*************************************************************************************************/
FUNCTION getVersion
         RETURN VARCHAR2
IS
BEGIN
    return 'EMA 0.1';
END getVersion;

/*************************************************************************************************
Function:  setOption

Purpose:    This function sets the specified mission-specific global variable to the specified value.

Input:      optionName  - String giving the name of the option, case insensitive.
            optionValue - String giving the value of the option; if the actual option is an integer,
	                  convert it to a string first.
Returns:    1=success, 0=failure			 
*************************************************************************************************/
FUNCTION setOption( optionName VARCHAR2,
                    optionValue VARCHAR2)
		    RETURN NUMBER
IS
    upperCaseOptionName VARCHAR2(128) := '';
BEGIN
    RETURN 0;
END setOption;



/*************************************************************************************************
Function:  clearOption

Purpose:    This function sets the specified mission-specific option to its default value.

Input:      optionName  - String giving the name of the option, case insensitive.

Returns:    1=success, 0=failure			 
*************************************************************************************************/
FUNCTION clearOption( optionName VARCHAR2)
                      RETURN NUMBER
IS
    upperCaseOptionName VARCHAR2(128) := '';
BEGIN
    RETURN 0;
END clearOption;



/*************************************************************************************************
Function:  getOptionsHelp

Purpose:    This procedure returns an options help string.

*************************************************************************************************/
FUNCTION getOptionsHelp
         RETURN VARCHAR2
IS
BEGIN
    return '';
END getOptionsHelp;

/*************************************************************************************************
Function:   getTableName

Purpose:    This function returns a table name constructed using the input type and systemId.

Input:      type_in     - NUMBER Determines how the VCs will be converted into table names.
                             0 Indicates some instance of the L0_Packets table is desired.
                             1 Indicates some instance of the TManalog table is desired.
                             2 Indicates some instance of the TMdiscrete table is desired.
            systemId_in - NUMBER SID or schemaId, depending on mission.

Returns:    A table name as a VARCHAR2

*************************************************************************************************/
FUNCTION getTableName( type_in IN NUMBER,
                       systemId_in IN NUMBER)
                       RETURN VARCHAR2
IS
    databaseName VARCHAR2(64) := '';
    tableName VARCHAR2(64) := '';
    tableNameExtension VARCHAR2(10) := '';
    invalidType EXCEPTION;
BEGIN
    -- Get base tablename by type.
    IF (type_in = 0) THEN
        tableName := 'L0_Packets';
    ELSIF (type_in = 1) THEN
        tableName := 'TManalog';
    ELSIF (type_in = 2) THEN
        tableName := 'TMdiscrete';
    ELSIF (type_in = 3) THEN
        tableName := 'TelemetryStorageLocation';
    ELSIF (type_in = 4) THEN
        tableName := 'TMDecom';
    ELSE
        RAISE invalidType;
    END IF;

    -- Add schema-SID prefix
    tableName := 'EMA_SCHEMA' || LPAD(TO_CHAR(systemId_in), 2) || '.' || tableName;

    -- TODO: Add _RT/_PBK suffix.

    RETURN tableName;
END getTableName;

/*************************************************************************************************
Function:   getTimeColumnsL0

Purpose:    This function returns an array of the columns to query for in L0 SELECT queries. 
            These are expected to match up to the values in getInsertColumns, where the output from 
            this function would be <time_col1, time_col2, time_col3>, and the output from getInsertColumns 
            would be <insert_time_col1, insert_time_col2, insert_time_col3, value>. These values do not need 
            to be identical, but the value that is represented should be the same (SCT_VTCW -> SCT).
            If these values do not match, the returned data may have incorrectly labeled data.

            
Input:      None

Returns:    A VARRAY of the time columns, maximum of 3.

*************************************************************************************************/
FUNCTION getTimeColumnsL0
    RETURN ONTHEFLYDECOM.string_varray
IS
BEGIN
    return ONTHEFLYDECOM.string_varray('SCT_VTCW AS SCT', 'ERT', 'ASCT');
END getTimeColumnsL0;

/*************************************************************************************************
Function:   getTimeColumnsL1

Purpose:    This function returns an array of the columns to query for in L1 SELECT queries. 
            These are expected to match up to the values in getInsertColumns, where the output from 
            this function would be <time_col1, time_col2, time_col3>, and the output from getInsertColumns 
            would be <insert_time_col1, insert_time_col2, insert_time_col3, value>. These values do not need 
            to be identical, but the value that is represented should be the same (SCT_VTCW -> SCT).
            If these values do not match, the returned data may have incorrectly labeled data.

            
Input:      None

Returns:    A VARRAY of the time columns, maximum of 3.
*************************************************************************************************/
FUNCTION getTimeColumnsL1
    RETURN ONTHEFLYDECOM.string_varray
IS
BEGIN
    return ONTHEFLYDECOM.string_varray('SCT_VTCW', 'ERT', 'ASCT');
END getTimeColumnsL1;

/*************************************************************************************************
Procedure:   addToL0Query

Purpose:    Adds any mission-specific SQL to the 'where' clause of the L0 data query.
            This proc must exist, even if it does nothing.
	    Called by queryL0.

Input:      exeString   - VARCHAR2(500)
            systemId_in - NUMBER SID or schemaId, depending on mission.

Output:     exeString   - May or may not have been updated.
*************************************************************************************************/
PROCEDURE addToL0Query( exeString IN OUT VARCHAR2,
                        systemId_in IN NUMBER)
IS
    fileId NUMBER := -1;
BEGIN
    NULL; -- TODO: Implement for EMA.
END addToL0Query;

/*************************************************************************************************
Procedure:   addToL1Query

Purpose:    Adds any mission-specific SQL to the 'where' clause of the L1 data query.
            This proc must exist, even if it does nothing.
	    Called by queryL1.

Input:      query       - VARCHAR2(500)
            systemId_in - NUMBER SID or schemaId, depending on mission.

Output:     query       - May or may not have been updated.
*************************************************************************************************/
PROCEDURE addToL1Query( exeString IN OUT VARCHAR2,
                        systemId_in IN NUMBER)
IS
    fileId NUMBER := -1;
BEGIN
    NULL; -- TODO: Implement for EMA.
END addToL1Query;

/*************************************************************************************************
PROCEDURE: getDecomMapCur

Purpose:    Given a SID, APID, TLMID, start and stop time, opens a cursor containing all relevant decom maps.
            This is done due to differences in the TMDecom table location and structure (EMA has a separate 
            table for each SID, IXPE has a single table with a SID column).

Inputs:
   
    systemId_in          - The SID of the decom map.
    apid_in              - The APID of the decom map.
    TMDQueryStartTime_in - The beginning of the time period being queried for, inclusive.
    TMDQueryStartTime_in - The end of the time period being queried for, inclusive.

Outputs:

    cursor_out     - The cursor created for the query.
    
*************************************************************************************************/
PROCEDURE getDecomMapCur(
    systemId_in IN NUMBER,
    apid_in IN NUMBER,
    tlmId_in IN NUMBER,
    TMDQueryStartTime_in IN NUMBER,
    TMDQueryStopTime_in IN NUMBER,
    cursor_out OUT curType
    )
IS 
    tmdecom_table_name VARCHAR2(50);
    query_sql CLOB; -- Practically unlimited length
BEGIN
    tmdecom_table_name := onTheFlyDecomMissionSpecific.getTableName(4, systemId_in);
    query_sql := 'SELECT :systemId_in AS systemId, dmid as apid, startBit, length, dataType, definitionStart
        FROM ' || tmdecom_table_name || '
        WHERE dmid     = :apid_in
          AND tlmId    = :tlmId_in
          AND definitionStart <= :tmdqstoptime
          AND definitionStart >= COALESCE(
                (SELECT MAX(definitionStart)
                   FROM ' || tmdecom_table_name || '
                  WHERE tlmId    = :tlmId_in2
                    AND definitionStart <= :tmdqstarttime
                ), 0)
        ORDER BY definitionStart';

    DBMS_OUTPUT.PUT_LINE('getDecomMapCur: ' || TO_CHAR(query_sql));

    OPEN cursor_out FOR query_sql
        USING systemId_in,                -- :systemId_in
              apid_in,                    -- :apid_in
              tlmId_in,                   -- :tlmId_in
              TMDQueryStopTime_in,        -- :tmdqstoptime
              tlmId_in,                   -- :tlmId_in2 (subquery)
              TMDQueryStartTime_in;           
END getDecomMapCur;

/*************************************************************************************************
PROCEDURE: getTSLCur

Purpose:    Given a SID, APID, TLMID, start and stop time, opens a cursor containing all relevant 
            TelemetryStorageLocation entries. This is done due to differences in the TelemetryStorageLocation
            table location and structure (EMA has a separate table for each SID, IXPE has a single table with 
            a SID column).

Inputs:
   
    systemId_in          - The SID of the decom map.
    apid_in              - The APID of the decom map.
    TMDQueryStartTime_in - The beginning of the time period being queried for, inclusive.
    TMDQueryStartTime_in - The end of the time period being queried for, inclusive.

Outputs:

    cursor_out     - The cursor created for the query.
    
*************************************************************************************************/
PROCEDURE getTSLCur(
    systemId_in IN NUMBER,
    tlmId_in IN NUMBER,
    definitionStartTime_in IN NUMBER,
    definitionStopTime_in IN NUMBER,
    cursor_out OUT curType
)
IS
    tsl_table_name VARCHAR(50);
    query_sql CLOB;
BEGIN
    tsl_table_name := onTheFlyDecomMissionSpecific.getTableName(3, systemId_in);

    query_sql := '
        SELECT definitionStart,
               isInL0,
               isInL1,
               dmid as apid
        FROM ' || tsl_table_name || '
        WHERE tlmId = :tlmId_in
          AND definitionStart <= :definitionStopTime_in
          AND definitionStart >= COALESCE(
                (SELECT MAX(definitionStart)
                   FROM TelemetryStorageLocation
                  WHERE tlmId    = :tlmId_in2
                    AND definitionStart <= :definitionStartTime_in
                ), 0)
        ORDER BY definitionStart, apid';

    DBMS_OUTPUT.PUT_LINE('getTSLCur: ' || TO_CHAR(query_sql));

    OPEN cursor_out FOR query_sql
        USING tlmId_in,         -- :tlmId_in (outer query)
              definitionStopTime_in, -- :definitionStopTime_in
              tlmId_in,         -- :tlmId_in2 (subquery)
              definitionStartTime_in; -- :definitionStartTime_in
END getTSLCur;

/*************************************************************************************************
FUNCTION: getDefinitionStartStopTimes

Purpose:  Gets start/stop times for use in queries to the TelemetryStorageLocation and TMDecom tables.

Inputs:
    systemId_in  - E.g. 1 = FLIGHT, 2 = TEST
    startERT_in  - Starting Earth Received Time in GPS microseconds. -1 if not used.
    stopERT_in   - Ending Earth Received Time in GPS microseconds. -1 if not used.
    startSCT_in  - Starting spacecraft time in GPS microseconds. -1 if not used.
    stopSCT_in   - Ending spacecraft time in GPS microseconds. -1 if not used.
    startASCT_in - Start Adjusted Time in GPS microseconds. -1 if not used.
    stopASCT_in  - End Adjusted Time in GPS microseconds. -1 if not used.

Outputs:
    definitionStart  - GPS microseconds
    definitionStop   - GPS microseconds
    definitionColumn - Column being used to get the start and stop times (0: SCT, 1: ERT, 2: ASCT)

Returns: 1=success, 0=failure

Notes:
  - SCT and/or ERT is always specified when filename is specified:
    IXPE retrieve_eng always requires SCT and/or ERT, even when source_filename is specified.
    Therefore we do not need code to select min_ert/max_ert of the TelemetrySourceFiles record.
    Using min_sct/max_sct would be problematic because even current data has near-zero time-stamps
    for min_sct, which if used as definition start/stop times, could cause a large number of
    decom maps to be used, i.e. from 1980/006 GPS epoch..current time the entire history 


*************************************************************************************************/
FUNCTION getDefinitionStartStopTimes(   systemId_in IN NUMBER,
                                        startSCT_in IN NUMBER,
                                        stopSCT_in  IN NUMBER,
                                        startERT_in IN NUMBER,
                                        stopERT_in  IN NUMBER,
                                        startASCT_in IN NUMBER,
                                        stopASCT_in  IN NUMBER,
                                    definitionStartTime OUT NUMBER,
                                    definitionStopTime OUT NUMBER,
                                    definitionColumn OUT NUMBER)
				      RETURN NUMBER
IS
BEGIN
    -- Initialize outputs in case return with error.
    definitionStartTime := -1;
    definitionStopTime := -1;
    definitionColumn := -1;

    -- If ERT or SCT are specified, error immediately.
    IF startERT_in >= 0 OR stopERT_in >= 0 OR startERT_in >= 0 OR stopERT_in >= 0 THEN
        ONTHEFLYDECOM.logError('ERROR EMA only supports querying by ASCT.');
        RETURN 0;
    END IF;

    IF (startASCT_in >= 0 AND stopASCT_in >= 0)  THEN
        -- Input ERT times are valid, so use them.
        definitionStartTime := startASCT_in;
        definitionStopTime  := stopASCT_in;
        definitionColumn    := 2;
    ELSE
        RETURN 0;
    END IF;
    RETURN 1;

END getDefinitionStartStopTimes;

END onTheFlyDecomMissionSpecific;
/