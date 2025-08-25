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
  


-- TODO: Update Methods list (Will probably change before merge)
Methods:
  logError             - The error logging function writes to the onTheFlyDecom_errors table.
  setOption            - End-user application calls to set options, both generic and mission-specific.
  clearOption          - End-user application calls to revert an option to its default value.
  replaceBindVars      - Replaces ":bind_var" in a query with the value.  For debugging queries.
  decomFromHexString   - Returns a NUMBER from a hex string, given offset, length and dataType.
  CSV2NestedTable      - Converts a comma separated string of apids to a PL/SQL table of integer apids.
  narrowStartStopTimes - Used so the data from L0/L1 queries with multiple TSL or TMD rows don't overlap.
  queryL0              - Queries L0_Packets and decoms a telemetry item from each BLOB, as directed
                         by one TMDecom record.  Inserts results into the onTheFlyDecom_results table.
  queryL1              - Queries TManalog or TMdiscrete, inserts results into onTheFlyDecom_results.
  selectNumericTlm     - The main telemetry retrieval procedure;  mostly generic code, with a few
                         calls to mission-specific code.

Usage: 
  1. In sqlplus:   If not already installed/compiled, do:
     @<full_path>/onTheFlyDecomMissionSpecific.pks     -- mission-specific package spec
     @<full_path>/onTheFlyDecomMissionSpecificIXPE.pkb -- mission-specific package body
     @<full_path>/onTheFlyDecom.pks                    -- generic package spec
     @<full_path>/onTheFlyDecom.pkb                    -- generic package body
     show errors                                       -- show compilation errors
     Be sure your login.sql file does *not* contain: "set autocommit on", otherwise
     any data in the two tables will be deleted before you can query for it!
     
     Optional:
     execute onTheFlyDecom.setOption('debugLevel','1');
     execute onTheFlyDecom.setOption('testId','0');

     EMM:
     This 1st query is faster than the 2nd, because it uses ERT only, which is the first column in the index
     for emm_schema03.
                                                    ERT 2021/008-22:56:59 2021/008-23:56:58
                                                    |                 |
     execute onTheFlyDecom.selectNumericTlm(3, 578, 1294181837338000, 1294185436338000, -1, -1); => 3600 pts
     Other tlmIds:                             |
     583 = FSA_OTIS GSEP5V, a 64-bit float     FSA_OTIS ACPTCNT apid=1536
                                               								  
                                                            SCT 2021/014-00   2021/014-01
                                                            |                 |
     execute onTheFlyDecom.selectNumericTlm(3, 578, -1, -1, 1294617618000000, 1294621218000000); => 3600 pts

     IXPE:                                               SCT 2023/111-19:20    2023/111-19:40
                                                             |                 |
     execute onTheFlyDecom.selectNumericTlm(1, 4118, -1, -1, 1366140018000000, 1366141218000000); => 1200 pts
                                               |
					       ADCS ADMAGA4AF, apid=100, dev & prod have same tlmId
     show errors
     select count(*) from onTheFlyDecom_results;
     select * from onTheFlyDecom_results;
     select ert,gps2dt(ert),value as sct,value from onTheFlyDecom_results;
     select message from onTheFlyDecom_errors order by sequence;
     select SCT, ERT, Value from onTheFlyDecom_results order by ERT, SCT;  -- The 'order by' *IS* necessary, per Test #4.

Notes:
  1. Overview:
     See the OnTheFlyDecom.txt document.
     
  2. Uses two Oracle global temporary tables:
     Oracle global temporary tables have the same name, but different contents for each connection.
     They must be created once by a DBA, like other permanent tables.
     The code clears these tables before each invocation of selectNumericTlm.
     The code also clears OnTheFlyDecom_errors before each invocation of setOption and clearOption.
     a. The onTheFlyDecom_results table stores the results of selectNumericTlm.
        Then the application (end-user) can query this table to get the data.
     b. The onTheFlyDecom_errors table stores errors, and can also be queried by the end-user.

  3. Compiler Errors:
     - If the ampersand character is present in a comment, in sqlplus will get this prompt
       upon compiling, and some error messages:
       Enter value for t:  (where t is the letter after the ampersand)

  4. Exception Handling and End-User Error Handling
     - If you let an exception propagate out to the caller, then the onTheFlyDecom_errors table
       gets emptied.  So have to catch all exceptions so that the end-user application can get
       information from that table.
     - The end user is expected to check the onTheFlyDecom_errors table after each call to
       selectNumericTlm, setOption and clearOption.  If the user has not increased the debug level
       over the default, then zero rows means no errors.  If the user has increased the debug level,
       and there are rows in the table, then the user should query the table to find out if any
       of them start with "ERROR" or "WARNING", to determine the error status of the last called
       procedure.
     - The user-callable procedures do not return status, because output variables and function
       return values from stored procedures/functions are harder to program in some languages.

  5. ERT vs SCT:
     - ERT (Earth Received Time) is wall clock time, present in telemetry wrappers from ground
       stations.  SCT (Spacecraft Time) refers to the time in telemetry packets, converted to UTC.
     - Data requests before launch often specify only an ERT range (for real-time data), or both an
       ERT range and a SCT range (for playback data).  The ERT range is used by this code together
       with the times in the TelemetryStorageLocation and TelemetryDecom table.   This does not work
       well with playback data, because the ERT range is a relatively short range when the data was dumped,
       but it contains a wider time range of data, whose SCT time-tags are before the dump time (assuming
       SCT has been jammed to be near to ERT).  In the playback case, if there are any times in TSL or TMD
       that are between the SCT start and ERT stop, the wrong records will probably be used.
       This case is unlikely because in the case of TMdecom, it would also apply even without OTFD, and
       at least on EMM, people were cognizant of it.  I.e. after a CT (decom map) release, don't dump
       and process playback data which contains data with old definitions.
       Q: What if we wanted to treat playback, real-time and EMM snorkel data differently w.r.t. ingesting
          into L0 or L1?  Possibilities:  TSL would need either more systemIds, or a new column extending
	  systemId, like VCs.
     - Data requests after launch specify only a SCT range, and the SCT times are like wall clock time,
       because the spacecraft clock has been set so it's correlated to UTC.
       In this case the SCT times used together with TSL and TMD times is not an issue.
