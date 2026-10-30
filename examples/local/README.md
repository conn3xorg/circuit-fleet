# Local example

Applies circuit-fleet to a throwaway Rocky Linux 10 container with systemd, along with MySQL, Valkey and osquery on the same host, then enrolls the host in its own Fleet. You need Conn3x and Podman, on amd64: Fleet has no arm64 Linux build, so this won't run on a Mac with Apple silicon.

circuit-valkey sets `vm.overcommit_memory`, so the host container runs privileged, which is simplest with rootful Podman. On Linux, use `sudo podman`:

```sh
export PODMAN="sudo podman"
./up.sh
conn3x init
conn3x apply                     # MySQL, Valkey and Fleet
./setup.sh                       # Fleet's setup, through its API
conn3x apply -var enroll=true    # osquery, which enrolls the host
conn3x plan -var enroll=true
./check.sh
```

The plan says `No changes.` `check.sh` finishes with `All checks passed.`, once it has seen the host listed and online and had an answer to a live query.

The apply comes in two parts because osquery needs an enroll secret, and that doesn't exist until Fleet's setup is done.

`up.sh` listens on `127.0.0.1:2305`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. To test another distro, set `CONTAINERFILE` to one of the images in Conn3x's `test/images`, which CI uses, and pass its name, `ubuntu` or `debian`, with `-var os=NAME`.

The secrets in `main.tf`, `setup.sh` and `check.sh` are examples, for this throwaway host only. Pick your own on a real one.

`./down.sh` removes the container, its volumes, the key and the state.
