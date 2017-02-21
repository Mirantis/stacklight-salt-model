#!/bin/bash -x

CWD="$(dirname "$(readlink -f "$0")")"

"$CWD"/infra_verify.sh
"$CWD"/infra_install.sh
"$CWD"/k8s.sh
"$CWD"/stacklight_infra_install.sh
"$CWD"/stacklight_monitor_install.sh

