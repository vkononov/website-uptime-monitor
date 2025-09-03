#!/bin/bash

# Email settings (add multiple email addresses separated by space)
emails=("email@example.com")

# Timezone variable for formatting timestamps
timezone="America/Winnipeg"

# Monitoring configuration
max_retries=3           # Number of retry attempts before marking site as down
retry_delay=5           # Seconds to wait between retry attempts
connect_timeout=10      # Seconds to wait for connection
max_timeout=30          # Maximum seconds for entire request
grace_period=2          # Number of consecutive failures before sending down alert (1 = immediate)

# Array of websites to check for their status
websites=(
  "https://example.com"
  "https://anotherexample.com"
)

# Temporary file to store the previous status of websites
status_file="/tmp/websites_status.txt"
# Lock file to prevent concurrent execution
lock_file="/tmp/uptime_monitor.lock"
# Ensure the status file exists
touch $status_file

# Status variables for easier readability
STATUS_UP="up"
STATUS_DOWN="down"

# Status emojis
EMOJI_UP="\xE2\x9C\x85" # Green check mark
EMOJI_DOWN="\xF0\x9F\x94\xB4" # Red circle

# Function to acquire lock
acquire_lock() {
  # Check if lock file exists
  if [ -f "$lock_file" ]; then
    local existing_pid=$(cat "$lock_file" 2>/dev/null)

    # Check if the process is still running
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
      echo "Another instance of the script is already running (PID: $existing_pid)"
      echo "If you're sure no other instance is running, remove: $lock_file"
      exit 1
    else
      # Stale lock file, remove it
      [ "$debug" == "true" ] && echo "Removing stale lock file (PID $existing_pid no longer exists)"
      rm -f "$lock_file"
    fi
  fi

  # Create lock file with current PID
  echo $$ > "$lock_file"
  [ "$debug" == "true" ] && echo "Acquired lock (PID: $$)"
}

# Function to release lock
release_lock() {
  if [ -f "$lock_file" ]; then
    local lock_pid=$(cat "$lock_file" 2>/dev/null)
    # Only remove lock if it's ours
    if [ "$lock_pid" = "$$" ]; then
      rm -f "$lock_file"
      [ "$debug" == "true" ] && echo "Released lock (PID: $$)"
    fi
  fi
}

# Set up trap to cleanup lock file on exit
trap 'release_lock; exit' INT TERM EXIT

# Function to check the status of a website with retry logic
check_website() {
  url=$1

  for ((attempt=1; attempt<=max_retries; attempt++)); do
    # Use curl with timeouts, user agent, and better error handling
    http_code=$(curl -L \
      --connect-timeout "${connect_timeout:-10}" \
      --max-time "${max_timeout:-30}" \
      --retry 0 \
      --user-agent "Website-Uptime-Monitor/1.0" \
      --silent -o /dev/null \
      --write-out "%{http_code}" \
      "$url" 2>/dev/null)

    # If we got a valid HTTP response code, return it
    if [[ "$http_code" =~ ^[0-9]{3}$ ]] && [ "$http_code" -ne 000 ]; then
      [ "$debug" == "true" ] && [ "$attempt" -gt 1 ] && echo "Success on attempt $attempt for $url" >&2
      echo "$http_code"
      return
    fi

    # Log the retry attempt in debug mode
    [ "$debug" == "true" ] && echo "Attempt $attempt failed for $url (HTTP code: $http_code), retrying in ${retry_delay}s..." >&2

    # Don't sleep after the last attempt
    if [ "$attempt" -lt "$max_retries" ]; then
      sleep $retry_delay
    fi
  done

  # All attempts failed, return the last result
  [ "$debug" == "true" ] && echo "All $max_retries attempts failed for $url, final HTTP code: $http_code" >&2
  echo "$http_code"
}

# Function to send email notification to multiple recipients
send_email() {
  local hostname
  local status=$1
  local url=$2
  local duration=$3
  local timestamp=$4
  local subject message
  # Extract the hostname from the URL for the email subject
  hostname=$(echo "$url" | awk -F[/:] '{print $4}')

  # Prepare the subject and message based on the status
  if [ "$status" == "$STATUS_DOWN" ]; then
    subject="$EMOJI_DOWN [$hostname] DOWN Alert"
    message="$url is down since $timestamp.\n\nHTTP code: $http_code"
  else
    subject="$EMOJI_UP [$hostname] UP Alert"
    message="$url is UP again at $timestamp, after $duration of downtime."
  fi

  # Send the email to all recipients
  for email in "${emails[@]}"; do
    echo -e "$message" | mailx -s "$(echo -e "$subject")" "$email"
    [ "$debug" == "true" ] && echo -e "Email sent to $email with subject: $subject"
  done
}

