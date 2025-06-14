#!/usr/bin/env python3


# TODO: Add check for table permissions before starting with multithreading.

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
    "aimprod": "AIM_L1A.TMANALOG_TABLE",
    "tsisprod": "TMANALOG_SID1",
    "ixpeprod": "TMANALOG_SID1",
}

# DEBUG: Mappings are currently configured for testing on my own schema. Will end up on the DB_L1 Schema.
TMAVERAGE_DBS = {
    "aimprod": "AIM_L1A.TMAVERAGE",
    "goldprod": "GOLD_L1A.TMAverage",
    "evep12c": "EVE_L1A.TMAverage",
    "tsisprod": "TSIS_L1A.TMAverage",
    "ixpeprod": "IXPE_L1A.TMAverage",
}

TELEMETRYITEMDEFINITION_DBS = {
    "aimprod": "AIM_CT_SC.TelemetryItemDefinition",
    "goldprod": "TelemetryItemDefinition",
    "evep12c": "TelemetryItemDefinition",
    "tsisprod": "TelemetryItemDefinition",
    "ixpeprod": "TelemetryItemDefinition",
}

TELEMETRYANALOGCONVERSIONS_DBS = {
    "aimprod": "AIM_CT_SC.TelemetryAnalogConversions",
    "goldprod": "TelemetryAnalogConversions",
    "evep12c": "TelemetryAnalogConversions",
    "tsisprod": "TelemetryAnalogConversions",
    "ixpeprod": "TelemetryAnalogConversions",
}


def get_password_from_file(file_path):
    try:
        with open(file_path, "r") as file:
            password = (
                file.readline().strip()
            )  # Read the first line and strip whitespace
        print(f"Password read in from path: {file_path}")
        return password
    except Exception as e:
        print(f"An error occurred while reading the password: {e}")
        exit(1)


# This is a helper function that, once run on a multiprocessing thread, initializes the logger
# which remains persistent through additional calls to multiprocessing.get_logger() within the
# same thread.
def init_worker_logger(
    database: str,
):
    logger = multiprocessing.get_logger()
    logger.setLevel(logging.INFO)

    # Create a per-process log file
    proc = multiprocessing.current_process()
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    log_file = f"/tmp/TMAverageLogs/TMAverage-{database}-{proc.name}-{timestamp}.log"

    # Clear and add handler
    logger.handlers.clear()
    fh = logging.FileHandler(log_file)
    formatter = logging.Formatter("%(asctime)s %(levelname)s - %(message)s")
    fh.setFormatter(formatter)
    logger.addHandler(fh)

    logger.info("Set logger.")


# Fetches all values for a specific day, then allocates numpy arrays for the values, calculated bucket
# ids, and the list of tmids, then populates them.
# OUTPUT: Tuple (results_len, results_values, results_bucket_ids, results_tmids)
def fetch_values_by_time_range(
    connection: oracledb.Connection,
    database: str,
    tmid,
    start_time_gps: int,
    end_time_gps: int,
):
    logger = multiprocessing.get_logger()

    # This exists because AIMPROD's primary key index has a 1st column of SID,
    # and excluding it causes the optimizer not to use the index.
    sid_clause = ""
    if database[:3] == "aim":
        sid_clause = " SID=1 AND "

    sql = f"""
        SELECT SCT_VTCW, VALUE FROM {TMANALOG_DBS[database]} WHERE 
        {sid_clause}
        (tmid = {tmid}) AND 
        (SCT_VTCW >= {start_time_gps} AND (SCT_VTCW < {end_time_gps}))
    """

    logger.debug(sql)

    cursor = connection.cursor()
    try:
        results = cursor.execute(sql).fetchall()
    except oracledb.DatabaseError as error:
        if str(error).find("ORA-00942") != -1:
            logger.fatal(
                "ORA-00942: table or view does not exist. \n"
                "Either the following tables do not exist or the script does not have access to them. \n"
                "Ensure that the script has the following permissions:  \n"
                "(TMAnalog(SELECT), TelemetryItemDefinition(SELECT), \n"
                "TelemetryAnalogConversions(SELECT), TMAverage(ALL) \n"
            )
            connection.close()
            exit(1)
        else:
            raise error
    except Exception as error:
        logger.fatal(traceback.format_exc())
        raise error

    # WARNING: The current version of the script uses a float 128 for the numpy array.
    # Oracle numbers can store up to 22 bytes of data, so this could result in a loss of
    # precision.
    results_len = len(results)
    results_values = np.zeros((results_len), dtype=np.float128)
    results_bucket_ids = np.zeros((results_len), dtype=np.uintc)
    results_tmids = np.zeros((results_len), dtype=np.uintc)

    logger.info(f"Retrieved {results_len} records. Ingesting...")

    row_number = 0
    for row in results:
        results_tmids[row_number] = row[0]

        # Calculate the bin ID for the specific row. Prevents needing to iterate over array later.
        time = row[1]
        timeDelta = time - start_time_gps
        results_bucket_ids[row_number] = int(math.trunc(timeDelta / 300000000))

        results_values[row_number] = row[2]
        row_number += 1

    cursor.close()

    return (results_len, results_values, results_bucket_ids, results_tmids)


