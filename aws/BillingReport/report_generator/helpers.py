"""
AvailabilityFlag: Public

Shared formatting helpers used by the EC2 and S3 report modules.
"""


def format_period_description(start_time, end_time):
    """
    Render a short label for a reporting window, e.g. "24h", "7d", "6h".

    Falls back to format_timedelta's "Xd Xh Xm" style for windows that
    aren't a whole number of days or hours.
    """
    period_duration = end_time - start_time
    total_seconds = int(period_duration.total_seconds())
    if total_seconds % 86400 == 0:
        days = total_seconds // 86400
        if days == 1:
            return "24h"
        return f"{days}d"
    if total_seconds % 3600 == 0:
        hours = total_seconds // 3600
        return f"{hours}h"
    return format_timedelta(period_duration)


def format_timedelta(delta):
    """Render a timedelta as "Xd Xh Xm", dropping leading zero units."""
    days = delta.days
    hours, remainder = divmod(delta.seconds, 3600)
    minutes, _ = divmod(remainder, 60)

    if days > 0:
        return f"{days}d {hours}h {minutes}m"
    if hours > 0:
        return f"{hours}h {minutes}m"
    return f"{minutes}m"
