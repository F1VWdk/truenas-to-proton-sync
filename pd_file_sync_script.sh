#!/bin/bash
# /mnt/${POOL_NAME}/home/${USER_NAME}/proton_file_tracker/pd_file_sync_script.sh
# Version History:
#   v8.0:
#		- Architecture Overhaul: Replaced rclone with official Proton Drive CLI wrapper
#      	- Implemented linear sequential execution (Trash Files -> Trash Folders -> Upload Files)
#		- Added custom retry logic for native CLI commands
#		- Retained pristine SQLite local tracking to minimize API overhead
#   v8.1:
#		- Added explicit pre-creation of new folders via filesystem create-folder to prevent upload path errors.
#		- Corrected remote target path syntax.
#	v8.2:
#		- Added abort logic to resolve uploading to an existing folder
#	v8.3:
#		- Fixed false-positive error logging by masking watchdog cleanup exit code
#		- Converted final remote log upload to a best-effort operation to prevent post-success ERR trap triggers
#	v8.4:
#		-Moved CLI wrapper into repo for tracking and updated main script path
#	v8.5:
#		-Sanitize hardcoded paths
#	v8.6:
#		-Refined file exclusions to track static logs by targeting only the active log file

# --- Load Configuration ---
CONFIG_FILE="$(dirname "$0")/sync_config.cfg"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file not found. Please copy sync_config.example.cfg to sync_config.cfg and configure your variables." >&2
    exit 1
fi

# --- Script Configuration ---
SOURCE_DIR="/mnt/${POOL_NAME}/Docs"
DB_DIR="/mnt/${POOL_NAME}/home/${USER_NAME}/proton_file_tracker"
LOG_DIR="/mnt/${POOL_NAME}/Docs/Docs/Computers & Related/Logs"
LOG_FILE="${LOG_DIR}/TrueNAS to Proton.log"
EXCLUDE_FILE="${LOG_DIR}/excluded.txt"

# --- Proton Drive CLI Configuration ---
PD_CLI="/mnt/${POOL_NAME}/home/${USER_NAME}/proton_file_tracker/proton-drive-cli-sync"
REMOTE_DIR="/my-files/Home-NAS"

# --- Path Sanitization ---
SOURCE_DIR="${SOURCE_DIR%/}/"
REMOTE_DIR="${REMOTE_DIR%/}"

# --- Temporary file definitions ---
DB_FILES="$DB_DIR/file_tracker.db"
CURRENT_FILES="$DB_DIR/current_files.txt"
CHANGED_FILES="$DB_DIR/changed_files.txt"
DELETED_FILES="$DB_DIR/deleted_files.txt"
DB_FOLDERS="$DB_DIR/folder_tracker.db"
CURRENT_FOLDERS="$DB_DIR/current_folders.txt"
NEW_FOLDERS="$DB_DIR/new_folders.txt"
DELETED_FOLDERS="$DB_DIR/deleted_folders.txt"

# --- Script state variables ---
RESET_STATE=0
FIRST_RUN=0
TIMEOUT_DURATION=""
WATCHDOG_PID=""
SYNC_ERROR=0 

# --- Function Definitions ---
validate_duration() {
    local duration=$1
    if ! [[ "$duration" =~ ^[0-9]+[smhd]$ ]]; then
        echo "Error: Invalid duration format: '$duration'." >&2
        exit 1
    fi
}

usage() {
    echo "Usage: $0 [--resetstate] [--timeout DURATION] [--help]"
    echo "Synchronizes $SOURCE_DIR to $REMOTE_DIR using local DB tracking, excluding folders in $EXCLUDE_FILE."
    exit 0
}

cleanup_and_exit() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - An error occurred or script was interrupted. Cleaning up..." >> "$LOG_FILE"
    pkill -TERM -P $$ find sqlite3 proton-drive &>/dev/null
    rm -f "$CHANGED_FILES" "$DELETED_FILES" "$CURRENT_FILES" "$DELETED_FOLDERS" "$NEW_FOLDERS" "$CURRENT_FOLDERS"
    rm -f "$DB_DIR/find_error.log" "$DB_DIR/sqlite_error.log"
    exit 1
}

