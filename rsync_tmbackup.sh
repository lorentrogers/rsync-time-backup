#!/usr/bin/env bash

readonly APPNAME=$(basename ${0%.sh})

# -----------------------------------------------------------------------------
# Log functions
# -----------------------------------------------------------------------------

fn_log_info()  { echo "$APPNAME: $1"; }
fn_log_warn()  { echo "$APPNAME: [WARNING] $1" 1>&2; }
fn_log_error() { echo "$APPNAME: [ERROR] $1" 1>&2; }

# -----------------------------------------------------------------------------
# traps
# -----------------------------------------------------------------------------

# ---
# Make sure everything really stops when CTRL+C is pressed
# ---

fn_terminate_script() {
       fn_log_info "SIGINT caught."
       exit 1
}

trap fn_terminate_script SIGINT

# ---
# clean up on exit
# ---

fn_cleanup() {
	if [ -n "$TMP_RSYNC_LOG" ]; then
		rm -f -- $TMP_RSYNC_LOG
	fi
}

trap fn_cleanup EXIT

# -----------------------------------------------------------------------------
# functions
# -----------------------------------------------------------------------------

fn_usage() {
	echo "Usage: $APPNAME [OPTIONS] command [ARGS]"
	echo
	echo "Commands:"
	echo
	echo "  init <backup_location> [--utc]"
	echo "      initialize <backup_location> by creating a backup marker file."
	echo "      if --utc is added all future backups will be created with UTC time."
	echo
	echo "  backup <src_location> <backup_location> [<exclude_file>]"
	echo "      create a Time Machine like backup from <src_location> at <backup_location>."
	echo "      optional: exclude files in <exclude_file> from backup"
	echo
	echo "General options:"
	echo
	echo "  -v, --verbose"
	echo "      increase verbosity"
	echo
	echo "  -h, --help"
	echo "      this help text"
	echo
}

fn_parse_date() {
	if [ "$UTC" == "true" ]; then
		local DATE_OPTION="-u"
	else
		local DATE_OPTION=""
	fi
	# Converts YYYY-MM-DD-HHMMSS to YYYY-MM-DD HH:MM:SS and then to Unix Epoch.
	case "$OSTYPE" in
		darwin*) date $DATE_OPTION -j -f "%Y-%m-%d-%H%M%S" "$1" "+%s" ;;
		*) date $DATE_OPTION -d "${1:0:10} ${1:11:2}:${1:13:2}:${1:15:2}" +%s ;;
	esac
}

fn_mkdir() {
	if ! mkdir -p -- "$1"; then
		fn_log_error "creation of directory $1 failed."
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
	if [ ! -f "$BACKUP_MARKER_FILE" ]; then
		fn_log_error "Destination does not appear to be a backup location - no backup marker file found."
		exit 1
	fi
	if ! touch -c "$BACKUP_MARKER_FILE" &> /dev/null ; then
		fn_log_error "no write permission for this backup location - aborting."
		exit 1
	fi
	if [ "$(cat "$BACKUP_MARKER_FILE")" == "UTC" ]; then
		UTC="true"
	else
		UTC="false"
	fi
}

fn_set_backup_marker() {
	fn_mkdir "$DEST_FOLDER"
	if [ "$1" == "UTC" ]; then
		echo "UTC" >> "$BACKUP_MARKER_FILE"
	else
		touch "$BACKUP_MARKER_FILE"
	fi
	fn_log_info "Backup marker $BACKUP_MARKER_FILE created."
}

fn_mark_expired() {
	fn_check_backup_marker
	fn_mkdir "$EXPIRED_DIR"
	mv -- "$1" "$EXPIRED_DIR/"
}

