"""
AvailabilityFlag: Public

EC2 instance uptime and estimated-cost report.

Scans every AWS region for EC2 instances, computes each instance's uptime
for the reporting window from CloudWatch metrics, and estimates cost using
on-demand pricing from the AWS Pricing API.
"""

import logging
import boto3
import json
from datetime import datetime, timezone, timedelta
from zoneinfo import ZoneInfo
from helpers import format_timedelta, format_period_description

logger = logging.getLogger("billing-report")
logger.setLevel(logging.INFO)

ec2_client = boto3.client("ec2")
pricing_client = boto3.client("pricing", region_name="us-east-1")
_cw_clients = {}  # Cache CloudWatch clients by region

# Maps AWS region codes to the "location" names used by the Pricing API.
REGION_LOCATION_MAP = {
    "us-east-1": "US East (N. Virginia)",
    "us-east-2": "US East (Ohio)",
    "us-west-1": "US West (N. California)",
    "us-west-2": "US West (Oregon)",
    "ca-central-1": "Canada (Central)",
    "eu-west-1": "EU (Ireland)",
    "eu-west-2": "EU (London)",
    "eu-west-3": "EU (Paris)",
    "eu-central-1": "EU (Frankfurt)",
    "eu-north-1": "EU (Stockholm)",
    "eu-south-1": "EU (Milan)",
    "eu-south-2": "EU (Spain)",
    "ap-northeast-1": "Asia Pacific (Tokyo)",
    "ap-northeast-2": "Asia Pacific (Seoul)",
    "ap-northeast-3": "Asia Pacific (Osaka)",
    "ap-southeast-1": "Asia Pacific (Singapore)",
    "ap-southeast-2": "Asia Pacific (Sydney)",
    "ap-southeast-3": "Asia Pacific (Jakarta)",
    "ap-south-1": "Asia Pacific (Mumbai)",
    "ap-south-2": "Asia Pacific (Hyderabad)",
    "sa-east-1": "South America (Sao Paulo)",
    "me-south-1": "Middle East (Bahrain)",
    "me-central-1": "Middle East (UAE)",
    "af-south-1": "Africa (Cape Town)",
}


def _get_cw_client(region):
    """Get or create a cached CloudWatch client for the given region."""
    if region not in _cw_clients:
        _cw_clients[region] = boto3.client("cloudwatch", region_name=region)
    return _cw_clients[region]


def get_ec2_report(start_time, end_time):
    """Build the formatted EC2 uptime/cost report table for a time window."""
    instances = get_all_instances(start_time, end_time)
    if not instances:
        return "No EC2 instances found.\n"

    return format_ec2_report_table(instances, start_time, end_time)


def get_all_instances(start_time, end_time):
    """
    Collect every EC2 instance across all regions with uptime and estimated
    cost for the given reporting window.

    Returns:
        list[dict]: One record per instance, see build_instance_record().
    """
    # Collect raw instance data across all regions
    raw_instances = []  # list of (instance_dict, region)

    instances_by_region = {}
    for region in get_all_regions():
        regional_client = boto3.client("ec2", region_name=region)
        paginator = regional_client.get_paginator("describe_instances")

        for page in paginator.paginate():
            for reservation in page.get("Reservations", []):
                for instance in reservation.get("Instances", []):
                    instance_id = instance.get("InstanceId", "N/A")
                    instances_by_region.setdefault(region, []).append(instance_id)
                    raw_instances.append((instance, region))

    if not raw_instances:
        return []

    # Bulk-fetch period uptimes (one get_metric_data call per region)
    uptime_map = get_bulk_period_uptimes(instances_by_region, start_time, end_time)

    # Extract unique (instance_type, region) pairs and bulk-fetch pricing
    unique_type_region_pairs = set()
    for instance, region in raw_instances:
        instance_type = instance.get("InstanceType", "N/A")
        unique_type_region_pairs.add((instance_type, region))
    price_map = get_bulk_pricing(unique_type_region_pairs)

    # Build final instance records with pre-fetched uptime and pricing data
    instances = []
    for instance, region in raw_instances:
        instance_id = instance.get("InstanceId", "N/A")
        period_uptime, period_uptime_seconds = uptime_map.get(instance_id, ("N/A", 0))
        instances.append(
            build_instance_record(
                instance, region, period_uptime, period_uptime_seconds, price_map
            )
        )

    return instances