timeout_exit() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Timeout of $TIMEOUT_DURATION exceeded." >> "$LOG_FILE"
    pkill -TERM -P $$ find sqlite3 proton-drive &>/dev/null
    exit 1
}

write_log() {
    if [ -f "$1" ]; then
        while IFS= read -r line; do
            echo "$(date '+%Y-%m-%d %H:%M:%S') - $line" >> "$LOG_FILE"
        done < "$1"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    fi
}

log_footer() {
    local new_changed_count=$1
    local deleted_count=$2
    local deleted_folder_count=$3
    printf "#%.0s" {1..80} >> "$LOG_FILE"; echo >> "$LOG_FILE"
    write_log "Sync completed successfully"
    write_log "New/changed files: $new_changed_count"
    write_log "Deleted files: $deleted_count"
    write_log "Deleted folders: $deleted_folder_count"
    printf "#%.0s" {1..80} >> "$LOG_FILE"; echo >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
}

# Wrapper for Proton CLI commands to add retry logic
run_pd_cli_with_retry() {
    local max_attempts=3
    local attempt=1
    local exit_code=0
    local temp_output="$DB_DIR/pd_cli_temp.log"
    
    while [ "$attempt" -le "$max_attempts" ]; do
        # Execute command and capture its true exit code immediately
        "$@" > "$temp_output" 2>&1
        exit_code=$?
        
        # Evaluate the captured exit code
        if [ "$exit_code" -eq 0 ]; then
            rm -f "$temp_output"
            return 0
        fi
        
        write_log "Attempt $attempt failed for command: $*"
        write_log "$temp_output"
        sleep 5
        ((attempt++))
    done
    rm -f "$temp_output"
    return $exit_code
}

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --resetstate) RESET_STATE=1; shift ;;
        --timeout)
            if [[ -n "$2" ]]; then TIMEOUT_DURATION="$2"; validate_duration "$TIMEOUT_DURATION"; shift 2;
            else echo "Error: --timeout requires duration." >&2; exit 1; fi ;;
        --help) usage ;;
        *) echo "Error: Unknown option: $1" >&2; exit 1 ;;
    esac
done

# --- Watchdog ---
MAIN_PID=$$
cleanup_watchdog() {
    if [[ -n "$WATCHDOG_PID" ]] && kill -0 "$WATCHDOG_PID" 2>/dev/null; then
        kill "$WATCHDOG_PID" 2>/dev/null
        wait "$WATCHDOG_PID" 2>/dev/null || true
    fi
}
trap cleanup_watchdog EXIT 
trap 'cleanup_and_exit' ERR INT
trap 'timeout_exit' TERM

# --- Start ---
mkdir -p "$DB_DIR" "$LOG_DIR"
echo "" >> "$LOG_FILE"
printf "#%.0s" {1..80} >> "$LOG_FILE"; echo >> "$LOG_FILE"
write_log "Sync operation started"

if [[ -n "$TIMEOUT_DURATION" ]]; then
    ( exec sleep "$TIMEOUT_DURATION"; kill -TERM "$MAIN_PID" ) &
    WATCHDOG_PID=$!
    write_log "Timeout watchdog started: $TIMEOUT_DURATION."
fi

