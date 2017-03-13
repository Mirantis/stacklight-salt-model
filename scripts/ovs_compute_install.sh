#!/bin/bash -x
exec > >(tee -i /tmp/"$(basename "$0" .sh)"_"$(date '+%Y-%m-%d_%H-%M-%S')".log) 2>&1

CWD="$(dirname "$(readlink -f "$0")")"

# Import common functions
COMMONS=$CWD/common_functions.sh
if [ ! -f "$COMMONS" ]; then
    echo "File $COMMONS does not exist"
    exit 1
fi
. "$COMMONS"

# OVS deployment
salt -C 'I@nova:compute' state.sls nova
salt -C 'I@cinder:volume' state.sls cinder
salt -C 'I@neutron:compute' state.sls neutron
