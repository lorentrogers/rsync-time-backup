#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

OPT_VERBOSE="false"
OPT_SYSLOG="false"
OPT_KEEP_EXPIRED="false"
readonly APPNAME=$(basename "${0%.sh}")
readonly VERSION=0.1.0

# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------

fn_log_info() {
  if [ "$OPT_SYSLOG" == "true" ]; then
    echo "$1" >&40
  fi
  echo "$1"
}

fn_log_warn() {
  if [ "$OPT_SYSLOG" == "true" ]; then
    echo "[WARNING] $1" >&40
  fi
  echo "[WARNING] $1" 1>&2
}

fn_log_error() {
  if [ "$OPT_SYSLOG" == "true" ]; then
    echo "[ERROR] $1" >&40
  fi
  echo "[ERROR] $1" 1>&2
}

# Make sure everything really stops when CTRL+C is pressed
fn_terminate_script() {
  fn_log_info "SIGINT caught."
  exit 1
}

# clean up on exit
fn_cleanup() {
  if [ -n "$TMP_RSYNC_LOG" ]; then
    rm -f -- $TMP_RSYNC_LOG
  fi
  # close redirection to logger
  if [ "$OPT_SYSLOG" == "true" ]; then
    exec 40>&-
  fi
}

fn_usage() {
  fn_log_info "Usage: $APPNAME [OPTIONS] command [ARGS]"
  fn_log_info
  fn_log_info "Commands:"
  fn_log_info
  fn_log_info "  init <backup_location> [--local-time]"
  fn_log_info "      initialize <backup_location> by creating a backup marker file."
  fn_log_info
  fn_log_info "         --local-time"
  fn_log_info "             name all backups using local time, per default backups"
  fn_log_info "             are named using UTC."
  fn_log_info
  fn_log_info "  backup <src_location> <backup_location> [<exclude_file>]"
  fn_log_info "      create a Time Machine like backup from <src_location> at <backup_location>."
  fn_log_info "      optional: exclude files in <exclude_file> from backup"
  fn_log_info
  fn_log_info "  diff <backup1> <backup2>"
  fn_log_info "      show differences between two backups."
  fn_log_info
  fn_log_info "Options:"
  fn_log_info
  fn_log_info "  -s, --syslog"
  fn_log_info "      log output to syslogd"
  fn_log_info
  fn_log_info "  -k, --keep-expired"
  fn_log_info "      do not delete expired backups until they can be reused by subsequent backups or"
  fn_log_info "      the backup location runs out of space."
  fn_log_info
  fn_log_info "  -v, --verbose"
  fn_log_info "      increase verbosity"
  fn_log_info
  fn_log_info "  --version"
  fn_log_info "      display version and exit"
  fn_log_info
  fn_log_info "  -h, --help"
  fn_log_info "      this help text"
  fn_log_info
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
    if [ -d "$EXPIRED_DIR" ]; then
      find "$EXPIRED_DIR" -maxdepth 1 -type d -name "????-??-??-??????" | sort -r
    fi
  else
    find "$DEST_FOLDER" -maxdepth 1 -type d -name "????-??-??-??????" | sort -r
  fi
}

# Creates the backup marker and populates it with
# default settings, if it does not already have them.
fn_set_backup_marker() {
  if [ "$1" == "UTC" ]; then
    echo "UTC=true" > "$BACKUP_MARKER_FILE"
  else
    echo "UTC=false" > "$BACKUP_MARKER_FILE"
  fi
( cat <<"__EOF__"
RETENTION_WIN_ALL="$((4 * 3600))"        # 4 hrs
RETENTION_WIN_01H="$((1 * 24 * 3600))"   # 24 hrs
RETENTION_WIN_04H="$((3 * 24 * 3600))"   # 3 days
RETENTION_WIN_08H="$((14 * 24 * 3600))"  # 2 weeks
RETENTION_WIN_24H="$((28 * 24 * 3600))"  # 4 weeks
__EOF__
) >> "$BACKUP_MARKER_FILE"
  # since we excute this file, access should be limited
  chmod 600 $BACKUP_MARKER_FILE
  fn_log_info "Backup marker $BACKUP_MARKER_FILE created."
}

