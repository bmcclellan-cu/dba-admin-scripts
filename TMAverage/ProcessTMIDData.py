#!/usr/bin/env python3


# System imports
import sys
import logging
import math
import traceback
import multiprocessing
import datetime
import os
# Third-party imports
import oracledb
import numpy as np



# Dictionary of databases this script is designed for and the appropriate table to access.
TMANALOG_DBS = {
    "goldprod": "TMANALOG_SID1",
    "evep12c": "TMANALOG",
    "aimprod": "TMANALOG_TABLE", 
    "tsisprod": "TMANALOG_SID1",
    # "ixpeprod": "TMANALOG_SID1"
}

# DEBUG: Mappings are currently configured for testing on my own schema. Will end up on the DB_L1 Schema.
TMAVERAGE_DBS = {
    "aimprod" : "ROBERT_TEST.TMAVERAGE",
    "goldprod": "ROBERT_TEST.TMAverage", 
    "evep12c": "ROBERT_TEST.TMAverage",
    "tsisprod": "ROBERT_TEST.TMAverage",
    # "ixpeprod": "ROBERT_TEST.TMAverage", # Currently does not have TMAverage table
}

TELEMETRYITEMDEFINITION_DBS = {
    "aimprod": "AIM_CT_SC.TelemetryItemDefinition",
    "goldprod": "TelemetryItemDefinition",
    "evep12c": "TelemetryItemDefinition",
    "tsisprod": "TelemetryItemDefinition",
    # "ixpeprod": "TelemetryItemDefinition",
}

TELEMETRYANALOGCONVERSIONS_DBS = {
    "aimprod": "AIM_CT_SC.TelemetryAnalogConversions",
    "goldprod": "TelemetryAnalogConversions",
    "evep12c": "TelemetryAnalogConversions",
    "tsisprod": "TelemetryAnalogConversions",
    # "ixpeprod": "TelemetryAnalogConversions",
}

def get_password_from_file(file_path):
    try:
        with open(file_path, 'r') as file:
            password = file.readline().strip()  # Read the first line and strip whitespace
        print(f"Password read in from path: {file_path}")
        return password
    except Exception as e:
        print(f"An error occurred while reading the password: {e}")
        exit(1)


# Fetches all values for a specific day, then allocates numpy arrays for the values, calculated bucket 
# ids, and the list of tmids, then populates them. 
# OUTPUT: Tuple (results_len, results_values, results_bucket_ids, results_tmids)
def fetch_all_values_by_time_range(connection, database, TMID, select_date_start_gps, select_date_end_gps):
    THREAD_LOGGER = multiprocessing.get_logger()


    if TMID == "ALL":
        sql = f"""SELECT /*+ parallel */ TMID, SCT_VTCW, VALUE FROM {TMANALOG_DBS[database]} WHERE 
        (SCT_VTCW >= {select_date_start_gps}) AND (SCT_VTCW < {select_date_end_gps}) AND VALUE IS NOT NULL"""
    else:
        sql = f"""SELECT /*+ parallel */ TMID, SCT_VTCW, VALUE FROM {TMANALOG_DBS[database]} WHERE 
        (TMID = {TMID}) AND
        (SCT_VTCW >= {select_date_start_gps}) AND (SCT_VTCW < {select_date_end_gps}) AND VALUE IS NOT NULL"""

    THREAD_LOGGER.debug(sql)

    cursor = connection.cursor()
    try: 
        results = cursor.execute(sql).fetchall()
    except oracledb.DatabaseError as error:
        if str(error).find("ORA-00942") != -1:
            THREAD_LOGGER.fatal("ORA-00942: table or view does not exist. \n"
                         "Either the following tables do not exist or the script does not have access to them. \n"
                         "Ensure that the script has the following permissions:  \n"
                         "(TMAnalog(SELECT), TelemetryItemDefinition(SELECT), \n"
                         "TelemetryAnalogConversions(SELECT), TMAverage(ALL) \n"
                         )
            connection.close()
            exit(1)
        else:
            raise error
        
    
    # WARNING: The current version of the script uses a float 128 for the numpy array. 
    # Oracle number can have up 176 bits of precision, so there could be overflow errors.
    results_len = len(results)
    results_values = np.zeros((results_len), dtype=np.float128) 
    results_bucket_ids = np.zeros((results_len), dtype=np.uintc)
    results_tmids = np.zeros((results_len), dtype=np.uintc)

    THREAD_LOGGER.info(f"Retrieved {results_len} records. Ingesting...")

    row_number = 0
    for row in results:
        results_tmids[row_number] = row[0]

        # Calculate the bin ID for the specific row. Prevents needing to iterate over array later.
        time = row[1]
        timeDelta = time - select_date_start_gps
        results_bucket_ids[row_number] = int(math.trunc(timeDelta/300000000))

        results_values[row_number] = row[2]
        row_number += 1

    cursor.close()

    return (results_len, results_values, results_bucket_ids, results_tmids)

