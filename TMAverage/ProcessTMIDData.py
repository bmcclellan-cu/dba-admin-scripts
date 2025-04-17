#!/usr/bin/env python3


# System imports
import sys
import logging
import math
import time
# Third-party imports
import oracledb
import numpy as np


connection = None
cursor = None
violatedReferentialIntegrity = False

# Dictionary of databases this script is designed for and the appropriate table to access.
TMANALOG_DBS = {
    "goldprod": "TMANALOG_SID1",
    "evep12c": "TMANALOG",
    "aimprod": "TMANALOG_TABLE", 
    "tsisprod": "TMANALOG_SID1",
    "ixpeprod": "TMANALOG_SID1"
}

TMAVERAGE_DBS = {
    "goldprod": "ROBERT_TEST.TMAverage", 
    # Currently this way for testing. I created the table in the sys schema, but will end up in the L1 schema.
    "evep12c": "ROBERT_TEST.TMAverage",
    "tsisprod": "ROBERT_TEST.TMAverage", # Added testing table, but will probably also be what it will be in prod.
    "ixpeprod": "ROBERT_TEST.TMAverage", # Currently does not have TMAverage table
    "aimprod" : "ROBERT_TEST.TMAVERAGE" # Currently this way for testing, need to compare.
}

TELEMETRYITEMDEFINITION_DBS = {
    "goldprod": "TelemetryItemDefinition",
    "evep12c": "TelemetryItemDefinition",
    "tsisprod": "TelemetryItemDefinition",
    "ixpeprod": "TelemetryItemDefinition",
    "aimprod": "AIM_CT_SC.TelemetryItemDefinition"
}

TELEMETRYANALOGCONVERSIONS_DBS = {
    "goldprod": "TelemetryAnalogConversions",
    "evep12c": "TelemetryAnalogConversions",
    "tsisprod": "TelemetryAnalogConversions",
    "ixpeprod": "TelemetryAnalogConversions",
    "aimprod": "AIM_CT_SC.TelemetryAnalogConversions"
}

def get_password_from_file(file_path):
    try:
        with open(file_path, 'r') as file:
            password = file.readline().strip()  # Read the first line and strip whitespace
        print(f"Password read in from path: {file_path}")
        return password
    except Exception as e:
        print(f"An error occurred while reading the password: {e}")
        return None


# Fetches all values for a specific day, then allocates numpy arrays for the values, calculated bucket 
# ids, and the list of tmids, then populates them. 
# OUTPUT: Tuple (results_len, results_values, results_bucket_ids, results_tmids)
def fetch_all_values_by_time_range(connection, database, select_date_start_gps, select_date_end_gps):
    sql = f"""SELECT /*+ PARALLEL(AUTO) */ TMID, SCT_VTCW, VALUE FROM {TMANALOG_DBS[database]} WHERE 
    (SCT_VTCW >= {select_date_start_gps}) AND (SCT_VTCW < {select_date_end_gps}) AND VALUE IS NOT NULL"""
    # print(sql) # DEBUG
    cursor = connection.cursor()
    try: 
        results = cursor.execute(sql).fetchall()
    except oracledb.DatabaseError as error:
        if str(error).find("ORA-00942") != -1:
            print("ORA-00942: table or view does not exist")
            print("This error is likely due to missing permissions.")
            print("Ensure that the script has the following permissions: ")
            print("(TMAnalog(SELECT), TelemetryItemDefinition(SELECT), TelemetryAnalogConversions(SELECT), TMAverage(ALL)")
            exit(1)
        else:
            raise error
            
    results_len = len(results)
    results_values = np.zeros((results_len))
    results_bucket_ids = np.zeros((results_len))
    results_tmids = np.zeros((results_len))

    print(f"Retrieved {results_len} records. Ingesting...")

    rowCounter = 0

    for row in results:
        results_tmids[rowCounter] = row[0]

        # Calculate the bin ID for the specific row. Prevents needing to iterate over array later.
        time = row[1]
        timeDelta = time - select_date_start_gps
        results_bucket_ids[rowCounter] = int(math.trunc(timeDelta/300000000))

        results_values[rowCounter] = row[2]
        rowCounter += 1

    cursor.close()

    return (results_len, results_values, results_bucket_ids, results_tmids)

def fetch_analog_conversions_by_tmid(cursor, tmid, database):
    sql = f"""select C.conversionType,  C.lowValue, C.c0,  C.c1,  C.c2,  C.c3,  C.c4,  C.c5,  C.c6,  C.c7 
            FROM {TELEMETRYANALOGCONVERSIONS_DBS[database]} C 
            where C.tlmId = {tmid} order by C.segmentNumber"""
    # print(sql) # DEBUG
    try:
        results = cursor.execute(sql).fetchone()
    except oracledb.DatabaseError as error:
        if str(error).find("ORA-00942") != -1:
            print("ORA-00942: table or view does not exist")
            print("This error is likely due to missing permissions.")
            print("Ensure that the script has the following permissions: ")
            print("(TMAnalog(SELECT), TelemetryItemDefinition(SELECT), TelemetryAnalogConversions(SELECT), TMAverage(ALL)")
            exit(1)
        else:
            raise error

    return results

