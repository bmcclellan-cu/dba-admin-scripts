;********************************************************************************
; Routine:  updateOnTheFlyDecomTables
;
; Purpose:  Creates a sql script which does the initial population of the TelemetryStorageLocation
;           and TMdecom tables, or inserts new rows as needed to update these tables, based on the
;           given the input system and a decom saveset.  Run the script in sqlplus or other DB app.
;           The two tables populated are the ones used by the on-the-fly decom stored procedures.
;           The TelemetryStorageLocation table is also used by TDP at run-time to determine
;           whether or not to ingest a given tlmId into an L1 table.
;
; Inputs:   systemIdStr - String version of a systemId from the SystemsDefinition table.
;                         The latest decom saveset file for this system name is found and used.
;           dbserver    - Optional.  The prod or dev database, e.g. 'ixpe-db-dev'.  Default is <mission>-db.
;           definition_start_time - Optional.  A string like: "yyyy/ddd-hh:mm:ss" which is used as the
;                                   definitionStart in all rows.  Default is current system time.
;                                   Set this when initially populating the tables to whenever TDP started
;                                   populating the L0/L1 tables.
;
; Usage:    source mission setup file
;           IDL> .r query_database2
;           IDL> .r update_on_the_fly_decom_tables
;           IDL> updateOnTheFlyDecomTables, 'FLATSAT_A', dbserver='emm-db-dev'  ; EMM dev
;           IDL> updateOnTheFlyDecomTables, 'FLIGHT', definition_start_time='2023/210-00:00:00'  ; EMM prod
;           IDL> updateOnTheFlyDecomTables, 'FLIGHT', dbserver='ixpe-db', definition_start_time='2021/001-00:00:00'  ; IXPE
;
;           % sqlplus user/password@mission-db[-dev]
;           SQL> @otfd_inserts.sql
;           SQL> commit;
;
;           The program uses the MISSIONID environmental variable to determine the mission.
;
; Algorithm:
;   Overview:
;   - The program never deletes or updates rows in either table;  it only inserts new rows.
;   - It only inserts rows for telemetry items which are in the decom saveset.  Derived items and
;     non-packetized items are never put in these tables, because they can't be on-the-fly decommed.
;   - It inserts the fewest rows possible.  It does *not* insert rows which only differ by
;     definitionStart, as a way to mark each tlmId having been considered by this routine.
;     The on-the-fly decom code depends on there not being any redundant rows.
;   - All the logic is done with in-memory copies of the two tables;  database queries are not intermixed
;     with the logic.  At the end, the in-memory variables are translated into sql insert statements
;     into the two tables, in a sqlldr file.
;
;   1. Restores the latest decom_saveset for the input systemId (variable: "decom_map").
;      The decom saveset should have the most recent packet definitions, as generated from the CT DB.
;      The CT DB may be updated at any time, but creation and release of a new decom saveset follows
;      a process whereby it is only done after Ops approval has been given.   Therefore these tables
;      should be updated as part of the same process.
;      IDL> help,/st,decom_map
;      ** Structure <2095268>, 5 tags
;      TMID       ULONG  1750
;      APID       UINT    121
;      DATATYPE   STRING   'U'
;      START_BIT  ULONG     0
;      LENGTH     UINT     16
;   2. Queries the database for the entire contents of the TelemetryStorageLocation and TMdecom tables.
;      Orders by systemId, apid, tlmId, definitionStart.  Stores in "tsl" and "tmd", each an array
;      of structures.   Removes records which aren't associated with the input systemId.
;   3. Creates empty arrays of structs, which will contain the rows to insert into these 2 tables.
;     "Create a record" below means add it to one of these array.
;   4. Assumes all telemetry items present in a decom saveset should be flagged as on-the-fly decommable:
;      isInL0=1, isInL1=0.  Exceptions can be added by adding logic to this code, or possibly in the future
;      via a config file.
;   5. Gets a list of apids from the decom_map (Step 1), and loops through the apids.  With each apid,
;      makes narrowed copies of all 3 variables (tsl, tmd, decom_map) which include only the current apid.
;      Pre-processes tsl and tmd by removing all but the most recent records (the newest row according to
;      the 'definitionStart' date/time).
;   6. Creates a TSL end record (isInL0=0, isInL1=0) for telemetry item(s) which no longer exist in this apid,
;      but did previously.  To the on-the-fly decom, this marks the time after which a telemetry item can
;      no longer be found in this packet.  Details: loops through tsl;  if a record exists for a tlmId,
;      and it's not already an end record (isInL0=0, isInL1=0), then searches for tlmId in decom_map.
;      If doesn't exist, then creates the TSL end record.
;   7. Creates a TMD end record (startBit=-1) for telemetry item(s) whose tlmIds no longer exist in this packet.
;      Details: loops through tmd;  If a tlmId doesn't exist in decom_map, creates the TMD end record.
;   8. Loops through decom_map, and creates new TSL and TMD records if they don't already exist in tsl and tmd.
;      Ignores end records, because we need to do inserts if a telemetry item re-instated.
;      - If the decom_map's tlmId exists in tsl and isn't an end record, then does nothing.
;        I.e. doesn't undo any manual changes to isInLx which may have been done (per logic or config file
;        mentioned in Step 4).
;        Otherwise creates a record with isInL0=1, isInL1=0.
;      - If the decom_maps's (tlmId,startBit,length,dataType) doesn't exist in tmd, creates a TMD record.
;
; Unit Test Cases:
;   These tests were run manually for IXPE.  They need to be coded into a unit_tests.bash shell script.
;      - Used ctpopulate files to create test data sets.
;      - Ran deleteByBuildType to delete the rows from the CT DB after use.
;      - Used select * queries on the tables and diffed their total contents with expected contents.
;   1. Swap the positions of two items in a packet.
;   2. Delete an item from a packet (only one occurrence should exist)
;        The new TelemetryStorageLocation row should have: isInL0=0, isInL1=0.
;        The new TMdecom row should have startOffset=-1.
;   3. Change an apid.  This is like deleting all the items from one packet, and adding
;      them to another.
;   4. Swap two apids.
;   5. Add a brand new item to the end of a packet.
;        One TelemetryStorageLocation row and one TMdecom row should be created.
;   6. Add a new item to the end of a packet, item already exists in another packet.
;        One TelemetryStorageLocation row and one TMdecom row should be created.
;   7. Verify no derived items are in the tables.
;   8. Verify no string items (dataType='C') are in the tables.
;   9. Add a second occurrence of an item in a packet, see what happens.  This isn't supported,
;      but check that the error handling / reporting is adequate.
;   
;********************************************************************************