def fetch_analog_conversions_by_tmid(cursor, tmid, database):
    THREAD_LOGGER = multiprocessing.get_logger()

    sql = f"""select C.c0,  C.c1,  C.c2,  C.c3,  C.c4,  C.c5,  C.c6,  C.c7 
            FROM {TELEMETRYANALOGCONVERSIONS_DBS[database]} C 
            where C.tlmId = {tmid} order by C.segmentNumber"""

    THREAD_LOGGER.debug(sql)
    try:
        results = cursor.execute(sql).fetchone()
    except oracledb.DatabaseError as error:
        if str(error).find("ORA-00942") != -1:
            THREAD_LOGGER.fatal("ORA-00942: table or view does not exist"
                        "Either the following tables do not exist or the script does not have access to them."
                        "Ensure that the script has the following permissions: "
                        "(TMAnalog(SELECT), TelemetryItemDefinition(SELECT), "
                        "TelemetryAnalogConversions(SELECT), TMAverage(ALL)"
                        )
            cursor.connection.close()
            exit(1)
        else:
            THREAD_LOGGER.fatal(traceback.format_exc())
            THREAD_LOGGER.fatal("An error occurred while retrieving Analog Conversion Polynomial. See above output:")

    return results



# Attempts to insert the passed array of values into tmaverage. If the number of inserted rows 
# Returns True if no errors occurred during insertion, and returns False if errors occurred.
def insert_tmaverage_rows(connection, database, tmaverage_values):
    THREAD_LOGGER = multiprocessing.get_logger()


    # If no data is being inserted, automatically succeed.
    if len(tmaverage_values) == 0: 
        THREAD_LOGGER.info("No values to insert. Continuing...")
        return True
    
    cursor = connection.cursor()

    # TODO: Might need alternative SQL for AIMPROD DB.

    sql = f"""INSERT INTO {TMAVERAGE_DBS[database]} 
        (TMID, SCT_VTCW, AVERAGE_VALUE, MINIMUM_VALUE, MAXIMUM_VALUE, VALUE_COUNT) 
        VALUES (:1, :2, :3, :4, :5, :6)"""

    THREAD_LOGGER.debug(sql)

    try:
        cursor.executemany(sql, tmaverage_values)
        connection.commit()
    except oracledb.IntegrityError as error:
        if str(error).find("ORA-00001") != -1:
            THREAD_LOGGER.error(f"ORA-00001: Unique Constraint Violated during insert. Insert has been rolled back."
                          "This is likely due to the script parameters overlapping with pre-existing data. Please double-check"
                          "the data in TMAverage. Continuing..."
                          )
            return False
        else:
            raise error
    except oracledb.DatabaseError as error:
        if str(error).find("ORA-00942") != -1:
            THREAD_LOGGER.fatal("ORA-00942: table or view does not exist"
                        "This error is likely due to missing permissions."
                        "Ensure that the script has the following permissions: "
                        "(TMAnalog(SELECT), TelemetryItemDefinition(SELECT), TelemetryAnalogConversions(SELECT), TMAverage(ALL)"
                        )
            connection.close()
            exit(1)
        else:
            raise error
    if cursor.rowcount != 0:
        THREAD_LOGGER.info(f"Successfully inserted {cursor.rowcount} rows into TMAverage.")
        return True
    else:
        THREAD_LOGGER.info("Error: Unable to insert rows... Continuing")
        return False

