# TrueNAS to Proton Sync

A robust bash script designed to efficiently synchronize files from a TrueNAS storage pool to Proton Drive. 

This script is built for infrequent secure online access to personal files and serves as a pseudo-backup. It performs a strict one-way UP sync of local files. To remain gentle on the Proton Drive API, it avoids full directory evaluations by tracking local states via SQLite, ensuring it only uploads new/changed files and propagates local deletions.

**Note on Sync Behavior:** Because this is strictly a one-way sync, modifications made directly online will not be reflected on TrueNAS. By design, if an online folder is deleted but the local folder still exists, local changes within that folder will log an error rather than auto-creating the missing folder, ensuring underlying issues aren't masked.

## Prerequisites
Before running this script, you must configure the official Proton Drive CLI wrapper. 
**👉 [See CLI_SETUP.md for authentication instructions](CLI_SETUP.md)**

## Features
* **Native CLI Integration:** Wraps the official Proton Drive CLI for reliable, fast transfers.
* **Minimal API Overhead:** Uses local SQLite databases to track file and folder deltas.
* **Sequential Processing:** Safely handles deletions, creates parent directories, and uploads modified files in a strict, error-resistant order.
* **Custom Exclusions:** Takes an `EXCLUDE_FILE` parameter (a text file listing folder paths) to exclude specific directories. Currently, only full paths are supported.

## Configuration
Before running, modify the variables listed under the `# --- Script Configuration ---` header inside `pd_file_sync_script.sh` to match your TrueNAS data pool and folder paths. Make the script executable using `chmod +x pd_file_sync_script.sh`.

## Usage
`./pd_file_sync_script.sh [--resetstate] [--timeout DURATION]`

* **`--resetstate`**: Takes a snapshot of the current local directory state and assumes all files are already online, skipping the initial upload.
* **`--timeout DURATION`**: Sets a watchdog timer to prevent hung sync operations. The duration format requires a number followed directly by a time unit suffix (`s`, `m`, `h`, `d`). 
  * Examples: `--timeout 30m`, `--timeout 12h`

## Automation (Cron Job)
You can automate this script via TrueNAS Cron Jobs.
1. Go to **System / Advanced Settings / Cron Jobs** and create a new job.
2. Use the following for the job command (adjusting your path):
   `/mnt/YOURPOOL/home/YOUHOMEFOLDER/proton_file_tracker/pd_file_sync_script.sh --timeout 12h > /dev/null 2>&1`
3. Be sure to check the **"Hide Standard Output"** box to be safe.
