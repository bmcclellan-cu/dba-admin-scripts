"""
AvailabilityFlag: Public

Overall AWS spend-by-service report, sourced from Cost Explorer.

Produces the "Services over $X" table that leads every billing report:
total spend for the period, the subset of services above the configured
threshold, and what share of total spend that subset represents.
"""

import logging
import boto3

logger = logging.getLogger("billing-report")
logger.setLevel(logging.INFO)

cost_explorer = boto3.client("ce")


def get_spending_report(start_time, end_time, SERVICE_SPEND_THRESHOLD):
    """
    Summarize per-service AWS spend for a time window.

    Args:
        start_time (datetime): Start of the reporting window.
        end_time (datetime): End of the reporting window.
        SERVICE_SPEND_THRESHOLD (float): Per-service spend (USD) a service
            must exceed to be listed in the returned table.

    Returns:
        tuple: (total_spend, high_spend_percentage, high_spend_table)
            - total_spend (float): Total spend across all services, USD.
            - high_spend_percentage (float): Percent of total_spend
              contributed by services above the threshold.
            - high_spend_table (str): Formatted "Service | Cost" table for
              services above the threshold.
    """
    start_str = start_time.strftime("%Y-%m-%d")
    end_str = end_time.strftime("%Y-%m-%d")

    try:
        logger.info("Attempting to retrieve cost and usage info")
        response = cost_explorer.get_cost_and_usage(
            TimePeriod={"Start": start_str, "End": end_str},
            Granularity="DAILY",
            Metrics=["UnblendedCost"],
            GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
        )
        logger.info(f"Successfully got cost and usage for {start_str} to {end_str}")
    except Exception as e:
        logger.error(f"Error occurred while getting cost and usage: {e}")
        raise

    # Calculate the total spending in the cost and usage report
    total_spend = 0
    for day in response["ResultsByTime"]:
        for service in day["Groups"]:
            total_spend += float(service["Metrics"]["UnblendedCost"]["Amount"])

    # Consolidate each services spend into a single value for the time period
    consolidated_services = {}
    for day in response["ResultsByTime"]:
        for service in day["Groups"]:
            if service["Keys"][0] in consolidated_services:
                consolidated_services[service["Keys"][0]] += float(
                    service["Metrics"]["UnblendedCost"]["Amount"]
                )
            else:
                consolidated_services[service["Keys"][0]] = float(
                    service["Metrics"]["UnblendedCost"]["Amount"]
                )

    # Get just the services that are above the threshold we want to display
    consolidated_services = [
        {"Keys": [k], "Metrics": {"UnblendedCost": {"Amount": v}}}
        for k, v in consolidated_services.items()
    ]
    high_spend_services = [
        service
        for service in consolidated_services
        if float(service["Metrics"]["UnblendedCost"]["Amount"])
        > SERVICE_SPEND_THRESHOLD
    ]
    high_spend_services.sort(
        key=lambda x: float(x["Metrics"]["UnblendedCost"]["Amount"]), reverse=True
    )

    # Calculate the total spending that is above the threshold
    high_spend_total = 0
    for service in high_spend_services:
        high_spend_total += float(service["Metrics"]["UnblendedCost"]["Amount"])

    high_spend_percentage = 0
    if total_spend > 0:
        high_spend_percentage = 100 * high_spend_total / total_spend

    # Create the spending table
    high_spend_table = "{service:50s} | {cost:4s}\n".format(
        service="Service", cost="Cost"
    )
    high_spend_table += "-------------------------------------------------------------------------------------------------\n"
    for service in high_spend_services:
        high_spend_table += "{service:50s} | ${cost:.2f}\n".format(
            cost=float(service["Metrics"]["UnblendedCost"]["Amount"]),
            service=service["Keys"][0],
        )

    return (total_spend, high_spend_percentage, high_spend_table)
