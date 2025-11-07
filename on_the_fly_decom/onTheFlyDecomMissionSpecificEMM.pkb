/*************************************************************************************************
File:       onTheFlyDecomMissionSpecificEMM.pkb (package body for package: onTheFlyDecomMissionSpecific

Purpose:    EMM-specific code for on-the-fly decom, called by the core package.
  
Revisions:
  mm/dd/yy who  description
  10/19/23 SM   Initial version.

Usage: 
  1. In sqlplus:
     @<full_path>/onTheFlyDecomMissionSpecific.pks     -- compile the package spec
     @<full_path>/onTheFlyDecomMissionSpecificEMM.pkb  -- compile the package body
  
Notes:
  1. Contents (In order of appearance)          
     FUNCTION  getVersion
     PROCEDURE setOption
     PROCEDURE clearOption
     FUNCTION  getTableName
     FUNCTION  getTimeColumnsL0
     FUNCTION  getTimeColumnsL1
     FUNCTION  getDecomIdentifier
     PROCEDURE addToL0Query
     PROCEDURE addToL1Query
     PROCEDURE getDecomMapCur
     PROCEDURE getTSLCur
     PROCEDURE getDefinitionStartStopTimes
     
  2. Mission Specific Global Variables:
     These are optional inputs which can be set by calling setOption or clearOption.
     gblVCs:
       Same as currently used by the DB_ROUTINES interface used by TCAD and retrieve_eng.
       For EMM: 
         If the least significant bit is set, i.e. (gblVCs and 1) != 0, then retrieve real-time data
         from the *_RT tables: L0_Packets_RT, TManalog_RT, TMdiscrete_RT.
         If the next bit is set, i.e. (gblVCs and 2) != 0, then retrieve playback data from the playback
         tables: L0_Packets_PBK, TManalog_PBK, TMdiscrete_PBK.
         If both bits are set, retrieve both real-time and playback data from the view which combines
         the RT and PBK tables: L0_Packets, TManalog, TMdiscrete.
         gblVCs ("virtual channels") is an integer used as a bit field, where each bit specifies
         a different type of data to retrieve.  They may mean different things on different missions.
         On EMM they mean real-time or playback, but EMM has multiple VCIDs for each of these.
         On other missions there may be a separate bit for each VCID.
         This is an integer, the default is 3.
       For GOLD: Not used.
       For IXPE: Not used.
     gblTestId:
       This is a signed integer, the default is -1, i.e. no testId, so  don't specify testId
       in queries; all testIds will be included.
       EMM only.

  3. Compiler Errors:
     - A login.sql file can cause compiler errors.
     - If the ampersand character is present in a comment, in sqlplus will get this prompt
       upon compiling, and some error messages:
       Enter value for t:  (where t is the letter after the ampersand)

*************************************************************************************************/

CREATE OR REPLACE PACKAGE BODY EMM_MISC.onTheFlyDecomMissionSpecific
AS

-- These options are settable by calling the setOption or clearOption procedure.
-- A -1 value or empty string means the option won't be used in queries.  I.e. either it
-- hasn't yet been set by the user, the user reset it.  These variables may be different
-- for different missions, as may the options which selectNumericTlm supports.
-- Each mission has its own instance of this code, although it may be identical for missions
-- with the same options.  We do not support a generalized code base which supports all options.
gblTestId  NUMBER := -1;          /* EMM only   */
gblVCs     NUMBER := -1;          /* NUMBER interpreted as a bit field, specifying realtime and/or playback
                                     data retrieval:
                                     1 Indicates only realtime data is desired.
                                     2 Indicates only playback data is desired.
                                     Any other value will get both realtime and playback data. */


/*************************************************************************************************
Function:  getVersion

Purpose:    This procedure will return version string.

*************************************************************************************************/
FUNCTION getVersion
         RETURN VARCHAR2
