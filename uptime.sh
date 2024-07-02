#!/bin/bash

# Email settings (add multiple email addresses separated by space)
emails=("email@example.com")

# Timezone variable for formatting timestamps
timezone="America/Winnipeg"

# Array of websites to check for their status
websites=(
  "https://example.com"
  "https://anotherexample.com"
)

# Temporary file to store the previous status of websites
status_file="/tmp/websites_status.txt"
# Ensure the status file exists
touch $status_file

# Status variables for easier readability
STATUS_UP="up"
STATUS_DOWN="down"

# Status emojis
EMOJI_UP="\xE2\x9C\x85" # Green check mark
EMOJI_DOWN="\xF0\x9F\x94\xB4" # Red circle

# Function to check the status of a website
check_website() {
  url=$1
  tempfile=$(mktemp)
  # Use curl to get the HTTP status code of the website
  http_code=$(curl -L -c "$tempfile" -b "$tempfile" --silent -o /dev/null --head --write-out "%{http_code}" "$url")
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
    message="$hostname is down since $timestamp.\n\nHTTP code: $http_code"
  else
    subject="$EMOJI_UP [$hostname] UP Alert"
    message="$hostname is UP again at $timestamp, after $duration of downtime."
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

if [ "$mode" == "summary" ]; then
  [ "$debug" == "true" ] && echo "Reading previous status for summary..."
  # Read previous status into an associative array
  declare -A previous_status
  while IFS= read -r line; do
    url=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $2}')
    timestamp=$(echo "$line" | awk '{print $3}')
    previous_status["$url"]="$status $timestamp"
  done < "$status_file"

  down_sites=()
  for url in "${!previous_status[@]}"; do
    status=$(echo "${previous_status[$url]}" | awk '{print $1}')
    timestamp=$(echo "${previous_status[$url]}" | awk '{print $2}')
    if [ "$status" == "$STATUS_DOWN" ]; then
      timestamp_formatted=$(TZ=$timezone date -d "@$timestamp" +"%B %d, %Y %H:%M:%S %Z")
      down_sites+=("$url is down since $timestamp_formatted")
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
  previous_status["$url"]="$status $timestamp"
done < "$status_file"
[ "$debug" == "true" ] && echo "Previous status loaded."

# Check each website and update status
new_status=()
for url in "${websites[@]}"; do
  [ "$debug" == "true" ] && echo "Checking website: $url"
  # Get the current HTTP status code
  http_code=$(check_website "$url")
  [ "$debug" == "true" ] && echo "HTTP status code for $url: $http_code"
  current_status="$STATUS_UP"
  if [ "$http_code" -ne 200 ]; then
    current_status="$STATUS_DOWN"
  fi
  [ "$debug" == "true" ] && echo "Current status for $url: $current_status"

  # Compare with previous status to detect changes
  if [[ -n "${previous_status[$url]}" ]]; then
    previous_status_value=$(echo "${previous_status[$url]}" | awk '{print $1}')
    previous_timestamp=$(echo "${previous_status[$url]}" | awk '{print $2}')
    [ "$debug" == "true" ] && echo "Previous status for $url: $previous_status_value"

    if [ "$previous_status_value" != "$current_status" ]; then
      current_time=$(date +%s)
      current_time_formatted=$(TZ=$timezone date +"%B %d, %Y %H:%M:%S %Z")
      if [ "$current_status" == "$STATUS_UP" ]; then
        # Calculate downtime duration
        duration=$((current_time - previous_timestamp))
        hours=$((duration / 3600))
        minutes=$(((duration % 3600) / 60))
        duration_formatted=$(printf '%dh %dm' $hours $minutes)
        send_email "$current_status" "$url" "$duration_formatted" "$current_time_formatted"
      else
        send_email "$current_status" "$url" "" "$current_time_formatted"
      fi
    else
      current_time=$previous_timestamp
    fi
  else
    current_time=$(date +%s)
    current_time_formatted=$(TZ=$timezone date +"%B %d, %Y %H:%M:%S %Z")
    if [ "$current_status" == "$STATUS_DOWN" ]; then
      send_email "$current_status" "$url" "" "$current_time_formatted"
    fi
  fi

  # Store the new status and timestamp
  new_status+=("$url $current_status $current_time")
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
