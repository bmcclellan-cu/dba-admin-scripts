/*************************************************************************************************
File:       onTheFlyDecomMissionSpecificNEOS.pkb (package body for package: onTheFlyDecomMissionSpecific

Purpose:    NEOS-specific code for on-the-fly decom, called by the core package.
  
Revisions:
  mm/dd/yy who  description
  01/14/26 RS   Initial Version (copied from IXPE)
  
Usage: 
  1. In sqlplus:
     @<full_path>/onTheFlyDecomMissionSpecific.pks      -- compile the package spec
     @<full_path>/onTheFlyDecomMissionSpecificNEOS.pkb  -- compile the package body

Notes:
  1. Contents:
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
     These are optional inputs which can be set by calling setOption or clearOption.
     gblTlmFileName:
       This is a string, the default is "" (empty string).
       NEOS only; the NEOS code will support this, but not testId.

  3. Compiler Errors:
     - A login.sql file can cause compiler errors.
     - If the ampersand character is present in a comment, in sqlplus will get this prompt
       upon compiling, and some error messages:
       Enter value for t:  (where t is the letter after the ampersand)

*************************************************************************************************/

CREATE OR REPLACE PACKAGE BODY NEOS_MISC.onTheFlyDecomMissionSpecific
AS

-- Array of supported SIDs
TYPE SIDsVARRAY IS TABLE of NUMBER(3);
supportedSIDs SIDsVARRAY := SIDsVARRAY(1, 2);

-- These options are settable by calling the setOption or clearOption procedure.
-- An empty string means the option won't be used in queries.  I.e. either it
-- hasn't yet been set by the user or the user reset it. These variables may be different
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
    return 'NEOS 0.2.0';
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
    IF (upperCaseOptionName = 'TLMFILENAME') THEN  -- NEOS only
        gblTlmFileName := optionValue;
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
    upperCaseOptionName := UPPER( optionName);
    CASE upperCaseOptionName
        WHEN 'TLMFILENAME' THEN
            gblTlmFileName := '';
        WHEN 'ALL' THEN
            gblTlmFileName := '';
        ELSE
            RETURN 0;
    END CASE;
    RETURN 1;
END clearOption;


/*************************************************************************************************
Function:  getOptionsHelp

Purpose:    This procedure returns an options help string.
            This is intended to be used as a helper for the ONTHEFLYDECOM.setOption and clearOption procedures.

*************************************************************************************************/
FUNCTION getOptionsHelp
         RETURN VARCHAR2
IS
BEGIN
    return 'NEOS options are: TLMFILENAME: <filename>';
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
    databaseName VARCHAR2(64) := '';
    tableName VARCHAR2(64) := '';
    tableNameExtension VARCHAR2(10) := '';
    invalidType EXCEPTION;
BEGIN
    ONTHEFLYDECOM.logOTFD('getTableName: type_in=' || type_in || ', systemId_in=' || systemId_in, 2);
    IF    (type_in = 0) THEN
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

    tableName := 'NEOS_SCHEMA' || LPAD(TO_CHAR(systemId_in), 2, '0') || '.' || tableName;

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
    -- Note: ASCT is unused for NEOS, so it is aliased as null. No queries can be made by ASCT, 
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
    ONTHEFLYDECOM.logOTFD('getTimeColumnsL1: <no_parameters>', 2);
    return ONTHEFLYDECOM.string_varray('SCT_VTCW', 'ERT', 'null AS ASCT');
END getTimeColumnsL1;

/************************************************************************************************* 
Procedure:  getDecomIdentifier

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
    fileId NUMBER := -1;
BEGIN
    ONTHEFLYDECOM.logOTFD('addToL0Query: exeString=' || exeString || ', systemId_in=' || systemId_in, 2);
    IF (LENGTH(gblTlmFileName) > 0) THEN
        -- Note:  getting fileId in a subquery doesn't work, get an Oracle error saying a right parenthesis
        -- is missing.  Plus have to use two single quotes on either side of filename if return the subquery
        -- in the string.  Here using a separate query to get fileId causes a single context switch between
        -- the PL/SQL and SQL engines, but should be negligible overall.
        ONTHEFLYDECOM.logOTFD('addToL0Query: SELECT fileId from TelemetrySourceFiles WHERE filename=''' || gblTlmFileName || '''', 2);
        EXECUTE IMMEDIATE 'SELECT fileId from TelemetrySourceFiles WHERE filename=''' ||
     	                  gblTlmFileName || '''' INTO fileId;
        IF (fileId IS NULL) THEN
            ONTHEFLYDECOM.logOTFD('addToL0Query: gblTlmFileName="' || gblTlmFileName || '" is not valid, returns no file ID', 0);
            RETURN;
        END IF;
        exeString := exeString || ' fileId=' || TO_CHAR(fileId) || ' AND ';
    END IF;
EXCEPTION
    -- On exception return without altering exeString and log as error.
    WHEN NO_DATA_FOUND THEN
        ONTHEFLYDECOM.logOTFD('addToL0Query: gblTlmFileName="' || gblTlmFileName || '" is not valid, returns no file ID', 0);
        RETURN;
    WHEN OTHERS THEN
        ONTHEFLYDECOM.logOTFD('addToL0Query: others exception: ' || SQLCODE || ' -ERROR- ' || SQLERRM, 0);
        -- Re-raise unknown exception to main procedure.
        raise;
END addToL0Query;

/*************************************************************************************************
Procedure:   addToL1Query

Purpose:    Adds any mission-specific SQL to the 'where' clause of the L1 data query.
            This proc must exist, even if it does nothing. Called by queryL1.

Input:      query       - VARCHAR2
            systemId_in - NUMBER SID or schemaId, depending on mission.

Output:     query       - May or may not have been updated.
*************************************************************************************************/
PROCEDURE addToL1Query( exeString IN OUT VARCHAR2,
                        systemId_in IN NUMBER)