# This function assumes that the on-the-fly-decom package has been loaded on the database. This is checked earlier in the
# code. Due to restrictions in how OTFD retrieves data, this process is not able to fetch ALL tmids at once, and needs to
# iterate through the ones listed in TelemetryItemDefinitions.
# Returns a tuple of (results_len, results_values, and results_bucket_ids)
def fetch_otfd_values_by_time_range(
    connection: oracledb.Connection,
    tmid: int,
    start_time_gps: int,
    end_time_gps: int,
):
    logger = multiprocessing.get_logger()

    cursor = connection.cursor()
    try:
        # Call PSQL function to retrieve data (SID (always 1), tmid, START_ERT (unused), END_ERT (unused), START_GPS, END_GPS))
        cursor.callproc(
            "IXPE_MISC.ONTHEFLYDECOM.selectNumericTlm",
            [1, tmid, -1, -1, start_time_gps, end_time_gps],
        )
        # Calling the function should lock the thread until it returns, at which point the results will be in ONTHEFLYDECOM_RESULTS
        otfd_results = cursor.execute(
            "SELECT SCT, VALUE FROM ONTHEFLYDECOM_RESULTS"
        ).fetchall()
        # Check if any errors occurred
        otfd_error = cursor.execute("SELECT * FROM ONTHEFLYDECOM_ERRORS").fetchall()
    except oracledb.DatabaseError as error:
        if str(error).find("ORA-00942") != -1:
            logger.fatal(  # TODO: Update to include OTFD permissions.
                "ORA-00942: table or view does not exist. \n"
                "Either the following tables do not exist or the script does not have access to them. \n"
                "Ensure that the script has the following permissions:  \n"
                "(TMAnalog(SELECT), TelemetryItemDefinition(SELECT), \n"
                "TelemetryAnalogConversions(SELECT), TMAverage(ALL) \n"
            )
            connection.close()
            exit(1)
        else:
            logger.fatal(traceback.format_exc())
            raise error
    except Exception as error:
        logger.fatal(traceback.format_exc())
        raise error

    if len(otfd_error) != 0 and otfd_results == None:
        logger.error(
            "No results were returned, and OnTheFlyDecom_errors contains errors. See below output for more details. Skipping..."
        )
        for row in otfd_error:
            logger.error(row)
        return (0, [], [])
    if len(otfd_error) != 0 and otfd_results != None:
        logger.error(
            f"The OnTheFlyDecom_errors contains {len(otfd_error)} errors, but results were still returned. See below output for more details. Continuing... "
        )
        for row in otfd_error:
            logger.error(row)

    # This exists because AIMPROD's primary key index has a 1st column of SID,
    # and excluding it causes the optimizer not to use the index.
    results_len = len(
        otfd_results
    )  # Gets length of results to pre-allocate numpy array
    results_values = np.zeros((results_len), dtype=np.float128)
    results_bucket_ids = np.zeros((results_len), dtype=np.uintc)

    logger.info(f"Retrieved {results_len} records. Ingesting...")

    row_number = 0
    for row in otfd_results:
        # Calculate the bin ID for the specific row. Prevents needing to iterate over array later and lets me use
        # efficient numpy filtering
        time = row[0]
        timeDelta = time - start_time_gps
        results_bucket_ids[row_number] = int(math.trunc(timeDelta / 300000000))

        results_values[row_number] = row[1]
        row_number += 1

    cursor.close()

    return (
        results_len,
        results_values,
        results_bucket_ids,
    )