IS
BEGIN
    return 'EMM 0.2';
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
    IF (upperCaseOptionName = 'TESTID') THEN
        gblTestId := TO_NUMBER( optionValue);
    ELSIF (upperCaseOptionName = 'VCS') THEN
        gblVCs := TO_NUMBER( optionValue);
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
    IF (upperCaseOptionName = 'TESTID') THEN
        gblTestId := -1;
    ELSIF (upperCaseOptionName = 'VCS') THEN
        gblVCs := -1;
    ELSIF (upperCaseOptionName = 'ALL') THEN
        gblTestId := -1;
        gblVCs := -1;
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
    return 'EMM options are: TESTID: xx, VCS: 1=realtime, 2=playback, 3=both';
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
    ONTHEFLYDECOM.logOTFD('getTableName: type_in=' || type_in || ', systemId_in=' || systemId_in, 2);
    -- Start by determining the extension of the table name
    -- Use the VCs find if the realtime data or playback data extensions should be added.
    IF (BITAND( gblVCs, 1) = 1 AND BITAND( gblVCs, 2) = 0) THEN
        tableNameExtension := '_RT';
    ELSIF (BITAND( gblVCs, 2) = 2 AND BITAND( gblVCs, 1) = 0) THEN
        tableNameExtension := '_PBK';
    ELSE
        tableNameExtension := '';
    END IF;

    IF    (type_in = 0) THEN
        tableName := 'emm_schema' || LPAD(TO_CHAR(systemId_in), 2, '0') || '.L0_Packets' ||
                      tableNameExtension;
    ELSIF (type_in = 1) THEN
        tableName := 'emm_schema' || LPAD(TO_CHAR(systemId_in), 2, '0') || '.TManalog' ||
                      tableNameExtension;
    ELSIF (type_in = 2) THEN
        tableName := 'emm_schema' || LPAD(TO_CHAR(systemId_in), 2, '0') || '.TMdiscrete' ||
                      tableNameExtension;
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
    ONTHEFLYDECOM.logOTFD('getTimeColumnsL0: <no_parameters>', 2);
    -- Note: ASCT is unused for IXPE, so it is aliased as null. No queries can be made by ASCT, 
    --       and will error during getDefinitionStartStopTime.
    return ONTHEFLYDECOM.string_varray('SCT_GPS_USEC', 'ERT', 'null AS ASCT');
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
    ONTHEFLYDECOM.logOTFD('getTimeColumnsL1: <no_parameters>', 2);
    return ONTHEFLYDECOM.string_varray('SCT_VTCW', 'ERT', 'null AS ASCT');
END getTimeColumnsL1;



/************************************************************************************************* 
Procedure:  getDecomIdentifier

Purpose:    Returns either 'apid' or 'dmid' based on what field is being used to determine the 
            decom map. This is only different for EMA, which uses 'dmid'.

*************************************************************************************************/
FUNCTION getDecomIdentifier
    RETURN VARCHAR2
IS
BEGIN
    ONTHEFLYDECOM.logOTFD('getDecomIdentifier: <no_parameters>', 2);
    RETURN 'apid';
END;


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
BEGIN
    ONTHEFLYDECOM.logOTFD('addToL0Query: exeString=' || exeString || ', systemId_in=' || systemId_in, 2);
    IF (gblTestId != -1) THEN
        exeString := exeString || ' AND testId=' || TO_CHAR(gblTestId);
    END IF;
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
BEGIN
    ONTHEFLYDECOM.logOTFD('addToL1Query: exeString=' || exeString || ', systemId_in=' || systemId_in, 2);
    IF (gblTestId != -1) THEN
        exeString := exeString || ' AND testId=' || TO_CHAR(gblTestId);
    END IF;
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
    name_value ONTHEFLYDECOM.name_value_t;
    booleanOpString VARCHAR(2);
BEGIN
    ONTHEFLYDECOM.logOTFD('getDecomMapCur: systemId_in=' || systemId_in ||
                          ', apid_in=' || apid_in ||
                          ', tlmId_in=' || tlmId_in || 
                          ', TMDQueryStartTime_in=' || TMDQueryStartTime_in ||
                          ', TMDQueryStopTime_in=' || TMDQueryStopTime_in, 2
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
    query_sql := 'SELECT :systemId_in AS systemId, apid, startBit, length, dataType, definitionStart
        FROM ' || tmdecom_table_name || '
        WHERE apid     = :apid_in
          AND tlmId    = :tlmId_in
          AND definitionStart ' || booleanOpString || ' :tmdqstoptime
          AND definitionStart >= COALESCE(
                (SELECT MAX(definitionStart)
                   FROM ' || tmdecom_table_name || '
                  WHERE tlmId    = :tlmId2_in
                    AND definitionStart <= :tmdqstarttime
                ), 0)
        ORDER BY definitionStart';

    ONTHEFLYDECOM.logOTFD('getDecomMapCur: ' || ONTHEFLYDECOM.prepareDebugSQL(query_sql, name_value), 2);

    OPEN cursor_out FOR query_sql
        USING systemId_in,                -- :systemId_in
              apid_in,                    -- :apid_in
              tlmId_in,                   -- :tlmId_in
              TMDQueryStopTime_in,        -- :tmdqstoptime
              tlmId_in,                   -- :tlmId2_in (subquery)
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
    name_value ONTHEFLYDECOM.name_value_t;
BEGIN
    ONTHEFLYDECOM.logOTFD('getTSLCur: systemId_in=' || systemId_in ||
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
                  WHERE tlmId    = :tlmId2_in
                    AND definitionStart <= :definitionStartTime_in
                ), 0)
        ORDER BY definitionStart, apid';

    ONTHEFLYDECOM.logOTFD('getTSLCur: ' || ONTHEFLYDECOM.prepareDebugSQL(query_sql, name_value), 2);

    OPEN cursor_out FOR query_sql
        USING tlmId_in,         -- :tlmId_in (outer query)
              definitionStopTime_in, -- :definitionStopTime_in
              tlmId_in,         -- :tlmId2_in (subquery)
              definitionStartTime_in; -- :definitionStartTime_in