fn_expire_backups() {
	local NOW_TS=$(fn_parse_date "$1")

	local KEEP_ALL_TS=$((NOW_TS - 4 * 3600))	# all backups, for 4 hrs
	local KEEP_1HR_TS=$((NOW_TS - 1 * 24 * 3600))	# max 24 per day, for 24 hrs
	local KEEP_4HR_TS=$((NOW_TS - 3 * 24 * 3600))	# max  6 per day, for 3 days
	local KEEP_8HR_TS=$((NOW_TS - 14 * 24 * 3600))	# max  3 per day, for 2 weeks
	local KEEP_24HR_TS=$((NOW_TS - 28 * 24 * 3600))	# max  1 per day, for 4 weeks

	# Default value for $PREV_DATE ensures that the most recent backup is never deleted.
	local PREV_DATE="0000-00-00-000000"
	local BACKUP
	for BACKUP in $(fn_find_backups | sort -r); do

		# BACKUP_DATE format YYYY-MM-DD-HHMMSS
		local BACKUP_DATE=$(basename "$BACKUP")
		local BACKUP_TS=$(fn_parse_date $BACKUP_DATE)

		local BACKUP_MONTH=${BACKUP_DATE:0:7}
		local BACKUP_DAY=${BACKUP_DATE:0:10}
		local BACKUP_HOUR=${BACKUP_DATE:11:2}
		local BACKUP_HOUR=${BACKUP_HOUR#0}	# work around bash octal numbers
		local PREV_MONTH=${PREV_DATE:0:7}
		local PREV_DAY=${PREV_DATE:0:10}
		local PREV_HOUR=${PREV_DATE:11:2}
		local PREV_HOUR=${PREV_HOUR#0}		# work around bash octal numbers

		# Skip if failed to parse date...
		if [ -z "$BACKUP_TS" ]; then
			fn_log_warn "Could not parse date: $BACKUP"
			continue
		fi
		if   [ $BACKUP_TS -ge $KEEP_ALL_TS ]; then
			true
		elif   [ $BACKUP_TS -ge $KEEP_1HR_TS ]; then
			if [ "$BACKUP_DAY" == "$PREV_DAY" ] && \
			   [ "$((BACKUP_HOUR / 1))" -eq "$((PREV_HOUR / 1))" ]; then
				fn_mark_expired "$BACKUP"
				fn_log_info "backup $BACKUP_DATE 01HR expired"
			else
				[ "$OPT_VERBOSE" == "true" ] && fn_log_info "backup $BACKUP_DATE 01HR retained"
			fi
		elif [ $BACKUP_TS -ge $KEEP_4HR_TS ]; then
			if [ "$BACKUP_DAY" == "$PREV_DAY" ] && \
			   [ "$((BACKUP_HOUR / 4))" -eq "$((PREV_HOUR / 4))" ]; then
				fn_mark_expired "$BACKUP"
				fn_log_info "backup $BACKUP_DATE 04HR expired"
			else
				[ "$OPT_VERBOSE" == "true" ] && fn_log_info "backup $BACKUP_DATE 04HR retained"
			fi
		elif [ $BACKUP_TS -ge $KEEP_8HR_TS ]; then
			if [ "$BACKUP_DAY" == "$PREV_DAY" ] && \
			   [ "$((BACKUP_HOUR / 8))" -eq "$((PREV_HOUR / 8))" ]; then
				fn_mark_expired "$BACKUP"
				fn_log_info "backup $BACKUP_DATE 08HR expired"
			else
				[ "$OPT_VERBOSE" == "true" ] && fn_log_info "backup $BACKUP_DATE 08HR retained"
			fi
		elif [ $BACKUP_TS -ge $KEEP_24HR_TS ]; then
			if [ "$BACKUP_DAY" == "$PREV_DAY" ]; then
				fn_mark_expired "$BACKUP"
				fn_log_info "backup $BACKUP_DATE 24HR expired"
			else
				[ "$OPT_VERBOSE" == "true" ] && fn_log_info "backup $BACKUP_DATE 24HR retained"
			fi
		else
			if [ "$BACKUP_MONTH" == "$PREV_MONTH" ]; then
				fn_mark_expired "$BACKUP"
				fn_log_info "backup $BACKUP_DATE  ALL expired"
			else
				[ "$OPT_VERBOSE" == "true" ] && fn_log_info "backup $BACKUP_DATE  ALL retained"
			fi
		fi
		PREV_DATE=$BACKUP_DATE
	done
}

fn_delete_backups() {
	fn_check_backup_marker
	fn_log_info "Deleting expired backups..."
	rm -rf -- "$EXPIRED_DIR"
}

# -----------------------------------------------------------------------------
# parse command line arguments
# -----------------------------------------------------------------------------

# set defaults
OPT_VERBOSE="false"

# parse arguments
while [ "$#" -gt 0 ]; do
	case "$1" in
		-h|--help)
			fn_usage
			exit 0
		;;
		-v|--verbose)
			OPT_VERBOSE="true"
		;;
		init)
			if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
				echo "Wrong number of arguments for command '$1'." 1>&2
				exit 1
			fi
			readonly DEST_FOLDER="${2%/}"
			if [ ! -d "$DEST_FOLDER" ]; then
			       fn_log_error "backup location $DEST_FOLDER does not exist"
			       exit 1
			fi
			readonly BACKUP_MARKER_FILE="$DEST_FOLDER/backup.marker"
			if [ "$3" == "--utc" ]; then
				fn_set_backup_marker "UTC"
			else
				fn_set_backup_marker
			fi
			exit 0
		;;
		backup)
			if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
				echo "Wrong number of arguments for command '$1'." 1>&2
				exit 1
			fi
			readonly SRC_FOLDER="${2%/}"
			readonly DEST_FOLDER="${3%/}"
			readonly EXCLUSION_FILE="$4"
			if [ ! -d "$SRC_FOLDER" ]; then
			       fn_log_error "source location $SRC_FOLDER does not exist."
			       exit 1
			fi
			if [ ! -d "$DEST_FOLDER" ]; then
			       fn_log_error "backup location $DEST_FOLDER does not exist."
			       exit 1
			fi
			for ARG in "$SRC_FOLDER" "$DEST_FOLDER" "$EXCLUSION_FILE"; do
				if [[ "$ARG" == *"'"* ]]; then
					fn_log_error "Arguments may not have any single quote characters."
					exit 1
				fi
			done
			break
		;;
		*)
			echo "Invalid argument '$1'. Use --help for more information." 1>&2
			exit 1
		;;
	esac
	shift
