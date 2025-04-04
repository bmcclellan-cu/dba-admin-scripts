#!/usr/bin/env python3

import sys
import numpy
import logging
import oracledb
import math
import time

# TODO: Add error checking for improper permissions

connection = None
cursor = None
violatedReferentialIntegrity = False

# Dictionary of databases this script is designed for and the appropriate table to access.
TMAnalogDBs = {
    "goldprod": "TMANALOG_SID1",
    "evep12c": "TMANALOG",
    # "aimprod": , 
    "tsisprod": "TMANALOG_SID1",
    "ixpeprod": "TMANALOG_SID1"
}

TMAverageDBs = {
    "goldprod": "SYS.TMAverage", # Currently this way for testing. I created the table in the sys schema, but will end up in the L1 schema.
    "evep12c": "EVE_L1.TMAverage",
    "tsisprod": "TSIS_L1.TMAverage", # Added testing table, but will probably also be what it will be in prod.
    "ixpeprod": "IXPE_L1.TMAverage" # Currently does not have TMAverage table
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


# Returns a list of all of the TMIDs in the server
def fetchAllTMIDs(cursor):
    global violatedReferentialIntegrity
    TMIDArray = []
    sql = """SELECT UNIQUE TLMID from TelemetryItemDefinition WHERE dataType='U' OR dataType='I' OR dataType='F'"""
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

    for row in results:
        # Row is in the form of a tuple, extract value from tuple and append to list.
        TMIDArray.append(row[0])

    return TMIDArray


def fetchTMIDValuesByTimeRange(cursor, TMID, database, selectDateStartGPS, selectDateEndGPS):
    # Uses the pre-defined table name for the given database to pull the data.
    sql = f"""SELECT SCT_VTCW, VALUE FROM {TMAnalogDBs[database]} WHERE TMID={TMID} AND SCT_VTCW BETWEEN 
        {selectDateStartGPS} AND {selectDateEndGPS} AND VALUE IS NOT NULL"""

    # First fetch the data, then determine the number of rows, resize numpy array, and insert into 
    # allocated array.

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
    # The fetchall method loads everything into a python array of tuples at once, which may cause issues. It can be improved by a bit
    # By increasing the arraysize attribute of the cursor, so that it loads them in bigger batches.

    resultsLen = len(results)
    TMIDValues = numpy.zeros((resultsLen, 2))
    rowCounter = 0

    for row in results:
        TMIDValues[rowCounter] = [row[0], row[1]]
        rowCounter += 1

    return TMIDValues


def fetchAnalogConversionbyTMID(cursor, TMID):
    sql = f"""select  N.euUnits,  C.conversionType,  C.lowValue, C.c0,  C.c1,  C.c2,  C.c3,  C.c4,  C.c5,  C.c6,  C.c7 
            from TelemetryItemDefinition N, TelemetryAnalogConversions C 
            where C.tlmId = {TMID} and N.tlmId = C.tlmId order by C.segmentNumber"""
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

def insertTMAverageRows(cursor, TMID, database, TMAverageValues):
    global connection
    global violatedReferentialIntegrity
    # TODO: Determine if the default should be that there is no SID recorded.
    if database != "goldprod":
        sql = f"INSERT INTO {TMAverageDBs[database]} (TMID, SCT_VTCW, AVERAGE_VALUE, MINIMUM_VALUE, MAXIMUM_VALUE, VALUE_COUNT) VALUES (:1, :2, :3, :4, :5, :6)"
    else:
        sql = f"INSERT INTO {TMAverageDBs[database]} (SID, TMID, SCT_VTCW, AVERAGE_VALUE, MINIMUM_VALUE, MAXIMUM_VALUE, VALUE_COUNT) VALUES (:1, :2, :3, :4, :5, :6, :7)"
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


def processValues(TMID, database, startTimeGPS, endTimeGPS):
    global connection
    cursor = connection.cursor()
    
    # Fetch all data for the given date range.
    dataArray = fetchTMIDValuesByTimeRange(cursor, TMID, database, startTimeGPS, endTimeGPS)

    # If there is no data for the TMID, do not average.
    if len(dataArray) == 0:
        print(f"No data found for TMID {TMID}, continuing...")
        return True

    calibrationData = fetchAnalogConversionbyTMID(cursor, TMID)

    # If there is no calibration data or if it's already in "DN", then calibrate.
    if calibrationData != None and calibrationData[0] != "DN":
        polynomialCalibration = calibrationData[3:] # Indexes of the polynomial coefficients, removes extra.
        dataArray = numpy.apply_along_axis(calibrate, -1, dataArray, polynomialCalibration)

    # Generates bucket list, width 300000000 GPS.

    # TODO:  Check if there would be a remainder from the bucket creation.

    if ((endTimeGPS - startTimeGPS) % 300000000 != 0):
        print("Error, time difference must be a multiple of 300000000 (5 minutes).")

    numOfBuckets = int((endTimeGPS - startTimeGPS)/300000000)

    # Makes a list of bin indexes to put the data into. 
    binIndexes = numpy.apply_along_axis(calculateBinID, -1, dataArray, startTimeGPS)

    # The resultant output from the script, formatted:
    # SCT_VTCW, AVERAGE_VALUE, MINIMUM_VALUE, MAXIMUM_VALUE, VALUE_COUNT

    TMAverageInsertData = []

    for i in range(numOfBuckets):
        bucketStartGPS = i * 300000000 + startTimeGPS
        bucketEndGPS = (i + 1) * 300000000 + startTimeGPS

        # Uses the binIndexes filter to determine what indexes to fetch data from, and simply filter. Then removes the time column, 
        # as it is no longer necessary and might add averaging overhead.
        currentBucketData = numpy.delete(dataArray[numpy.where(binIndexes == i)], 0, axis=1)

        # No data in bucket, continue.
        if numpy.size(currentBucketData) == 0:
            continue

        # The outputs are always tuples, so index out the value.
        currentBucketAverage = float(numpy.average(currentBucketData, axis=0)[0]) # Defaults to np.float64
        currentBucketMin = float(numpy.min(currentBucketData, axis=0)[0])
        currentBucketMax = float(numpy.max(currentBucketData, axis=0)[0])
        currentBucketCount = numpy.size(currentBucketData)

        # TODO: Determine if default should be no SID, have if statement for now.
        if database != "goldprod":
            TMAverageInsertData.append((TMID, (bucketStartGPS + bucketEndGPS)/2, currentBucketAverage, currentBucketMin, currentBucketMax, currentBucketCount))
        else:
            TMAverageInsertData.append((1, TMID, (bucketStartGPS + bucketEndGPS)/2, currentBucketAverage, currentBucketMin, currentBucketMax, currentBucketCount))

    insertTMAverageRows(cursor, TMID, database, TMAverageInsertData)

    return True

def convertDTtoGPS(cursor, DTValue):
    # The DT2GPS function takes a string in the format "{date} {time}"
    sql = f"""SELECT DT2GPS('{DTValue}') FROM dual"""
    for row in cursor.execute(sql):
        result = row[0]
    return result


def filter(arraySlice, startTime, endTime):
    if arraySlice[0] < startTime or arraySlice[0] > endTime:
        return False
    else:
        return True


def calibrate(arraySlice, c):
    value = arraySlice[1]
    newValue = c[0] + c[1]*value + c[2]*value**2 + c[3]*value**3 + c[4]*value**4 + c[5]*value**5 + c[6]*value**6 + c[7]*value**7
    return [arraySlice[0], newValue]


# This function uses the startTimeGPS value and the assumption that each bin will be 300000000 (5 min)
# wide to categorize each value into a bin.
def calculateBinID(arraySlice, startTimeGPS):
    time = arraySlice[0]
    timeDelta = time - startTimeGPS
    return int(math.trunc(timeDelta/300000000))


def main():
    """ 
        This script fetches the values for each TMID in the provided database for the day provided from
        all TMAnalog_SIDX tables, and computes the min, max, average, and count of measurements
        over 5 minute increments, then inserts them into the TMAverage table.
        Inputs: [database] [Date]
    """
    # Usage and example
    usage = "Usage: ./ProcessTMIDData.py [input.csv] [output.csv] [start time | gps] [end time | gps]"
    example = "Example: ./ProcessTMIDData.py TMIDData.csv ProcessedTMIDData.csv 1420675218000000 1420761618000000"

    global connection
    global violatedReferentialIntegrity

    username = "PROCESSTMIDTEST"
    password = get_password_from_file("./.passwd")

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

    # Validate database input
    if database not in TMAverageDBs.keys() or database not in TMAnalogDBs.keys():
        print("Selected database is not supported by script. Supported databases are: " + str(tuple(TMAverageDBs.keys())))
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
    

    TMIDArray = fetchAllTMIDs(cursor)
    
    print(f"TMID Length: {len(TMIDArray)}")

    startTimeGPS = convertDTtoGPS(cursor, f"{selectDate} 12.00.00.000000000 AM")
    endTimeGPS = convertDTtoGPS(cursor, f"{selectDate} 11.59.59.999999999 PM")

    print(startTimeGPS, endTimeGPS)

    
    cursor.close()

    for TMID in TMIDArray:
        
        # Re-open fresh cursor to prevent clutter from many large queries (performance degreades otherwise.)
        print(f"Fetching data for {TMID}.")

        TMIDT0 = time.time()
        
        processValues(TMID, database, startTimeGPS, endTimeGPS)
        
        print(f"Finished TMID {TMID} in {time.time() - TMIDT0}")


    if(violatedReferentialIntegrity):
        print("The script ran successfully, but during insertion of data there was at least one Unique Constraint Violation.")
        print("This usually means that the script's range overlapped with pre-existing data in the TMAverage table.")
        print("Please check above output for more details.")
    else:
        print("Script completed successfully. Exiting...")

    exit(0)

if __name__ == "__main__":
    main()

