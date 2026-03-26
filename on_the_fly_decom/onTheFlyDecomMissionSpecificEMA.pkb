/*************************************************************************************************
File:       onTheFlyDecomMissionSpecificEMA.pkb (package body for package: onTheFlyDecomMissionSpecific

Purpose:    EMA-specific code for on-the-fly decom, called by the core package.
  
Revisions:
  mm/dd/yy who  description
  08/27/25 RS   Initial Version
  11/13/25 RS   Logging updates
  
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
    FUNCTION  getDecomIdentifier
    PROCEDURE addToL0Query
    PROCEDURE addToL1Query
    PROCEDURE getDefinitionStartStopTimes
     
  2. Mission Specific Global Variables:
     gblVCs:
        Determines whether or not OTFD queries Realtime or Playback data:
        1 = only Realtime
        2 = only Playback
        Any other value (defaults to 3) indicates both.
     
  3. Compiler Errors:
     - A login.sql file can cause compiler errors.
     - If the ampersand character is present in a comment, in sqlplus will get this prompt
       upon compiling, and some error messages:
       Enter value for t:  (where t is the letter after the ampersand)

*************************************************************************************************/


CREATE OR REPLACE PACKAGE BODY EMA_MISC.onTheFlyDecomMissionSpecific
AS


-- Array of supported SIDs
TYPE SIDsVARRAY IS TABLE of NUMBER(3);
supportedSIDs SIDsVARRAY := SIDsVARRAY(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20);

-- These options are settable by calling the setOption or clearOption procedure.
-- A -1 value or empty string means the option won't be used in queries.  I.e. either it
-- hasn't yet been set by the user, the user reset it.  These variables may be different
-- for different missions, as may the options which selectNumericTlm supports.
-- Each mission has its own instance of this code, although it may be identical for missions
-- with the same options.  We do not support a generalized code base which supports all options.

gblVCs     NUMBER := 3;          /* NUMBER interpreted as a bit field, specifying realtime and/or playback
                                     data retrieval:
                                     1 Indicates only realtime data is desired.
                                     2 Indicates only playback data is desired.
                                     Any other value will get both realtime and playback data. */


/*************************************************************************************************
Function:  getVersion

Purpose:    This function will return version string.

*************************************************************************************************/
FUNCTION getVersion
    RETURN VARCHAR2
IS
BEGIN
    return 'EMA 0.1.3';
END getVersion;

/*************************************************************************************************
Function:  setOption

Purpose:    This function sets the specified mission-specific global variable to the specified value.
            This is intended to be used as a helper for the ONTHEFLYDECOM.setOption procedure

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
    IF (upperCaseOptionName = 'VCS') THEN
        gblVCs := TO_NUMBER( optionValue);
    ELSE
        RETURN 0;
    END IF;
    RETURN 1;
END setOption;



/*************************************************************************************************
Function:  clearOption

Purpose:    This function sets the specified mission-specific option to its default value.
            This is intended to be used as a helper for the ONTHEFLYDECOM.clearOption procedure

Input:      optionName  - String giving the name of the option, case insensitive.

Returns:    1=success, 0=failure			 
*************************************************************************************************/
FUNCTION clearOption( optionName VARCHAR2)
                      RETURN NUMBER
IS
    upperCaseOptionName VARCHAR2(128) := '';
BEGIN
    upperCaseOptionName := UPPER(optionName);
    IF (upperCaseOptionName = 'VCS') THEN
        gblVCs := 3;
    ELSIF (upperCaseOptionName = 'ALL') THEN
        gblVCs := 3;
    ELSE
        RETURN 0;
    END IF;
    RETURN 1;
END clearOption;



/*************************************************************************************************
Function:  getOptionsHelp

Purpose:    This function returns an options help string.
            This is intended to be used as a helper for the ONTHEFLYDECOM.setOption and clearOption procedures.

*************************************************************************************************/
FUNCTION getOptionsHelp
         RETURN VARCHAR2
IS
BEGIN
    return 'EMA options are: VCS: 1=realtime, 2=playback, 3=both';
END getOptionsHelp;

/*************************************************************************************************
Function:   getTableName

Purpose:    This function returns a table name constructed using the input type and systemId.
            Differing missions have different table names and schema placements.

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
    tableName VARCHAR2(64) := '';
    tableNameExtension VARCHAR2(10) := '';
    invalidType EXCEPTION;
BEGIN
    ONTHEFLYDECOM.logOTFD('getTableName: type_in=' || type_in || ', systemId_in=' || systemId_in, 2);
    IF gblVCs = 1 THEN
        tableNameExtension := '_RT';
    ELSIF gblVCs = 2 THEN
        tableNameExtension := '_PBK';
    END IF;

    -- Get base tablename by type.
    IF (type_in = 0) THEN
        tableName := 'L0_Packets' || tableNameExtension;
    ELSIF (type_in = 1) THEN
        tableName := 'TManalog' || tableNameExtension;
    ELSIF (type_in = 2) THEN
        tableName := 'TMdiscrete' || tableNameExtension;
    ELSIF (type_in = 3) THEN
        tableName := 'TelemetryStorageLocation';
    ELSIF (type_in = 4) THEN
        tableName := 'TMDecom';
    ELSE
        RAISE invalidType;
    END IF;

    -- Add schema-SID prefix
    tableName := 'EMA_SCHEMA' || LPAD(TO_CHAR(systemId_in), 2, '0') || '.' || tableName;

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
    return ONTHEFLYDECOM.string_varray('SCT_VTCW', 'ERT', 'ASCT');
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
    return ONTHEFLYDECOM.string_varray('SCT_VTCW', 'ERT', 'ASCT');
END getTimeColumnsL1;

/************************************************************************************************* 
Function:  getDecomIdentifier

Purpose:    Returns either 'apid' or 'dmid' based on what field is being used to determine the 
            decom map.

*************************************************************************************************/
FUNCTION getDecomIdentifier
    RETURN VARCHAR2