def get_bulk_period_uptimes(instances_by_region, start_time, end_time):
    """
    Bulk-fetch period uptimes for all instances using get_metric_data,
    making one API call per region (batched at 500 if needed).

    Uses the StatusCheckFailed_Instance metric — the presence of any
    datapoint means the instance was running during that period.

    Args:
        instances_by_region (dict): {region: [instance_id_1, ...]}
        start_time (datetime): Start of the reporting window
        end_time (datetime): End of the reporting window

    Returns:
        dict: {instance_id: (formatted_uptime_str, uptime_seconds)}
    """
    period_duration = end_time - start_time
    if period_duration >= timedelta(days=7):
        period_seconds = 600  # 10-minute intervals
    else:
        period_seconds = 300  # 5-minute intervals

    total_possible_seconds = period_duration.total_seconds()
    batch_size = 500
    uptime_map = {}  # {instance_id: (str, int)}

    for region, instance_ids in instances_by_region.items():
        cw_client = _get_cw_client(region)

        # Build one MetricDataQuery per region
        queries = []
        query_id_map = {}  # query_id -> instance_id
        for instance_id in instance_ids:
            # Sanitize instance ID for query Id: must match ^[a-z][a-zA-Z0-9_]*$
            safe_id = "i_" + instance_id.replace("-", "_")
            query_id_map[safe_id] = instance_id
            queries.append(
                {
                    "Id": safe_id,
                    "MetricStat": {
                        "Metric": {
                            "Namespace": "AWS/EC2",
                            "MetricName": "StatusCheckFailed_Instance",
                            "Dimensions": [
                                {"Name": "InstanceId", "Value": instance_id}
                            ],
                        },
                        "Period": period_seconds,
                        "Stat": "Maximum",
                    },
                    "ReturnData": True,
                }
            )

        # Fetch in batches
        try:
            for i in range(0, len(queries), batch_size):
                batch = queries[i : i + batch_size]

                paginator = cw_client.get_paginator("get_metric_data")
                for page in paginator.paginate(
                    MetricDataQueries=batch,
                    StartTime=start_time,
                    EndTime=end_time,
                ):
                    for result in page["MetricDataResults"]:
                        query_id = result["Id"]
                        instance_id = query_id_map[query_id]
                        datapoint_count = len(result.get("Values", []))

                        if datapoint_count == 0:
                            uptime_map[instance_id] = ("0m (00.0%)", 0)
                        else:
                            total_uptime_seconds = datapoint_count * period_seconds
                            uptime_delta = timedelta(seconds=total_uptime_seconds)
                            pct = total_uptime_seconds / total_possible_seconds * 100
                            uptime_map[instance_id] = (
                                f"{format_timedelta(uptime_delta)} ({pct:.1f}%)",
                                total_uptime_seconds,
                            )
        except Exception as e:
            logger.error(f"Exception in region {region}: {type(e).__name__}: {str(e)}")
            # Mark all instances in this region as N/A
            for instance_id in instance_ids:
                if instance_id not in uptime_map:
                    uptime_map[instance_id] = ("N/A", 0)

    return uptime_map


def get_all_regions():
    """List every AWS region enabled for this account."""
    response = ec2_client.describe_regions(AllRegions=False)
    return [region["RegionName"] for region in response.get("Regions", [])]


def build_instance_record(
    instance, region, period_uptime, period_uptime_seconds, price_map
):
    """Assemble one report row from a describe_instances entry plus
    pre-fetched uptime/pricing data."""
    instance_id = instance.get("InstanceId", "N/A")
    instance_type = instance.get("InstanceType", "N/A")
    state = instance.get("State", {}).get("Name", "unknown")
    launch_time = instance.get("LaunchTime")

    uptime_seconds = calculate_uptime_seconds(launch_time, state) if launch_time else 0
    uptime = format_timedelta(timedelta(seconds=uptime_seconds))

    hourly_price = price_map.get((instance_type, region))
    estimated_cost = calculate_estimated_cost(period_uptime_seconds, hourly_price)

    return {
        "region": region,
        "instance_id": instance_id,
        "instance_type": instance_type,
        "state": state,
        "launch_time": launch_time,
        "uptime": uptime,
        "uptime_seconds": uptime_seconds,
        "period_uptime": period_uptime,
        "estimated_cost": estimated_cost,
    }


def calculate_uptime_seconds(launch_time, state):
    """Seconds since launch, or 0 if the instance isn't currently running."""
    if state != "running":
        return 0
    if launch_time.tzinfo is None:
        launch_time = launch_time.replace(tzinfo=timezone.utc)
    now = datetime.now(timezone.utc)
    delta = now - launch_time
    return int(delta.total_seconds())