# Function to print usage information
print_usage() {
  echo "Usage: $0 [--summary] [--debug] [--help]"
  echo "  --summary    Run the script in summary mode"
  echo "  --debug      Enable debug mode"
  echo "  --help       Print this help message"
}

# Function to calculate and format duration of time
calculate_duration() {
  local start_time=$1
  local end_time=$2
  local duration=$((end_time - start_time))

  # ignores time zone changes, daylight saving time, leap seconds, etc.
  local days=$((duration / 86400))
  local hours=$(( (duration % 86400) / 3600))
  # Round minutes up - if there's any remainder of seconds, count as a full minute
  local remaining_seconds=$(( duration % 3600 ))
  local minutes=$(( (remaining_seconds + 59) / 60 ))

  if [ $days -gt 0 ]; then
    printf '%dd %dh %dm' $days $hours $minutes
  elif [ $hours -gt 0 ]; then
    printf '%dh %dm' $hours $minutes
  else
    printf '%dm' $minutes
  fi
}

# Parse arguments
mode="minute"
debug="false"

for arg in "$@"; do
  case $arg in
    --summary)
      mode="summary"
      ;;
    --debug)
      debug="true"
      ;;
    --help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg"
      print_usage
      exit 1
      ;;
  esac
done

# Acquire lock to prevent concurrent execution
acquire_lock

