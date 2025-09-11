/*************************************************************************************************
File:       onTheFlyDecomMissionSpecificIXPE.pkb (package body for package: onTheFlyDecomMissionSpecific

Purpose:    IXPE-specific code for on-the-fly decom, called by the core package.
  
Revisions:
  mm/dd/yy who  description
  10/19/23 SM   Initial version.
  
Usage: 
  1. In sqlplus:
     @<full_path>/onTheFlyDecomMissionSpecific.pks      -- compile the package spec
     @<full_path>/onTheFlyDecomMissionSpecificIXPE.pkb  -- compile the package body

Notes:
  1. Contents (In order of appearance)          
     FUNCTION  getVersion
     PROCEDURE setOption
     PROCEDURE clearOption
     FUNCTION  getTableName
     FUNCTION  getL0PacketsSCTColName
     PROCEDURE addToL0Query
     PROCEDURE addToL1Query
     PROCEDURE getDefinitionStartStopTimes
     
  2. Mission Specific Global Variables:
     These are optional inputs which can be set by calling setOption or clearOption.
     gblTlmFileName:
       This is a string, the default is "" (empty string).
       IXPE only; the IXPE code will support this, but not testId.

  3. Compiler Errors:
     - A login.sql file can cause compiler errors.
     - If the ampersand character is present in a comment, in sqlplus will get this prompt
       upon compiling, and some error messages:
       Enter value for t:  (where t is the letter after the ampersand)

*************************************************************************************************/



CREATE OR REPLACE PACKAGE BODY IXPE_MISC.onTheFlyDecomMissionSpecific
AS

-- These options are settable by calling the setOption or clearOption procedure.
-- A -1 value or empty string means the option won't be used in queries.  I.e. either it
-- hasn't yet been set by the user, the user reset it.  These variables may be different
-- for different missions, as may the options which selectNumericTlm supports.
-- Each mission has its own instance of this code, although it may be identical for missions
-- with the same options.  We do not support a generalized code base which supports all options.
gblTlmFileName   VARCHAR2(128) := '';



/*************************************************************************************************
Function:  getVersion

Purpose:    This procedure will return version string.

*************************************************************************************************/
FUNCTION getVersion
         RETURN VARCHAR2
IS
BEGIN
    return 'IXPE 0.1';
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
    upperCaseOptionName := UPPER( optionName);
    IF (upperCaseOptionName = 'TLMFILENAME') THEN  -- IXPE only
        gblTlmFileName := optionValue;
    ELSE
        RETURN 0;
    END IF;
    RETURN 1;
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
    upperCaseOptionName := UPPER( optionName);
    IF (upperCaseOptionName = 'TLMFILENAME') THEN  -- IXPE only
        gblTlmFileName := '';
    ELSIF (upperCaseOptionName = 'ALL') THEN
        gblTlmFileName := '';
    ELSE
        RETURN 0;
    END IF;
    RETURN 1;
END clearOption;



/*************************************************************************************************
Function:  getOptionsHelp

Purpose:    This procedure returns an options help string.

*************************************************************************************************/
FUNCTION getOptionsHelp
         RETURN VARCHAR2
IS
BEGIN
    return 'IXPE options are: TLMFILENAME: <filename>';
END getOptionsHelp;



/*************************************************************************************************
Function:   getTableName

Purpose:    This function returns a table name constructed using the input type and systemId.

Input:      type_in     - NUMBER Determines how the VCs will be converted into table names.
                             0 Indicates some instance of the L0_Packets table is desired.
                             1 Indicates some instance of the TManalog table is desired.
                             2 Indicates some instance of the TMdiscrete table is desired.
                             3 Indicates some instance of TelemetryStorageLocation is desired.
                             4 Indicates some instance of TMDecom is desired.
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
    IF    (type_in = 0) THEN
        tableName := 'L0_Packets_SID' || systemId_in;
    ELSIF (type_in = 1) THEN
        tableName := 'TManalog_SID'   || systemId_in;
    ELSIF (type_in = 2) THEN
        tableName := 'TMdiscrete_SID' || systemId_in;
    ELSIF (type_in = 3) THEN
        tableName := 'TelemetryStorageLocation';
    ELSIF (type_in = 4) THEN
        tableName := 'TMDecom';

    ELSE
        RAISE invalidType;
    END IF;
    RETURN tableName;

END getTableName;



/*************************************************************************************************
Function:   getTimeColumnsL0

Purpose:    This function returns an array of the columns names used to query in L0_Packets. These
            are expected in the order (0: SCT, 1: ERT, 2: ASCT). They are used both for the query and
            the where clause.

Input:      None

Returns:    A VARRAY of the time columns, maximum of 3.

*************************************************************************************************/
FUNCTION getTimeColumnsL0
    RETURN ONTHEFLYDECOM.string_varray
IS
BEGIN
    -- Note: ASCT is unused for IXPE, so it is aliased as null. No queries can be made by ASCT, 
    --       and will error during getDefinitionStartStopTime.
    return ONTHEFLYDECOM.string_varray('SCT_VTCW', 'ERT', 'null AS ASCT');
