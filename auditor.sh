#!/bin/bash
# vim: set ft=sh:ts=2:sw=2


# Global Vars
################################################################################
MASTER_NODES=""
USERS=""

LOGS_FOLDER="./logs"
STATS_FOLDER="./stats"
CLUSTER_DOMAIN=""

OUTPUT_FILE="./identities.log"
STATS_FILE="$STATS_FOLDER/stats.json"
OAUTH_IDENTITY_FILE="$LOGS_FOLDER/oauth_identity.log"

collect=true

################################################################################
function info_msg() {
  echo -e "[INF] - $@"
}

function err_msg() {
  echo -e "[ERR] - $@"
}

# Prints the list of master nodes in the current cluster
function get_master_node_list() {
  oc get nodes -o json | jq -r '.items[] | select(.spec.taints[]?.key=="node-role.kubernetes.io/master") | .metadata.labels."kubernetes.io/hostname"'
  return $?
}

# Prints the list of Users in the current cluster
function get_user_list() {
  oc get users -o=custom-columns='NAME:.metadata.name' --no-headers
  return $?
}

# Script Init function
function init() {
  info_msg "Starting Auditor Script"

  MASTER_NODES=$(get_master_node_list)
  USERS=$(get_user_list)

  # Preparing folders
  [[ ! -d "$LOGS_FOLDER" ]] && { mkdir $LOGS_FOLDER; }
  [[ ! -d "$STATS_FOLDER" ]] && { mkdir $STATS_FOLDER; }

  CLUSTER_DOMAIN="$(
    oc cluster-info | \
      head -1 | \
      sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,2})?)?[mGK]//g" | \
      sed 's/^.*https:\/\/api.\(.*\):[0-9]*/\1/'\
      )"

  STATS_FOLDER=$STATS_FOLDER/$CLUSTER_DOMAIN
  [[ ! -d "$STATS_FOLDER" ]] && { mkdir $STATS_FOLDER; }

  LOGS_FOLDER=$LOGS_FOLDER/$CLUSTER_DOMAIN
  [[ ! -d "$LOGS_FOLDER" ]] && { mkdir $LOGS_FOLDER; }

  STATS_FILE="$STATS_FOLDER/${CLUSTER_DOMAIN}.json"

  oc cluster-info
}

# Collect every Apiserver audit log from every master node
function collect_logs() {
  info_msg "Collecting Audit Logs"
  for master in $MASTER_NODES; do
    for log_folder in $(oc adm node-logs $master --path= | grep apiserver); do
      for log_file in $(oc adm node-logs $master --path=$log_folder); do
        mkdir -p $LOGS_FOLDER/$master/$log_folder/
        info_msg "Collecting: [$master/$log_folder$log_file]"
        oc adm node-logs $master --path=/$log_folder/$log_file > $LOGS_FOLDER/$master/$log_folder$log_file &
      done
    done
  done
  wait
}


# Print script usage flags
function print_usage() {
  echo "
  $0
    -c: Collects every Audit log
    -s: Process the collected logs and extract the available stats
    -h: Prints script's usage
  "
}

################################################################################
function init_report_file() {
  echo '
  {
    "report": []
  }
  ' > $STATS_FILE
  for user in $USERS; do
    jq ".report += [{\"userName\": \"$user\", logins:[], events:[]}]" $STATS_FILE > .tmp
    mv .tmp $STATS_FILE
  done
}