IS
    fileId NUMBER := -1;
BEGIN
    ONTHEFLYDECOM.logOTFD('addToL1Query: exeString=' || exeString || ', systemId_in=' || systemId_in, 2);
    IF (LENGTH(gblTlmFileName) > 0) THEN
        ONTHEFLYDECOM.logOTFD('addToL1Query: SELECT fileId from TelemetrySourceFiles WHERE filename=''' || gblTlmFileName || '''', 2);
        EXECUTE IMMEDIATE 'SELECT fileId from TelemetrySourceFiles WHERE filename=''' ||
     	                  gblTlmFileName || '''' INTO fileId;
        IF (fileId IS NULL) THEN
            ONTHEFLYDECOM.logOTFD('addToL1Query: gblTlmFileName="' || gblTlmFileName || '" is not valid, returns no file ID', 0);
            RETURN;
        END IF;
        exeString := exeString || ' AND SCT_VTCW in (select SCT_VTCW from L0_Packets_SID' ||
	             TO_CHAR(systemId_in) || ' where fileId=' || TO_CHAR(fileId) || ')';
    END IF;
EXCEPTION
    -- On exception return without altering exeString and log as error.
    WHEN NO_DATA_FOUND THEN
        ONTHEFLYDECOM.logOTFD('addToL0Query: gblTlmFileName="' || gblTlmFileName || '" is not valid, returns no file ID', 0);
        RETURN;
    WHEN OTHERS THEN
        ONTHEFLYDECOM.logOTFD('addToL0Query: others exception: ' || SQLCODE || ' -ERROR- ' || SQLERRM, 0);
        -- Re-raise unknown exception to main procedure.
        raise;
END addToL1Query;

/*************************************************************************************************
FUNCTION: getDefinitionStartStopTimes

Purpose:  Gets start/stop times for use in queries to the TelemetryStorageLocation and TMDecom tables.
          This does not narrow the query being made, but rather chooses which parameter to use to fetch
          the relevant records for decommutation.

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
  - NEOS does not support ASCT, so any attempt to query by that column gets prevented here as a
    form of input validation. 
  - SCT and/or ERT is always specified when filename is specified:
    NEOS retrieve_eng always requires SCT and/or ERT, even when source_filename is specified.
    Therefore we do not need code to select min_ert/max_ert of the TelemetrySourceFiles record.
    Using min_sct/max_sct would be problematic because even current data has near-zero time-stamps
    for min_sct, which if used as definition start/stop times, could cause a large number of
    decom maps to be used, i.e. from 1980/006 GPS epoch..current time the entire history 

*************************************************************************************************/
FUNCTION getDefinitionStartStopTimes(   
    systemId_in IN NUMBER,
    startSCT_in IN NUMBER,
    stopSCT_in  IN NUMBER,
    startERT_in IN NUMBER,
    stopERT_in  IN NUMBER,
    startASCT_in IN NUMBER,
    stopASCT_in IN NUMBER,

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
    
    -- Check if SID is supported
    IF not systemId_in MEMBER OF supportedSIDs THEN
        ONTHEFLYDECOM.logOTFD('getDefinitionStartStopTimes: EMA does not support SID ' || systemId_in || '.', 0);
        RETURN 0;
    END IF;


    -- If ASCT is specified, error immediately.
    IF startASCT_in >= 0 OR stopASCT_in >= 0 THEN
        ONTHEFLYDECOM.logOTFD('getDefinitionStartStopTimes: NEOS Only supports querying by ERT, SCT.', 0);
        RETURN 0;
    END IF;

    -- If an ERT range was specified, use it as the time range for the queries.
    -- Otherwise assume SCT can be used for the time range when querying these tables.
    -- This presumes SCT and ERT are the same, or close enough.

    IF (startERT_in >= 0 AND stopERT_in >= 0) THEN
        -- Input ERT times are valid, so use them.
        definitionStartTime := startERT_in;
        definitionStopTime  := stopERT_in;
        definitionColumn    := 1;
    ELSIF (startSCT_in >= 0 AND stopSCT_In >= 0) THEN
        -- No ERT times were input, so set the TSL and TMD times to SCT times,
        -- and hope they're comparable to TSF and TMD times (and ERT).  In flight,
        -- SCT is the same as ERT, i.e. not jammed in the future like during IandT.
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