def fetch_analog_conversions_by_tmid(cursor, tmid, database):
    logger = multiprocessing.get_logger()

    sql = f"""select C.c0,  C.c1,  C.c2,  C.c3,  C.c4,  C.c5,  C.c6,  C.c7 
            FROM {TELEMETRYANALOGCONVERSIONS_DBS[database]} C 
            where C.tlmId = {tmid} order by C.segmentNumber"""

    logger.debug(sql)
    try:
        results = cursor.execute(sql).fetchone()
    except oracledb.DatabaseError as error:
        if str(error).find("ORA-00942") != -1:
            logger.fatal(
                "ORA-00942: table or view does not exist"
                "Either the following tables do not exist or the script does not have access to them."
                "Ensure that the script has the following permissions: "
                "(TMAnalog(SELECT), TelemetryItemDefinition(SELECT), "
                "TelemetryAnalogConversions(SELECT), TMAverage(ALL)"
            )
            cursor.connection.close()
            exit(1)
        else:
            logger.fatal(traceback.format_exc())
            logger.fatal(
                "An error occurred while retrieving Analog Conversion Polynomial. See above output:"
            )

    return results


# Attempts to insert the passed array of values into tmaverage. If the number of inserted rows
# Returns the number of rows inserted if no errors occurred during insertion, and returns -1 if errors occurred.
def insert_tmaverage_rows(connection, database, tmaverage_values):
    logger = multiprocessing.get_logger()

    # If no data is being inserted, automatically succeed.
    if len(tmaverage_values) == 0:
        logger.info("No values to insert. Continuing...")
        return 0

    cursor = connection.cursor()

    # TODO: Might need alternative SQL for AIMPROD DB.

    sql = f"""INSERT INTO {TMAVERAGE_DBS[database]} 
        (tmid, SCT_VTCW, AVERAGE_VALUE, MINIMUM_VALUE, MAXIMUM_VALUE, VALUE_COUNT) 
        VALUES (:1, :2, :3, :4, :5, :6)"""

    logger.debug(sql)

    try:
        cursor.executemany(sql, tmaverage_values)
        connection.commit()
    except oracledb.IntegrityError as error:
        if str(error).find("ORA-00001") != -1:
            logger.error(
                f"ORA-00001: Unique Constraint Violated during insert. Insert has been rolled back."
                "This is likely due to the script parameters overlapping with pre-existing data. Please double-check"
                "the data in TMAverage. Continuing..."
            )
            return -1
        else:
            raise error
    except oracledb.DatabaseError as error:
        if str(error).find("ORA-00942") != -1:
            logger.fatal(
                "ORA-00942: table or view does not exist"
                "This error is likely due to missing permissions."
                "Ensure that the script has the following permissions: "
                "(TMAnalog(SELECT), TelemetryItemDefinition(SELECT), TelemetryAnalogConversions(SELECT), TMAverage(ALL)"
            )
            connection.close()
            exit(1)
        else:
            raise error
    if cursor.rowcount != 0:
        logger.info(f"Successfully inserted {cursor.rowcount} rows into TMAverage.")
        return cursor.rowcount
    else:
        logger.info("Error: Unable to insert rows... Continuing")
        return -1


