#!/bin/bash -x
exec > >(tee -i /tmp/"$(basename "$0" .sh)"_"$(date '+%Y-%m-%d_%H-%M-%S')".log) 2>&1

# Create and distribute SSL certificates for services using salt state
salt "*" state.sls salt

# Install keepalived
salt -C 'I@keepalived:cluster' state.sls keepalived -b 1

# Install haproxy
salt -C 'I@haproxy:proxy' state.sls haproxy
salt -C 'I@haproxy:proxy' service.status haproxy

# Install docker
salt -C 'I@docker:host' state.sls docker.host
salt -C 'I@docker:host' cmd.run "docker ps"

# Install etcd
salt -C 'I@etcd:server' state.sls etcd.server.service
salt -C 'I@etcd:server' cmd.run "etcdctl cluster-health"

# Install Kubernetes and Calico
salt -C 'I@kubernetes:master' state.sls kubernetes.master.kube-addons
salt -C 'I@kubernetes:pool' state.sls kubernetes.pool
salt -C 'I@kubernetes:pool' cmd.run "calicoctl node status"
salt -C 'I@kubernetes:pool' cmd.run "calicoctl get ippool"

# Setup NAT for Calico
salt -C 'I@kubernetes:master' state.sls etcd.server.setup

# Run whole master to check consistency
salt -C 'I@kubernetes:master' state.sls kubernetes exclude=kubernetes.master.setup

# Register addons
salt -C 'I@kubernetes:master' --subset 1 state.sls kubernetes.master.setup

# Nginx needs to be configured
salt -C 'I@nginx:server' state.sls nginx
