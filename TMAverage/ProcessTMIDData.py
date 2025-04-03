#!/usr/bin/env python3

import os
import sys
import numpy
import logging
import oracledb

connection = None
cursor = None

Username = "PROCESSTMIDTEST"
ConnectionString = "localhost/goldprod" # TODO: Take a user input for the server SID.
Password = "testPWD"  # TODO: Script will read the password from a local file 


# Returns a list of all of the TMIDs in the server
def fetchAllTMIDs(cursor):
    TMIDArray = []
    sql = """SELECT UNIQUE TLMID from TelemetryItemDefinition WHERE dataType='U' OR dataType='I' OR dataType='F'"""
    for row in cursor.execute(sql):
        # Row is in the form of a tuple, extract value from tuple and append to list.
        TMIDArray.append(row[0])

    return TMIDArray


def fetchTMIDValuesByTimeRange(cursor, TMID, selectDateStartGPS, selectDateEndGPS):
    sql = f"""SELECT SCT_VTCW, VALUE FROM TMANALOG_SID1 WHERE TMID={TMID} AND SCT_VTCW BETWEEN 
        {selectDateStartGPS} AND {selectDateEndGPS}"""

    # First fetch the data, then determine the number of rows, resize numpy array, and insert into 
    # allocated array.

    cursor.execute(sql)
    results = cursor.fetchall()
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
    cursor.execute(sql)
    results = cursor.fetchone()

    return results




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


def main():
    """ 
        This script loads the provided csv file into a numpy array and returns the 
        minimum, maximum, average, and count of values provided for every 5 minute increment 
        into an output csv file

        Inputs:  [Date]
    """
    # Usage and example
    usage = "Usage: ./ProcessTMIDData.py [input.csv] [output.csv] [start time | gps] [end time | gps]"
    example = "Example: ./ProcessTMIDData.py TMIDData.csv ProcessedTMIDData.csv 1420675218000000 1420761618000000"


    numArgs = len(sys.argv)

    # Check if there were 1 arguments passed (+1 including python script name)
    if numArgs != 2:
        print(usage)
        print(example)
        exit(0)

    selectDate = sys.argv[1]

    # TODO: Need to check if times are in proper order.

    # Connect to database
    try: 
        connection = oracledb.connect(user=Username, password=Password, dsn=ConnectionString)
        cursor = connection.cursor()
    except:
        print("Error connecting to database.")
        exit(1)
    
    print("Successfully connected to database.")

    TMIDArray = fetchAllTMIDs(cursor)
    
    print(len(TMIDArray))


    startTimeGPS = convertDTtoGPS(cursor, f"{selectDate} 12.00.00.000000000 AM")
    endTimeGPS = convertDTtoGPS(cursor, f"{selectDate} 11.59.59.999999999 PM")

    print(startTimeGPS)
    print(endTimeGPS)

    # TODO: Temporary, will iterate through all TMIDs

    TMID = 841

    dataArray = fetchTMIDValuesByTimeRange(cursor, TMID, startTimeGPS, endTimeGPS)

    calibrationData = fetchAnalogConversionbyTMID(cursor, TMID)

    print(calibrationData)


    if calibrationData[0] != "DN":
        polynomialCalibration = calibrationData[3:] # Indexes of the polynomial coefficients, removes extra.
        dataArray = numpy.apply_along_axis(calibrate, -1, dataArray, polynomialCalibration)

    
    # Generates bucket list, width 300000000 GPS.

    # TODO:  Check if there would be a remainder from the bucket creation.

    if ((endTimeGPS - startTimeGPS) % 300000000 != 0):
        print("Error, time difference must be a multiple of 300000000 (5 minutes).")

    numOfBuckets = int((endTimeGPS - startTimeGPS)/300000000)

    # The resultant output from the script, formatted:
    # SCT_VTCW, AVERAGE_VALUE, MINIMUM_VALUE, MAXIMUM_VALUE, VALUE_COUNT
    outputArray = []

    print(numOfBuckets)

    for i in range(numOfBuckets):
        print(i)
        bucketStartGPS = i * 300000000 + startTimeGPS
        bucketEndGPS = (i + 1) * 300000000 + startTimeGPS
        currentBucketBool = numpy.apply_along_axis(filter, -1, dataArray, bucketStartGPS, bucketEndGPS)
        # Use the filter to keep only the relevant bucket data, and delete the leftmost column (timestamp) from the copied array.
        # Less overhead for the compute, and makes numpy.size accurate to the 1-dimensional array length.
        currentBucketData = numpy.delete(dataArray[currentBucketBool], 0, axis=1)
        
        # The outputs are always tuples, so index out the value.
        currentBucketAverage = float(numpy.average(currentBucketData, axis=0)[0])
        currentBucketMin = float(numpy.min(currentBucketData, axis=0)[0])
        currentBucketMax = float(numpy.max(currentBucketData, axis=0)[0])
        currentBucketCount = numpy.size(currentBucketData)

        # Midpoint of bucket time range is used for SCT_VTCW
        outputArray.append(((bucketStartGPS + bucketEndGPS)/2, currentBucketAverage, currentBucketMin, currentBucketMax, currentBucketCount))

    print(outputArray)


    # print("Averaging for whole day")
    # # Average value over entire numpy array.
    # averageValue = numpy.average(dataArray, axis=0)[1]
    # print(averageValue)



    exit(0)

if __name__ == "__main__":
    main()