# This function processes the data for a single tmid over a given time range in a single thread.
# Returns a tuple of the number of rows ingested/inserted, (-1, -1) if an error occurred.
def process_values_by_tmid(
    username: str,
    password: str,
    connection_string: str,
    database: str,
    tmid: int,
    start_time_gps: int,
    end_time_gps: int,
    is_otfd: bool,
):
    logger = multiprocessing.get_logger()

    os.makedirs(f"/tmp/TMAverageLogs/{database}/", exist_ok=True)

    logger.info(f"Connecting to DB {connection_string} as {username}")
    connection = oracledb.connect(
        user=username, password=password, dsn=connection_string
    )
    cursor = connection.cursor()

    # Fetch all data for the given date range.
    logger.info(
        f"Pulling data for time range {start_time_gps} - {end_time_gps} for tmid {tmid}"
    )

    if is_otfd:
        data = fetch_otfd_values_by_time_range(
            connection=connection,
            tmid=tmid,
            start_time_gps=start_time_gps,
            end_time_gps=end_time_gps,
        )
    else:
        data = fetch_values_by_time_range(
            connection=connection,
            database=database,
            tmid=tmid,
            start_time_gps=start_time_gps,
            end_time_gps=end_time_gps,
        )

    results_len = data[0]
    results_values = data[1]
    results_bucket_ids = data[2]

    # If there is no data for the time range and tmid, then exit.
    if results_len == 0:
        logger.info(
            f"No data found for the time range {start_time_gps} - {end_time_gps} and TMID {tmid}"
        )
        return (0, 0)

    unique_bucket_ids = range(int(((end_time_gps - start_time_gps) / 300000000)))

    logger.info(f"Unique_bucket_ids: {str(unique_bucket_ids)}")

    # Fetch calibration data, then apply to all values for the specific TMID.
    calibration_data = fetch_analog_conversions_by_tmid(cursor, tmid, database)

    # Apply the polynomial calibration every time, as long as it exists.
    if calibration_data != None:
        # Splices out the the polynomial coefficients, removes unnecessary data
        results_values = np.apply_along_axis(
            calibrate, -1, results_values, (calibration_data)
        )

    insertion_data = []
    for bucket_id in unique_bucket_ids:
        bucket_mask = np.where(results_bucket_ids == bucket_id, True, False)
        bucket_values = results_values[bucket_mask]
        sct_vtcw = int(
            bucket_id * 300_000_000 + start_time_gps + 150_000_000 + 18_000_000
        )

        current_bucket_count = int(np.size(bucket_values))

        if current_bucket_count == 0:
            # 18_000_000 re-adds the 18 second offset so that the column is consistent with AIMPROD.
            insertion_data.append((int(tmid), sct_vtcw, 0, 0, 0, 0))
            continue

        current_bucket_average = float(np.average(bucket_values))
        current_bucket_min = float(np.min(bucket_values))
        current_bucket_max = float(np.max(bucket_values))
        insertion_data.append(
            (
                int(tmid),
                sct_vtcw,
                current_bucket_average,
                current_bucket_min,
                current_bucket_max,
                current_bucket_count,
            )
        )

    return (results_len, insert_tmaverage_rows(connection, database, insertion_data))


def convert_dt2gps(cursor, DTValue, isAim):
    # The DT2GPS function takes a string in the format "{date} {time}"
    logger = multiprocessing.get_logger()

    if isAim:
        cursor.execute(
            "ALTER SESSION SET NLS_TIMESTAMP_FORMAT='DD-MON-RR HH.MI.SSXFF AM'"
        )

    sql = f"""SELECT DT2GPS('{DTValue}') FROM dual"""

    logger.debug(sql)

    try:
        result = cursor.execute(sql).fetchone()[0]
    except:
        logger.fatal(traceback.format_exc())
        logger.fatal("An error occurred while calling DT2GPS. See above output:")
        cursor.connection.close()
        exit(1)
    return result


def calibrate(value, c):
    newValue = (
        c[0]
        + c[1] * value
        + c[2] * value**2
        + c[3] * value**3
        + c[4] * value**4
        + c[5] * value**5
        + c[6] * value**6
        + c[7] * value**7
    )
    return newValue


