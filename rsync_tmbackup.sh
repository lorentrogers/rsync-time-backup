#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Log functions
# -----------------------------------------------------------------------------

fn_log_info()  { echo "$APPNAME: $1"; }
fn_log_warn()  { echo "$APPNAME: [WARNING] $1" 1>&2; }
fn_log_error() { echo "$APPNAME: [ERROR] $1" 1>&2; }

# -----------------------------------------------------------------------------
# Make sure everything really stops when CTRL+C is pressed
# -----------------------------------------------------------------------------

fn_terminate_script() {
	fn_log_info "SIGINT caught."
	exit 1
}

trap 'fn_terminate_script' SIGINT

# -----------------------------------------------------------------------------
# functions
# -----------------------------------------------------------------------------

fn_parse_date() {
	# Converts YYYY-MM-DD-HHMMSS to YYYY-MM-DD HH:MM:SS and then to Unix Epoch.
	case "$OSTYPE" in
		darwin*) date -j -f "%Y-%m-%d-%H%M%S" "$1" "+%s" ;;
		*) date -d "${1:0:10} ${1:11:2}:${1:13:2}:${1:15:2}" +%s ;;
	esac
}

fn_mkdir() {
	# make sure directory $1 exists
	if mkdir -p -- "$1"; then
		fn_log_info "Ensure that directory $1 exists."
	else
		fn_log_error "Creation of directory $1 failed."
		exit 1
	fi
}

fn_find_backups() {
	if [ "$1" == "expired" ]; then
		find "$EXPIRED_DIR" -type d -name "????-??-??-??????" -prune | sort -r
	else
		find "$DEST_FOLDER" -type d -name "????-??-??-??????" -prune | sort -r
	fi
}

fn_check_backup_marker() {
	#
	# TODO: check that the destination supports hard links
	#
	if [ -f "$BACKUP_MARKER_FILE" ]; then
		if ! touch -c "$BACKUP_MARKER_FILE"; then
			fn_log_error "no write permission for this backup location - aborting."
			exit 1
		fi
	else
		fn_log_error "Destination does not appear to be a backup location - no backup marker file found."
		fn_log_error  "If it is indeed a backup folder, you may add the marker file by running the following command:"
		fn_log_error  ""
		fn_log_error  "mkdir -p -- \"$DEST_FOLDER\" ; touch \""$BACKUP_MARKER_FILE"\""
		exit 1
	fi
}

fn_mark_expired() {
	fn_check_backup_marker
	fn_log_info "expiring backup $1"
	mv -- "$1" "$EXPIRED_DIR/"

	local LOG="$LOG_DIR/$(basename "$1").log"
	if [ -f "$LOG" ]; then 
		fn_log_info "expiring log $LOG"
		mv -- "$LOG" "$EXPIRED_DIR/"
	fi
}

fn_expire_backups() {
	local EPOCH=$(fn_parse_date "$NOW")
	local KEEP_ALL_DATE=$((EPOCH - 86400))       # 1 day ago
	local KEEP_DAILIES_DATE=$((EPOCH - 2678400)) # 31 days ago

	# Default value for $PREV ensures that the most recent backup is never deleted.
	local PREV="0000-00-00-000000"
	local BACKUP
	for BACKUP in $(fn_find_backups | sort -r); do
		local BACKUP_DATE=$(basename "$BACKUP")
		local TIMESTAMP=$(fn_parse_date $BACKUP_DATE)

		# Skip if failed to parse date...
		if [ -z "$TIMESTAMP" ]; then
			fn_log_warn "Could not parse date: $BACKUP"
			continue
		fi
		if   [ $TIMESTAMP -ge $KEEP_ALL_DATE ]; then
			true
		elif [ $TIMESTAMP -ge $KEEP_DAILIES_DATE ]; then
			# Delete all but the most recent of each day.
			[ "${BACKUP_DATE:0:10}" == "${PREV:0:10}" ] && fn_mark_expired "$BACKUP"
		else
			# Delete all but the most recent of each month.
			[ "${BACKUP_DATE:0:7}" == "${PREV:0:7}" ] && fn_mark_expired "$BACKUP"
		fi
		PREV=$BACKUP_DATE
	done
}

fn_delete_backups() {
	fn_check_backup_marker
	fn_log_info "Deleting expired backups..."
	rm -rf -- "$EXPIRED_DIR"
}

# -----------------------------------------------------------------------------
# basic variables
# -----------------------------------------------------------------------------

readonly APPNAME=$(basename $0 | sed "s/\.sh$//")
readonly NOW=$(date +"%Y-%m-%d-%H%M%S")

# Better for handling spaces in filenames.
export IFS=$'\n'

# -----------------------------------------------------------------------------
# Source and destination information
# -----------------------------------------------------------------------------

readonly SRC_FOLDER="${1%/}"
readonly DEST_FOLDER="${2%/}"
readonly EXCLUSION_FILE="$3"

for ARG in "$SRC_FOLDER" "$DEST_FOLDER" "$EXCLUSION_FILE"; do
	if [[ "$ARG" == *"'"* ]]; then
		fn_log_error 'Arguments may not have any single quote characters.'
		exit 1
	fi
done

# -----------------------------------------------------------------------------
# Check that the destination directory is a backup location
# -----------------------------------------------------------------------------

readonly BACKUP_MARKER_FILE="$DEST_FOLDER/backup.marker"
fn_check_backup_marker

# -----------------------------------------------------------------------------
# subdirectories & files
# -----------------------------------------------------------------------------