;********************************************************************************
pro db_init, username, password, server
;********************************************************************************

  if n_params() ne 3 then begin
    message, 'Expected 3 arguments, got: ' + strtrim( n_params(),2) + '!'
  endif
  
  mission = getenv('MISSIONID')
  
  missions = ['emm', 'ixpe']
  w = where( missions eq mission, count)
  if count eq 0 then begin
    message, 'Error: invalid mission: ' + mission + $
             '!  Mission argument must be set to a supported mission: ' + $
             strjoin( missions, ',')
  endif
  index = w[0]
  mission  = missions[ index]

  print, 'Querying ' + strupcase( mission) + ' ' + server
  
  dbDriver = 'oracle.jdbc.driver.OracleDriver'

  switch mission of
    'goesr':
    'gold':
    'maven':
    'mms':
    'tsis': begin
      dbUrl = 'jdbc:oracle:thin:@' + strupcase( server) + ':1521/' + mission
      break
    end
  
    'emm': begin
      dbDriver = 'oracle.jdbc.driver.OracleDriver'
      if strlowcase(server) eq 'emm-db-dev' then begin
        dbUrl = 'jdbc:oracle:thin:@//emm-db-dev:1521/emmdev'
      endif else if strlowcase(server) eq 'emm-db' then begin
        dbUrl = 'jdbc:oracle:thin:@//emm-db:1521/emmprod'
      endif
      break
    end

    'imap':
    'ixpe':
    'suda': begin
      dbDriver = 'oracle.jdbc.driver.OracleDriver'
      dbUrl = 'jdbc:oracle:thin:@//' + server + ':1521/' + server
      ; e.g. jdbc:oracle:thin:@//ixpe-db-dev:1521/ixpe-db-dev
      break
    end

  endswitch

  ; Note: /DbConnect keyword prevents query_database from closing the connection every call.
  ; ctpopulate.pro calls query_database with /DbClose at the end.

  query = 'select count(*) from BuildTypes'
  query_database, query, result, nrows, server=server, user=username, password=password, $
                  /DbConnect, dbDriver=dbDriver, dbUrl=dbUrl
  if nrows lt 0 then begin
    fjava_print_exception
    print, ''
    print, 'IDL traceback:'
    help, /TRACEBACK
    print, ''
    message, 'Error occurred when initially connecting to database.  dbUrl = ' + dbUrl
  endif
