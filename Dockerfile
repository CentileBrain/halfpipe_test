# syntax=docker/dockerfile:1.7

ARG fmriprep_version=20.2.7

# Use existing verified base image
FROM condaforge/mambaforge:23.3.1-0 AS builder

# Configure conda
RUN mamba config --system --set remote_max_retries 10 \
    --set remote_backoff_factor 2 \
    --set channel_priority strict \
    && mamba clean --all -f -y

# Create retry script
RUN printf '#!/bin/sh\nfor i in 1 2 3 4 5; do "$@" && exit 0; sleep 15; done; exit 1' > /usr/bin/retry \
    && chmod +x /usr/bin/retry

# Build stage for conda packages
FROM builder AS package_builder
ARG MAMBA_DOCKERFILE_ACTIVATE=1
WORKDIR /recipes

COPY recipes ./recipes

# Build packages with cache mounting
RUN --mount=type=cache,target=/opt/conda/pkgs \
    set -eux \
    && for pkg in rmath traits nipype niflow-nipype1-workflows nitransforms tedana templateflow niworkflows sdcflows smriprep fmriprep halfpipe; do \
        retry mamba mambabuild \
          --no-anaconda-upload \
          --numpy "1.24" \
          --output-folder /opt/conda/conda-bld \
          "recipes/${pkg}" \
        && mamba clean --all -f -y; \
    done \
    && rm -rf /opt/conda/conda-bld/work \
    && find /opt/conda/conda-bld -name '*.a' -delete

# Final image
FROM nipreps/fmriprep:${fmriprep_version} AS runtime

ENV XDG_CACHE_HOME=/var/cache \
    HALFPIPE_RESOURCE_DIR=/var/cache/halfpipe \
    TEMPLATEFLOW_HOME=/var/cache/templateflow \
    PATH="/opt/conda/bin:${PATH}"

RUN mkdir -p /ext /host /var/cache \
    && chmod a+rwx /ext /host /var/cache \
    && mv /home/fmriprep/.cache/templateflow /var/cache \
    && rm -rf /usr/lib/ants \
    && git config --global user.name "HALFpipe" \
    && git config --global user.email "halfpipe@fmri.science"

COPY --from=package_builder /opt/conda/conda-bld /opt/conda/conda-bld

RUN --mount=type=cache,target=/opt/conda/pkgs \
    mamba install --yes --use-local \
      "python=3.11" "nodejs" "sqlite" "halfpipe" \
    && mamba clean --all -f -y \
    && find /opt/conda -follow -type f -name '*.a' -delete \
    && rm -rf /opt/conda/conda-bld \
              /opt/conda/pkgs \
              /opt/conda/include

RUN python -c "from matplotlib import font_manager" \
    && sed -i '/backend:/s/^#*//;s/: .*/: Agg/' \
        $(python -c "import matplotlib; print(matplotlib.matplotlib_fname())") \
    && rm -rf /root/.cache/pip

COPY --from=coinstacteam/coinstac-base:latest /server/ /server/
COPY src/halfpipe/resource.py /resource.py
RUN python /resource.py

ENTRYPOINT ["/opt/conda/bin/halfpipe"]