# Processes all the data for a single day in a single thread. Returns True if successful, False if not.
def process_values_by_date(username, password, connection_string, database, TMID, single_date):
    if not os.path.exists("./logs"):
        os.mkdir("./logs", )

    # Logger is setup in process_values_by_date, and future calls to multiprocessing.get_logger() will return the same logger
    formatter = logging.Formatter('%(asctime)s %(levelname)s - %(message)s')


    # Setup log file for thread:
    THREAD_LOGGER = multiprocessing.get_logger()
    log_file_name = f"./logs/TMAverage-{database}-{single_date}-{TMID}.log"
    handler = logging.FileHandler(log_file_name)        
    handler.setFormatter(formatter)
    THREAD_LOGGER.handlers.clear()
    THREAD_LOGGER.addHandler(handler)
    THREAD_LOGGER.setLevel(logging.INFO)
    
    THREAD_LOGGER.info(f"Connecting to DB {connection_string} as {username}")
    
    connection = oracledb.connect(user=username, password=password, dsn=connection_string)
    cursor = connection.cursor()

    # The 18_000_000 offset exists to resolve the discrepencies with the AIMPROD DB. 
    # Does not appear to be intended behavior, but needed to be reproduced.
    start_time_gps = convert_dt2gps(
        cursor, f"{single_date.strftime('%d-%b-%y')} 12.00.00.000000000 AM", 
        database == "aimprod") - 18_000_000
    
    end_time_gps = convert_dt2gps(
        cursor, f"{single_date.strftime('%d-%b-%y')} 11.59.59.999999999 PM", 
        database == "aimprod") - 18_000_000
    
    # Fetch all data for the given date range.

    THREAD_LOGGER.info(f"Pulling data for time range {start_time_gps} - {end_time_gps}")

    data = fetch_all_values_by_time_range(connection, database, TMID, start_time_gps, end_time_gps)

    results_len = data[0]
    results_values = data[1]
    results_bucket_ids = data[2]
    results_tmids = data[3]

    # If there is no data for the time range, then exit.
    if results_len == 0:
        THREAD_LOGGER.info(f"No data found for the time range {start_time_gps} - {end_time_gps}")
        return True

    unique_tmids = np.unique(results_tmids)
    unique_bucket_ids = range(int(((end_time_gps-start_time_gps)/300000000)))


    THREAD_LOGGER.info(f"Unique_bucket_ids: {str(unique_bucket_ids)}")
    THREAD_LOGGER.info(f"Unique_tmids: {str(unique_tmids)}")

    insertion_data = []

    for tmid in unique_tmids:
        THREAD_LOGGER.info(f"Processing TMID: {tmid}")
        tmid_mask = np.where(results_tmids == tmid, True, False)
        tmid_bucket_ids = results_bucket_ids[tmid_mask]

        # Fetch calibration data, then apply to all values for the specific TMID.

        tmid_values = results_values[tmid_mask]
                                          
        calibration_data = fetch_analog_conversions_by_tmid(cursor, tmid, database)

        if np.size(tmid_values) == 0:
            THREAD_LOGGER.info(f"No data for tmid {tmid}")
            continue

        # Apply the polynomial calibration every time, as long as it exists.
        if calibration_data != None:
            # Splices out the the polynomial coefficients, removes unnecessary data
            tmid_values = np.apply_along_axis(calibrate, -1, tmid_values, (calibration_data))

        for bucket_id in unique_bucket_ids:
            bucket_mask = np.where(tmid_bucket_ids == bucket_id, True, False)
            bucket_values = tmid_values[bucket_mask]
            sct_vtcw = int(bucket_id * 300_000_000 + start_time_gps + 150_000_000 + 18_000_000) 

            current_bucket_count = int(np.size(bucket_values))


            if current_bucket_count == 0:
                # 18_000_000 re-adds the 18 second offset so that the column is consistent with AIMPROD.
                insertion_data.append((int(tmid), sct_vtcw , 0, 0, 0, 0)) 
                continue

            current_bucket_average = float(np.average(bucket_values))
            current_bucket_min = float(np.min(bucket_values))
            current_bucket_max = float(np.max(bucket_values))
            insertion_data.append(
                (int(tmid), sct_vtcw, 
                 current_bucket_average, current_bucket_min, current_bucket_max, current_bucket_count)
                )


    # There will always be data to insert, even if no actual values are present 
    # because the output just gets zeroed for all bins.

    return insert_tmaverage_rows(connection, database, insertion_data)

def convert_dt2gps(cursor, DTValue, isAim):
    # The DT2GPS function takes a string in the format "{date} {time}"
    THREAD_LOGGER = multiprocessing.get_logger()


    if isAim:
        cursor.execute("ALTER SESSION SET NLS_TIMESTAMP_FORMAT='DD-MON-RR HH.MI.SSXFF AM'")
    
    sql = f"""SELECT DT2GPS('{DTValue}') FROM dual"""

    THREAD_LOGGER.debug(sql)

    try:
        result = cursor.execute(sql).fetchone()[0]
    except:
        THREAD_LOGGER.fatal(traceback.format_exc())
        THREAD_LOGGER.fatal("An error occurred while calling DT2GPS. See above output:")
        cursor.connection.close()
        exit(1)
    return result