def insert_tmaverage_rows(cursor, TMID, database, TMAverageValues):
    global connection
    global violatedReferentialIntegrity


    # TODO: Determine if the default should be that there is no SID recorded.
    sql = f"""INSERT INTO {TMAVERAGE_DBS[database]} 
        (TMID, SCT_VTCW, AVERAGE_VALUE, MINIMUM_VALUE, MAXIMUM_VALUE, VALUE_COUNT) 
        VALUES (:1, :2, :3, :4, :5, :6)"""
    # print(sql) # DEBUG
    try:
        cursor.executemany(sql, TMAverageValues)
        connection.commit()
    except oracledb.IntegrityError as error:
        if str(error).find("ORA-00001") != -1:
            print(f"Error: Unique Constraint Violated for TMID {TMID}, skipping insert...")
            violatedReferentialIntegrity = True
        else:
            raise error
    except oracledb.DatabaseError as error:
        if str(error).find("ORA-00942") != -1:
            print("ORA-00942: table or view does not exist")
            print("This error is likely due to missing permissions.")
            print("Ensure that the script has the following permissions: ")
            print("(TMAnalog(SELECT), TelemetryItemDefinition(SELECT), TelemetryAnalogConversions(SELECT), TMAverage(ALL)")
            exit(1)
        else:
            raise error

    if cursor.rowcount != 0:
        print(f"Successfully inserted {cursor.rowcount} rows into TMAverage for TMID: {TMID}")
    else:
        print("Unable to insert rows... Continuing")
        violatedReferentialIntegrity = True


def processValues(connection, database, start_time_gps, end_time_gps):
    cursor = connection.cursor()
    
    # Fetch all data for the given date range.
    print("Pulling data")
    data = fetch_all_values_by_time_range(connection, database, start_time_gps, end_time_gps)

    results_len = data[0]
    results_values = data[1]
    results_bucket_ids = data[2]
    results_tmids = data[3]

    # np.savetxt("/ssd_internal/Robert/TMAverage_testing_data/results_values_aim.csv", results_values, delimiter=",")
    # print("Saved values")
    # np.savetxt("/ssd_internal/Robert/TMAverage_testing_data/results_bucket_ids_aim.csv", results_bucket_ids, delimiter=",")
    # print("Saved bucket ids")
    # np.savetxt("/ssd_internal/Robert/TMAverage_testing_data/results_tmids_aim.csv", results_tmids, delimiter=",")
    # print("Saved tmids")

    # exit(0)


    # Currently loads from csv while I am testing the new averaging code.
    # results_values = np.loadtxt("/ssd_internal/Robert/TMAverage_testing_data/results_values_aim.csv")
    # print("Read from results_values.csv")
    # results_bucket_ids = np.loadtxt("/ssd_internal/Robert/TMAverage_testing_data/results_bucket_ids_aim.csv")
    # print("Read from results_bucket_ids.csv")
    # results_tmids = np.loadtxt("/ssd_internal/Robert/TMAverage_testing_data/results_tmids_aim.csv")
    # print("Read from results_tmids.csv")

    # results_len = int(np.size(results_tmids))
    # print("Calculated the length")



    # If there is no data for the time range, then exit.
    if results_len == 0:
        print(f"No data found for the time range {start_time_gps} - {end_time_gps}")
        return True

    unique_tmids = np.unique(results_tmids)
    unique_bucket_ids = range(int(((end_time_gps-start_time_gps)/300000000)))


    print("Unique_bucket_ids: " + str(unique_bucket_ids))
    print("Unique_tmids: " + str(unique_tmids))

    insertion_data = []

    for tmid in unique_tmids:
        print(f"Processing TMID: {tmid}")
        tmid_mask = np.where(results_tmids == tmid, True, False)
        tmid_bucket_ids = results_bucket_ids[tmid_mask]

        # Fetch calibration data, then apply to all values for the specific TMID.

        tmid_values = results_values[tmid_mask]
                                          
        calibration_data = fetch_analog_conversions_by_tmid(cursor, tmid, database)

        if np.size(tmid_values) == 0:
            print(f"No data for tmid {tmid}")
            continue

        # Apply the polynomial calibration every time, as long as it exists.
        if calibration_data != None:
            polynomial_calibration = calibration_data[2:] # Indexes of the polynomial coefficients, removes extra.
            tmid_values = np.apply_along_axis(calibrate, -1, tmid_values, (polynomial_calibration))

        for bucket_id in unique_bucket_ids:
            bucket_mask = np.where(tmid_bucket_ids == bucket_id, True, False)
            bucket_values = tmid_values[bucket_mask]

            current_bucket_count = np.size(bucket_values)

            if current_bucket_count == 0:
                insertion_data.append((int(tmid), int(bucket_id * 300_000_000 + start_time_gps + 150_000_000 + 18_000_000), 0, 0, 0, 0)) # DEBUG: Here to test 18 second offset
                continue

            current_bucket_average = float(np.average(bucket_values))
            current_bucket_min = float(np.min(bucket_values))
            current_bucket_max = float(np.max(bucket_values))
            insertion_data.append((int(tmid), int(bucket_id * 300000000 + start_time_gps + 150_000_000 + 18_000_000), current_bucket_average, current_bucket_min, current_bucket_max, current_bucket_count))


    # There will always be data to insert, even if no actual values are present because the output just gets zeroed for all bins.
    insert_tmaverage_rows(cursor, "Done", database, insertion_data)
    return True

