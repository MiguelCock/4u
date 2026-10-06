# Phase 1 EC2 deployment

A single, cheap EC2 instance running the existing `docker-compose.yml` unmodified, reachable over the internet, for real usability testing (issue #90). Not production — see the future `deployment/phase2-production/` for that (#94).

## Out of scope here (separate issues)

- Running the full real end-to-end user flow through this deployment (the app's `API_GATEWAY_URL` gets wired up automatically as part of the steps below, but the broader "does the whole flow actually work" check is separate) — #91.
- A budget alarm / automated stop-start schedule — #93 (`stop.sh`/`start.sh` below are the manual version of half of that).

## Prerequisites (one-time)

1. **AWS CLI v2 installed and configured** with your own credentials (`aws configure` — never paste your access key/secret into a chat session; run it yourself in your own terminal).
2. Verify it works: `aws sts get-caller-identity` should print your account details.
3. **If this is an AWS Academy Learner Lab account** (`assumed-role/voclabs/...` in step 2's output is the tell): these use short-lived session credentials tied to the lab session, not a long-lived IAM user — if any script suddenly starts failing auth partway through, the lab session likely needs restarting and `aws configure` re-run with the new temporary credentials it gives you. No region is set by default either; every script here defaults `AWS_REGION` to `us-east-1` (Academy labs are commonly restricted to this region) — override via the env var if yours differs.
4. An AWS account on the free tier / a promotional credit — see the sizing/cost appendix at the end before picking an instance type, though the defaults here are already chosen with a $50 credit in mind.
5. **SSH is over AWS Systems Manager Session Manager, not a direct connection to port 22** (#116 — a plain IP-restricted security-group rule kept breaking as the operator's public IP rotated). One-time setup:
   - Install the [`session-manager-plugin`](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) for your OS — it's what `aws ssm start-session` (and the SSH `ProxyCommand` below) actually shells out to.
   - Add this to your **own** `~/.ssh/config` (not a project file — this only transparently covers the `ssh`/`rsync`/`scp` commands below if it's the config SSH already reads):
     ```
     Host i-* mi-*
         ProxyCommand sh -c "aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p'"
         User ec2-user
         IdentityFile ~/.ssh/4u-phase1-key.pem
         StrictHostKeyChecking accept-new
     ```
     `StrictHostKeyChecking accept-new` matters here specifically: connecting by instance ID means a brand-new `known_hosts` entry every time an instance is replaced, and the default `ask` behavior would hang the first non-interactive `rsync`/`scp` run (no TTY to answer the prompt).
   - This needs the instance to carry an IAM instance profile with `AmazonSSMManagedInstanceCore` attached. On an AWS Academy Learner Lab account, the pre-existing `LabInstanceProfile` already has this — `provision.sh` uses it by default (`IAM_INSTANCE_PROFILE` to override, e.g. on a non-Academy account, which would need its own role+instance-profile with that managed policy attached).

All four scripts below read their config from environment variables (sensible defaults baked in, nothing to edit) and are run from this directory.

## Deploying for the first time

### 1. `./provision.sh`

```
./provision.sh
```

This one command creates everything:

- **A security group** — HTTPS on 80/443 open to everyone (nothing else is reachable — the 6 backend services stay internal, same as local `docker compose`; see the HTTPS note below for why 8000 isn't opened anymore). **No inbound SSH port at all** — see #116 below.
- **An SSH key pair — this is where `~/.ssh/4u-phase1-key.pem` comes from.** AWS requires a key pair to exist before an instance can use one, so the first time this runs it calls `aws ec2 create-key-pair` and saves the private key to `~/.ssh/4u-phase1-key.pem` (outside the repo — `KEY_OUTPUT_DIR` if you want it elsewhere). AWS hands back the private key exactly once at creation time and never lets you download it again, so treat that `.pem` file as something to keep safe, not something to regenerate casually. Every later run of `provision.sh` reuses the same key pair instead of making a new one. It's still used for SSH auth — only the *transport* changed (see below).
- **SSH over SSM, not a direct port — issue #116.** A plain security-group rule restricted to the operator's current public IP kept breaking as that IP rotated (confirmed live, repeatedly, within minutes on one connection). `provision.sh` instead attaches an IAM instance profile (`IAM_INSTANCE_PROFILE`, defaults to the AWS Academy-provided `LabInstanceProfile`) at launch and installs/enables `amazon-ssm-agent` via user-data, so the instance registers with AWS Systems Manager Session Manager — reachable from anywhere by IAM authorization, no inbound port needed. **This can only be set at launch**, not retrofitted onto an already-running instance (confirmed live: `ec2:AssociateIamInstanceProfile` is explicitly denied for the student role on an Academy account) — if you're migrating an existing instance onto this, terminate it first (not `delete.sh` — that also releases the Elastic IP) and let `provision.sh` launch a fresh one. See Prerequisites above for the one-time local setup (`session-manager-plugin` + an SSH config block) this needs.
- **A static Elastic IP**, allocated and attached to the instance. EC2's default public IP is *not* permanent — it changes on every stop/start cycle (confirmed live) — so without this, `application/.env` would need hand-editing after every restart. Set `ALLOCATE_EIP=false` if you'd rather skip this and manage the IP yourself — HTTPS setup (below) needs a stable IP, so it's skipped entirely when this is off.
- **HTTPS, via a free domain and automatic Let's Encrypt — issue #92.** `provision.sh` derives `DOMAIN=<ip-with-dashes>.sslip.io` from the Elastic IP — [sslip.io](https://sslip.io) is a free public DNS service that resolves `34-201-1-2.sslip.io` straight back to `34.201.1.2`, so there's no domain to buy and no Route53 access needed (handy since AWS Academy Learner Lab accounts commonly restrict Route53). It's on the Public Suffix List, so Let's Encrypt's rate limits apply per-derived-subdomain, not against a shared parent domain — repeated provisioning here won't collide with anyone else using sslip.io. Because the domain is *derived from* the IP rather than *pointed at* it, a `delete.sh` + re-`provision.sh` cycle (new IP) needs no manual DNS fix-up — the new domain just falls out of the new IP. `provision.sh` writes `API_GATEWAY_URL=https://$DOMAIN` into `application/.env` and `DOMAIN`/`COMPOSE_PROFILES=https` into `deployment/phase1-ec2/.env` (copied to the instance in step 3) — nothing to configure by hand. TLS termination is `caddy`, a new service in `docker-compose.yml` (gated behind the `https` Compose profile so it never starts during local dev or CI) that reverse-proxies to the existing `gateway` and gets a real certificate automatically, at no extra AWS cost (no ALB, no ACM, no Route53).
- **The instance itself** — `t3.medium`, a 20GB disk, and Docker + the Compose plugin + `buildx` + `rsync` installed via user-data. Two real things worth knowing, both only found by actually deploying this once: the Amazon Linux 2023 AMI's *default* root disk is just 2GB, which fills up completely partway through building 6 Docker images (confirmed live: `No space left on device`) — that's why 20GB is requested explicitly (`ROOT_VOLUME_GB` to change it). And AL2023's base `docker` package doesn't include a recent enough `buildx` for `docker compose build`, and doesn't include `rsync` at all — both are installed by user-data alongside Docker for exactly that reason.

Takes a couple of minutes (a bit longer than before — user-data now also installs the SSM agent); prints the instance id, the Elastic IP, the HTTPS domain, and the SSH command to use next (by instance id, over SSM). Safe to re-run against an already-provisioned instance too — it detects the existing instance (by its `Name` tag) and re-applies the security-group/HTTPS migration to it instead of launching a second one (though see the SSH-over-SSM bullet above — an *existing* instance from before #116 won't gain SSM access without being replaced).

### 2. Wait for the instance to finish bootstrapping

User-data (installing Docker/buildx/rsync/the SSM agent) takes a minute or two after `provision.sh` reports the instance as running. Confirm SSM has registered it (re-run `provision.sh` once this shows the instance, to clean up any stale port-22 rules):

```
aws ssm describe-instance-information --filters "Key=InstanceIds,Values=<instance-id>"
```

Then confirm the instance itself is ready:

```
ssh ec2-user@<instance-id> "docker --version && docker buildx version && rsync --version"
```

### 3. Copy the repo over

Only what the stack actually needs — `docker-compose.yml`, `gateway/`, `packages/`, and the 6 `backend-*/` directories (each already has its real, populated `.env` with Supabase Cloud/Qdrant Cloud credentials). The Flutter `application/` directory doesn't run on the server, so it's deliberately left out:

```
ssh ec2-user@<instance-id> "mkdir -p ~/4u"
rsync -avz -e ssh \
  --exclude '.venv' \
  docker-compose.yml gateway packages backend-ai-training backend-data-collection backend-map-management backend-navigation-management backend-route-management backend-user-management \
  ec2-user@<instance-id>:~/4u/
```

Run from the repo root. **No trailing slashes on the directory names** — confirmed live that adding them (e.g. `gateway/` instead of `gateway`) makes rsync copy each directory's *contents* into a shared destination, flattening and overwriting everything into one directory instead of preserving `gateway`, `packages`, etc. as their own subdirectories. `--exclude '.venv'` matches at any depth, so each service's own `.venv` is skipped either way.

Also copy `provision.sh`'s `DOMAIN`/`COMPOSE_PROFILES` file up, **renamed to `.env` at the instance's repo root** (docker compose auto-loads a root `.env` for every invocation — that's deliberate here, see `provision.sh`'s comments for why the local copy deliberately isn't named `.env` on your own machine):

```
scp deployment/phase1-ec2/.env ec2-user@<instance-id>:~/4u/.env
```

### 4. Build and start the stack

```
ssh ec2-user@<instance-id>
cd ~/4u
sudo docker compose up --build -d
```

`sudo` is needed here even though user-data added `ec2-user` to the `docker` group — that only takes effect in a *new* login session, not the one you're already SSHed into right after provisioning. (Log out and back in, or just use `sudo`, which is simpler.)

This same command now also starts `caddy` — no separate command to remember. It reads `COMPOSE_PROFILES=https` from the `.env` step 3 copied into `~/4u/`, which is what turns the `profiles: ["https"]`-gated `caddy` service on (plain `docker compose up`, like CI and local dev use, never starts it). Give it a few seconds after first start for Caddy to obtain its Let's Encrypt certificate — `sudo docker compose logs caddy` if an HTTPS request doesn't work right away.

### 5. Verify it's reachable — from your own machine, not just inside the instance

```
curl https://<domain>/map/
curl https://<domain>/route/
curl https://<domain>/user/
curl https://<domain>/navigation/
curl https://<domain>/data-collection/
curl https://<domain>/ai-training/
```

(`<domain>` is the `sslip.io` hostname `provision.sh` printed, e.g. `34-201-1-2.sslip.io` — same thing `application/.env`'s `API_GATEWAY_URL` now points at.) Each is a service's `GET /` health check, proxied through Caddy then the gateway (see `gateway/nginx.conf` for the full path-prefix list). Confirmed live: all 6 respond `200 OK` once the stack settles — **if the very first request to any endpoint 502s or 504s, just retry once.** Two real, harmless timing issues found by actually doing this: nginx can briefly resolve a backend before it's fully listening right after `docker compose up -d` (502, self-resolves in a few seconds); and the very first real `/search_similar`/`/index_anchor` call anywhere downloads EfficientNet-B0's pretrained weights (~20.5MB) from `download.pytorch.org` at runtime, which took ~2.5 minutes on this connection and exceeded nginx's default 60s timeout (504 the first time, 200 OK on retry). Neither is fixed here — just don't mistake either for a real failure.

### 6. `application/.env` is already done

No extra step — step 1's write already put the right `API_GATEWAY_URL=https://<domain>` in place. The app is ready to point at this deployment as soon as step 5 passes.

## Redeploying once everything above is already set up

The fast path — AWS CLI, credentials, the key pair, security group, and Elastic IP all already exist from a previous `provision.sh` run:

- **Resuming after `stop.sh`**: run `./start.sh`. Every service has `restart: unless-stopped`, so the containers come back on their own once Docker finishes starting on the instance — no SSH step needed in the common case. `start.sh` prints the IP — it's the same permanent Elastic IP (and so the same HTTPS domain) as before, so neither `application/.env` nor `~/4u/.env` need touching again, and Caddy's already-issued certificate is still valid (it's on the `caddy_data` named volume, which also survives the reboot). If something didn't come back for any reason, the fallback is the same as always — no `--build` needed, the already-built images survive on disk:
  ```
  ssh ec2-user@<instance-id> "cd ~/4u && sudo docker compose up -d"
  ```
- **Pulled new code and want it live**: repeat step 3's `rsync`/`scp` commands, then step 4's `sudo docker compose up --build -d` again, on the already-running instance.
- **Done testing for now**: `./stop.sh` — pauses compute billing, everything on disk (and the Elastic IP) survives.

## Tearing down completely

```
./delete.sh
```

Permanently terminates the instance, releases the Elastic IP (it has its own small ongoing cost if left allocated and unattached — not worth keeping around once you're done), and deletes the security group. Asks for confirmation first. The SSH key pair is left alone — `provision.sh` will reuse it for the next instance, but that next instance will get a **new, different** Elastic IP, and therefore a **new** `sslip.io` HTTPS domain (both automatically re-written into `application/.env`/`deployment/phase1-ec2/.env` — no manual DNS to fix up, see step 1's HTTPS note), and the manual repo-copy + build steps above need doing again from scratch.

## Appendix: instance sizing & cost

Issue #90 asked for sizing to be validated, not assumed. Real measurement (local build + a real `t3.medium`, `docker stats`/`free -h`, predating #92's `caddy` sidecar): the 7 containers together use **~800MB** under light real use (the `ai-training` container, which loads a PyTorch model, is the largest single one at ~420-440MB). `caddy` (Alpine-based, no app runtime) adds only a few MB on top of that. That's application memory only — add OS/Docker overhead and it's already at or past 1GB, which is why the true free-tier types (`t2.micro`/`t3.micro`, 1GB) are very likely too small, especially to *build* on (installing `torch`/`torchvision`/`opencv-python-headless` is more memory- and disk-hungry than steady-state running — see step 1's disk note above). `provision.sh` defaults to `t3.medium` (4GB) for headroom on both.

Approximate on-demand pricing, commonly-cited region (not independently verified live — check current rates in your AWS billing view): `t3.micro` ≈ $0.0104/hr, `t3.small` ≈ $0.0208/hr, `t3.medium` ≈ $0.0416/hr. Even 100 hours at `t3.medium`'s rate is about $4 — comfortably inside a $50 credit, especially combined with `stop.sh` between sessions. To stretch the credit further once the images are already built:

```
./stop.sh
aws ec2 modify-instance-attribute --instance-id <id> --instance-type t3.small
./start.sh
```

(Only works while stopped. `t3.small` is 2GB — enough to *run* the already-built stack, not to rebuild it; resize back to `t3.medium` temporarily for any future `--build`.)