done

if [ "$#" -eq 0 ]; then
        echo "Usage: $APPNAME [OPTIONS] command [ARGS]"
        echo "Try '$APPNAME --help' for more information."
        exit 0
fi

# -----------------------------------------------------------------------------
# Check that the destination directory is a backup location
# -----------------------------------------------------------------------------

readonly BACKUP_MARKER_FILE="$DEST_FOLDER/backup.marker"
# this function sets variable $UTC dependent on backup marker content
fn_check_backup_marker

# -----------------------------------------------------------------------------
# BACKUP: basic variables
# -----------------------------------------------------------------------------

if [ "$UTC" == "true" ]; then
	readonly NOW=$(date -u +"%Y-%m-%d-%H%M%S")
else
	readonly NOW=$(date +"%Y-%m-%d-%H%M%S")
fi

readonly DEST="$DEST_FOLDER/$NOW"
readonly INPROGRESS_FILE="$DEST_FOLDER/backup.inprogress"
readonly EXPIRED_DIR="$DEST_FOLDER/expired"
readonly TMP_RSYNC_LOG=$(mktemp "/tmp/${APPNAME}_XXXXXXXXXX")

# Better for handling spaces in filenames.
export IFS=$'\n'

# -----------------------------------------------------------------------------
# Check for previous backup operations
# -----------------------------------------------------------------------------

PREVIOUS_DEST="$(fn_find_backups | head -n 1)"

if [ -f "$INPROGRESS_FILE" ]; then
	if pgrep -F "$INPROGRESS_FILE" > /dev/null 2>&1 ; then
		fn_log_error "previous backup task is still active - aborting."
		exit 1
	fi
	echo "$$" > "$INPROGRESS_FILE"
	if [ -d "$PREVIOUS_DEST" ]; then
		fn_log_info "previous backup $PREVIOUS_DEST failed or was interrupted - resuming from there."

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

fn_log_info "expiring backups..."
fn_expire_backups "$NOW"

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
	CMD="$CMD --human-readable"
	CMD="$CMD --delete --delete-excluded"
	CMD="$CMD --log-file '$TMP_RSYNC_LOG'"

	if [ -n "$EXCLUSION_FILE" ]; then
		# We've already checked that $EXCLUSION_FILE doesn't contain a single quote
		CMD="$CMD --exclude-from '$EXCLUSION_FILE'"
	fi
	if [ -n "$PREVIOUS_DEST" ]; then
		# If the path is relative, it needs to be relative to the destination. To keep
		# it simple, just use an absolute path. See http://serverfault.com/a/210058/118679
		PREVIOUS_DEST="$(cd "$PREVIOUS_DEST"; pwd)"
		fn_log_info "doing incremental backup from previous backup $PREVIOUS_DEST"
		CMD="$CMD --link-dest='$PREVIOUS_DEST'"
	fi
	CMD="$CMD -- '$SRC_FOLDER/' '$DEST/'"
	CMD="$CMD | grep -E '^deleting|[^/]$'"

	fn_log_info "$CMD"

	eval $CMD

	# -----------------------------------------------------------------------------
	# Check if we ran out of space
	# -----------------------------------------------------------------------------

	# TODO: find better way to check for out of space condition without parsing log.
	NO_SPACE_LEFT="$(grep "No space left on device (28)\|Result too large (34)" "$TMP_RSYNC_LOG")"

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

if [ -n "$(grep "rsync:" "$TMP_RSYNC_LOG")" ]; then
	fn_log_warn "Rsync reported a warning, please check '$TMP_RSYNC_LOG' for more details."
fi
if [ -n "$(grep "rsync error:" "$TMP_RSYNC_LOG")" ]; then
	fn_log_error "Rsync reported an error, please check '$TMP_RSYNC_LOG' for more details."
	exit 1
fi

# -----------------------------------------------------------------------------
# Add symlink to last successful backup
# -----------------------------------------------------------------------------

rm -f -- "$DEST_FOLDER/latest"
ln -s -- "$(basename "$DEST")" "$DEST_FOLDER/latest"

# -----------------------------------------------------------------------------
# delete expired backups
# -----------------------------------------------------------------------------

fn_delete_backups

# -----------------------------------------------------------------------------
# exit
# -----------------------------------------------------------------------------

rm -f -- "$INPROGRESS_FILE"

fn_log_info "Backup completed without errors."
exit 0