def convertDTtoGPS(cursor, DTValue, isAim):
    # The DT2GPS function takes a string in the format "{date} {time}"

    if isAim:
        cursor.execute("ALTER SESSION SET NLS_TIMESTAMP_FORMAT='DD-MON-RR HH.MI.SSXFF AM'")
    
    sql = f"""SELECT DT2GPS('{DTValue}') FROM dual"""

    # print(sql) # DEBUG

    try:
        result = cursor.execute(sql).fetchone()[0]
    except oracledb.DatabaseError:
        print("Failed to convert date to GPS. Please ensure that you entered in the format 'DD-MMM-YY'")
        print("Example: 28-MAR-25")
        exit(1)
    return result - 18000000 # DEBUG: Here in order to test 18 second offset.

def calibrate(arraySlice, c):
    value = arraySlice
    newValue = c[0] + c[1]*value + c[2]*value**2 + c[3]*value**3 + c[4]*value**4 + c[5]*value**5 + c[6]*value**6 + c[7]*value**7
    return newValue


# This function uses the start_time_gps value and the assumption that each bin will be 300000000 (5 min)
# wide to categorize each value into a bin.
def calculateBinID(arraySlice, start_time_gps):
    time = arraySlice[0]
    timeDelta = time - start_time_gps
    return int(math.trunc(timeDelta/300000000))


def main():
    """ 
        This script fetches the values for each TMID in the provided database for the day provided from
        all TMAnalog_SIDX tables, and computes the min, max, average, and count of measurements
        over 5 minute increments, then inserts them into the TMAverage table.
        Inputs: [database] [date]
    """
    # Usage and example
    usage = "Usage: ./ProcessTMIDData.py [database] [date]"
    example = "Example: ./ProcessTMIDData.py goldprod 12-JAN-25"
    global connection
    global violatedReferentialIntegrity

    for argument in sys.argv:
        if argument == "-h":
            print(usage)
            print(example)
            exit(0)
    
    numArgs = len(sys.argv)

    # Check if there were 2 arguments passed (+1 including python script name)
    if numArgs != 3:
        print(usage)
        print(example)
        exit(1)

    database = sys.argv[1].lower()
    selectDate = sys.argv[2]

    username = "PROCESSTMIDTEST"
    password = get_password_from_file("./.passwd")

    if password == None:
        # Error message is already printed by get_password_from_file
        exit(1)


    # Validate database input
    if database not in TMAVERAGE_DBS.keys() or database not in TMANALOG_DBS.keys():
        print("Selected database is not supported by script. Supported databases are: " + str(tuple(TMAVERAGE_DBS.keys())))
        exit(1)
    

    # Connect to database
    try: 
        ConnectionString = f"localhost/{database}"
        connection = oracledb.connect(user=username, password=password, dsn=ConnectionString)
        cursor = connection.cursor()
        print(f"Successfully connected to database {database}.")
    except:
        print(f"Error connecting to database {database}. Check if database exists and the script has connect priviliges.")
        exit(1)

    start_time_gps = convertDTtoGPS(cursor, f"{selectDate} 12.00.00.000000000 AM", database == "aimprod")
    end_time_gps = convertDTtoGPS(cursor, f"{selectDate} 11.59.59.999999999 PM", database == "aimprod")

    print(start_time_gps, end_time_gps)

    cursor.close()

    processValues(connection, database, start_time_gps, end_time_gps)

    if(violatedReferentialIntegrity):
        print("The script ran successfully, but during insertion of data there was at least one Unique Constraint Violation.")
        print("This usually means that the script's range overlapped with pre-existing data in the TMAverage table.")
        print("Please check above output for more details.")
    else:
        print("Script completed successfully. Exiting...")

    exit(0)

if __name__ == "__main__":
    main()