DEST="$DEST_FOLDER/$NOW"
PREVIOUS_DEST="$(fn_find_backups | head -n 1)"

readonly INPROGRESS_FILE="$DEST_FOLDER/backup.inprogress"

readonly EXPIRED_DIR="$DEST_FOLDER/expired"
fn_mkdir "$EXPIRED_DIR"

readonly LOG_DIR="$DEST_FOLDER/log"
fn_mkdir "$LOG_DIR"
readonly LOG_FILE="$LOG_DIR/$NOW.log"

# -----------------------------------------------------------------------------
# check for previous backup operations
# -----------------------------------------------------------------------------

if [ -f "$INPROGRESS_FILE" ]; then
	if pgrep -F "$INPROGRESS_FILE" > /dev/null 2>&1 ; then
		fn_log_error "Previous backup task is still active - aborting."
		exit 1
	fi
	echo "$$" > "$INPROGRESS_FILE"
	if [ -d "$PREVIOUS_DEST" ]; then
		fn_log_info "Previous backup $PREVIOUS_DEST failed or was interrupted - resuming from there."

		# - Last backup is moved to current backup folder so that it can be resumed.
		# - 2nd to last backup becomes last backup.
		mv -- "$PREVIOUS_DEST" "$DEST"
		if [ "$(fn_find_backups | wc -l)" -gt 1 ]; then
			PREVIOUS_DEST="$(fn_find_backups | sed -n '2p')"
		else
			PREVIOUS_DEST=""
		fi
	fi
else
	echo "$$" > "$INPROGRESS_FILE"
	# for a fresh backup a new backup directory is needed
	fn_mkdir "$DEST"
fi

# -----------------------------------------------------------------------------
# expire backups
# -----------------------------------------------------------------------------

fn_expire_backups

# -----------------------------------------------------------------------------
# Run in a loop to handle the "No space left on device" logic.
# -----------------------------------------------------------------------------
while : ; do

	# -----------------------------------------------------------------------------
	# Start backup
	# -----------------------------------------------------------------------------

	fn_log_info "Starting backup..."
	fn_log_info "From: $SRC_FOLDER"
	fn_log_info "To:   $DEST"

	CMD="rsync"
	CMD="$CMD --compress"
	CMD="$CMD --numeric-ids"
	CMD="$CMD --links"
	CMD="$CMD --hard-links"
	CMD="$CMD --one-file-system"
	CMD="$CMD --archive"
	CMD="$CMD --itemize-changes"
	CMD="$CMD --verbose"
	CMD="$CMD --log-file '$LOG_FILE'"
	if [ -n "$EXCLUSION_FILE" ]; then
		# We've already checked that $EXCLUSION_FILE doesn't contain a single quote
		CMD="$CMD --exclude-from '$EXCLUSION_FILE'"
	fi
	if [ -n "$PREVIOUS_DEST" ]; then
		# If the path is relative, it needs to be relative to the destination. To keep
		# it simple, just use an absolute path. See http://serverfault.com/a/210058/118679
		PREVIOUS_DEST="$(cd "$PREVIOUS_DEST"; pwd)"
		fn_log_info "Previous backup found - doing incremental backup from $PREVIOUS_DEST"
		CMD="$CMD --link-dest='$PREVIOUS_DEST'"
	fi

	CMD="$CMD -- '$SRC_FOLDER/' '$DEST/'"
	CMD="$CMD | grep -E '^deleting|[^/]$'"

	fn_log_info "Running command:"
	fn_log_info "$CMD"

	eval $CMD

	# -----------------------------------------------------------------------------
	# Check if we ran out of space
	# -----------------------------------------------------------------------------

	# TODO: find better way to check for out of space condition without parsing log.
	NO_SPACE_LEFT="$(grep "No space left on device (28)\|Result too large (34)" "$LOG_FILE")"

	if [ -n "$NO_SPACE_LEFT" ]; then
		if [ -z "$(fn_find_backups expired)" ]; then
			# no backups scheduled for deletion, delete oldest backup
			fn_log_warn "No space left on device, removing oldest backup"

			if [[ "$(fn_find_backups | wc -l)" -lt "2" ]]; then
				fn_log_error "No space left on device, and no old backup to delete."
				exit 1
			fi
			fn_mark_expired "$(fn_find_backups | tail -n 1)"
		fi

		fn_delete_backups

		# Resume backup
		continue
	fi

	break
done

# -----------------------------------------------------------------------------
# Check whether rsync reported any errors
# -----------------------------------------------------------------------------

if [ -n "$(grep "rsync:" "$LOG_FILE")" ]; then
	fn_log_warn "Rsync reported a warning, please check '$LOG_FILE' for more details."
fi
if [ -n "$(grep "rsync error:" "$LOG_FILE")" ]; then
	fn_log_error "Rsync reported an error, please check '$LOG_FILE' for more details."
	exit 1
fi

# -----------------------------------------------------------------------------
# Add symlink to last successful backup
# -----------------------------------------------------------------------------

rm -f -- "$DEST_FOLDER/latest" "$DEST_FOLDER/latest.log"
ln -s -- "$(basename "$DEST")" "$DEST_FOLDER/latest"
ln -s -- "log/$(basename "$LOG_FILE")" "$DEST_FOLDER/latest.log"

# -----------------------------------------------------------------------------
# delete expired backups
# -----------------------------------------------------------------------------

fn_delete_backups

# -----------------------------------------------------------------------------
# clean up and exit
# -----------------------------------------------------------------------------

rm -f -- "$INPROGRESS_FILE"

fn_log_info "Backup completed without errors."

exit 0