IS
BEGIN
    ONTHEFLYDECOM.logOTFD('getDecomIdentifier: <no_parameters>', 2);
    RETURN 'dmid';
END;

/*************************************************************************************************
Procedure:   addToL0Query

Purpose:    Adds any mission-specific SQL to the 'where' clause of the L0 data query.
            This proc must exist, even if it does nothing. Called by queryL0.

Input:      exeString   - VARCHAR2
            systemId_in - NUMBER SID or schemaId, depending on mission.

Output:     exeString   - May or may not have been updated.
*************************************************************************************************/
PROCEDURE addToL0Query( exeString IN OUT VARCHAR2,
                        systemId_in IN NUMBER)
IS
BEGIN
    ONTHEFLYDECOM.logOTFD('addToL0Query: exeString=' || exeString || ', systemId_in=' || systemId_in, 2);
    NULL;
END addToL0Query;

/*************************************************************************************************
Procedure:   addToL1Query

Purpose:    Adds any mission-specific SQL to the 'where' clause of the L1 data query.
            This proc must exist, even if it does nothing. Called by queryL1.

Input:      exeString   - VARCHAR2
            systemId_in - NUMBER SID or schemaId, depending on mission.

Output:     exeString   - May or may not have been updated.
*************************************************************************************************/
PROCEDURE addToL1Query( exeString IN OUT VARCHAR2,
                        systemId_in IN NUMBER)
IS
    fileId NUMBER := -1;
BEGIN
    ONTHEFLYDECOM.logOTFD('addToL1Query: exeString=' || exeString || ', systemId_in=' || systemId_in, 2);
    NULL;
END addToL1Query;

/*************************************************************************************************
Function: getDefinitionStartStopTimes

Purpose:  Gets start/stop times for use in queries to the TelemetryStorageLocation and TMDecom tables.
          This does not narrow the query being made, but rather chooses which parameter to use to fetch
          the relevant records for decommutation. Also acts as input validation.


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
  - EMA only allows for queries by ASCT, and inclusion of any other time query will fail here.
*************************************************************************************************/
FUNCTION getDefinitionStartStopTimes(   
    systemId_in IN NUMBER,
    startSCT_in IN NUMBER,
    stopSCT_in  IN NUMBER,
    startERT_in IN NUMBER,
    stopERT_in  IN NUMBER,
    startASCT_in IN NUMBER,
    stopASCT_in  IN NUMBER,

    definitionStartTime OUT NUMBER,
    definitionStopTime OUT NUMBER,
    definitionColumn OUT NUMBER
) RETURN NUMBER
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
    definitionColumn := -1;

    -- Check if SID is supported
    IF not systemId_in MEMBER OF supportedSIDs THEN
        ONTHEFLYDECOM.logOTFD('getDefinitionStartStopTimes: EMA does not support SID ' || systemId_in || '.', 0);
        RETURN 0;
    END IF;

    -- If ERT or SCT are specified, error immediately.
    IF startSCT_in >= 0 OR stopSCT_in >= 0 THEN
        ONTHEFLYDECOM.logOTFD('getDefinitionStartStopTimes: EMA only supports queries by ASCT (required). SCT was used which is unsupported by EMA.', 0);
        RETURN 0;
    ELSIF startERT_in >= 0 OR stopERT_in >= 0 THEN
        ONTHEFLYDECOM.logOTFD('getDefinitionStartStopTimes: EMA only supports queries by ASCT (required). ERT was used which is unsupported by EMA.', 0);
        RETURN 0;
    END IF;

    IF (startASCT_in >= 0 AND stopASCT_in >= 0)  THEN
        -- Input ASCT times are valid, so use them.
        definitionStartTime := startASCT_in;
        definitionStopTime  := stopASCT_in;
        definitionColumn    := 2;
    ELSE
        ONTHEFLYDECOM.logOTFD('getDefinitionStartStopTimes: EMA only supports queries by ASCT (required). Both startASCT_in and stopASCT_in must be at least 0.', 0)
        RETURN 0;
    END IF;
    RETURN 1;

END getDefinitionStartStopTimes;

END onTheFlyDecomMissionSpecific;
/