END getTimeColumnsL0;

/*************************************************************************************************
Function:   getTimeColumnsL1

Purpose:    This function returns an array of the columns names used to query L1 tables. These
            are expected in the order (0: SCT, 1: ERT, 2: ASCT). They are used both for the query and
            the where clause.
 
Input:      None

Returns:    A VARRAY of the time columns, maximum of 3.
*************************************************************************************************/
FUNCTION getTimeColumnsL1
    RETURN ONTHEFLYDECOM.string_varray
IS
BEGIN
    return ONTHEFLYDECOM.string_varray('SCT_VTCW', 'ERT', 'null AS ASCT');
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
    IF (LENGTH(gblTlmFileName) > 0) THEN
        -- Note:  getting fileId in a subquery doesn't work, get an Oracle error saying a right parenthesis
	-- is missing.  Plus have to use two single quotes on either side of filename if return the subquery
	-- in the string.  Here using a separate query to get fileId causes a single context switch between
	-- the PL/SQL and SQL engines, but should be negligible overall.
        EXECUTE IMMEDIATE 'SELECT fileId from TelemetrySourceFiles WHERE filename=''' ||
     	                  gblTlmFileName || '''' INTO fileId;
        exeString := exeString || 'fileId=' || TO_CHAR(fileId) || ' and ';
    END IF;
END addToL0Query;


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
    query_sql := 'SELECT :systemId_in AS systemId, apid, startBit, length, dataType, definitionStart
        FROM ' || tmdecom_table_name || '
        WHERE apid     = :apid_in
          AND tlmId    = :tlmId_in
          AND definitionStart <= :tmdqstoptime
          AND definitionStart >= COALESCE(
                (SELECT MAX(definitionStart)
                   FROM ' || tmdecom_table_name || '
                  WHERE tlmId    = :tlmId_in2
                    AND definitionStart <= :tmdqstarttime
                ), 0)
        ORDER BY definitionStart';

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
               apid
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
    IF (LENGTH(gblTlmFileName) > 0) THEN
        EXECUTE IMMEDIATE 'SELECT fileId from TelemetrySourceFiles WHERE filename=''' ||
     	                  gblTlmFileName || '''' INTO fileId;
        exeString := exeString || 'SCT_VTCW in (select SCT_VTCW from L0_Packets_SID' ||
	             TO_CHAR(systemId_in) || ' where fileId=' || TO_CHAR(fileId) || ') and ';
    END IF;
END addToL1Query;


/*************************************************************************************************
FUNCTION: getDefinitionStartStopTimes

Purpose:  Gets start/stop times for use in queries to the TelemetryStorageLocation and TMDecom tables.
          The IXPE version of this function can be used for most missions.  Only EMM has a different
	  version of this function, because it has testId.

Inputs:
    systemId_in  - E.g. 1 = FLIGHT, 2 = TEST
    startERT_in  - Starting Earth Received Time in GPS microseconds. -1 if not used.
    stopERT_in   - Ending Earth Received Time in GPS microseconds. -1 if not used.
    startSCT_in  - Starting spacecraft time in GPS microseconds. -1 if not used.
    stopSCT_in   - Ending spacecraft time in GPS microseconds. -1 if not used.

Outputs:
    definitionStart - GPS microseconds
    definitionStop  - GPS microseconds

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
                                        stopASCT_in IN NUMBER,

	                                    definitionStartTime OUT NUMBER,
				                        definitionStopTime OUT NUMBER,
                                        definitionColumn OUT NUMBER)
				      RETURN NUMBER
IS
BEGIN
    -- Initialize outputs in case return with error.
    definitionStartTime := -1;
    definitionStopTime := -1;
    
    -- If an ERT range was specified, use it as the time range for the queries.
    -- Otherwise assume SCT can be used for the time range when querying these tables.
    -- This presumes SCT and ERT are the same, or close enough.

    IF (startERT_in >= 0) THEN
        -- Input ERT times are valid, so use them.
        definitionStartTime := startERT_in;
        definitionStopTime  := stopERT_in;
        definitionColumn    := 1;
    ELSIF (startSCT_in >= 0) THEN
        -- No ERT times were input, so set the TSL and TMD times to SCT times,
        -- and hope they're comparable to TSF and TMD times (and ERT).  In flight,
        -- SCT is the same as ERT, i.e. not jammed in the future like during IandT.
        definitionStartTime := startSCT_in;
        definitionStopTime  := stopSCT_in;
        definitionColumn    := 0;
    ELSE
        ONTHEFLYDECOM.logError('ERROR IXPE Only supports querying by ERT, SCT.');
        RETURN 0;
    END IF;
    RETURN 1;

END getDefinitionStartStopTimes;

FUNCTION getDecomIdentifier
    RETURN VARCHAR2
IS
BEGIN
    RETURN 'apid';
END;


END onTheFlyDecomMissionSpecific;
/