# --- Exclusions ---
FIND_EXCLUDE_ARGS=()
if [ -f "$EXCLUDE_FILE" ]; then
    while IFS= read -r rule; do
        if [[ -z "$rule" || "$rule" =~ ^[[:space:]]*# ]]; then continue; fi
        rule=$(echo "$rule" | tr -d '\r' | xargs)
        [ -z "$rule" ] && continue
        find_path=$(echo "$rule" | sed 's#/\*\*##; s#/$##')
        if [ -n "$find_path" ]; then
            FIND_EXCLUDE_ARGS+=(-path "$SOURCE_DIR$find_path" -prune -o)
        fi
    done < "$EXCLUDE_FILE"
fi

if [[ "$RESET_STATE" -eq 1 ]]; then
    write_log "Resetting state due to --resetstate."
    rm -f "$DB_FILES" "$DB_FOLDERS"
fi

# Check Proton Drive Auth
if [ "$RESET_STATE" -eq 0 ]; then
    if ! "$PD_CLI" filesystem list / >/dev/null 2>&1; then
        write_log "Error: Proton Drive CLI authentication failed. Run the wrapper manually to fix."
        cleanup_and_exit
    fi
fi

# --- Initialize DBs and Check Integrity ---
if [ ! -f "$DB_FILES" ]; then
    sqlite3 "$DB_FILES" "CREATE TABLE files (path TEXT PRIMARY KEY, mtime INTEGER, size INTEGER); CREATE TABLE metadata (key TEXT PRIMARY KEY, value INTEGER); INSERT INTO metadata VALUES ('last_run_time', 0);"
fi
if [ ! -f "$DB_FOLDERS" ]; then
    sqlite3 "$DB_FOLDERS" "CREATE TABLE folders (path TEXT PRIMARY KEY); CREATE TABLE metadata (key TEXT PRIMARY KEY, value INTEGER); INSERT INTO metadata VALUES ('last_run_time', 0);"
    FIRST_RUN=1
fi

if ! sqlite3 "$DB_FILES" "PRAGMA integrity_check;" | grep -q "ok"; then
    write_log "CRITICAL: File database integrity check failed. Aborting."
    cleanup_and_exit
fi

# --- Generate File Delta ---
if ! find "$SOURCE_DIR" "${FIND_EXCLUDE_ARGS[@]}" -type f -not -path "$LOG_FILE" -printf '%p|%T@|%s\n' > "$CURRENT_FILES" 2> "$DB_DIR/find_error.log"; then
    write_log "Error running find: $(cat "$DB_DIR/find_error.log")"; cleanup_and_exit
fi

RELATIVE_SQL_CHANGED="SELECT substr(f.path, length('$SOURCE_DIR') + 1) AS path FROM files f LEFT JOIN files_last_run flr ON f.path = flr.path WHERE flr.path IS NULL OR f.mtime > COALESCE(flr.mtime, 0);"
RELATIVE_SQL_DELETED="SELECT substr(flr.path, length('$SOURCE_DIR') + 1) AS path FROM files_last_run flr WHERE flr.path NOT IN (SELECT path FROM files);"

if ! sqlite3 "$DB_FILES" <<SQL > /dev/null 2> "$DB_DIR/sqlite_error.log"
PRAGMA synchronous=OFF;
PRAGMA journal_mode=WAL;
BEGIN TRANSACTION;
DROP TABLE IF EXISTS files_new;
CREATE TABLE files_new (path TEXT PRIMARY KEY, mtime INTEGER, size INTEGER);
.mode list
.separator "|"
.import $CURRENT_FILES files_new
DROP TABLE IF EXISTS files;
ALTER TABLE files_new RENAME TO files;
CREATE INDEX IF NOT EXISTS idx_files_path ON files(path);
COMMIT;

BEGIN TRANSACTION;
CREATE TABLE IF NOT EXISTS files_last_run (path TEXT PRIMARY KEY, mtime INTEGER, size INTEGER);
.output $CHANGED_FILES
$RELATIVE_SQL_CHANGED
.output $DELETED_FILES
$RELATIVE_SQL_DELETED
COMMIT;
SQL
then
    write_log "Error SQLite files: $(cat "$DB_DIR/sqlite_error.log")"; cleanup_and_exit
fi

# --- Generate Folder Delta ---
if ! find "$SOURCE_DIR" "${FIND_EXCLUDE_ARGS[@]}" -type d -printf '%p\n' | tr -d '\r' | sort -u > "$CURRENT_FOLDERS" 2> "$DB_DIR/find_error.log"; then
    write_log "Error running find folders"; cleanup_and_exit
fi

# Order deleted folders descending to delete deeply nested folders before their parents
RELATIVE_SQL_DELETED_FOLDERS="SELECT substr(flr.path, length('$SOURCE_DIR') + 1) AS path FROM folders_last_run flr WHERE flr.path NOT IN (SELECT path FROM folders) AND flr.path != '${SOURCE_DIR%/}' ORDER BY path DESC;"
# Order new folders ascending to create parent directories before subdirectories
RELATIVE_SQL_NEW_FOLDERS="SELECT substr(f.path, length('$SOURCE_DIR') + 1) AS path FROM folders f WHERE f.path NOT IN (SELECT path FROM folders_last_run) AND f.path != '${SOURCE_DIR%/}' ORDER BY path ASC;"

if ! sqlite3 "$DB_FOLDERS" <<SQL > /dev/null 2> "$DB_DIR/sqlite_error.log"
PRAGMA synchronous=OFF;
PRAGMA journal_mode=WAL;
BEGIN TRANSACTION;
DROP TABLE IF EXISTS folders_new;
CREATE TABLE folders_new (path TEXT PRIMARY KEY);
.mode list
.separator "\t"
.import $CURRENT_FOLDERS folders_new
DROP TABLE IF EXISTS folders;
ALTER TABLE folders_new RENAME TO folders;
COMMIT;
BEGIN TRANSACTION;
CREATE TABLE IF NOT EXISTS folders_last_run (path TEXT PRIMARY KEY);
$( [ "$FIRST_RUN" -eq 0 ] && echo ".output $DELETED_FOLDERS" )
$( [ "$FIRST_RUN" -eq 0 ] && echo "$RELATIVE_SQL_DELETED_FOLDERS" )
.output $NEW_FOLDERS
$RELATIVE_SQL_NEW_FOLDERS
COMMIT;
SQL
then
    write_log "Error SQLite folders"; cleanup_and_exit
fi

# --- Proton Drive Native Operations ---
if [ "$RESET_STATE" -eq 0 ]; then
    
    # 1. Process File Deletions
    if [ -s "$DELETED_FILES" ]; then
        write_log "Processing file deletions..."
        while IFS= read -r rel_path; do
            [ -z "$rel_path" ] && continue
            
            target_remote_path="$REMOTE_DIR/$rel_path"
            if ! run_pd_cli_with_retry "$PD_CLI" filesystem trash "$target_remote_path"; then
                write_log "Failed to trash file: $target_remote_path"
                SYNC_ERROR=1
            fi
        done < "$DELETED_FILES"
    fi
    
    # 2. Process Folder Deletions
    if [ "$FIRST_RUN" -eq 0 ] && [ -s "$DELETED_FOLDERS" ]; then
        write_log "Processing folder deletions..."
        while IFS= read -r rel_path; do
            [ -z "$rel_path" ] && continue
            
            target_remote_path="$REMOTE_DIR/$rel_path"
            if ! run_pd_cli_with_retry "$PD_CLI" filesystem trash "$target_remote_path"; then
                write_log "Failed to trash folder: $target_remote_path"
                SYNC_ERROR=1
            fi
        done < "$DELETED_FOLDERS"
    fi

    # API Stability Buffer
    if [ -s "$DELETED_FILES" ] || [ -s "$DELETED_FOLDERS" ]; then
        if [ -s "$CHANGED_FILES" ] || [ -s "$NEW_FOLDERS" ]; then 
            sleep 5 
        fi
    fi

    # 3. Process New Folder Creations
    if [ -s "$NEW_FOLDERS" ]; then
        write_log "Processing new folder creations..."
        while IFS= read -r rel_path; do
            [ -z "$rel_path" ] && continue
            
            parent_dir=$(dirname "$rel_path")
            folder_name=$(basename "$rel_path")
            
            # Format target parent directory
            if [ "$parent_dir" = "." ]; then
                target_parent="$REMOTE_DIR"
            else
                target_parent="$REMOTE_DIR/$parent_dir"
            fi
            
            if ! run_pd_cli_with_retry "$PD_CLI" filesystem create-folder "$target_parent" "$folder_name"; then
                # We do not set SYNC_ERROR=1 here because failure often just means the folder already exists.
                # If it truly failed to create, the file upload below will catch the error and flag it.
                write_log "Note: Folder creation failed or already exists: $target_parent/$folder_name"
            fi
        done < "$NEW_FOLDERS"
    fi

    # 4. Process File Uploads
    if [ -s "$CHANGED_FILES" ]; then
        write_log "Processing file uploads..."
        while IFS= read -r rel_path; do
            [ -z "$rel_path" ] && continue
            
            local_file="$SOURCE_DIR$rel_path"
            dir_name=$(dirname "$rel_path")
            
            # Format target directory string securely
            if [ "$dir_name" = "." ]; then
                target_remote_dir="$REMOTE_DIR"
            else
                target_remote_dir="$REMOTE_DIR/$dir_name"
            fi
            
            if ! run_pd_cli_with_retry "$PD_CLI" filesystem upload "$local_file" "$target_remote_dir" --conflict-strategy replace; then
                write_log "Failed to upload file: $local_file"
                SYNC_ERROR=1
            fi
        done < "$CHANGED_FILES"
    else
        write_log "No new or changed files to upload."
    fi
fi

# --- Final State Commit & Cleanup ---
if [ "$SYNC_ERROR" -eq 0 ]; then
    write_log "Operations successful. Committing state database."
    
    sqlite3 "$DB_FILES" <<SQL
    BEGIN TRANSACTION;
    DROP TABLE IF EXISTS files_last_run;
    ALTER TABLE files RENAME TO files_last_run;
    CREATE INDEX IF NOT EXISTS idx_files_last_run_path ON files_last_run(path);
    INSERT OR REPLACE INTO metadata (key, value) VALUES ('last_run_time', $(date +%s));
    COMMIT;
SQL

    sqlite3 "$DB_FOLDERS" <<SQL
    BEGIN TRANSACTION;
    DROP TABLE IF EXISTS folders_last_run;
    ALTER TABLE folders RENAME TO folders_last_run;
    INSERT OR REPLACE INTO metadata (key, value) VALUES ('last_run_time', $(date +%s));
    COMMIT;
SQL
    
    NEW_CHANGED_COUNT=$([ -f "$CHANGED_FILES" ] && wc -l < "$CHANGED_FILES" || echo 0)
    DELETED_COUNT=$([ -f "$DELETED_FILES" ] && wc -l < "$DELETED_FILES" || echo 0)
    DELETED_FOLDER_COUNT=0
    [ "$FIRST_RUN" -eq 0 ] && DELETED_FOLDER_COUNT=$([ -f "$DELETED_FOLDERS" ] && wc -l < "$DELETED_FOLDERS" || echo 0)
    
    log_footer "$NEW_CHANGED_COUNT" "$DELETED_COUNT" "$DELETED_FOLDER_COUNT"
else
    write_log "ERRORS detected during sync. Database state NOT updated. Will retry next run."
    echo "Errors detected. Check log." >&2
    exit 1
fi

rm -f "$CHANGED_FILES" "$DELETED_FILES" "$CURRENT_FILES" "$DELETED_FOLDERS" "$NEW_FOLDERS" "$CURRENT_FOLDERS"
rm -f "$DB_DIR/find_error.log" "$DB_DIR/sqlite_error.log"

# Upload the final log file to the remote
# Removed the extra trailing slash from the variable expansion
RELATIVE_LOG_PATH=$(dirname "${LOG_FILE#$SOURCE_DIR}")
if [ "$RELATIVE_LOG_PATH" = "." ]; then
    TARGET_LOG_DIR="$REMOTE_DIR"
else
    TARGET_LOG_DIR="$REMOTE_DIR/$RELATIVE_LOG_PATH"
fi
run_pd_cli_with_retry "$PD_CLI" filesystem upload "$LOG_FILE" "$TARGET_LOG_DIR" --conflict-strategy replace >/dev/null 2>&1 || true

exit 0

