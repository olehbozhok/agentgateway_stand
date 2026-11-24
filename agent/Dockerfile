# The e2e agent: runs in the OpenShell sandbox, and once without it as the control run.
# Same base image as OpenShell's default sandbox image.
FROM nvcr.io/nvidia/base/ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# /usr/local/bin is readable under OpenShell's default filesystem policy; /opt is not.
COPY --chmod=755 agent.py /usr/local/bin/agent.py

# Non-root also outside the sandbox (the control run); OpenShell runs it as uid 1000 anyway.
USER ubuntu
# No ENTRYPOINT: OpenShell runs the command given to `sandbox create` as the main process.
CMD ["python3", "/usr/local/bin/agent.py", "run"]