# This function sets variable $UTC dependent on backup marker content
# Confirms that the backup marker exists in the destination folder.
# Checks if write permissions are properly set.
# Reads the contents of the backup.marker file, or creates defaults if
# they do not yet exist.
# TODO: check that the destination supports hard links
# TODO: Split this into multiple sub-functions. too heavy.
# TODO: Use variables to set default values for retention and utc
#       instead of typing them out again here.
fn_check_backup_marker() {
  # TODO: check that the destination supports hard links
  if [ ! -f "$BACKUP_MARKER_FILE" ]; then
    fn_log_error "Destination does not appear to be a backup location - no backup marker file found."
    exit 1
  fi
  if ! touch -c "$BACKUP_MARKER_FILE" &> /dev/null ; then
    fn_log_error "no write permission for this backup location - aborting."
    exit 1
  fi
  if [ -z "$CONFIG_IMPORTED" ]; then
    CONFIG_IMPORTED=true
    if [ -n "$(cat "$BACKUP_MARKER_FILE")" ]; then
      # read backup configuration from backup marker
      source "$BACKUP_MARKER_FILE"
      fn_log_info "configuration imported from backup.marker"
    else
      fn_log_info "no configuration imported from backup marker - using defaults"
    fi
    # set defaults if missing - compatibility with old backups
    [ -z "$UTC" ] && UTC="false"
    [ -z "$RETENTION_WIN_ALL" ] && RETENTION_WIN_ALL="$((4 * 3600))"
    [ -z "$RETENTION_WIN_01H" ] && RETENTION_WIN_01H="$((1 * 24 * 3600))"
    [ -z "$RETENTION_WIN_04H" ] && RETENTION_WIN_04H="$((3 * 24 * 3600))"
    [ -z "$RETENTION_WIN_08H" ] && RETENTION_WIN_08H="$((14 * 24 * 3600))"
    [ -z "$RETENTION_WIN_24H" ] && RETENTION_WIN_24H="$((28 * 24 * 3600))"
  fi
}

fn_mark_expired() {
  fn_check_backup_marker
  fn_mkdir "$EXPIRED_DIR"
  mv -- "$1" "$EXPIRED_DIR/"
}

