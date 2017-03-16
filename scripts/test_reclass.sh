#!/usr/bin/env bash

set -e
if [[ $DEBUG =~ ^(True|true|1|yes)$ ]]; then
    set -x
fi

## Overrideable options
DOCKER_IMAGE=${DOCKER_IMAGE:-"ubuntu:16.04"}
DIST=${DIST:-xenial}
RECLASS_ROOT=${RECLASS_ROOT:-$(pwd)}
SALT_OPTS="${SALT_OPTS} --retcode-passthrough --force-color"
DOCKER_OPTS="${DOCKER_OPTS} -e DEBIAN_FRONTEND=noninteractive"
SKIP_CLEANUP=${SKIP_CLEANUP:-0}

declare -a CONTAINERS

## Functions
log_info() {
    echo "[INFO] $*"
}

log_err() {
    echo "[ERROR] $*" >&2
}

docker_exec() {
    if [[ $DETACH =~ ^(True|true|1|yes)$ ]]; then
        exec_opts="-d"
    else
        exec_opts=""
    fi

    docker exec ${exec_opts} "${CONTAINER}" /bin/bash -c "$*"
}

_atexit() {
    RETVAL=$?
    trap true INT TERM EXIT
    if [ "$SKIP_CLEANUP" -eq 1 ]; then
        return $RETVAL
    fi

    log_info "Cleaning up"

    for container in "${CONTAINERS[@]}"; do
        CONTAINER=$container docker_exec "chown -R $(id -u):$(id -g) /srv/salt/reclass" || true
        docker rm -f "$container" >/dev/null || true
    done

    if [ $RETVAL -ne 0 ]; then
        log_err "Execution failed"
    else
        log_info "Execution successful"
    fi

    return $RETVAL
}

run_container() {
    MASTER_HOSTNAME=$1
    CONTAINER=$(docker run ${DOCKER_OPTS} --name "${MASTER_HOSTNAME}-$(openssl rand -hex 2)" -h "$(echo "${MASTER_HOSTNAME}"|cut -d . -f 1)" -v "${RECLASS_ROOT}":/srv/salt/reclass -i -t -d "${DOCKER_IMAGE}")
    echo "$CONTAINER"
}

test_master() {
    MASTER_HOSTNAME=$1
    log_info "Installing packages"
    docker_exec "which wget >/dev/null || (apt-get update; apt-get install -y wget)"
    docker_exec "echo 'deb [arch=amd64] http://apt-mk.mirantis.com/${DIST}/ nightly salt salt-latest' > /etc/apt/sources.list.d/apt-mk.list"
    docker_exec "wget -O - http://apt-mk.mirantis.com/public.gpg | apt-key add -"

    docker_exec "apt-get update"
    docker_exec "apt-get install -y salt-master python-psutil iproute2 curl reclass salt-formula-*"

    log_info "Setting up Salt master"
    # TODO: remove grains.d hack when fixed in formula
    docker_exec "mkdir -p /etc/salt/grains.d && touch /etc/salt/grains.d/dummy"
    docker_exec "[ ! -d /etc/salt/pki/minion ] && mkdir -p /etc/salt/pki/minion"
    docker_exec "[ ! -d /etc/salt/master.d ] && mkdir -p /etc/salt/master.d || true"
    docker_exec "cat << 'EOF' >> /etc/salt/master.d/master.conf
file_roots:
  base:
    - /usr/share/salt-formulas/env
pillar_opts: False
open_mode: True
reclass: &reclass
  storage_type: yaml_fs
  inventory_base_uri: /srv/salt/reclass
ext_pillar:
  - reclass: *reclass
master_tops:
  reclass: *reclass
EOF"

    log_info "Setting up reclass"
    docker_exec "[ -d /srv/salt/reclass/classes/service ] || mkdir -p /srv/salt/reclass/classes/service || true"
    docker_exec "for i in /usr/share/salt-formulas/reclass/service/*; do
    [ -e /srv/salt/reclass/classes/service/\$(basename \$i) ] || ln -s \$i /srv/salt/reclass/classes/service/\$(basename \$i)
    done"

    docker_exec "[ ! -d /etc/reclass ] && mkdir /etc/reclass || true"
    docker_exec "cat << 'EOF' >> /etc/reclass/reclass-config.yml
storage_type: yaml_fs
pretty_print: True
output: yaml
inventory_base_uri: /srv/salt/reclass
EOF"

    log_info "Setting up Salt minion"
    docker_exec "apt-get install -y salt-minion"
    docker_exec "[ ! -d /etc/salt/minion.d ] && mkdir -p /etc/salt/minion.d || true"
    docker_exec "cat << EOF >> /etc/salt/minion.d/minion.conf
id: ${MASTER_HOSTNAME}
master: localhost
EOF"

    log_info "Starting Salt master service"
    DETACH=1 docker_exec "/usr/bin/salt-master"
    sleep 3

    docker_exec "salt-call saltutil.sync_all"
    log_info "Running states to finish Salt master setup"
    docker_exec "reclass --nodeinfo ${MASTER_HOSTNAME} >/dev/null"
    docker_exec "salt-call ${SALT_OPTS} state.show_top"

    if [[ $SALT_MASTER_FULL =~ ^(True|true|1|yes)$ ]]; then
        # TODO: can fail on "hostname: you must be root to change the host name"
        docker_exec "salt-call ${SALT_OPTS} state.sls linux,openssh" || true
        docker_exec "salt-call ${SALT_OPTS} state.sls salt,reclass"
    else
        docker_exec "salt-call ${SALT_OPTS} state.sls reclass.storage.node" || true
    fi

    NODES=$(docker_exec "find /srv/salt/reclass/nodes -type f -name *.yml ! -name cfg*")
    for node in ${NODES}; do
        node=$(basename "$node" .yml)
        log_info "Testing node ${node}"
        docker_exec "reclass --nodeinfo ${node} >/dev/null"
        docker_exec "salt-call ${SALT_OPTS} --id=${node} state.show_top"
        docker_exec "salt-call ${SALT_OPTS} --id=${node} state.show_lowstate >/dev/null"
    done
}


## Main
trap _atexit INT TERM EXIT

masters=$(find nodes -type f -name "cfg*.yml")
for master in "${masters[@]}"; do
    master=$(basename "$master" .yml)
    log_info "Testing Salt master ${master}"
    log_info "Creating docker container from image ${DOCKER_IMAGE}"
    CONTAINER=$(run_container "$master")
    CONTAINERS+=(${CONTAINER})
    test_master "$master"
done