if [ "$mode" == "summary" ]; then
  [ "$debug" == "true" ] && echo "Reading previous status for summary..."
  # Read previous status into an associative array
  declare -A previous_status
  while IFS= read -r line; do
    url=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $2}')
    timestamp=$(echo "$line" | awk '{print $3}')
    failure_count=$(echo "$line" | awk '{print $4}')  # New field for consecutive failures
    # Default failure_count to 0 for backwards compatibility
    [[ -z "$failure_count" ]] && failure_count=0
    previous_status["$url"]="$status $timestamp $failure_count"
  done < "$status_file"

  down_sites=()
  for url in "${!previous_status[@]}"; do
    status=$(echo "${previous_status[$url]}" | awk '{print $1}')
    timestamp=$(echo "${previous_status[$url]}" | awk '{print $2}')
    failure_count=$(echo "${previous_status[$url]}" | awk '{print $3}')
    # Only show sites that are down AND have reached the grace period
    if [ "$status" == "$STATUS_DOWN" ] && [ "$failure_count" -ge "$grace_period" ]; then
      current_time=$(date +%s)
      duration_formatted=$(calculate_duration "$timestamp" "$current_time")
      timestamp_formatted=$(TZ=$timezone date -d "@$timestamp" +"%B %d, %Y %H:%M:%S %Z")
      down_sites+=("$url is down since $timestamp_formatted, down for $duration_formatted")
    fi
  done

  if [ ${#down_sites[@]} -ne 0 ]; then
    message="The following sites are down:\n\n"
    for site in "${down_sites[@]}"; do
      message+="$site\n"
    done
    for email in "${emails[@]}"; do
      echo -e "$message" | mailx -s "$(echo -e "$EMOJI_DOWN DOWN Alert Summary")" "$email"
      [ "$debug" == "true" ] && echo "Summary email sent to $email"
    done
  fi
  exit 0
fi

# Read previous status into an associative array
declare -A previous_status
[ "$debug" == "true" ] && echo "Reading previous status from $status_file..."
  while IFS= read -r line; do
    url=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $2}')
    timestamp=$(echo "$line" | awk '{print $3}')
    failure_count=$(echo "$line" | awk '{print $4}')  # New field for consecutive failures
    # Default failure_count to 0 for backwards compatibility
    [[ -z "$failure_count" ]] && failure_count=0
    previous_status["$url"]="$status $timestamp $failure_count"
  done < "$status_file"
[ "$debug" == "true" ] && echo "Previous status loaded."

# Check each website and update status
new_status=()
for url in "${websites[@]}"; do
  [ "$debug" == "true" ] && echo "Checking website: $url"
  # Get the current HTTP status code
  http_code=$(check_website "$url")
  [ "$debug" == "true" ] && echo "HTTP status code for $url: $http_code"
  # Determine if site is up based on HTTP status code
  # Consider 2xx and 3xx as "up", 4xx and 5xx as "down"
  # 000 means curl couldn't connect at all
  if [[ "$http_code" =~ ^[23][0-9][0-9]$ ]]; then
    current_status="$STATUS_UP"
  elif [[ "$http_code" == "000" ]]; then
    current_status="$STATUS_DOWN"
    [ "$debug" == "true" ] && echo "Connection failed for $url (HTTP code: 000 - connection timeout, DNS failure, or network error)"
  elif [[ "$http_code" =~ ^[45][0-9][0-9]$ ]]; then
    current_status="$STATUS_DOWN"
    [ "$debug" == "true" ] && echo "HTTP error for $url (HTTP code: $http_code)"
  else
    # Unknown/unexpected response code - treat as down but log it
    current_status="$STATUS_DOWN"
    [ "$debug" == "true" ] && echo "Unexpected response for $url (HTTP code: $http_code)"
  fi
  [ "$debug" == "true" ] && echo "Current status for $url: $current_status"

    # Compare with previous status to detect changes and handle grace period
  current_failure_count=0
  send_alert=false

  if [[ -n "${previous_status[$url]}" ]]; then
    previous_status_value=$(echo "${previous_status[$url]}" | awk '{print $1}')
    previous_timestamp=$(echo "${previous_status[$url]}" | awk '{print $2}')
    previous_failure_count=$(echo "${previous_status[$url]}" | awk '{print $3}')
    [ "$debug" == "true" ] && echo "Previous status for $url: $previous_status_value (failure count: $previous_failure_count)"

    if [ "$current_status" == "$STATUS_DOWN" ]; then
      if [ "$previous_status_value" == "$STATUS_DOWN" ]; then
        # Still down, increment failure count and keep original timestamp
        current_failure_count=$((previous_failure_count + 1))
        current_time=$previous_timestamp
        [ "$debug" == "true" ] && echo "Site $url still down, failure count: $current_failure_count"

        # Send alert only when crossing the grace period threshold
        if [ "$current_failure_count" -eq "$grace_period" ]; then
          send_alert=true
          current_time_formatted=$(TZ=$timezone date -d "@$current_time" +"%B %d, %Y %H:%M:%S %Z")
          [ "$debug" == "true" ] && echo "Grace period reached for $url, sending down alert"
        fi
      else
        # Just went down, start counting failures with new timestamp
        current_failure_count=1
        current_time=$(date +%s)
        [ "$debug" == "true" ] && echo "Site $url just went down, failure count: $current_failure_count"

        # Send immediate alert if grace period is 1
        if [ "$grace_period" -eq 1 ]; then
          send_alert=true
          current_time_formatted=$(TZ=$timezone date +"%B %d, %Y %H:%M:%S %Z")
          [ "$debug" == "true" ] && echo "Grace period is 1, sending immediate down alert"
        fi
      fi
    else
      # Site is up
      current_failure_count=0
      if [ "$previous_status_value" == "$STATUS_DOWN" ]; then
        # Site came back up - use new timestamp
        current_time=$(date +%s)
        current_time_formatted=$(TZ=$timezone date +"%B %d, %Y %H:%M:%S %Z")

        # Send "up" alert only if we had previously sent a "down" alert
        if [ "$previous_failure_count" -ge "$grace_period" ]; then
          send_alert=true
          duration_formatted=$(calculate_duration "$previous_timestamp" "$current_time")
          [ "$debug" == "true" ] && echo "Site $url is back up after reaching grace period, sending up alert"
        else
          [ "$debug" == "true" ] && echo "Site $url is back up but hadn't reached grace period, no alert needed"
        fi
      else
        # Still up, keep previous timestamp
        current_time=$previous_timestamp
      fi
    fi
  else
    # No previous status - first time checking this URL
    current_time=$(date +%s)
    if [ "$current_status" == "$STATUS_DOWN" ]; then
      current_failure_count=1
      [ "$debug" == "true" ] && echo "First check for $url shows it's down, failure count: $current_failure_count"

      # Send immediate alert only if grace period is 1
      if [ "$grace_period" -eq 1 ]; then
        send_alert=true
        current_time_formatted=$(TZ=$timezone date +"%B %d, %Y %H:%M:%S %Z")
      fi
    else
      current_failure_count=0
      [ "$debug" == "true" ] && echo "First check for $url shows it's up"
    fi
  fi

  # Send email if needed
  if [ "$send_alert" = true ]; then
    if [ "$current_status" == "$STATUS_DOWN" ]; then
      send_email "$current_status" "$url" "" "$current_time_formatted"
    else
      send_email "$current_status" "$url" "$duration_formatted" "$current_time_formatted"
    fi
  fi

  # Store the new status, timestamp, and failure count
  new_status+=("$url $current_status $current_time $current_failure_count")
done

# Write the new status back to the status file without duplicates
[ "$debug" == "true" ] && echo "Updating status file: $status_file"
true > "$status_file"
for status in "${new_status[@]}"; do
  echo "$status" >> "$status_file"
  [ "$debug" == "true" ] && echo "Status updated for: $status"
done

[ "$debug" == "true" ] && echo "Status file updated successfully."
[ "$debug" == "true" ] && echo "All websites checked successfully."