def main():
    """
    This script fetches the values for each TMID in the provided database for the day provided from
    all TMAnalog_SIDX tables, and computes the min, max, average, and count of measurements
    over 5 minute increments, then inserts them into the TMAverage table.
    Inputs: [database] [TMID | ALL] [start_date] [end_date] [parallel_degree (optional)]
    """
    # Usage and example
    usage = "Usage: ./ProcesstmidData.py [database] [TMID | ALL] [start_date] [end_date] [parallel_degree (optional)]"
    example = "Example: ./ProcesstmidData.py goldprod ALL 12-JAN-25 13-FEB-25"

    is_otfd = False
    for argument in sys.argv:
        if argument == "-h":
            print(usage)
            print(example)
            exit(0)
        if argument == "-o":
            is_otfd = True

    num_args = len(sys.argv)

    # Check that there were either 4 or 5 arguments passed.
    if num_args < 5 or num_args > 6:
        print(usage)
        print(example)
        exit(1)

    database = sys.argv[1].lower()

    tmid = None

    if sys.argv[2].upper() != "ALL":
        try:
            tmid = int(sys.argv[2])
        except ValueError:
            print("TMID must be a number or 'ALL'.")
            exit(1)
    else:
        tmid = "ALL"

    start_date = None
    end_date = None

    try:
        start_date = datetime.datetime.strptime(sys.argv[3], "%d-%b-%y").date()
    except ValueError:
        print(
            f"Inputted date {sys.argv[3]} does not match format DD-MMM-YY. Exiting..."
        )
        exit(1)

    try:
        end_date = datetime.datetime.strptime(sys.argv[4], "%d-%b-%y").date()
    except ValueError:
        print(
            f"Inputted date {sys.argv[4]} does not match format DD-MMM-YY. Exiting..."
        )
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
        print(
            f"Selected database is not supported by script. Supported databases "
            f"are: {str(tuple(TMAVERAGE_DBS.keys()))}"
        )
        exit(1)

    # Connect to the database as a test to ensure credentials are valid.
    # Each thread will connect to the DB individually.
    try:
        connection_string = f"localhost/{database}"
        connection = oracledb.connect(
            user=username, password=password, dsn=connection_string
        )
        print(f"Successfully connected to database {database}.")
    except:
        print(
            f"Error connecting to database {database}. Check if database exists and "
            "the script has connect privileges."
        )
        exit(1)

    start_time = datetime.datetime.now()

    print(f"Script has started at {start_time}")

    # An array that stores both the results, as well as the date that is being
    # processed for that worker (AsyncResult, date)

    cursor = connection.cursor()

    # The 18_000_000 offset exists to resolve the discrepancies with the AIMPROD DB.
    # Does not appear to be intended behavior, but needed to be reproduced.
    start_time_gps = (
        convert_dt2gps(
            cursor,
            f"{start_date.strftime('%d-%b-%y')} 12.00.00.000000000 AM",
            database == "aimprod",
        )
        - 18_000_000
    )

    end_time_gps = (
        convert_dt2gps(
            cursor,
            f"{end_date.strftime('%d-%b-%y')} 11.59.59.999999999 PM",
            database == "aimprod",
        )
        - 18_000_000
    )

    # Get list of all tmids
    if tmid == "ALL":
        tmids = cursor.execute(
            f"SELECT UNIQUE TLMID from {TELEMETRYITEMDEFINITION_DBS[database]} WHERE dataType='U' OR dataType='I' OR dataType='F'"
        ).fetchall()
        tmids = [tmid[0] for tmid in tmids]
        tmids.sort()
        print(f"There are {len(tmids)} unique tmids.")
    else:
        tmids = [tmid]

    cursor.close()
    connection.close()

    # Allocate worker pool of specified parallel degree and setup the logger to log to the correct file.
    worker_pool = multiprocessing.Pool(
        parallel_degree, initializer=init_worker_logger, initargs=(database,)
    )
    worker_async_results = []

    # Iterate through all tmids specified:
    for tmid in tmids:
        async_results = worker_pool.apply_async(
            process_values_by_tmid,
            args=(
                username,
                password,
                connection_string,
                database,
                tmid,
                start_time_gps,
                end_time_gps,
                is_otfd,
            ),
        )

        worker_async_results.append((async_results, tmid))

        print(f"Added task to process pool for {tmid}")

    worker_pool.close()
    worker_pool.join()

    end_time = datetime.datetime.now()

    print(f"Script completed at time {end_time}. Duration: {end_time - start_time}")

    error_status = False

    ingested_rows = 0
    inserted_rows = 0

    # Loop through all of the results, and print out any errors encountered (if any)
    for result in worker_async_results:
        try:
            results = result[0].get()
            if results[0] == -1:
                error_status = True
            elif results[1] == -1:
                error_status = True
            else:
                ingested_rows += results[0]
                inserted_rows += results[0]
        except Exception as e:
            error_status = True
            print(f"An exception occurred for {result[1]}. See below output:")
            traceback.print_exc()

    if error_status:
        print(
            "One or more errors occurred during execution. "
            " Please check the above output and the log files for more details."
        )
        print(f"Rows ingested: {ingested_rows}")
        print(f"Rows inserted: {inserted_rows}")

    else:
        print("Script has successfully completed!")
        print(f"Rows ingested: {ingested_rows}")
        print(f"Rows inserted: {inserted_rows}")

    exit(0)


if __name__ == "__main__":
    main()