def calibrate(value, c):
    newValue = (c[0] + c[1]*value + c[2]*value**2 + c[3]*value**3 
        + c[4]*value**4 + c[5]*value**5 + c[6]*value**6 + c[7]*value**7)
    return newValue


def main():
    """ 
        This script fetches the values for each TMID in the provided database for the day provided from
        all TMAnalog_SIDX tables, and computes the min, max, average, and count of measurements
        over 5 minute increments, then inserts them into the TMAverage table.
        Inputs: [database] [TMID | ALL] [start_date] [end_date] [parallel_degree (optional)]
    """
    # Usage and example
    usage = "Usage: ./ProcessTMIDData.py [database] [TMID | ALL] [start_date] [end_date] [parallel_degree (optional)]"
    example = "Example: ./ProcessTMIDData.py goldprod ALL 12-JAN-25 13-FEB-25"

    for argument in sys.argv:
        if argument == "-h":
            print(usage)
            print(example)
            exit(0)
    
    num_args = len(sys.argv)

    # Check that there were either 4 or 5 arguments passed.
    if num_args < 5 or num_args > 6:
        print(usage)
        print(example)
        exit(1)

    database = sys.argv[1].lower()

    TMID = None

    if sys.argv[2].upper() != "ALL":
        try:
            TMID = int(sys.argv[2])
        except ValueError:
            print("TMID must be a number or 'ALL'.")
            exit(1)
    else:
        TMID = "ALL"

    start_date = None
    end_date = None

    try:
        start_date = datetime.datetime.strptime(sys.argv[3], "%d-%b-%y").date()
    except ValueError:
        print(f"Inputted date {sys.argv[3]} does not match format DD-MMM-YY. Exiting...")
        exit(1)

    
    try:
        end_date = datetime.datetime.strptime(sys.argv[4], "%d-%b-%y").date()
    except ValueError:
        print(f"Inputted date {sys.argv[4]} does not match format DD-MMM-YY. Exiting...")
        exit(1)



    # Calculate the number of days that need to be iterated over and determine if input is valid.
    num_of_days = (end_date - start_date).days + 1

    if num_of_days < 1:
        print("Error, end date is earlier than start date. Exiting...")
        exit(1)

    parallel_degree = None
    if num_args == 5:
        parallel_degree = 1
    else:
        try:
            parallel_degree = int(sys.argv[5])
        except ValueError:
            print("Parallel degree must be a number.")
            exit(1)


    username = "PROCESSTMIDTEST"
    password = get_password_from_file("./.passwd")

    if password == None:
        # Error message is already printed by get_password_from_file
        exit(1)


    # Validate database input
    if database not in TMAVERAGE_DBS.keys() or database not in TMANALOG_DBS.keys():
        print(f"Selected database is not supported by script. Supported databases "
              f"are: {str(tuple(TMAVERAGE_DBS.keys()))}")
        exit(1)
    

    # Connect to the database as a test to ensure credentials are valid. 
    # Each thread will connect to the DB individually.
    try: 
        connection_string = f"localhost/{database}"
        connection = oracledb.connect(user=username, password=password, dsn=connection_string)
        connection.close()
        print(f"Successfully connected to database {database}.")
    except:
        print(f"Error connecting to database {database}. Check if database exists and "
              "the script has connect priviliges.")
        exit(1)
    

    # Allocate worker pool of specified parallel degree
    worker_pool = multiprocessing.Pool(parallel_degree)
    worker_async_results = [] 
    # An array that stores both the results, as well as the date that is being 
    # processed for that worker (AsyncResult, date)
    
    # Iterate through all of the days specified:
    for single_date in (start_date + datetime.timedelta(n) for n in range(num_of_days)):
        

        async_results = worker_pool.apply_async(
            process_values_by_date, args=(
                username, password, connection_string, 
                database, TMID, single_date, )
            )

        worker_async_results.append((async_results, single_date))
        
        print(f"Added task to process pool for {single_date}")


    worker_pool.close()
    worker_pool.join()

    print("Processed data for full date range.")

    error_status = False

    # Loop through all of the results, and print out any errors encountered (if any)
    for result in worker_async_results:
        try:
            error_status = not result[0].get() or error_status
        except Exception as e:
            error_status = True
            print(f"An exception occurred for {result[1]}. See below output:")
            traceback.print_exc()

    
    if error_status:
        print("One or more errors occurred during execution. "
              " Please check the above ouput and the log files for more details.")
    else:
        print("Script has successfully completed!")

    exit(0)

if __name__ == "__main__":
    main()