fn_expire_backups() {
  fn_log_info "expiring backups..."

  local NOW_TS=$(fn_parse_date "$1")

  # backup aggregation windows and retention times
  local LIMIT_ALL_TS=$((NOW_TS - RETENTION_WIN_ALL))  # until this point in time all backups are retained
  local LIMIT_1H_TS=$((NOW_TS  - RETENTION_WIN_01H))  # max 1 backup per hour
  local LIMIT_4H_TS=$((NOW_TS  - RETENTION_WIN_04H))  # max 1 backup per 4 hours
  local LIMIT_8H_TS=$((NOW_TS  - RETENTION_WIN_08H))  # max 1 backup per 8 hours
  local LIMIT_24H_TS=$((NOW_TS - RETENTION_WIN_24H))  # max 1 backup per day

  # Default value for $PREV_BACKUP_DATE ensures that the most recent backup is never deleted.
  local PREV_BACKUP_DATE="0000-00-00-000000"
  local BACKUP
  for BACKUP in $(fn_find_backups); do

    # BACKUP_DATE format YYYY-MM-DD-HHMMSS
    local BACKUP_DATE=$(basename "$BACKUP")
    local BACKUP_TS=$(fn_parse_date $BACKUP_DATE)

    local BACKUP_MONTH=${BACKUP_DATE:0:7}
    local BACKUP_DAY=${BACKUP_DATE:0:10}
    local BACKUP_HOUR=${BACKUP_DATE:11:2}
    local BACKUP_HOUR=${BACKUP_HOUR#0}  # work around bash octal numbers
    local PREV_BACKUP_MONTH=${PREV_BACKUP_DATE:0:7}
    local PREV_BACKUP_DAY=${PREV_BACKUP_DATE:0:10}
    local PREV_BACKUP_HOUR=${PREV_BACKUP_DATE:11:2}
    local PREV_BACKUP_HOUR=${PREV_BACKUP_HOUR#0}  # work around bash octal numbers

    # Skip if failed to parse date...
    if [ -z "$BACKUP_TS" ]; then
      fn_log_warn "Could not parse date: $BACKUP"
      continue
    fi
    if   [ $BACKUP_TS -ge $LIMIT_ALL_TS ]; then
      true
      [ "$OPT_VERBOSE" == "true" ] && fn_log_info "  $BACKUP_DATE ALL retained"
    elif   [ $BACKUP_TS -ge $LIMIT_1H_TS ]; then
      if [ "$BACKUP_DAY" == "$PREV_BACKUP_DAY" ] && \
         [ "$((BACKUP_HOUR / 1))" -eq "$((PREV_BACKUP_HOUR / 1))" ]; then
        fn_mark_expired "$BACKUP"
        fn_log_info "  $BACKUP_DATE 01H expired"
      else
        [ "$OPT_VERBOSE" == "true" ] && fn_log_info "  $BACKUP_DATE 01H retained"
      fi
    elif [ $BACKUP_TS -ge $LIMIT_4H_TS ]; then
      if [ "$BACKUP_DAY" == "$PREV_BACKUP_DAY" ] && \
         [ "$((BACKUP_HOUR / 4))" -eq "$((PREV_BACKUP_HOUR / 4))" ]; then
        fn_mark_expired "$BACKUP"
        fn_log_info "  $BACKUP_DATE 04H expired"
      else
        [ "$OPT_VERBOSE" == "true" ] && fn_log_info "  $BACKUP_DATE 04H retained"
      fi
    elif [ $BACKUP_TS -ge $LIMIT_8H_TS ]; then
      if [ "$BACKUP_DAY" == "$PREV_BACKUP_DAY" ] && \
         [ "$((BACKUP_HOUR / 8))" -eq "$((PREV_BACKUP_HOUR / 8))" ]; then
        fn_mark_expired "$BACKUP"
        fn_log_info "  $BACKUP_DATE 08H expired"
      else
        [ "$OPT_VERBOSE" == "true" ] && fn_log_info "  $BACKUP_DATE 08H retained"
      fi
    elif [ $BACKUP_TS -ge $LIMIT_24H_TS ]; then
      if [ "$BACKUP_DAY" == "$PREV_BACKUP_DAY" ]; then
        fn_mark_expired "$BACKUP"
        fn_log_info "  $BACKUP_DATE 24H expired"
      else
        [ "$OPT_VERBOSE" == "true" ] && fn_log_info "  $BACKUP_DATE 24H retained"
      fi
    else
      if [ "$BACKUP_MONTH" == "$PREV_BACKUP_MONTH" ]; then
        fn_mark_expired "$BACKUP"
        fn_log_info "  $BACKUP_DATE 01M expired"
      else
        [ "$OPT_VERBOSE" == "true" ] && fn_log_info "  $BACKUP_DATE 01M retained"
      fi
    fi
    PREV_BACKUP_DATE=$BACKUP_DATE
  done
}

fn_delete_backups() {
  fn_check_backup_marker
  local BACKUP
  for BACKUP in $EXPIRED_DIR/* ; do
    # work-around: in case of no match, bash returns "*"
    if [ "$BACKUP" != '*' ] && [ -e "$BACKUP" ]; then
      fn_log_info "deleting expired backup $(basename $BACKUP)"
      rm -rf -- "$BACKUP"
    fi
  done
  rmdir -- "$EXPIRED_DIR"
}

# Sets the basic variables needed for backup
# Assumes that $UTC, $DEST_FOLDER, $NOW, and $APPNAME have been set.
fn_set_backup_vars() {
  # Basic variables
  if [ "$UTC" == "true" ]; then
    readonly NOW=$(date -u +"%Y-%m-%d-%H%M%S")
    fn_log_info "backup time base: UTC"
  else
    readonly NOW=$(date +"%Y-%m-%d-%H%M%S")
    fn_log_info "backup time base: local time"
  fi
  readonly DEST="$DEST_FOLDER/$NOW"
  readonly INPROGRESS_FILE="$DEST_FOLDER/backup.inprogress"
  readonly EXPIRED_DIR="$DEST_FOLDER/expired"
  readonly TMP_RSYNC_LOG=$(mktemp "/tmp/${APPNAME}_XXXXXXXXXX")
  export IFS=$'\n' # Better for handling spaces in filenames.
}

# Checks if there are existing backups in the destination and
# whether or not there was a previous backup in progress.
# Sets the inprogress file accordingly.
fn_check_previous_backups(){
  # Check for previous backup operations
  PREVIOUS_DEST="$(fn_find_backups | head -n 1)"

  if [ -f "$INPROGRESS_FILE" ]; then
    if pgrep -F "$INPROGRESS_FILE" "$APPNAME" > /dev/null 2>&1 ; then
      fn_log_error "previous backup task is still active - aborting."
      exit 1
    fi
    echo "$$" > "$INPROGRESS_FILE"
    if [ -d "$PREVIOUS_DEST" ]; then
      fn_log_info "previous backup $PREVIOUS_DEST was interrupted - resuming from there."

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
  fi
}

# Moves the last expired backup and reuses it for the current one.
# This reuses the newest expired backup as the basis for the next rsync
# operation - significantly speeds up backup times!
# In order for this to work, rsync needs the
# following options: --delete --delete-excluded
fn_create_backup_directory() {
  LAST_EXPIRED="$(fn_find_backups expired | head -n 1)"
  if [ -n "$LAST_EXPIRED" ]; then
    fn_log_info "reusing expired backup $(basename $LAST_EXPIRED)"
    mv "$LAST_EXPIRED" "$DEST"
  else
    # a new backup directory is needed
    fn_mkdir "$DEST"
  fi
}

# Builds and runs the rsync command that backs up the files.
# TODO: Make backups immutable -- contents should be read only.
fn_run_rsync_cmd() {
  # Start backup
  CMD="rsync"
  CMD="$CMD --archive"
  CMD="$CMD --hard-links"
  CMD="$CMD --numeric-ids"
  CMD="$CMD --delete --delete-excluded"
  CMD="$CMD --one-file-system"
  CMD="$CMD --itemize-changes"
  CMD="$CMD --human-readable"
  CMD="$CMD --log-file '$TMP_RSYNC_LOG'"
  CMD="$CMD --verbose"

  if [ -n "$EXCLUSION_FILE" ]; then
    # We've already checked that $EXCLUSION_FILE doesn't contain a single quote
    CMD="$CMD --exclude-from '$EXCLUSION_FILE'"
  fi
  if [ -n "$PREVIOUS_DEST" ]; then
    # If the path is relative, it needs to be relative to the destination. To keep
    # it simple, just use an absolute path. See http://serverfault.com/a/210058/118679
    PREVIOUS_DEST="$(cd "$PREVIOUS_DEST"; pwd)"
    fn_log_info "doing incremental backup from $(basename $PREVIOUS_DEST)"
    CMD="$CMD --link-dest='$PREVIOUS_DEST'"
  fi
  CMD="$CMD -- '$SRC_FOLDER/' '$DEST/'"

  fn_log_info "backup name $(basename $DEST)"
  fn_log_info "rsync start"

  CMD="$CMD | grep -v -E '^[*]?deleting|^$|^.[Ld]\.\.t\.\.\.\.\.\.'"
  if [ "$OPT_VERBOSE" == "true" ]; then
    fn_log_info "$CMD"
  fi
  if [ "$OPT_SYSLOG" == "true" ]; then
    CMD="$CMD | tee /dev/stderr 2>&40"
  fi
  eval "$CMD"
  fn_log_info "rsync end"
}

# Check if we ran out of space
# TODO: find better way to check for out of space condition without parsing log.
fn_check_out_of_space() {
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
}

# Looks to see if rsync threw anything funky recently and prints a warning
# or error if it did.
fn_check_for_rsync_errors() {
  # Check whether rsync reported any errors
  if [ -n "$(grep "^rsync:" "$TMP_RSYNC_LOG")" ]; then
    fn_log_warn "Rsync reported a warning."
  fi
  if [ -n "$(grep "^rsync error:" "$TMP_RSYNC_LOG")" ]; then
    fn_log_error "Rsync reported an error - exiting."
    exit 1
  fi
}

# Makes a new symlink to the latest backup directory. Overrides the old one.
fn_create_latest_backup_symlink() {
  rm -f -- "$DEST_FOLDER/latest"
  ln -s -- "$(basename "$DEST")" "$DEST_FOLDER/latest"
}

# Removes any backups that have expired, unless keep expired option was set.
fn_delete_expired_backups() {
  # delete expired backups
  if [ "$OPT_KEEP_EXPIRED" != "true" ]; then
    fn_delete_backups
  elif [ ! "$(ls -A $EXPIRED_DIR)" ]; then
    # remove empty expired directory in any case
    rmdir -- "$EXPIRED_DIR"
  fi
}

# Runs a backup of the source files into the destination.
# Uses the exclude file if provided to specify which files are backed up.
fn_backup() {
  # Prep for backup
  fn_log_info "backup location: $DEST_FOLDER/"
  fn_log_info "backup source path: $SRC_FOLDER/"
  readonly BACKUP_MARKER_FILE="$DEST_FOLDER/backup.marker"
  fn_check_backup_marker
  fn_set_backup_vars
  fn_check_previous_backups
  fn_expire_backups "$NOW"
  fn_create_backup_directory

  # Main backup loop
  while : ; do # Run in a loop to handle the "No space left on device" logic.
    fn_run_rsync_cmd
    fn_check_for_rsync_errors
    fn_log_info "rsync end"
    fn_check_out_of_space
    break
  done

  # Clean up
  fn_check_for_rsync_errors
  fn_create_latest_backup_symlink
  fn_delete_expired_backups
  rm -f -- "$INPROGRESS_FILE"
  fn_log_info "backup $DEST completed."
}

# -----------------------------------------------------------------------------
# Runtime Configuration
# -----------------------------------------------------------------------------

# Catch critical events
trap fn_terminate_script SIGINT
trap fn_cleanup EXIT

# Parse command line arguments
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      fn_usage
      exit 0
    ;;
    --version)
      echo $APPNAME version $VERSION
      exit 0
    ;;
    -v|--verbose)
      OPT_VERBOSE="true"
    ;;
    -s|--syslog)
      OPT_SYSLOG="true"
      exec 40> >(exec logger -t "$APPNAME[$$]")
    ;;
    -k|--keep-expired)
      OPT_KEEP_EXPIRED="true"
    ;;
    init)
      if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
        fn_log_error "Wrong number of arguments for command '$1'."
        exit 1
      fi
      readonly DEST_FOLDER="${2%/}"
      if [ ! -d "$DEST_FOLDER" ]; then
        fn_log_error "backup location $DEST_FOLDER does not exist"
        exit 1
      fi
      readonly BACKUP_MARKER_FILE="$DEST_FOLDER/backup.marker"
      if [ "$3" == "--local-time" ]; then
        fn_set_backup_marker
      else
        fn_set_backup_marker "UTC"
      fi
      exit 0
    ;;
    diff)
      if [ "$#" -ne 3 ]; then
        fn_log_error "Wrong number of arguments for command '$1'."
        exit 1
      fi
      LOC1="${2%/}"
      LOC2="${3%/}"
      rsync --dry-run -auvi "$LOC1/" "$LOC2/" | grep -E -v '^sending|^$|^sent.*sec$|^total.*RUN\)'
      exit 0

    ;;
    backup)
      if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
        fn_log_error "Wrong number of arguments for command '$1'."
        exit 1
      fi
      readonly SRC_FOLDER="${2%/}"
      readonly DEST_FOLDER="${3%/}"
      readonly EXCLUSION_FILE="$4"
      if [ ! -d "$SRC_FOLDER/" ]; then
        fn_log_error "source location $SRC_FOLDER does not exist."
        exit 1
      fi
      if [ ! -d "$DEST_FOLDER/" ]; then
        fn_log_error "backup location $DEST_FOLDER does not exist."
        exit 1
      fi
      for ARG in "$SRC_FOLDER" "$DEST_FOLDER" "$EXCLUSION_FILE"; do
        if [[ "$ARG" == *"'"* ]]; then
          fn_log_error "Arguments may not have any single quote characters."
          exit 1
        fi
      done
      fn_backup
      exit 0
    ;;
    *)
      fn_log_error "Invalid argument '$1'. Use --help for more information."
      exit 1
    ;;
  esac
  shift
done

fn_log_info "Usage: $APPNAME [OPTIONS] command [ARGS]"
fn_log_info "Try '$APPNAME --help' for more information."
exit 0
