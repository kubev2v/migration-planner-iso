FROM --platform=linux/amd64 registry.access.redhat.com/ubi9/ubi-minimal AS builder

ARG ISO_URL
ARG ISO_FILE_NAME
ARG ISO_CHECKSUM

# Download the ISO
RUN curl -L -o /${ISO_FILE_NAME} ${ISO_URL}

# Verify checksum
RUN echo "${ISO_CHECKSUM}  /${ISO_FILE_NAME}" | sha256sum -c -

ENTRYPOINT ["/bin/bash"]
