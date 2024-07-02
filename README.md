# Website Uptime Monitoring Script

This repository contains a bash script to monitor the uptime of a list of websites. The script sends email notifications if a website goes down or comes back up. It can also send summary reports of websites that are currently down.

## Features

- Monitors a list of websites for uptime.
- Sends email notifications when a website goes down or comes back up.
- Can run in summary mode to send a list of all websites that are currently down.

## How It Works

The script monitors the uptime of a list of websites by performing the following steps:

1.  **Website Status Check**: The script uses  `curl`  to send an HTTP request to each website. The  `curl`  command is configured to follow redirects (`-L`  option) and handle cookies (`-c`  and  `-b`  options) to ensure that websites using cookies for session management are properly checked. The command retrieves the HTTP status code of the website, which indicates whether the website is up or down.
    
    ```bash
    http_code=$(curl -L -c $tempfile -b $tempfile --silent -o /dev/null --head --write-out "%{http_code}" "$url")
    ```
    
2.  **Status Comparison**: The script compares the current status of each website with its previous status, stored in a temporary file. If the status has changed (e.g., from up to down or from down to up), the script prepares an email notification with the relevant information.
    
3.  **Email Notifications**: The script sends email notifications to a predefined list of recipients. When a website goes down, it sends a "DOWN Alert" email with the time the website was first detected as down. When a website comes back up, it sends an "UP Alert" email with the duration of the downtime.
    
4.  **Summary Mode**: In summary mode, the script does not perform uptime checks. Instead, it reads the previous status file and sends a summary email listing all websites that are currently down. This mode relies on the output from the most recent uptime checks performed in regular mode.

## Requirements

- `curl` for making HTTP requests.
- `mailx` for sending emails.

## Usage

### Running the Script

```bash
./uptime.sh
```

### Options

-   `--summary`: Runs the script in summary mode, sending an email with the list of all websites that are currently down.
-   `--debug`: Enables debug mode, printing detailed information about the script's execution.
-   `--help`: Displays usage information.

> Summary mode does not check website uptime. It only sends a summary email based on the results of the most recent uptime check. Therefore, you still need to run the script in regular mode to perform the actual uptime checks.

### Example Cron Jobs

To run the script every minute:

```bash
* * * * * /path/to/this/uptime.sh
0 * * * * /path/to/this/uptime.sh --summary
```

### Email Notifications Examples

#### Down Alert

```plaintext
Subject: 🔴 [example.com] DOWN Alert

example.com is down since January 01, 2024 12:00:00 GMT.

HTTP code: 500
```

#### Up Alert

```plaintext
Subject: ✅ [example.com] UP Alert

example.com is UP again at January 01, 2024 12:05:00 GMT, after 5m of downtime.
```

#### Summary

```plaintext
Subject: 🔴 DOWN Alert Summary

The following sites are down:

https://example.com is down since January 01, 2024 12:00:00 GMT
https://anotherexample.com is down since January 01, 2024 12:00:00 GMT
```

## Configuration

### Email Addresses

The script sends notifications to a predefined list of email addresses. To add or remove email addresses, modify the  `emails` array in the script:

```bash
emails=("your-email@example.com")
```

### Timezone

The script uses a specific timezone for formatting timestamps. To change the timezone, modify the  `timezone` variable in the script:

```bash
timezone="America/Winnipeg"
```

### Websites

The script monitors a predefined list of websites. To add or remove websites, modify the  `websites` array in the script:

```bash
websites=(
  "https://example.com"
  "https://anotherexample.com"
)
```
