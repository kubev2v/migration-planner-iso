#!/bin/bash

# Fail on unset variables and errors
set -euo pipefail

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

export DIR_PATH=""
export RHCOS_URL=""

#
# Parse command line arguments
#
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --rhcos-url)
                RHCOS_URL="$2"
                shift 2
                ;;
            --dir)
                DIR_PATH="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

#
# Show usage information
#
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Agent-based Installer OVE ISO Builder

This script creates an agent-based installer OVE ISO by extracting RHCOS ISO contents,
adding agent installer artifacts, and creating a bootable hybrid ISO image.

OPTIONS:
    --rhcos-url URL         URL to download RHCOS ISO (optional)
    --dir PATH              Working directory path (default: /tmp/iso_builder)
    -h, --help              Show this help message

ENVIRONMENT VARIABLES:
    RHCOS_URL               URL to download RHCOS ISO if not found locally
    DIR_PATH                Working directory path (overridden by --dir)

EXAMPLES:
    # Basic usage (expects RHCOS ISO to exist or RHCOS_URL env var set)
    $(basename "$0")

    # Specify RHCOS URL directly
    $(basename "$0") --rhcos-url https://example.com/rhcos.iso

    # Specify custom directory
    $(basename "$0") --dir ~/iso_work

    # Using environment variable
    RHCOS_URL=https://example.com/rhcos.iso $(basename "$0")

OUTPUTS:
    agent.iso               Bootable agent OVE ISO image

EOF
}

function setup_vars() {
    # Set default directory if not provided via parameter
    if [[ -z "$DIR_PATH" ]]; then
        DIR_PATH="/tmp/iso_builder"
    fi
    
    ove_dir="${DIR_PATH}/ove"
    rhcos_work_dir="${DIR_PATH}"
    mkdir -p "${DIR_PATH}"
    mkdir -p "${rhcos_work_dir}"

    work_dir="${ove_dir}/work"
    output_dir="${ove_dir}/output"
    agent_ove_iso="${output_dir}"/agent.iso

    mkdir -p "${output_dir}"
}

function download_rhcos_iso() {
    if [[ -z "${RHCOS_URL:-}" ]]; then
        echo "Error: RHCOS_URL is not set. Cannot download rhcos.iso."
        echo "Please either:"
        echo "  1. Set RHCOS_URL environment variable to download the ISO"
        echo "  2. Manually place rhcos.iso in ${rhcos_work_dir}/"
        exit 1
    fi

    echo "Downloading RHCOS ISO from: ${RHCOS_URL}"
    echo "Saving to: ${rhcos_work_dir}/rhcos.iso"
    
    # Create directory if it doesn't exist
    mkdir -p "${rhcos_work_dir}"
    
    # Download with curl, showing progress
    if ! curl -L --fail --show-error --progress-bar -o "${rhcos_work_dir}/rhcos.iso" "${RHCOS_URL}"; then
        echo "Error: Failed to download RHCOS ISO from ${RHCOS_URL}"
        exit 1
    fi
    
    echo "Successfully downloaded RHCOS ISO"
}

function extract_live_iso() {
    local rhcos_mnt_dir="${rhcos_work_dir}/isomnt"
    if [ -d "${rhcos_mnt_dir}" ]; then
        echo "Skip extracting RHCOS ISO. Reusing ${rhcos_mnt_dir}."
    else
        echo "Extracting ISO contents..."
        mkdir -p "${rhcos_mnt_dir}"

        if [ ! -f "${rhcos_work_dir}"/rhcos.iso ]; then
            echo "RHCOS ISO not found at ${rhcos_work_dir}/rhcos.iso"
            download_rhcos_iso
        fi
        # Mount the ISO when not in a container
        if [ ${rhcos_work_dir} != '/' ]; then
            $SUDO mount -o loop "${rhcos_work_dir}"/rhcos.iso "${rhcos_mnt_dir}"
        fi
    fi
    if [ -d "${work_dir}" ]; then
        echo "Skip copying extracted RHCOS ISO contents to a writable directory. Reusing ${work_dir}."
    else
        mkdir -p "${work_dir}"
        if [ ${rhcos_work_dir} == '/' ]; then
            # Use osirrox to extract the ISO without mounting it
            $SUDO osirrox -indev "${rhcos_work_dir}"/rhcos.iso -extract / "${rhcos_mnt_dir}"
        fi
        echo "Copying extracted RHCOS ISO contents to a writable directory."
        $SUDO rsync -aH --info=progress2 "${rhcos_mnt_dir}/" "${work_dir}/"
        $SUDO chown -R $(whoami):$(whoami) "${work_dir}/"
        if mountpoint -q ${rhcos_mnt_dir}; then
            $SUDO umount ${rhcos_mnt_dir}
        fi
    fi
    volume_label=$(xorriso -indev "${rhcos_work_dir}"/rhcos.iso -toc 2>/dev/null | awk -F',' '/ISO session/ {print $4}' | xargs)
}

function setup_agent_artifacts() {
    local image=migration-planner-agent
    local image_dir="${work_dir}"/images/"${image}"
    local pull_spec="quay.io/redhat-user-workloads/assisted-migration-tenant/${image}:213e597ae9b6d7cff7adddb8dc2e87f9dcc03dcc"

    if [ ! -f "${image_dir}"/"${image}".tar ]; then
        mkdir -p "${image_dir}"
        $SUDO skopeo copy -q docker://"${pull_spec}" oci-archive:"${image_dir}"/"${image}".tar
    else
        echo "Skip pulling image. Reusing ${image_dir}/${image}.tar."
    fi
}

function create_ove_iso() {
    if [ ! -f "${agent_ove_iso}" ]; then
        local boot_image="${work_dir}/images/efiboot.img"
        if [ -f "${boot_image}" ]; then
            local size=$(stat --format="%s" "${boot_image}")
            # Calculate the number of 2048-byte sectors needed for the file
            # Add 2047 to round up any remaining bytes to a full sector
            local boot_load_size=$(( (size + 2047) / 2048 ))
        else
            echo "Error: Clean /tmp/iso_builder directory."
            exit 1
        fi

        echo "Creating ${agent_ove_iso}."
        xorriso -as mkisofs \
        -o "${agent_ove_iso}" \
        -J -R -V "${volume_label}" \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -eltorito-alt-boot \
        -e images/efiboot.img \
        -no-emul-boot -boot-load-size "${boot_load_size}" \
        "${work_dir}"
    fi
}

function finalize()
{
    /usr/bin/isohybrid --uefi $agent_ove_iso
    echo "Generated agent based installer OVE ISO at: $agent_ove_iso"
    end_time=$(date +%s)
    elapsed_time=$(($end_time - $start_time))
    minutes=$((elapsed_time / 60))
    seconds=$((elapsed_time % 60))

    if [[ $minutes -gt 0 && $seconds -gt 0 ]]; then
        echo "ISOBuilder execution time: ${minutes}m ${seconds}s"
    fi
}

function build()
{
    # Parse command line arguments first
    parse_arguments "$@"
    
    start_time=$(date +%s)

    if [ "$(id -u)" -eq 0 ]; then
        SUDO=""
    else
        SUDO="sudo"
    fi

    setup_vars
    extract_live_iso
    setup_agent_artifacts
    create_ove_iso
    finalize

    # Remove directory to limit size of container
    rm -r ${work_dir}

    # Move to top-level dir for easier retrieval
    mv -v ${agent_ove_iso} ${rhcos_work_dir}

}

# Build agent installer OVI ISO
build "$@"