END getTSLCur;



/*************************************************************************************************
FUNCTION: getDefinitionStartStopTimes

Purpose:  Gets start/stop times for use in queries to the TelemetryStorageLocation and TMDecom tables.
          This does not narrow the query being made, but rather chooses which parameter to use to fetch
          the relevant records for decommutation. In this case, it takes into account if the user
          has a testID selected.

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
  - EMA does not support ASCT, so any attempt to query by that column gets prevented here as a
    form of input validation. 

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
    ONTHEFLYDECOM.logOTFD('getDefinitionStartStopTimes: systemId_in=' || systemId_in ||
                          ', startSCT_in=' || startSCT_in ||
                          ', stopSCT_in=' || stopSCT_in ||
                          ', startERT_in=' || startERT_in ||
                          ', stopERT_in=' || stopERT_in ||
                          ', startASCT_in=' || startASCT_in ||
                          ', stopASCT_in=' || stopASCT_in, 2 
    );
    -- Initialize outputs in case return with error.
    definitionStartTime := -1;
    definitionStopTime := -1;

    -- If ASCT is specified, error immediately.
    IF startASCT_in >= 0 OR stopASCT_in >= 0 THEN
        ONTHEFLYDECOM.logOTFD('getDefinitionStartStopTimes: EMM only supports querying by ERT, SCT.', 0);
        RETURN 0;
    END IF;
    
    -- If a ERT range was specified, use it as the definition range.
    -- Else if a non-zero testId was specified, use that test's ERT range, as reflected by min/max ERT in TelemetrySourceFiles.
    -- Else (testId=0 was specified, or no testId was specified), use the input SCT range.
    -- When using a SCT range, have to assume it can be used for the time range when querying the TSL and TMD tables,
    -- which means SCT and ERT times are assumed to be commensurate, i.e. the same, or close enough.  I.e. the time wasn't jammed.

    IF (startERT_in >= 0) THEN
        -- Input ERT times are valid, so use them.
        definitionStartTime := startERT_in;
        definitionStopTime  := stopERT_in;
        definitionColumn    := 1;
    ELSIF (gblTestId >= 1) THEN
        -- No ERT range was specified, but a non-zero testId was specified.  Use the ERT range of files associated with that testId.
        SELECT min(MIN_ERT), max(MAX_ERT) INTO definitionStartTime,definitionStopTime FROM TelemetrySourceFiles WHERE 
               testId = gblTestId AND schemaId = systemId_in;
        
        definitionColumn   := 1; -- The outputted definitionTimes are ERT. 
    ELSIF (startSCT_in >= 0) THEN
        -- No ERT times were input.  Set the TSL and TMD times to SCT times.
	-- Either testId=0 was specified, meaning return all tlm data *not* associated with a specific test, or
	-- no testId was specified, meaning return all tlm data, regardless of testId value.
        -- This is the case for flight, where SCT is the same as ERT, i.e. not jammed in the future like during IandT.
        definitionStartTime := startSCT_in;
        definitionStopTime  := stopSCT_in;
        definitionColumn    := 0;
    ELSE
        ONTHEFLYDECOM.logOTFD('getDefinitionStartStopTimes: Incomplete query provided. Missing start/stop ERT/SCT.', 0);
        RETURN 0;
    END IF;
    RETURN 1;

END getDefinitionStartStopTimes;

END onTheFlyDecomMissionSpecific;
/