*************************************************************************************************/


-- TODO: Temp change for testing.
CREATE OR REPLACE PACKAGE BODY EMA_MISC.onTheFlyDecom
AS

-- These options, and additional mission-specific options, are settable by calling the setOption
-- or clearOption procedure.  Mission-specific options are defined in onTheFlyDecomMissionSpecific<MSN>
-- package.  These procedures chain to similar procedures in that package.
-- A -1 value or empty string means the option won't be used in queries.  I.e. either it
-- hasn't yet been set by the user, the user reset it.
-- See the mission-specific onTheFlyDecom<mission>.pkb file for mission-specific options.

-- If debug level is above 0, the L0 and L1 queries will have the monitor flag enabled, allowing for query performance to be measured.
-- Keep in mind that this does not apply for TMDecom/TelemetryStorageLocation queries, as those are unlikely to be performance bottlenecks
-- and use inline SQL, which cannot have those flags injected.
gblDebugLevel      NUMBER := 0;           /* 0=silent,  1=verbose, 2=more verbose */
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

-- Make a type for input to replaceBindVars.
TYPE name_value_t IS TABLE OF VARCHAR2(64) INDEX BY VARCHAR2(64);

gblSequence NUMBER := 1;  /* sequence column (row counter) in onTheFlyDecom_errors */

/*************************************************************************************************
Procedure:  string_varray_to_csv

Purpose:    Converts the string_varray datatype to a csv for use in query creation.

Input:      array_in - string_varray (VARRAY(3) OF VARCHAR(200)) The array to convert.
*************************************************************************************************/
FUNCTION string_varray_to_csv(array_in IN string_varray)
RETURN VARCHAR2 IS
    l_result VARCHAR2(32767);
BEGIN
    IF array_in IS NOT NULL THEN
        FOR i IN 1 .. array_in.COUNT LOOP
            IF i > 1 THEN
                l_result := l_result || ',';
            END IF;
            l_result := l_result || array_in(i);
        END LOOP;
    END IF;

    RETURN l_result;
END string_varray_to_csv;

/*************************************************************************************************
Procedure:  logError

Purpose:    Inserts a new row with a message to the onTheFlyDecom_errors temporary table, incrementing
            a global counter indicating the order of events. The collateErrors function is used to 
            compact the errors such that identical error messages are not repeated.

Input:      message - VARCHAR2 The error message to log.
                      It should start with "ERROR ", "WARNING " or "INFO ".

Notes:
    Rows in the onTheFlyDecom_errors temporary table are of the form sequence, message, occurrences.
*************************************************************************************************/
PROCEDURE logError(msg VARCHAR2)
IS
    tmpOccurrences NUMBER;
BEGIN
    INSERT INTO onTheFlyDecom_errors (sequence, message, occurrences) VALUES (gblSequence, msg, 1);
    gblSequence := gblSequence + 1;
EXCEPTION
    WHEN others THEN
        DBMS_OUTPUT.PUT_LINE('Error in logError: ' || SQLCODE || ' -ERROR- ' || SQLERRM);
        DBMS_OUTPUT.PUT_LINE('Attempted message logged: ' || msg);

END logError;


/*************************************************************************************************
Procedure:  collateErrors

Purpose:    If gblDebugLevel is 0, takes the errors currently in the onTheFlyDecom_errors table and 
            deletes errors with identical error messages, incrementing an occurrences counter to reflect
            the number of errors. The lowest sequence is preserved, such that the order that the errors 
            initially occurred in is preserved. This was done to the inefficiency of incrementing said
            counter throughout runtime when displaying 80K+ errors.

Input:      None

Notes:
    Rows in the onTheFlyDecom_errors temporary table are of the form sequence, message, occurrences.
*************************************************************************************************/
PROCEDURE collateErrors IS
BEGIN
    if (gblDebugLevel = 0) THEN
        MERGE INTO onTheFlyDecom_errors t
        USING (
            SELECT message, COUNT(*) AS cnt
            FROM onTheFlyDecom_errors
            GROUP BY message
        ) s
        ON (t.message = s.message)
        WHEN MATCHED THEN
        UPDATE SET t.occurrences = s.cnt;

        DELETE FROM onTheFlyDecom_errors t
        WHERE sequence NOT IN (
            SELECT MIN(sequence)
            FROM onTheFlyDecom_errors
            GROUP BY message
        );
    END IF;
EXCEPTION
    WHEN others THEN
        DBMS_OUTPUT.PUT_LINE('Error in collateErrors: ' || SQLCODE || ' -ERROR- ' || SQLERRM);
END collateErrors;

/*************************************************************************************************
Procedure:  getVersion

Purpose:    This procedure writes the version in a log message to the onTheFlyDecom_errors temporary table.

*************************************************************************************************/
PROCEDURE getVersion
IS
    missionSpecificVersion VARCHAR2(128);
BEGIN
    missionSpecificVersion := onTheFlyDecomMissionSpecific.getVersion();
    logError( 'INFO multimission version: 0.1');
    logError( 'INFO mission-specific version: ' || missionSpecificVersion);
END getVersion;

