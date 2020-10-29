#!/usr/bin/env bash
# The key file can be generate through the Grafana GUI Admin tools
# For Mac you may need to install jq: brew install jq
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
KEY=$(<grafanakey)
HOST="http://grafana.eyalzo.com:3000"


if [ ! -d $SCRIPT_DIR/dashboards ] ; then
    mkdir -p $SCRIPT_DIR/dashboards
fi

for dash in $(curl -k -H "Authorization: Bearer $KEY" $HOST/api/search\?query\=\& | jq -r '.[] | .uri'); do
  curl -k -H "Authorization: Bearer $KEY" $HOST/api/dashboards/$dash | sed 's/"id":[0-9]\+,/"id":null,/' | sed 's/\(.*\)}/\1,"overwrite": true}/' | jq . > dashboards/$(echo ${dash} |cut -d\" -f 4 |cut -d\/ -f2).json
done