def get_bulk_pricing(unique_type_region_pairs):
    """
    Fetch hourly pricing for each unique (instance_type, region) pair.
    Only makes one Pricing API call per unique combination.

    Args:
        unique_type_region_pairs (set): Set of (instance_type, region) tuples

    Returns:
        dict: {(instance_type, region): hourly_price_float_or_None}
    """
    price_map = {}
    for instance_type, region in unique_type_region_pairs:
        price_map[(instance_type, region)] = get_instance_hourly_price(
            instance_type, region
        )
    return price_map


def get_instance_hourly_price(instance_type, region):
    """
    Get the on-demand hourly price for a Linux, shared-tenancy instance type.

    Args:
        instance_type (str): EC2 instance type (e.g., t3.micro)
        region (str): AWS region (e.g., us-east-1)

    Returns:
        float: Price per hour in USD (e.g., 0.0104) or None if not found
    """
    location = REGION_LOCATION_MAP.get(region)
    if not location:
        return None

    try:
        response = pricing_client.get_products(
            ServiceCode="AmazonEC2",
            Filters=[
                {"Type": "TERM_MATCH", "Field": "instanceType", "Value": instance_type},
                {"Type": "TERM_MATCH", "Field": "location", "Value": location},
                {"Type": "TERM_MATCH", "Field": "operatingSystem", "Value": "Linux"},
                {"Type": "TERM_MATCH", "Field": "tenancy", "Value": "Shared"},
                {"Type": "TERM_MATCH", "Field": "preInstalledSw", "Value": "NA"},
                {"Type": "TERM_MATCH", "Field": "capacitystatus", "Value": "Used"},
                {
                    "Type": "TERM_MATCH",
                    "Field": "licenseModel",
                    "Value": "No License required",
                },
            ],
            MaxResults=1,
        )
        if not response.get("PriceList"):
            return None

        price_item = json.loads(response["PriceList"][0])
        terms = price_item.get("terms", {}).get("OnDemand", {})
        if not terms:
            return None

        term = next(iter(terms.values()))
        price_dimensions = term.get("priceDimensions", {})
        if not price_dimensions:
            return None

        dimension = next(iter(price_dimensions.values()))
        price_per_unit = dimension.get("pricePerUnit", {}).get("USD")
        if not price_per_unit:
            return None

        return float(price_per_unit)
    except Exception as e:
        logger.error(
            f"Error getting hourly price for {instance_type} in {region}: {e!s}"
        )
        return None


def calculate_estimated_cost(period_uptime_seconds, hourly_price):
    """Estimated cost for the period from uptime seconds and hourly price."""
    if hourly_price is None or period_uptime_seconds == 0:
        return "N/A"
    hours = period_uptime_seconds / 3600
    cost = hours * hourly_price
    return f"${cost:.2f}"


def format_ec2_report_table(instances, start_time, end_time):
    """Render instance records as the plain-text EC2 report table."""
    period_description = format_period_description(start_time, end_time)
    period_label = f"{period_description} Uptime"

    header = "EC2 INSTANCE REPORT\n"
    header += f"Includes all instances. {period_label} tracks total running time from {start_time.astimezone(ZoneInfo('America/Denver')).strftime('%Y-%m-%d %H:%M')} MTN to {end_time.astimezone(ZoneInfo('America/Denver')).strftime('%Y-%m-%d %H:%M')} MTN. This can be off by a few minutes. Especially if the EC2 frequently changes states.\n"
    header += "=" * 85 + "\n\n"

    col_width = [14, 22, 18, 12, 20, 20, 24, 15]
    columns = [
        "Region",
        "Instance ID",
        "Instance Type",
        "State",
        "Launch Time (UTC)",
        "Uptime",
        period_label,
        "Est. Cost",
    ]

    header_line = ""
    for i, col in enumerate(columns):
        header_line += col.ljust(col_width[i])
    header += header_line + "\n"
    header += "-" * 165 + "\n"

    rows = ""
    for data in sorted(instances, key=lambda x: x["uptime_seconds"], reverse=True):
        launch_time = data["launch_time"]
        launch_time_str = (
            launch_time.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
            if launch_time
            else "N/A"
        )

        row = ""
        row += data["region"].ljust(col_width[0])
        row += data["instance_id"].ljust(col_width[1])
        row += data["instance_type"].ljust(col_width[2])
        row += data["state"].ljust(col_width[3])
        row += launch_time_str.ljust(col_width[4])
        row += data["uptime"].ljust(col_width[5])
        row += data["period_uptime"].ljust(col_width[6])
        row += data["estimated_cost"].ljust(col_width[7])
        rows += row + "\n"

    footer = "=" * 85 + "\n"
    return header + rows + footer