/*************************************************************************************************
Procedure:  setOption

Purpose:    This procedure sets the specified global variable to the specified value.
            Generic option variables are in this package.  Mission-specific ones are in
	        onTheFlyDecom<mission>.pkb  Once set, an option stays in effect for the life of the
	        database connection, unless it is set back to the default by clearOption().

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
    -- Don't use truncate, doesn't work;  only the last row inserted is still there upon return.
    
    EXECUTE IMMEDIATE 'delete from onTheFlyDecom_errors';
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
        status := onTheFlyDecomMissionSpecific.setOption( optionName, optionValue);
	IF (status != 1) THEN
            logError( 'WARNING setOption: Unsupported option: ' || optionName);
            logError( 'INFO multimission options are: DEBUGLEVEL: 0|1|2, APIDS: "xx[,yy[,zz]]" etc., ' ||
	              'DECOMMAPTIMEGPS: nnnnnn, FORCEISINL0: 0|1, FORCEISINL1: 0|1');
            optionsHelp := onTheFlyDecomMissionSpecific.getOptionsHelp;
	    logError( 'INFO ' || optionsHelp);
	END IF;
    END IF;
    RETURN;

    EXCEPTION
    WHEN INVALID_NUMBER THEN
        logError('ERROR setOption: invalid number: optionName=' || optionName || ', optionValue=' || optionValue);
    WHEN others THEN
        logError('ERROR setOption: others exception: optionName=' || optionName || ', optionValue=' || optionValue);

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
BEGIN
    -- Clear the temp table in which the errors are stored.
    -- Don't use truncate, doesn't work;  only the last row inserted is still there upon return.
    
    EXECUTE IMMEDIATE 'delete from onTheFlyDecom_errors';
    gblSequence := 1;

    upperCaseOptionName := UPPER( optionName);
    IF    (upperCaseOptionName = 'DEBUGLEVEL') THEN
        gblDebugLevel := 0;
    ELSIF (upperCaseOptionName = 'APIDS') THEN
        gblApids := '-1';
    ELSIF (upperCaseOptionName = 'DECOMMAPTIMEGPS') THEN
        gblDecomMapTimeGPS := -1;
    ELSIF (upperCaseOptionName = 'FORCEISINL0') THEN
        gblForceIsInL0 := -1;
    ELSIF (upperCaseOptionName = 'FORCEISINL1') THEN
        gblForceIsInL1 := -1;
    ELSIF (upperCaseOptionName = 'ALL') THEN
        gblDebugLevel := 0;
        gblApids := '-1';
        gblDecomMapTimeGPS := -1;
        gblForceIsInL0 := -1;
        gblForceIsInL1 := -1;
        status := onTheFlyDecomMissionSpecific.clearOption( optionName);
    ELSE
        status := onTheFlyDecomMissionSpecific.clearOption( optionName);
	IF (status != 1) THEN
            logError( 'WARNING clearOption: Unsupported option: ' || optionName);
	END IF;
    END IF;
    RETURN;
END clearOption;

/*************************************************************************************************
Function:   replaceBindVars

Purpose:    Replaces occurrences of a string within another string, with the provided value.
            Does this for all the name/values provided in the associative array input.

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
FUNCTION replaceBindVars(
    query_str IN VARCHAR2,
    name_value IN name_value_t)
    RETURN VARCHAR2
IS
    name VARCHAR2(64);
    result VARCHAR2(1000);
BEGIN
    result := query_str;
    name := name_value.FIRST;
    WHILE name IS NOT NULL LOOP
        -- Replace all occurrences of name by value.
        result := REPLACE(result, name, name_value(name));
	name := name_value.NEXT(name);
    END LOOP;
    return result;
END replaceBindVars;

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
  03/07/25 RS   Fixed bug with BITAND, added overflow check.
  02/23/23 SM   Added error handling.
  01/15/20 JH   Comment and output reformatting.
  06/07/19 SM   Initial version.
  
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
    errMsg VARCHAR2(500) := 'decomFromHexString: Error! ';
    message VARCHAR2(500) := '';
BEGIN

    -- First, the inputs are validated -----------------------------------------------------------

    IF hexString_in = '' THEN
        errMsg := errMsg || 'Input hex string is empty!';
        return 0;
    END IF;

    nBytes := LENGTH( hexString_in)/2; -- Get the number of bytes in hexString_in

    IF MOD( LENGTH( hexString_in), 2) != 0 THEN
        errMsg := errMsg || 'Input hex string does not have an even number of characters: ' || hexString_in;
        return 0;
    END IF;

    IF nBytes > 8 THEN
        errMsg := errMsg || 'Input hex string longer than 8 bytes! nBytes = ' || nBytes;
        return 0;
    END IF;

    IF bitOffset_in < 0 or bitOffset_in > (nBytes*8 - 1) THEN
        errMsg := errMsg || 'Input bitOffset is invalid: ' || bitOffset_in;
        return 0;
    END IF;

    IF (bitOffset_in + bitLength_in) > (nBytes*8) THEN
        errMsg := errMsg || 'Error: Input bitOffset + bitLength (' ||
	          bitOffset_in || ' + ' || bitLength_in || ') exceeds length of hex string: ' ||
                  nBytes*8;
        return 0;
    END IF;

    IF (dataType_in != 'F') and (dataType_in != 'I') and (dataType_in != 'U') and 
       (dataType_in != 'D') THEN
        errMsg := errMsg || 'Unsupported input dataType: ' || dataType_in;
        return 0;
    END IF;

    IF (dataType_in = 'F') THEN
        IF (bitLength_in != 32) and (bitLength_in != 64) THEN
            errMsg := errMsg || 'Invalid bitLength = ' || bitLength_in || ' for dataType=F';
            return 0;
        END IF;
        IF bitOffset_in != 0 THEN
            errMsg := errMsg || 'Input bitOffset must be 0 for ' || 'dataType=F';
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
	        errMsg := errMsg || 'Cannot convert bits to float';
	        return 0;
	END;
    ELSIF dataType_in = 'F' and bitLength_in = 64 and nBytes = 8 THEN
        -- This matches a double telemetered on a byte boundary, as they always have been on past missions
        -- The 2nd parameter specifies that the raw value (1st parameter) is in big-endian byte order.
        BEGIN
            valueAsNumber := TO_NUMBER( UTL_RAW.CAST_TO_BINARY_DOUBLE( HEXTORAW( hexString_in), 1));
	    EXCEPTION
	    WHEN others THEN
	        errMsg := errMsg || 'Cannot convert bits to double';
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
            errMsg := errMsg || 'Cannot convert bits directly to number';
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
            logError('WARNING: Numeric overflow detected, dropping record with hex ' || hexString_in);
        END IF;
        valueAsNumber := NULL;
        return 0;
    END IF;

    -- The bits are now set correctly for an unsigned integer
    -- If dataType is signed integer, and the MSB bit is set, then we want to interpret the bits as a negative number
    -- The correct negative value is returned by the expression:  (valueAsNumber - 2^bitLength_in)
    message := 'ValueAsNumber : ' || TO_CHAR(valueAsNumber);
    message := message || ', Hexstring_in : ' || hexString_in;

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
        logError('ERROR decomFromHexString: others exception: ' || SQLCODE || ' -ERROR- ' || SQLERRM || ' with: ' || message);
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
BEGIN
    LOOP
        l_comma_index := INSTR(l_string, ',', l_index);
        EXIT WHEN l_comma_index = 0;
        l_tab.EXTEND;
        l_tab(l_tab.COUNT) := TO_NUMBER(SUBSTR(l_string, l_index, l_comma_index - l_index));
        l_index := l_comma_index + 1;
    END LOOP;
    RETURN l_tab;
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
            1.  Queries the L0_Packets table's 'packet' column (a BLOB), which contains the raw packet,
                and extracts the range of hex characters (using Oracle built-in rawtohex) containing the
	            desired telemetry item.
            2.  Decommutates the hex data into a numeric type, using the offset, length and data type
	            from the decom record.
	        3.  Formats a row using SCT, ERT, AST and Value, and writes it to the global temporary table.
Inputs:
   
    decomMap     - PL/SQL table based record containing one row from the TMDecom table.
    startERT_in  - Starting earth received time in GPS microseconds.  -1 if not used.
    stopERT_in   - Stopping earth received time in GPS microseconds.  -1 if not used.
    startSCT_in  - Starting spacecraft in GPS microseconds.    -1 if not used.
    stopSCT_in   - Stopping spacecraft in GPS microseconds.    -1 if not used.
    doInclusiveQuery - true = include stop time, false = don't include stop time
*************************************************************************************************/
PROCEDURE queryL0
    (decomMap IN tmdecom_row_t,
    startERT_in IN NUMBER,         -- optional (-1 if not used)
    stopERT_in IN NUMBER,          -- optional (-1 if not used)
    startSCT_in IN NUMBER,         -- optional (-1 if not used)
    stopSCT_in IN NUMBER,          -- optional (-1 if not used)
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

    n_batch_rows CONSTANT NUMBER := 100;

    -- row structure returned by the query for times and hex string from the L0_Packets table.
    TYPE result_row_t IS RECORD( SCT NUMBER(16),
                                 ERT NUMBER(16),
                                 ASCT NUMBER(16),
                                 hexString VARCHAR(16));

    -- Temp variable for holding each row as it is decommed.
    row result_row_t;
    -- PL/SQL table of these rows.
    TYPE result_table_t IS TABLE OF result_row_t INDEX BY PLS_INTEGER;
    result_table result_table_t;

    -- array of numeric values, the results of decomming from hex strings
    TYPE value_arr_t IS VARRAY(n_batch_rows) OF NUMBER;
    value_arr value_arr_t := value_arr_t();

    -- arrays for SCT, ERT, and ASCT
    ert_arr value_arr_t := value_arr_t();
    sct_arr value_arr_t := value_arr_t();
    ASCT_arr value_arr_t := value_arr_t();

    -- the cursor for the query for times and hex string from L0_Packets.
    c curType;

    hexString VARCHAR2(16);
    i NUMBER;
    byteOffset NUMBER;
    hexCharOffset NUMBER;
    bitOffsetInSubstring NUMBER;
    lastBitOffset NUMBER;
    nBytes NUMBER;
    nHexChars NUMBER;
    valueAsNumber NUMBER;
    SCT NUMBER;
    ERT NUMBER;
    nRows NUMBER := 0;
    nValues NUMBER := 0;
    status NUMBER;
    debugString      VARCHAR2(1000);
    exeString        VARCHAR2(1000);
    exeStringPart1   VARCHAR2(500);
    exeStringPart2   VARCHAR2(500);
    booleanOpString  VARCHAR2(10);
    name_value name_value_t;
    decom_error EXCEPTION;

    select_time_columns string_varray; -- Currently supports a maximum of 4 columns to select by. SCT, ERT, ASCT.
    select_time_columns_string VARCHAR2(200);

    where_clauses string_varray; 
    where_clause_index NUMBER := 1;  -- VARRAY indexing starts at 1

    monitor_value VARCHAR2(20); -- This string is set to inject the monitor flag into SQL queries made.
BEGIN
    -- Get the table name
    tableName := onTheFlyDecomMissionSpecific.getTableName(0, decomMap.systemId);

    -- Get the mapping of time columns onto SCT, ERT, and ASCT. This varies mission-to-mission. An SQL snippet is expected.  
    select_time_columns := onTheFlyDecomMissionSpecific.getTimeColumnsL0;
    select_time_columns_string := string_varray_to_csv(select_time_columns);

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
	-- Make an associative array to tell replaceBindVars the variable names to replace with actual values
        -- in the query.  This is for a debug string.
        name_value := name_value_t( ':nBytes'      => TO_CHAR(nBytes),
                                    ':byteOffset'  => TO_CHAR(byteOffset),
                                    ':apid'        => TO_CHAR(apid),
                                    ':startERT_in' => TO_CHAR(startERT_in),
                                    ':stopERT_in'  => TO_CHAR(stopERT_in),
                                    ':startSCT_in' => TO_CHAR(startSCT_in),
                                    ':stopSCT_in'  => TO_CHAR(stopSCT_in),
                                    ':startASCT_in' => TO_CHAR(startASCT_in),
                                    ':stopASCT_in'  => TO_CHAR(stopASCT_in));
        
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
    -- which is passed through definitionColumn (0: SCT, 1: ERT, 2: ASCT) (TODO: Currently hardcoded for EMA).
    IF (doInclusiveQuery) THEN
        booleanOpString := '<=';
    ELSE
        booleanOpString := '<';
    END IF;

    exeStringPart1 := 'select ' || monitor_value || select_time_columns_string ||
                      ', rawtohex(dbms_lob.substr(packet, :nBytes, :byteOffset)) ' ||
                      'from ' || tableName || ' where dmid=:apid and ';
    exeStringPart2 := 'length >= (:byteOffset-1 + :nBytes)';

    exeStringPart2 := exeStringPart2 || ' AND ASCT >= :startASCT_in AND ASCT ' || booleanOpString || ' :stopASCT_in';

    -- Add anything mission-specific to the query.
    onTheFlyDecomMissionSpecific.addToL0Query( exeStringPart1, decomMap.systemId);

    exeString := exeStringPart1 || exeStringPart2;

    -- If this version of OTFD will be made compatible with IXPE, EMA, etc., it might be useful to wrap the base query as follows. This would 
    -- allow for standard column names using aliases while still being able to reference the aliases in the where clause. This appears to have 
    -- little impact on performance.
    -- exeString := 'SELECT * FROM (' || exeString || ') inner_table WHERE ASCT >= :startASCT_in AND ASCT ' || booleanOpString || ' :stopASCT_in';

    -- Log the composed query if debug level is high enough
    IF (gblDebugLevel >= 1) THEN        
        debugString := replaceBindVars( exeString, name_value);
        logError('INFO debugString=' || exeString);
    END IF;

    -- TODO: Currently hardcoded for EMA.
    open c for exeString using nBytes, byteOffset, apid, byteOffset, nBytes, 
        startASCT_in, stopASCT_in;
    
    -- BULK COLLECT and FORALL greatly reduce the number of context switches which happen when data
    -- is passed between the Oracle PL/SQL engine and the SQL engine.  This improves performance.
    -- BULK COLLECT has a row limit of 'n_batch_rows' for each bulk collect fetch and insert.
    -- For large queries, this limits the memory required in PL/SQL so the max isn't exceeded.

    -- Make the VARRAYs big enough for the batch size.
    value_arr.EXTEND(n_batch_rows);
    ert_arr.EXTEND(n_batch_rows);
    sct_arr.EXTEND(n_batch_rows);
    ASCT_arr.EXTEND(n_batch_rows);

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
                ASCT_arr(nValues)   := row.ASCT;
            ELSIF (valueAsNumber IS NULL) THEN
                CONTINUE; -- Ignore any null values, which are a result of near-infinite values/invalid floating point values.
	        ELSE
		        debugString := 'Error occurred with apid=' || TO_CHAR(apid) || ', offset=' || TO_CHAR(byteOffset) ||
		               ':' || TO_CHAR(bitOffsetInSubstring) || ', dataType=' || dataType;
	            logError( 'INFO ' || debugString);
	        END IF;
        END LOOP;

        -- Formulate rows and insert them into the temporary table.
	    -- Note: FORALL is *not* a loop; it is a declarative statement to the PL/SQL engine which says:
	    -- "Generate all the DML statements that would have been executed one row at a time,
        --  and send them all across to the SQL engine with one context switch."

        FORALL indx IN 1 .. nValues
            INSERT INTO onTheFlyDecom_results (SCT, ERT, ASCT, VALUE) VALUES (ert_arr(indx), sct_arr(indx), ASCT_arr(indx), value_arr(indx));
        
        nRows := nRows + nValues; -- Increment the row counter 
    END LOOP;

    IF (gblDebugLevel >= 1) THEN
        debugString := 'queryL0: inserted ' || nRows || ' rows into onTheFlyDecom_results table.';
        logError( 'INFO ' || debugString);
    END IF;

    CLOSE c;
    RETURN;

    EXCEPTION
    WHEN decom_error THEN
        logError('ERROR queryL0: No provided ERT or SCT time range');
        RETURN;
    WHEN others THEN
        logError('ERROR queryL0: others exception: ' || SQLCODE || ' -ERROR- ' || SQLERRM);
        RETURN;
END queryL0;



/*************************************************************************************************
Procedure:  queryL1

Purpose:   Queries the appropriate L1 table (TManalog or TMdiscrete) for the L1 data, and
           inserts the data into the temporary table.
           The end points of the time range are included.

Inputs:    These are mostly the same inputs as selectNumericTlm.
           start/stop times which are -1 are not used
    systemId_in       - NUMBER SID or schemaId, depending on mission.     
    tlmId_in          - NUMBER Same as TMID.       
    startERT_in       - NUMBER Starting earth received time in GPS microseconds.
    stopERT_in        - NUMBER Stopping earth received time in GPS microseconds.  
    startSCT_in       - NUMBER Starting spacecraft time in GPS microseconds.   
    stopSCT_in        - NUMBER Stopping spacecraft time in GPS microseconds.   
    TSLRowStartTime   - NUMBER TelemetryStorageLocation start time
    TSLRowStopTime    - NUMBER TelemetryStorageLocation stop time
    dataType          - VARCHAR
    doInclusiveQuery  - BOOLEAN
    
    When called from within the TSL loop, TSLRowStart/StopTimes are passed in, and dealt with
    by the logic.  When there is no TSL loop (no TSL row), set TSLRowStart/StopTimes to -1's.
    
Outputs: None

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
    debugString VARCHAR2(500);
    tableName VARCHAR2(200);
    name_value name_value_t;

    booleanOpString VARCHAR(2);

    -- Contain the bounds for the definition column.
    queryStart NUMBER;
    queryStop NUMBER; 

    countBefore NUMBER;
    countAfter NUMBER;

    select_time_columns string_varray;
    select_time_columns_string VARCHAR2(200);

    monitor_value VARCHAR2(20); 
BEGIN
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
	-- Make an associative array to tell replaceBindVars the variable names to replace with actual values
        -- in the query.  This is for a debug string.  Query start/stop times are added later.
        name_value := name_value_t( ':tlmId_in' => TO_CHAR(tlmId_in));

        monitor_value := ' /*+ monitor */ ';
    END IF;		

    select_time_columns := onTheFlyDecomMissionSpecific.getTimeColumnsL1;
    select_time_columns_string := string_varray_to_csv(select_time_columns);		    

    -- Define the invariant part of the query.

    exeString := 'INSERT INTO onTheFlyDecom_results (ERT, SCT, ASCT, Value) ' ||
                 'SELECT ' || monitor_value || select_time_columns_string || ', Value from ' || tableName ||
		         ' WHERE TMID = :tlmId_in';

    -- Add anything mission-specific to the query, such as testId or tlmFileName.
    
    onTheFlyDecomMissionSpecific.addToL1Query(exeString, systemId_in);

    IF doInclusiveQuery THEN
        booleanOpString := '<=';
    ELSE
        booleanOpString := '<';
    END IF;

    -- Note: I'm testing forgoing bind variables for this part, as there are many possible inputs, and the which values need to be 
    --       queried by will vary significantly.

    -- Narrow by the column used for TSL fetch, and query by the rest if provided.
    CASE definitionColumn
        WHEN 0 THEN
            narrowStartStopTimes(startSCT_in, stopSCT_in, TSLRowStartTime, TSLRowStopTime, queryStart, queryStop);
            exeString := exeString || ' AND SCT_VTCW >= ' || queryStart ||' AND SCT_VTCW ' || booleanOpString || queryStop;
            IF startERT_in != -1 THEN
                exeString := exeString || ' AND ERT BETWEEN ' || startERT_in || ' AND ' || stopERT_in;
            END IF;
            IF startASCT_in != -1 THEN
                exeString := exeString || ' AND ASCT BETWEEN ' || startASCT_in || ' AND ' || stopASCT_in;
            END IF;
        WHEN 1 THEN
            narrowStartStopTimes(startERT_in, stopERT_in, TSLRowStartTime, TSLRowStopTime, queryStart, queryStop);
            exeString := exeString || ' AND ERT >= ' || queryStart ||' AND ERT ' || booleanOpString || queryStop;
            IF startSCT_in != -1 THEN
                exeString := exeString || ' AND SCT_VTCW BETWEEN ' || startSCT_in || ' AND ' || stopSCT_in;
            END IF;
            IF startASCT_in != -1 THEN
                exeString := exeString || ' AND ASCT BETWEEN ' || startASCT_in || ' AND ' || stopASCT_in;
            END IF;
        WHEN 2 THEN 
            narrowStartStopTimes(startASCT_in, stopASCT_in, TSLRowStartTime, TSLRowStopTime, queryStart, queryStop);
            exeString := exeString || ' AND ASCT >= ' || queryStart || ' AND ASCT ' || booleanOpString || queryStop;
            IF startSCT_in != -1 THEN
                exeString := exeString || ' AND SCT_VTCW BETWEEN ' || startSCT_in || ' AND ' || stopSCT_in;
            END IF;
            IF startERT_in != -1 THEN
                exeString := exeString || ' AND ERT BETWEEN ' || startERT_in || ' AND ' || stopERT_in;
            END IF;
    END CASE;

    IF (gblDebugLevel >= 1) THEN
        logError( 'INFO ' || exeString);
        logError( 'INFO startASCT_in='||startASCT_in||', stopASCT_in'||stopASCT_in);
        logError( 'INFO TSLRowStartTime='||TSLRowStartTime||', TSLRowStopTime='||TSLRowStopTime);
    END IF;

    -- Insert the values.
    EXECUTE IMMEDIATE exeString USING IN tlmId_in;

    IF (gblDebugLevel >= 1) THEN
        logError( 'INFO queryL1: inserted ' || sql%Rowcount || ' rows into onTheFlyDecom_results table.');
    END IF;
    
    RETURN;
    
END queryL1;



/*************************************************************************************************
Procedure:  selectNumericTlm  

Purpose:    Gets requested data from either the L0 table, L1 table, or both. 
            Stores this data into a temporary table.

Inputs:      
    systemId_in     - NUMBER SID or schemaId, depending on mission.     
    tlmId_in        - NUMBER Same as TMID.       
    startERT_in   - NUMBER GPS timestamp for start of query. Specific column is mission-defined. Typically ERT.
    stopERT_in    - NUMBER GPS timestamp for end of query. Specific column is mission-defined. Typically ERT.
    startSCT_in   - NUMBER GPS timestamp for start of query. Specific column is mission-defined. Typically SCT.  
    stopSCT_in    - NUMBER GPS timestamp for end of query. Specific column is mission-defined. Typically SCT.  

Outputs: 
    Returns a string of the format: 
    '<Number of rows written>, <Error message 1>\n <Error message two>\n...'

Notes:
  1. Input Times:
     ERT time, SCT time, or both can be used to specify the time range of the desired telemetry..
     If the user specifies a testId, the input times are ignored, and the testId is translated
     into ERT start and stop times.
  2. Algorithm:
     A. Initialization
          Sets desired time ranges and sets up apid_list_in
     B. Gets all the rows from TelemetryStorageLocation which contain the user's ERT range
        (or SCT range, if only a SCT range was specified).
          First main block, queries the TSL table for rows in the desired time range
     C. Loops through and processes the TelemetryStorageLocation rows
          First main loop, everything after this will happen for one processed row 
          in the TSL table.
     D. Gets the decom map(s) for this tlmId and time-range of the TSL row
          Second main block, gets all TMdecom rows that have the same apid as the TSL row
          and is in the time range.
     E. If isInL1, does query for data, using dataType from first TMdecom row, continues to
        next TSL row, and skips F.
     F. Otherwise (inInL0) loops through the decom map(s) for this tlmId, calls queryL0 for each one.
        Note: this is written assuming TMDecom does not have any near duplicate records, which could
	plausibly be present just to record a new version.  If we decide to include such records,
	would have to change this code to look ahead, detect near duplicates, and adjust start/stop
	times accordingly.

*************************************************************************************************/
PROCEDURE selectNumericTlm
    (systemId_in IN NUMBER,
    tlmId_in IN NUMBER,
    startERT_in IN NUMBER,
    stopERT_in IN NUMBER,
    startSCT_in IN NUMBER,
    stopSCT_in IN NUMBER,
    startASCT_in IN NUMBER,
    stopASCT_in IN NUMBER)
IS
    exeString VARCHAR2(500);    -- This string contains sql commands to be executed
    definitionStartTime NUMBER;
    definitionStopTime NUMBER;
    definitionColumn NUMBER;
    apidArray nestedTable_typ;
    time_error EXCEPTION;
    definition_error EXCEPTION;
    dataType VARCHAR2(1);
    status NUMBER;

    tmd_cursor curType;
    tsl_cursor curType;
BEGIN 

    -- STEP A: Initialization --------------------------------------------------------------------

    -- Clear the temp tables in which the results and errors are stored.
    -- TODO: Determine if the below comment is correct. My testing indicates it may not be correct. Checking with Brian & Jon.
    --       Don't use truncate, doesn't work;  only the last row inserted is still there upon return.

    -- TODO: De-hardcode the statement.
    -- EXECUTE IMMEDIATE 'TRUNCATE TABLE EMA_MISC.onTheFlyDecom_results';
    -- EXECUTE IMMEDIATE 'TRUNCATE TABLE EMA_MISC.ONTHEFLYDECOM_ERRORS';
    EXECUTE IMMEDIATE 'DELETE FROM ONTHEFLYDECOM_RESULTS';
    EXECUTE IMMEDIATE 'DELETE FROM ONTHEFLYDECOM_ERRORS';
    gblSequence := 1;
    
    -- In case we return early with an error, create a cursor to read the empty results table.
    -- Later if the data needs to be sorted, we'll re-create it with a sort clause.

    -- Set the time range for the queries to TelemetryStorageLocation and TMdecom.
    -- Usually this is the ERT range of the queries.
    -- For EMM it may be the ERT range of a test, if no ERT range was input, but a testId was input.
    -- It may also be a SCT range, for flight data where SCT is commensurate with ERT.


    -- TODO: Currently, getDefinitionStartStopTimes acts as input validation. Maybe a more elegant way to do 
    --       this.
    status := onTheFlyDecomMissionSpecific.getDefinitionStartStopTimes( systemId_in,
    	                                                                startERT_in, stopERT_in,
	                                                                    startSCT_in, stopSCT_in,
                                                                        startASCT_in, stopASCT_in,
                                                                        definitionStartTime,
									                                    definitionStopTime,
                                                                        definitionColumn);
    IF (status != 1) THEN
        raise definition_error;
    END IF;

    IF (gblDecomMapTimeGPS != -1) THEN
        logError( 'INFO gblDecomMapTimeGPS = ' || TO_CHAR( gblDecomMapTimeGPS));
    END IF;

    -- Initialize apidArray
    apidArray := CSV2NestedTable( gblApids);

    -- STEP B: Get all the TelemetryStorageLocation rows which overlap the time range found above  -------

    -- Define the query to get rows from TelemetryStorageLocation.
    -- Coalesce is used here, which will output either the results of the select statement, or 0
    -- Subsequent logic depends on order by clause including apid, for when multiple apids are present.

    -- Define a table for the above query's results.
    DECLARE TYPE TSL_typ IS TABLE OF tsl_row_t INDEX BY PLS_INTEGER;
    TSLRows TSL_typ;

    -- Declare all other variables
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
        -- Fetch TelemetryStorageLocationRows
        onTheFlyDecomMissionSpecific.getTSLCur(systemId_in, tlmId_in, definitionStartTime, definitionStopTime, tsl_cursor);
        FETCH tsl_cursor BULK COLLECT INTO TSLRows;
        CLOSE tsl_cursor;

        IF TSLRows.COUNT = 0 THEN

            DBMS_OUTPUT.PUT_LINE( 'No TSL rows exist, must be a derived item; querying L1...');
	    
            -- No TSL rows exist, so must be a derived item or other non-packetized item,
	        -- which are only stored in the L1 tables.   Query TelemetryItemDefinition
	        -- for the dataType, then call queryL1.

            EXECUTE IMMEDIATE 'SELECT dataType from TelemetryItemDefinition WHERE tlmId = ' || tlmId_in
                              INTO dataType;

            -- Check that dataType is in the supported set: unsigned or signed int, float or discrete.
	        -- We don't support strings by design.

            IF (NOT ((dataType = 'U') OR (dataType = 'I') OR (dataType = 'F') OR (dataType = 'D'))) THEN
                logError('ERROR unsupported dataType for tlmId=' || tlmId_in || ': ' || dataType);
                RETURN;
            END IF;

            queryL1( systemId_in, tlmId_in, startERT_in, stopERT_in, startSCT_in, stopSCT_in, startASCT_in, stopASCT_in,
	             -1, -1, dataType, true, definitionColumn);
	        RETURN;

        END IF;

        -- STEP C: Loop through and process the TelemetryStorageLocation rows ------------------

        FOR i IN 1 .. TSLRows.COUNT LOOP
            -- NOTE pl/sql arrays and tables start at index one, not zero

            -- If an option is in effect to override isInL0 and/or isInL1, do so.
	        -- This is only used in testing.
            IF (gblForceIsInL0 != -1) THEN
	            IF (TSLRows(i).isInL0 != gblForceIsInL0) THEN
		            logError('INFO changing TSLRows(' || TO_CHAR(i) || ').isInL0 to ' || TO_CHAR( gblForceIsInL0));
		        END IF;
	            TSLRows(i).isInL0 := gblForceIsInL0;
	        END IF;
            IF (gblForceIsInL1 != -1) THEN
	            IF (TSLRows(i).isInL1 != gblForceIsInL1) THEN
		            logError('INFO changing TSLRows(' || TO_CHAR(i) || ').isInL1 to ' || TO_CHAR( gblForceIsInL1));
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

            -- Skip this row and continue with the next row if both isInL0=0 and isInL1=0 (an end marker).
            IF (isInL0 = false AND isInL1 = false) THEN
                CONTINUE;
            END IF;

            -- Set isLastTSLRow to true if this is the last TSL row for this apid.
            -- This controls whether the end time of the query is inclusive or exclusive.
            -- a. We want exclusive for all except the last row, so that we don't get duplicates in the
            --    onTheFlyDecom_results table.
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
                END IF;
            END LOOP;
        END IF;


        -- STEP D: Get the decom rows applicable to this tlmId and to the time range of the TSL row. ---------

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
        END IF;
        -- Get data from TMDecom.  For L0 queries, this gives the offset, size and dataType
        -- of the telemetry item, for use in OTFD.  For L1 queries, this gives the dataType,
        -- for choosing between TManalog or TMdiscrete.

        -- Make a table of tmdecom rows.
        DECLARE TYPE TMD_typ IS TABLE OF tmdecom_row_t INDEX BY PLS_INTEGER;
        TMDRows TMD_typ;

        -- Declare all other variables
        TSLRowApid NUMBER;
        tmpRowsWritten NUMBER;

        BEGIN
            -- Fetch TMDecom rows
            onTheFlyDecomMissionSpecific.getDecomMapCur(systemId_in, TSLRows(i).apid, tlmId_in, TMDQueryStartTime, TMDQueryStopTime, tmd_cursor);
            FETCH tmd_cursor BULK COLLECT INTO TMDRows; 
            CLOSE tmd_cursor;

            IF (TMDRows.COUNT = 0) THEN
                CONTINUE;
            END IF;

            -- Check that dataType is allowed.  In particular, this API does not allow strings,
		    -- partly because the onTheFlyDecom_results VALUE column is numeric, not a string type.

                dataType := TMDRows(1).dataType;
	        IF (NOT ((dataType = 'U') OR (dataType = 'I') OR (dataType = 'F') OR (dataType = 'D'))) THEN
	            logError('ERROR unsupported dataType for tlmId=' || tlmId_in || ': ' || dataType);
	            CONTINUE;
	        END IF;

            -- STEP E: If isInL1, query for data.

            -- SM Note: if isInL1, then we don't need a separate data query for every TMDecom record.
            -- The TMDecom records are largely irrelevant, since the data has already been decommed,
            -- even if the telemetry item has been moved around and multiple TMDecom records exist.
            -- We only need one row to determine the table (TManalog or TMdiscrete) for the query.
            -- We do not support the case where a dataType changes between discrete and analog
            -- during the user's time range, so that the data is located in 2 different tables.
            -- Data analysis code downstream from this database retrieval layer is unlikely to either.
        
            IF (isInL1 = true) THEN
		        queryL1( systemId_in, tlmId_in, startERT_in, stopERT_in, startSCT_in, stopSCT_in, startASCT_in, stopASCT_in,
		             TSLRowStartTime, TSLRowStopTime, dataType, isLastTSLRow, definitionColumn);
			    
                CONTINUE;  -- to next TSL row
            END IF;  -- isInL1 = true


		    -- If we got this far, then we're querying from L0 and doing on-the-fly decom.
            -- STEP F: Loop through the decom map(s) for this tlmId --------------------------

            TSLRowApid := TSLRows(i).apid;

            FOR j in 1 .. TMDRows.COUNT LOOP
            -- Continue with the next row if startBit=-1 (an end marker)
		    -- This shouldn't happen because is should be true that isInL0=0 and isInL1=0.
		    -- This is just for extra robustness in case TSL and TMD don't both have end markers.
                IF (TMDRows(j).startBit = -1) THEN
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

		        IF (gblDebugLevel >= 2) THEN
                    logError('INFO isLastTSLRow = ' || (case when isLastTSLRow = true then 'true' else 'false' end) ||
		             ', isLastTMDRow = ' || (case when isLastTMDRow = true then 'true' else 'false' end) ||
			            ', doInclusiveQuery = ' || (case when doInclusiveQuery = true then 'true' else 'false' end));
	            END IF;
			     
                -- Get start and stop times for this TMD row.  Adjust these times so they're within the range
                -- of the TSL record, because we don't want to query outside the TSL record's range.
                -- Also if this is the last TMD record, widen the stop time to be the TSL stop time, because
                -- the TMD record is valid until at least then.
                -- If the user specified gblDecomMapTimeGPS, then set the one and only TMD row's start time 
                -- to the TSL start time.
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

                -- STEP F) Get the data from L0 ---------------------------------------
                -- This makes a call back to the mission-specific code.

                IF ((apidArray(1) = -1) OR ((apidArray(1) != -1) AND (TSLRowApid MEMBER OF apidArray))) THEN
                    -- Use definitionColumn to determine which time column to restrict by decom map and which ones to 
                    -- 'loosely bound' the query (0: SCT, 1: ERT, 2: ASCT). 

                    CASE definitionColumn
                        WHEN 0 THEN
                            queryL0(TMDRows(j), TMDRowStartTime, TMDRowStopTime, startERT_in, stopERT_in, startASCT_in, stopASCT_in, doInclusiveQuery, definitionColumn);
                        WHEN 1 THEN
                            queryL0(TMDRows(j), startSCT_in, stopSCT_in, TMDRowStartTime, TMDRowStopTime, startASCT_in, stopASCT_in, doInclusiveQuery, definitionColumn);
                        WHEN 2 THEN 
                            queryL0(TMDRows(j), startSCT_in, stopSCT_in, startERT_in, stopERT_in, TMDRowStartTime, TMDRowStopTime, doInclusiveQuery, definitionColumn);
                    END CASE;
                END IF;
            END LOOP;  -- loop through TMdecom rows
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    logError('ERROR selectNumericTlm: ' || 'No TMDecom rows found for time range ' || 
                              TSLRowStartTime || ' - ' || TSLRowStopTime);
                WHEN others THEN
                    logError('ERROR selectNumericTlm: fetch block: others exception: ' ||
		              SQLCODE || ' -ERROR- ' || SQLERRM);
            END;    
        END LOOP;  -- end loop through TelemetryStorageLocation rows

        collateErrors();

        RETURN;

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            LogError('ERROR selectNumericTlm: No telemetryStorageLocation ' ||
                     'rows found for time range ' || definitionStartTime || ' - ' || definitionStopTime);
            collateErrors();
            RETURN;
    END;

    EXCEPTION
        WHEN time_error THEN
            logError('ERROR selectNumericTlm: Invalid or missing time range');
            collateErrors();
            RETURN;
        WHEN others THEN
            logError('ERROR selectNumericTlm: others exception: ' || SQLCODE || ' -ERROR- ' || SQLERRM);
            collateErrors();
            RETURN;

END selectNumericTlm;
END onTheFlyDecom;
/

