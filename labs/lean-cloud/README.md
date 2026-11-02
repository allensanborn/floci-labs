# lean-cloud

> [lean-cloud](https://github.com/palladin/lean-cloud) — distributed programming for
> Lean 4, with proofs that replay after a crash returns the same answer — running its
> demos, its own test suites and its AWS provisioning against local Floci. Nothing in
> lean-cloud is modified. This README is also the test.

## The short version

**Lean** is a programming language that can also check mathematical proofs. You write
an ordinary program in it, then a proof about that program, and the compiler checks the
proof the same way it checks types. Mathematicians use it to formalize mathematics
([Mathlib](https://github.com/leanprover-community/mathlib4) is their shared library).
Programmers use it to write code that comes with guarantees.
[lean-lang.org](https://lean-lang.org/) has the full story.

**lean-cloud** lets a Lean program spread its work across many machines. You write

```lean
cloud {
  let counts ← Cloud.parallel (files.map fun name => Cloud.exec fun env => countErrors name)
  ...
}
```

and each piece inside `Cloud.parallel` can run on a different worker. The workers share
an S3 bucket. Whenever a worker finishes a step, it writes a small record there saying
"I did this step, and here is the answer". The write only succeeds if no record exists
yet, so two workers can never both claim the same step. A worker that crashes and comes
back reads its records and carries on instead of starting over.

The interesting part is that lean-cloud doesn't just promise this. It ships Lean proofs
(`restarting_parallel_replay_matches_direct` and two sibling theorems) showing that, for
pure programs, running in parallel, and even crashing and restarting, gives exactly the
same answer as running everything in one place.

**This lab** runs all of that on [Floci](https://floci.io/), a free AWS emulator that
runs on your laptop, and changes nothing in lean-cloud:

1. **The storage part.** Floci stands in for S3, and lean-cloud's own test suites pass
   against it. A demo job counts errors across 16 log files on 3 workers and gets the
   answer lean-cloud's docs give. Then we kill a worker halfway through. The job waits;
   the worker comes back, reads its records from Floci, and the job finishes with the
   same answer.
2. **The cloud part.** lean-cloud ships real scripts that set it up on AWS: a network,
   permissions, a Kubernetes cluster (EKS), an image registry (ECR) and a bucket, 28
   resources in all. We run those scripts against Floci, push the image, start
   lean-cloud as pods inside Floci's Kubernetes, run the same job there, and tear it all
   down.

In one sentence: **a distributed runtime that comes with crash-safety proofs, set up by
its own real AWS scripts (S3, IAM, EKS, ECR), runs end to end on a laptop with no AWS
account, and you can kill a worker mid-job and still get the right answer.**

The crash demo shows the runtime doing what the proofs describe; it does not prove
anything itself. The demo job reads and writes files, and the theorems cover pure
programs.

### Where lean-cloud comes from

lean-cloud is new: its repository was created in September 2026. Its author, Nick
Palladinos, co-wrote [MBrace](https://en.wikipedia.org/wiki/MBrace), an F# framework
from 2013 whose "cloud workflows" (`cloud { ... }` blocks, parallel combinators, and a
runtime that schedules them across a cluster) are described in
[*MBrace: Cloud Computing with Monads*](https://doi.org/10.1145/2525528.2525531)
(PLOS '13, [slides](https://es.slideshare.net/petrogiannakispantelis/mbrace-plosslides-final)).
lean-cloud returns to that idea in a language that can prove things about it. It is
built on the same author's [lean-eff](https://github.com/palladin/lean-eff), a library
of extensible effects. Another library by the same author,
[lean-reducers](https://github.com/palladin/lean-reducers), provides parallel folds.

Mentions elsewhere, as of 2026-11-02:

- The [Awesome Lean Programming](https://leangineer.com/awesome/) list: "Parallel and
  distributed programming with monadic workflows over shared blob storage".
- A [Hacker News submission](https://news.ycombinator.com/item?id=50326459) on
  2026-11-01, which the [*Daily Diff*](https://github.com/arpitbbhayani/the-daily-diff)
  digest included in its 2026-11-01 edition.

We found no blog posts, talks or discussion threads about it yet, so this lab may be the
first write-up that runs it.

## What it shows

- **A non-SDK S3 client on Floci.** lean-cloud's runtime has no AWS SDK: it signs its
  own requests through libcurl's `--aws-sigv4`, writes replay records with
  `PUT` + `If-None-Match: *` (several workers race for the same key, exactly one may
  win), and parses `ListObjectsV2` with `encoding-type=url` by hand. Floci is its blob
  store here instead of the SeaweedFS container the upstream compose file runs.
- **lean-cloud's own tests, pointed at Floci:** its storage contract check
  (`cloud_storage_tests`) and its integration suite (`cloud_integration_tests`, what its
  CI runs) both pass unchanged.
- **The bundled workflows:** `log-summary` fans 16 log files out over 3 workers and
  returns `files=16, errors=24`, the answer lean-cloud's docs promise. `sum-squares`
  returns `29`.
- **Crash and resume.** Kill a worker mid-run and the run waits; restart it and the worker
  resumes the same assignment from the replay records it left in Floci, with the same answer.
- **Its whole AWS walkthrough.** `deploy/aws.sh` and its OpenTofu root create a VPC,
  IAM roles, an EKS cluster with a node group, add-ons and pod identity associations,
  an ECR repository and an encrypted S3 bucket. All 28 resources apply. The image goes
  into Floci's ECR, `aws.sh configure` pins its digest, and `kubernetes.sh up` runs the
  scheduler and three workers as pods on the k3s node Floci runs behind the cluster.
  `log-summary` then runs **inside that cluster** against the provisioned bucket, and
  `aws.sh destroy` passes its own post-checks.

## Stack

- **Language / runtime:** Lean 4 (built inside Docker, no local Lean needed), Bash
- **AWS services:** S3 (runtime); EKS, EC2/VPC, IAM, ECR, S3, STS (provisioning)
- **Tooling:** Docker with Buildx, AWS CLI v2, OpenTofu >= 1.10, kubectl, jq,
  `mechanical-markdown` for the README test

---

## Run it

Floci on `localhost:4566` with the Docker socket mounted (EKS is a real k3s container,
ECR a real registry) and `FLOCI_SERVICES_EKS_DEFAULT_STORAGE_CLASS=true`, so the cluster
can bind disks. [`docker-compose.yml`](docker-compose.yml) starts one like that. Set
`AWS_ENDPOINT_URL` to use another Floci, and `FLOCI_PORT` to move the compose one off 4566.

<!-- STEP
name: Start Floci
expected_stdout_lines:
  - 'Floci is up'
output_match_mode: substring
timeout_seconds: 300
-->

```bash
ENDPOINT=${AWS_ENDPOINT_URL:-http://localhost:4566}
if ! curl -sf "$ENDPOINT/_floci/health" > /dev/null 2>&1; then
  export FLOCI_PORT=${ENDPOINT##*:}
  docker compose -f docker-compose.yml up -d
  for _ in $(seq 1 60); do curl -sf "$ENDPOINT/_floci/health" > /dev/null && break; sleep 2; done
fi
curl -sf "$ENDPOINT/_floci/health" > /dev/null && echo "Floci is up"
```

<!-- END_STEP -->

`build.sh` clones lean-cloud at a pinned commit into `.work/` and builds its images with
its own `deploy/build.sh` and Dockerfile targets. The first build compiles Lean and its
dependencies: allow 15–30 minutes. Later builds come from Docker's cache.

<!-- STEP
name: Build lean-cloud
expected_stdout_lines:
  - 'lean-cloud at 0ab87f0'
  - 'images built'
output_match_mode: substring
timeout_seconds: 3600
-->

```bash
./build.sh
```

<!-- END_STEP -->

### Act 1 — the runtime, with Floci as its blob store

<!-- STEP
name: Run lean-cloud on Floci
expected_stdout_lines:
  - 'Storage contract and 8 direct/replay/warm-replay comparisons passed.'
  - 'Real adapters: pool terminal failure/recovery'
  - 'scheduler and 3 workers healthy'
  - 'log-summary on Floci: files=16, errors=24'
  - 'restarted worker2 resumed from its replay records in Floci: files=16, errors=24'
  - 'sum-squares [2,3,4] = 29'
  - 'lean-cloud runs on Floci.'
output_match_mode: substring
timeout_seconds: 900
-->

```bash
./run.sh
```

<!-- END_STEP -->

### Act 2 — lean-cloud's AWS walkthrough, on Floci's EKS

<!-- STEP
name: Provision, deploy into EKS, run, destroy
expected_stdout_lines:
  - 'Plan: 28 to add, 0 to change, 0 to destroy.'
  - 'Apply complete! Resources: 28 added, 0 changed, 0 destroyed.'
  - 'storageclass.storage.k8s.io/lean-cloud-floci-lab-gp3 created'
  - 'Ready'
  - 'aws.sh configure pinned image @sha256:'
  - 'pod worker3-0 Running'
  - "log-summary in Floci's EKS: files=16, errors=24"
  - 'Removed namespace lean-cloud and its node disks.'
  - 'AWS infrastructure removed.'
  - 'lean-cloud provisions and tears down its AWS stack on Floci.'
output_match_mode: substring
timeout_seconds: 1800
-->

```bash
./infra.sh
```

<!-- END_STEP -->

### Clean up

<!-- STEP
name: Clean up
expected_stdout_lines:
  - 'teardown complete'
output_match_mode: substring
timeout_seconds: 300
-->

```bash
./teardown.sh
```

<!-- END_STEP -->

---

## How it works

### The only change: one config block

lean-cloud's runtime reads one JSON config. `run.sh` takes lean-cloud's own template,
`deploy/config.json`, and replaces its `blobs` block:

```json
{"provider": "s3", "endpoint": "http://host.docker.internal:4566", "bucket": "lean-cloud-lab",
 "region": "us-east-1", "authentication": {"kind": "keys", "accessKey": "test", "secretKey": "test"}}
```

[`nodes.compose.yaml`](nodes.compose.yaml) is lean-cloud's local topology (a scheduler
and three workers, each with its own HTTP inbox and SQLite database) minus the SeaweedFS
container. The scheduler takes requests on one endpoint, `POST /deployment`. `run.sh`
calls it with curl, the same JSON the `lean_cloud` console sends, so the lab doesn't have
to build the console.

### What lean-cloud needs from S3

The client is [`runtime/LeanCloudRuntime/S3.lean`](https://github.com/palladin/lean-cloud/blob/0ab87f0/runtime/LeanCloudRuntime/S3.lean),
160 lines. Its whole contract with the object store:

| Request | What must hold |
|---|---|
| `PUT /bucket` | 2xx, or 409 when it exists |
| `PUT /bucket/key` + `If-None-Match: *` | One writer wins. Every other writer gets 412 (or 409) and the object is **not** overwritten. Replay records and content-addressed blobs depend on this. |
| `GET` / `HEAD /bucket/key` | 404 when missing; `HEAD` carries `Content-Length` |
| `GET /bucket?list-type=2&encoding-type=url&max-keys=128&prefix=…` | `<KeyCount>` matches the `<Key>` elements; `/` in keys arrives as `%2F` |
| `DELETE /bucket/key` | 2xx, or 404 |

Requests are path-style and signed by libcurl (`--aws-sigv4 aws:amz:<region>:s3`), so
this is a different client from any SDK. Floci passes all of it, including 32 concurrent
conditional writers per key with exactly one 200.

### Crash and resume

The crash in `run.sh` uses `docker compose kill`, so Docker does not restart the worker.
lean-cloud does not hand the assignment to another worker: a worker's identity is
durable, its inbox lives on its own disk, and its replay records are in shared storage.
This is the design in
[ReplayRecovery.md](https://github.com/palladin/lean-cloud/blob/0ab87f0/LeanCloud/ReplayRecovery.md),
where a crash retries the same assignment with its surviving records. So the run waits.
When worker2 comes back it replays from what it had already written to Floci and
finishes with the same result.

### The AWS act

`infra.sh` makes an AWS CLI profile named `lean-cloud` (the default `aws.sh` uses) whose
`endpoint_url` is Floci. It then follows
[lean-cloud's AWS guide](https://github.com/palladin/lean-cloud/blob/0ab87f0/deploy/AWS.md)
step by step: `aws.sh init`, `plan`, `create`, push, `configure`, `kubernetes.sh up`,
connect, run, `kubernetes.sh clean`, `aws.sh destroy-plan` and `destroy`. Its deviations
from the guide:

| Guide step | What `infra.sh` does instead, and why |
|---|---|
| `aws.sh publish` | `docker push` to the same repository through Floci's path-style alias, `localhost:<port>/<account>/<region>/<repo>`. With the containerd image store (the default from Docker Engine 29), the daemon reaches only `localhost` and `127.0.0.1` over plain HTTP, so the `<account>.dkr.ecr.<region>.localhost` name that `publish` pushes to needs TLS. `aws.sh configure` then finds the image through ECR as usual. |
| `deployment.json` `storageClass` | `local-path`, not the EBS class `create` made. Floci records the `aws-ebs-csi-driver` add-on but does not provision volumes. This is a setting the guide says to review before the first `up`. |
| `storage.json` | `endpoint` is Floci's address on the cluster's VPC network (Floci joins that Docker network), and `authentication` is `keys`. lean-cloud accepts the pod identity agent only at `169.254.170.23`, and Floci injects pod identity only when TLS is on. |

Everything else, from the 28 resources to the pods pulling their image by digest through
the cluster's ECR mirror, is lean-cloud's code doing what it does on AWS. Two more
things are worth knowing:

- **kubectl needs a key Floci issued.** `aws eks get-token` makes a presigned STS URL, and
  Floci's EKS token webhook checks its signature against keys it knows. The blanket
  `test`/`test` key is not one of them, so `infra.sh` creates an IAM user and uses that
  user's access key.
- **Edit `storage.json` only before the first `up`.** lean-cloud records a hash of it
  in the cluster, and both `up` and `clean` refuse a deployment whose blob storage
  changed. `clean` refusing as well means that, once you have edited it, you have to put
  the old file back before you can clean up.
- **`aws.sh destroy` checks its own work.** It refuses while tagged EBS volumes remain,
  then verifies that the state is empty, the EKS cluster is gone and the tagged VPC is
  gone. Floci passes those checks too.

## What Floci supports here, and what it doesn't

Measured against `floci/floci:nightly-11012026`, `nightly-10312026` and `latest` (2.4.0).

| | Status |
|---|---|
| `aws eks describe-cluster-versions` is not implemented (`Unknown operation: GET /cluster-versions`) | Stops `aws.sh init`, which pins the newest version in standard support. Until a fix is released, `infra.sh` writes the same `aws.tfvars.json` that `init` would have written, and says so. |
| `ec2 describe-instance-types` returns nothing for `m7g.large` (Graviton3, lean-cloud's default) | `init` derives the architecture and worker zone from it. The catalog has 25 types, and plain `m7g` is not among them. |
| `aws_eks_cluster.upgrade_policy` is dropped, so every plan shows a diff | Reported upstream as [floci-io/floci#5640](https://github.com/floci-io/floci/issues/5640). `infra.sh` accepts exactly this drift and fails on any other. |
| `aws.sh destroy` sometimes waits forever on `aws_vpc.cloud` | Floci has already deleted the VPC and its Docker network, but OpenTofu's `DeleteVpc` connection stays open with no reply. Seen in 4 of 7 full runs on `nightly-11012026`; the cause is not identified yet. `infra.sh` waits 4 minutes, checks with Floci that the VPC is gone, stops that run and destroys again, and says so with a `gap` line. |
| ECR `docker login` and `docker push` return 503, and `delete-repository --force` fails with "Backing registry unreachable" | Seen on `floci:latest` (2.4.0) and `nightly-10312026`; works on `nightly-11012026`. The only ECR change in between is [floci-io/floci#7224](https://github.com/floci-io/floci/pull/7224). `docker-compose.yml` pins that nightly until a release includes it. |

### Left to Floci

To run the guide with no deviations at all, Floci would need:

- **The two `init` calls:** `describe-cluster-versions`, and `m7g` in the instance catalog.
- **`upgrade_policy`** stored and returned ([#5640](https://github.com/floci-io/floci/issues/5640)).
- **An HTTPS ECR name by default**, or a Docker daemon that trusts Floci's CA, so
  `aws.sh publish` can push to the `repositoryUri` itself.
- **Volumes behind the EBS CSI add-on**, so lean-cloud's `gp3` StorageClass binds.
- **Pod identity at `169.254.170.23`**, so pods can use `podIdentity` instead of keys.

## This README is the test

```bash
python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt
./validate.sh
```

[mechanical-markdown](https://github.com/dapr/mechanical-markdown) runs every `STEP` above
and checks its output against the lines listed in it. `validate.sh` exits `0` when the
README held, `1` when something did not match, and `2` when it could not run at all
(missing tool, no Floci). A skip must never look like a pass.

## Try changing...

- **Break the conditional write.** Point `run.sh` at an S3 that ignores `If-None-Match`
  and watch `cloud_storage_tests` refuse it. That property carries lean-cloud's replay
  correctness.
- **Kill the scheduler instead of a worker.** Its state is SQLite on its own volume, so
  `docker compose -f nodes.compose.yaml restart scheduler` mid-run should still finish.
- **More workers.** Add `worker4` to `nodes.compose.yaml` and to `mailboxes.workers` in
  `.work/config.json`; `log-summary` has 8 batches to spread.

## Credit

[lean-cloud](https://github.com/palladin/lean-cloud) by Nick Palladinos, MIT licensed.
This lab pins it at
[`0ab87f0`](https://github.com/palladin/lean-cloud/commit/0ab87f003faa756e5dd75c7832d7a4f788f0b931)
and changes none of its files.

## Author

Allen Sanborn ([@allensanborn](https://github.com/allensanborn))
