FROM --platform=linux/amd64 quay.io/centos/centos:stream9 AS builder

ARG ISO_URL ISO_FILE_NAME ISO_CHECKSUM AGENT_IMAGE AGENT_TAG REGISTRY ORG

USER root

# Copy the configuration script into the container
COPY iso_builder/build-ove-image.sh /tmp/

RUN chmod +x /tmp/build-ove-image.sh

RUN dnf -y update; micro-dnf -y reinstall shadow-utils; \
dnf -y install podman runc ; \
rm -rf /var/cache /var/log/dnf* /var/log/yum.*

# Use runc as containers engine
RUN mkdir -p /etc/containers/ && \
  echo "[engine]" >> /etc/containers/containers.conf && \
  echo "runtime=\"runc\"" >> /etc/containers/containers.conf

# Do the postprocessing step to generate the OVE ISO
RUN dnf install -y xorriso skopeo rsync syslinux \
 && dnf clean all

# Download the ISO
RUN curl -L --fail --show-error --progress-bar -o /${ISO_FILE_NAME} ${ISO_URL}

# Verify checksum
RUN echo "${ISO_CHECKSUM}  /${ISO_FILE_NAME}" | sha256sum -c -

# Create output directory
RUN mkdir -p /output

# Run the build script with the downloaded ISO file and config values
RUN /tmp/build-ove-image.sh \
    --iso-file /${ISO_FILE_NAME} \
    --dir / \
    --output-file /output/agent.iso \
    --agent-image ${AGENT_IMAGE} \
    --agent-tag ${AGENT_TAG} \
    --registry ${REGISTRY} \
    --org ${ORG} \
    && rm /${ISO_FILE_NAME} && rm -rf /isomnt

# Final stage with minimal image
FROM --platform=linux/amd64 registry.access.redhat.com/ubi9/ubi-minimal AS final

ARG ISO_FILE_NAME

COPY --from=builder /output/agent.iso /${ISO_FILE_NAME}

ENTRYPOINT ["/bin/bash"]