END


;********************************************************************************
pro db, query, result, n_rows, close=close, ignore_exceptions=ignore_exceptions
;********************************************************************************
  
  verbose = 0
  
  if keyword_set( close) then begin
    query_database, /dbClose
    return
  endif

  query_database, query, result, n_rows

  if n_rows eq -1 and not keyword_set( IGNORE_EXCEPTIONS)  then begin
    fjava_print_exception
    print, ''
    print, 'IDL traceback:'
    help, /TRACEBACK
    print, ''
  endif

  if n_rows eq 0 && n_elements( result) ne 0 then begin
    junk = temporary( result)
  endif

  verbose_str = 'n_rows=' + strtrim( n_rows,2)

  if n_tags( result) eq 1 then begin
    result = result.(0)
    if n_rows eq 1 then begin
      verbose_str += ', result=' + strtrim( result, 2)
    endif
  endif
  if verbose ge 1 then begin
    print, verbose_str
  endif
END


;********************************************************************************
pro updateOnTheFlyDecomTables, systemIdStr_in, dbserver=dbserver, definition_start_time=definition_start_time
;********************************************************************************
  
  mission = getenv( 'MISSIONID')
  
  server = n_elements( dbserver) eq 0 ? strupcase( mission) + '-DB' : dbserver
  
  ; Get login credentials from the standard multi-mission TDP routine.
  
  get_database_login, mission, get_username=username, get_password=password
  db_init, username, password, server
  
  if keyword_set( definition_start_time) then begin
    definition_start_time_as_gps_usec = (DT_TO_SCT( STRING_TO_DT( definition_start_time))).vtcw
  endif else begin
    definition_start_time_as_gps_usec = (DT_TO_SCT( CURRENT_DT())).vtcw
  endelse
  
  ; Get the defined systems from the SystemsDefinition table.
  
  DB_CONNECT, username, password, server=server
  DB_GET_SYSTEMS, systems, systemIds
  DB_DISCONNECT
  
  ; Verify the input system is defined.
  
  systemIdStr = strupcase( systemIdStr_in)
  w = where( strupcase( systems) eq systemIdStr, count)
  if count ne 1 then begin
    print, "Couldn't find input systemIdStr: " + systemIdStr + " in SystemsDefinition table!"
    return
  endif
  systemId = systemIds[ w[0]]  
  
  ; Algorithm Step 1.
  ; Restore the newest decom saveset for the input system.
  
  print, 'Reading decom saveset...'
  mission = getenv('MISSIONID')
  
  if mission eq 'emm' then begin
    saveset_spec = 'ct_db_' + strupcase( systemIdStr) + '_20*.save'
    vars = {decom_maps: ptr_new()}
    DB_READ_CT_DB_SAVESET, saveset_spec, vars=vars
    if ptr_valid( vars.decom_maps) then begin
      decom_maps = *(vars.decom_maps)
      ptr_free, vars.decom_maps
    endif else begin
      message, "Couldn't restore CT DB and decom maps!"  ; IDL halts here
    endelse
    
    ; The following narrowing is here for test purposes: we only test with OTIS data because
    ; it has uniform density.  This should be removed later...FIXME!
    ; Maybe replaced by filtering out of the RFTC and CFG_FSA buildTypes, which can't be OTFD.
    
    if systemIdStr eq 'FLATSAT_A' then begin
      w = where( decom_maps.buildType eq 'OTIS_FSA', count)
      if count eq 0 then begin
        message, "Couldn't find buildType OTIS_FSA in decom_maps!"
      endif
      decom_map = *(decom_maps[w[0]].decom_map)
    endif else if systemIdStr eq 'FLIGHT' then begin
      ; EMM will be used for performance tuning AWS infrastructure and the DB for OTFD.
      ; So only a subset of telemetry is needed for OTFD testing.  I vetted the SC_FLT buildType.
      w = where( decom_maps.buildType eq 'SC_FLT', count)
      if count eq 0 then begin
        message, "Couldn't find buildType SC_FLT in decom_maps!"
      endif
      decom_map = *(decom_maps[w[0]].decom_map)
      ; I got all the apids from this decom_map and put them in a query to find packet names.
      ; I found one apid that needs to be excluded: apid=1569, packetName=PSEUDO_GENERAL.
      ; ny packet with name containing "pseudo" is not telemetered.  It was probably used
      ; to add derived items to the CT DB through the usual CT import process.
      w = where( decom_map.apid ne 1569)
      decom_map = decom_map[w]
      ; When I ran update_on_the_fly_decom_tables for EMM 03/2025, the most recent CT DB saveset
      ; was 2023/210, so I specified keyword definition_start_time to be: '2023/210-00:00:00'
    endif else begin
      message, "Only FLIGHT and FLATSAT_A are currently supported as systemIdStr input!"
    endelse
    
    ; Note: dataType='C' (strings) are always ingested into L1 and are not handled by the
    ; on-the-fly decom stored procedure.  Apps should query the TMstrings table directly.
    ; Remove these records from the decom map.
    
    w = where( decom_map.dataType ne 'C', count)
    if count lt n_elements( decom_map) then begin
      decom_map = decom_map[w]
    endif
    

  endif else if mission eq 'ixpe' then begin
    
    ; I verified that the decom saveset does not contain any pseudo-packets for derived items,
    ; nor any string items.
    
    read_decom_saveset, systemIdStr + '*.save', decom_map
    
  endif else begin
    
    print, 'Unsupported mission: ' + mission
    print, "Have to first check that mission's decom map saveset does not include any pseudo-packets for derived items."
    print, 'If it does, add code here to remove them, because otherwise OTFD would try to decom these, but derived items'
    print, 'only exist in L1.'
    stop
    
  endelse
  
  ; Algorithm Step 2.
  
  ; Read the subset of the TelemetryStorageLocation table for this systemId into an array of structures.
  
  print, 'Querying TelemetryStorageLocation...'
  query = "select * from TelemetryStorageLocation where systemId=" + strtrim(systemId,2) + $
          " order by apid, tlmId, definitionStart"
  db, query, tsl, n_rows
  if n_rows eq 0 then begin
    tsl = !NULL
  endif
  
  ; Read the subset of the TMdecom table for this systemId into an array of structures.
  
  print, 'Querying TMdecom...'
  query = "select * from TMdecom where systemId=" + strtrim(systemId,2) + $
          " order by apid, tlmId, definitionStart"
  db, query, tmd, n_rows
  if n_rows eq 0 then begin
    tmd = !NULL
  endif
  
  ; Algorithm Step 3.
  ; Define the arrays of rows to insert, initialized with just one row.
  
  tsl_record = {TSL,            $
                systemId: 0U,   $
                apid:     0U,   $
                tlmId:    0UL,  $
                definitionStart: 0ULL, $
                isInL0:   0,    $
                isInL1:   0}
  tsl_record.systemId = systemId
  new_tsl_records = tsl_record
  
  tmd_record = {TMD,            $
                systemId: 0U,   $
                apid:     0U,   $
                tlmId:    0UL,  $
                definitionStart: 0ULL, $
                dataType: '',   $
                startBit: -1,   $
                length:    0}
  tmd_record.systemId = systemId
  new_tmd_records = tmd_record
  
  ; Algorithm Step 4:
  ; Add any mission-specific logic with exceptions to the default of using OTFD for all downlinked numeric telemetry.
  
  if mission eq 'IXPE' then begin
    ; Designate the telemetry items used by ixpe_find_data_gaps --auto as still existing in L1.
    ; The tlmIds are the same in prod and dev.
    tlmIds_for_L1 = [2287, 2288, 2293]  ; [SSRSCIENCERECADDRHI, SSRSCIENCERECADDRLO, SSRSSOHRECADDR]
    for i=0,n_elements( tlmIds_for_L1)-1 do begin
      w = where( tsl.tlmId eq tlmIds_for_L1[i], /NULL)  ; if didn't find exactly one row, let idl halt with error and investigate DB
      tsl[w[0]].isInL0 = 0
      tsl[w[0]].isInL1 = 1
    endfor
  endif
  
  
  ; Get a list of apids from the decom_map.
  
  apids = decom_map.apid
  sorted_apids = apids[ sort( apids)]
  unique_apids = sorted_apids[ uniq( sorted_apids)]
  n_apids = n_elements( unique_apids)
  
  ; Save copies of the full sized variables.
  
  decom_map_all = decom_map
  tsl_all       = tsl
  tmd_all       = tmd
  
  n_recs_added = {TSL_end_records: 0L, TMD_end_records: 0L, TSL_records: 0L, TMD_records: 0L}
  
  
  ; Algorithm Step 5.
  ; Loop through apids.
  
  print, 'Looping through ' + strtrim( n_apids,2) + ' apids...'
  
  for apid_index=0, n_apids-1 do begin
    apid = unique_apids[ apid_index]
    
    print, 'Processing apid=' + strtrim( apid,2)
    
    ; Initialize the constant fields of what will be used as the new record.
    ; When we create a new tsl or tmd record, we fill out tsl[0] or tmd[0], then add it
    ; to the end of the array.   At the end, we'll remove this dummy 1st array element.
    
    new_tsl_records[0].apid = apid
    new_tsl_records[0].definitionStart = definition_start_time_as_gps_usec
    new_tmd_records[0].apid = apid
    new_tmd_records[0].definitionStart = definition_start_time_as_gps_usec
    
    ; Make a narrowed copy of decom_map that only includes this apid.
    
    w = where( decom_map_all.apid eq apid, count)
    decom_map = (count gt 0) ? decom_map_all[w] : !NULL
    
    ; Narrow TSL.
    ; 1. Make a narrowed copy that only includes this apid.
    ; 2. Remove all but the last (most recent) records for each tlmId.  The query
    ;    already sorted by definitionStart, so multiple records with the same tlmId
    ;    are already ordered by time.
    
    if n_elements( tsl_all) gt 0 then begin
      w = where( tsl_all.apid eq apid, count)
      if count gt 0 then begin
        tsl = tsl_all[w]
        mask = intarr( n_elements( tsl)) + 1  ; 1 => keep record, 0 => toss record
        for i=1,n_elements( tsl)-1 do begin
          ; If the previous record has the same tlmId, flag the previous record for tossing out
          if tsl[i-1].tlmId eq tsl[i].tlmId then mask[i-1] = 0
        endfor
        w = where( mask eq 1)  ; guaranteed to be at least one
        tsl = tsl[w]
      endif else begin
        tsl = !NULL
      endelse
    endif else begin
      tsl = !NULL
    endelse
    
    ; Narrow TMD.
    ; 1. Make a narrowed copy that only includes this apid.
    ; 2. Remove all but the last (most recent) records for each tlmId.
    
    if n_elements( tmd_all) gt 0 then begin
      w = where( tmd_all.apid eq apid, count)
      if count gt 0 then begin
        tmd = tmd_all[w]
        mask = intarr( n_elements( tmd)) + 1  ; 1 => keep record, 0 => toss record
        for i=1,n_elements( tmd)-1 do begin
          ; If the previous record has the same tlmId, flag the previous record for tossing out
          if tmd[i-1].tlmId eq tmd[i].tlmId then mask[i-1] = 0
        endfor
        w = where( mask eq 1)  ; guaranteed to be at least one
        tmd = tmd[w]
      endif else begin
        tmd = !NULL
      endelse
    endif else begin  
      tmd = !NULL
    endelse
    
    ; Algorithm Step 6.
    ; Create a TSL end record (isInL0=0, isInL1=0) for telemetry items which no longer exist in this apid,
    ; but did previously.  Loop through tsl;  if a record exists for a tlmId, and it's not an end record
    ; (isInL0=0, isInL1=0), then search for tlmId in decom_map.  If doesn't exist, create the TSL end record.
    
    n_tsl = n_elements( tsl)
    for i=0, n_tsl-1 do begin
      is_an_end_record = tsl[i].isInL0 eq 0 and tsl[i].isInL1 eq 0
      if ~is_an_end_record then begin
        w = where( decom_map.tmid eq tsl[i].tlmId, count)
        if count eq 0 then begin
          ; systemId, apid, definitionStart are already set
          new_tsl_records[0].tlmId = tsl[i].tlmId
          new_tsl_records[0].isInL0 = 0
          new_tsl_records[0].isInL1 = 0
          new_tsl_records = [new_tsl_records, new_tsl_records[0]]
          n_recs_added.TSL_end_records++
        endif
      endif
    endfor
    
    ; Algorithm Step 7.
    ; Create a TMD end record (startBit=-1) for telemetry items whose tlmIds no longer exist in this packet,
    ; but did previously.  Loop through tmd;  If a tlmId doesn't exist in decom_map, create the TMD end record.
    
    n_tmd = n_elements( tmd)
    for i=0, n_tmd-1 do begin
      w = where( decom_map.tmid eq tmd[i].tlmId, count)
      if count eq 0 then begin
        ; systemId, apid, definitionStart are already set
        new_tmd_records[0].tlmId    = tmd[i].tlmId
        new_tmd_records[0].dataType = tmd[i].dataType
        new_tmd_records[0].startBit = -1
        new_tmd_records[0].length   = tmd[i].length
        new_tmd_records = [new_tmd_records, new_tmd_records[0]]
        n_recs_added.TSL_end_records++
      endif
    endfor
    
    ; Algorithm Step 8.
    ; Loop through decom_map, and create a new TSL and a new TMD record for each tlmId,
    ; if they don't already exist in tsl and tmd, or if the existing record is an end record.
    ; 1. If the decom_maps's (tlmId,startBit,length,dataType) doesn't exist in tmd, create a TMD record.    
    ; 2. If the decom_map's tlmId exists in tsl and isn't an end record, then do nothing.
    ;    I.e. don't undo any manual changes to isInLx which may have been done.
    ;    Otherwise (doesn't exist or is an end record) create a record with isInL0=1, isInL1=0.
    ;    If it doesn't exist (never did), then it was added to the packet definition since this
    ;    program was last run.
    ;    If an end record exists, then it was deleted, and has now been re-instated.
  
    for i=0, n_elements( decom_map)-1 do begin
      
      if n_elements( tmd) gt 0 then begin
        w = where( tmd.tlmId    eq decom_map[i].tmid      and $
                   tmd.startBit eq decom_map[i].start_bit and $
                   tmd.length   eq decom_map[i].length    and $
                   tmd.dataType eq decom_map[i].dataType, count)
      endif else begin
        count = 0
      endelse
      
      if count eq 0 then begin
        ; Create new record.
        new_tmd_records[0].tlmId    = decom_map[i].tmid
        new_tmd_records[0].startBit = decom_map[i].start_bit
        new_tmd_records[0].length   = decom_map[i].length
        new_tmd_records[0].dataType = decom_map[i].dataType
        new_tmd_records = [new_tmd_records, new_tmd_records[0]]
        n_recs_added.TMD_records++
      endif
      
      if n_elements( tsl) gt 0 then begin
        w = where( tsl.tlmId eq decom_map[i].tmid, count)
      endif else begin
        count = 0
      endelse
      
      if count eq 1 then begin
        is_an_end_record = tsl[w[0]].isInL0 eq 0 and tsl[w[0]].isInL1 eq 0
        if ~is_an_end_record then begin
          continue
        endif
      endif
      
      ; Create new record.
      new_tsl_records[0].tlmId = decom_map[i].tmid
      new_tsl_records[0].isInL0 = 1
      new_tsl_records[0].isInL1 = 0
      new_tsl_records = [new_tsl_records, new_tsl_records[0]]
      n_recs_added.TSL_records++
      
    endfor  ; loop through decom_map records
    
  endfor ; end loop through apids 
  
  ; Remove the first dummy record from the new* arrays.
  
  new_tsl_records = (n_elements( new_tsl_records) gt 1) ? new_tsl_records[1:*] : !NULL
  new_tmd_records = (n_elements( new_tmd_records) gt 1) ? new_tmd_records[1:*] : !NULL
  
  print, ''
  print, 'Adding ' + strtrim( n_recs_added.TSL_end_records,2) + ' TSL end records.'
  print, 'Adding ' + strtrim( n_recs_added.TSL_records,2)     + ' TSL normal records.'
  print, 'Adding ' + strtrim( n_recs_added.TMD_end_records,2) + ' TMD end records.'
  print, 'Adding ' + strtrim( n_recs_added.TMD_records,2)     + ' TMD normal records.'
  print, ''
  
  ; Translate the new* array contents to insert statements.
  
  filename = 'otfd_inserts.sql'
  openw, lun, /GET_LUN, filename
  
  column_names = "(systemId, apid, tlmId, definitionStart, isInL0, isInL1)"
  for i=0, n_elements( new_tsl_records)-1 do begin
    str = "insert into TelemetryStorageLocation " + column_names + " values (" + $
          strtrim( new_tsl_records[i].systemId, 2)             + "," + $
          strtrim( new_tsl_records[i].apid, 2)                 + "," + $
          strtrim( new_tsl_records[i].tlmId, 2)                + "," + $
          string( new_tsl_records[i].definitionStart, format='(I16)') + "," + $
          strtrim( new_tsl_records[i].isInL0, 2)               + "," + $
          strtrim( new_tsl_records[i].isInL1, 2)               + ");"
    printf, lun, str          
  endfor
  
  column_names = "(systemId, apid, tlmId, definitionStart, dataType, startBit, length)"
  for i=0, n_elements( new_tmd_records)-1 do begin
    str = "insert into TMdecom " + column_names + " values (" + $
          strtrim( new_tmd_records[i].systemId, 2)             + "," + $
          strtrim( new_tmd_records[i].apid, 2)                 + "," + $
          strtrim( new_tmd_records[i].tlmId, 2)                + "," + $
          string( new_tmd_records[i].definitionStart, format='(I16)') + "," + $
          "'" + new_tmd_records[i].dataType + "'"              + "," + $
          strtrim( new_tmd_records[i].startBit, 2)             + "," + $
          strtrim( new_tmd_records[i].length, 2)               + ");"
    printf, lun, str          
  endfor
  
  free_lun, lun
  
  print, 'Output sql for ingest is in ' + filename
  
END