# Get each login timestamp for each user
function get_login_timestamp() {
  for user in $USERS; do
    info_msg "Getting Log in Events for $user"
    for node in $(ls $LOGS_FOLDER); do
      for file in $(ls $LOGS_FOLDER/$node/oauth-apiserver/*.log); do
        # Get every identity event for each user in each master node
        logins=$(
          jq "
            select(.objectRef.resource == \"identities\") |
            select(.responseStatus.code == 200) |
            select(.objectRef.name | test(\".*:$user\")) |
            {login_timestamp: .requestReceivedTimestamp, masterNode: \"$node\"}" $file \
          | jq -s -r -c
        )

        # Adding matched identities to final JSON report
        jq \
          --arg user "$user" \
          --argjson logins $logins \
          '.report |= map(if .userName == $user then .logins += $logins else . end)' \
          $STATS_FILE > .tmp
        mv .tmp $STATS_FILE
      done
    done
    jq \
      --arg user "$user" \
      '.report |= map(if .userName == $user then .loginCount = (.logins | length) else . end)' \
      $STATS_FILE > .tmp
    mv .tmp $STATS_FILE
  done
}

function get_interactions() {
  for user in $USERS; do
    info_msg "Getting interaction Events for $user"
    for node in $(ls $LOGS_FOLDER); do
      for file in $(ls $LOGS_FOLDER/$node/kube-apiserver/*.log $LOGS_FOLDER/$node/openshift-apiserver/*.log); do
        events=$(jq -c \
            --arg user "$user" \
            '
            select(.userAgent | test("^oc/4.*")) |
            select(.user.username == $user) |
            {
              URI: .requestURI, 
              objectRef: .objectRef, 
              verb: .verb, 
              date: .requestReceivedTimestamp, 
              day_date: .requestReceivedTimestamp[:10]
            }' \
            $file 2>/dev/null | jq -s -r -c
          )
        if [ ! -z "$events" ]; then
          jq \
            --arg user "$user" \
            --argjson events $events \
            '.report |= map(if .userName == $user then .events += $events else . end)' \
            $STATS_FILE > .tmp
          mv .tmp $STATS_FILE
        fi
      done
    done
    jq \
      --arg user "$user" \
      '
        .report |= map(
          if .userName == $user then
            .events |= [(group_by(.URI)[] | {URI: (.[0].URI), events: [.[] |{date: .date, day_date: .day_date, verb: .verb, objectRef: .objectRef}]})]
          else
            .
          end) 
      ' $STATS_FILE > .tmp
      mv .tmp $STATS_FILE
  done
}

function plot_data() {
  cat $STATS_FILE | jq -r '.report[].events[].events[] | [.day_date, .verb, .objectRef.resource, .objectRef.namespace] | @csv' | sed 's/\"//g' | sort > plot.csv
  gnuplot << _EOF_
# File properties
# --------------------------------------------
set output '$STATS_FOLDER/$CLUSTER_DOMAIN-verb.png'
set terminal png


# Graph properties
# --------------------------------------------
set title "Cluster Stadistics: $CLUSTER_DOMAIN"
set key left top
set timefmt "%Y-%m-%d"
set style fill solid

## X Axis
set xlabel "Time"
set xdata time
set format x "%Y-%m-%d"
set xtics rotate

## Y Axis
set ylabel "Events"


# Data properties
# --------------------------------------------
set datafile separator ","

# Style
# --------------------------------------------
set grid

# Plots
# --------------------------------------------
plot 'plot.csv' using 1:(stringcolumn(2) eq "create"?\$1:1/0) smooth freq w boxes fill title "create", \
     'plot.csv' using 1:(stringcolumn(2) eq "delete"?\$1:1/0) smooth freq w boxes fill title "delete", \
     'plot.csv' using 1:(stringcolumn(2) eq "get"?\$1:1/0) smooth freq w boxes fill title "get", \
     'plot.csv' using 1:(stringcolumn(2) eq "list"?\$1:1/0) smooth freq w boxes fill title "list", \
     'plot.csv' using 1:(stringcolumn(2) eq "watch"?\$1:1/0) smooth freq w boxes fill title "watch"
_EOF_


  cat $STATS_FILE | jq -r '.report[] | [.userName, (.events | length)] | @csv' | sed 's/\"//g' | sort > plot.csv
  gnuplot << _EOF_
# File properties
# --------------------------------------------
set output '$STATS_FOLDER/$CLUSTER_DOMAIN-user.png'


# Graph properties
# --------------------------------------------
set title "Cluster Stadistics: $CLUSTER_DOMAIN"
set terminal png
set key right top
set style fill solid

## X Axis
set xlabel "User"
set xtics rotate

## Y Axis
set ylabel "Events"


# Data properties
# --------------------------------------------
set datafile separator ","

# Style
# --------------------------------------------
set grid

# Plots
# --------------------------------------------
set style data histogram
plot 'plot.csv' using 2:xtic(1) title "Actions per user"
_EOF_
}


# Collect every Stadistic
function stats() {
  init_report_file
  get_login_timestamp
  get_interactions
  plot_data
}

while getopts 'csh' flag; do
  case "${flag}" in
    c) collect_all_logs=1 ;;
    s) process_stats=1 ;;
    h) print_usage; exit 0 ;;
    *) print_usage; exit 1 ;;
  esac
done

init

if [ $collect_all_logs ]; then
 collect_logs
fi

if [ $process_stats ]; then
  stats
fi
