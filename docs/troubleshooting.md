# Troubleshooting: kind Kubelet Fails From inotify Exhaustion

This note documents the host-level bug encountered before the mesh lab could run.

## Symptom

Creating a kind cluster failed during `kubeadm init`. The control-plane kubelet kept restarting and never reached a healthy state. In this incident, 290 restart attempts were observed.

The visible error looked like a generic bootstrap timeout, which made it tempting to debug Kubernetes resources or container capacity first.

## Wrong Turn

The initial assumption was resource pressure: CPU, memory, or Docker capacity. That was plausible because kubelet restart loops often appear when the node cannot start core components.

That was not the root cause here. The failure was below Kubernetes scheduling and workload placement. The kubelet itself could not initialize required watchers.

## Command That Revealed the Cause

Inspect the kubelet logs inside the kind control-plane node:

```bash
docker exec -it <kind-control-plane-container> journalctl -u kubelet --no-pager
```

For this lab, the useful pattern was:

```bash
docker exec -it mesh-lab-control-plane journalctl -u kubelet --no-pager | grep -iE 'inotify|cadvisor|certificate'
```

The decisive error was:

```text
inotify_init: too many open files
```

That error caused cAdvisor and certificate watcher startup to fail, which kept kubelet unhealthy and made `kubeadm init` time out.

## Fix

Raise the host's inotify instance limit. On Fedora, the setting that mattered in this incident was `fs.inotify.max_user_instances`.

Temporary fix:

```bash
sudo sysctl fs.inotify.max_user_instances=1024
```

Persistent fix:

```bash
echo 'fs.inotify.max_user_instances=1024' | sudo tee /etc/sysctl.d/99-kind-inotify.conf
sudo sysctl --system
```

Then recreate the kind cluster.

## How To Recognize This Class Of Problem

Look for a mismatch between the top-level error and the component that is actually failing.

Typical signals:

- `kind create cluster` or `kubeadm init` times out;
- the control-plane container exists, but the node never becomes Ready;
- kubelet restarts repeatedly;
- `journalctl -u kubelet` mentions `inotify_init`, cAdvisor, certificate watchers, or too many open files.

When those signals appear together, check host sysctl limits before spending time on Kubernetes manifest or pod-level debugging.
