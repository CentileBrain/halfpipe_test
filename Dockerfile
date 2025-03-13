# syntax=docker/dockerfile-upstream:master

FROM condaforge/mambaforge:22.11.1-4 as builder

RUN mamba update --yes --all
RUN mamba install --yes "boa" "conda-verify"

# Build all custom recipes in one command. We build our own conda packages to simplify
# the environment creation process, as some of them were only available in pypi.
COPY recipes /recipes
RUN for pkg in rmath traits niflow-nipype1-workflows nitransforms pybids; do \
        conda mambabuild --no-anaconda-upload /recipes/$pkg && \
        conda build purge; \
    done

FROM condaforge/mambaforge:22.11.1-4 as install

COPY --from=builder /opt/conda/conda-bld/ /opt/conda/conda-bld/
RUN mamba install --yes --use-local \
    "python=3.11" "pip" "nodejs" "rmath" "ants"
RUN mamba update --yes --all

# ✅ COPY requirement files into the container instead of using --mount
COPY requirements.txt /requirements.txt
COPY requirements-test.txt /requirements-test.txt
COPY install-requirements.sh /install-requirements.sh

# ✅ Make sure install-requirements.sh is executable
RUN chmod +x /install-requirements.sh

# ✅ Run the installation script
RUN /install-requirements.sh --requirements-file /requirements.txt --requirements-file /requirements-test.txt

# ✅ Clean up conda cache to reduce image size
RUN mamba clean --yes --all --force-pkgs-dirs \
    && find /opt/conda -follow -type f -name "*.a" -delete \
    && rm -rf /opt/conda/conda-bld

FROM nipreps/fmriprep:20.2.7

RUN mkdir /ext /host \
    && chmod a+rwx /ext /host

# Use `/var/cache` for downloaded resources instead of
# `/home/fmriprep/.cache`, because it is less likely to be
# obscured by default bind mounts when running with
# Singularity
ENV XDG_CACHE_HOME="/var/cache" \
    HALFPIPE_RESOURCE_DIR="/var/cache/halfpipe" \
    TEMPLATEFLOW_HOME="/var/cache/templateflow"
RUN mv /home/fmriprep/.cache/templateflow /var/cache

# Remove `conda` and `ants` installations
RUN rm -rf /opt/conda /usr/lib/ants

# Update path to reflect new `conda` location
ENV PATH="${PATH/\/usr\/local\/miniconda\/bin//opt/conda/bin}" \
    MAMBA_EXE="/opt/conda/bin/mamba"
# Update the path to reflect new `ants` location
ENV PATH="${PATH//:\/usr\/lib\/ants/}"

# Copy `conda` from `install` stage
COPY --from=install /opt/conda/ /opt/conda/

# Re-apply `matplotlib` settings after re-installing `conda`
# Taken from `fmriprep`
# Pre-caches fonts, set 'Agg' as default backend for `matplotlib`
RUN python -c "from matplotlib import font_manager" \
    && sed -i '/backend:/s/^#*//;/^backend/s/: .*/: Agg/' \
    $( python -c "import matplotlib; print(matplotlib.matplotlib_fname())" )

# ✅ Copy resource file explicitly
COPY src/halfpipe/resource.py /resource.py

# ✅ Run the resource download script
RUN python /resource.py

# Add `coinstac` server components
COPY --from=coinstacteam/coinstac-base:latest /server/ /server/

# Install `halfpipe`
COPY halfpipe /halfpipe  # Ensure the "halfpipe" directory is copied
RUN pip install --no-deps /halfpipe \
    && rm -rf ~/.cache/pip /var/cache/pip /tmp/* /var/tmp/* \
    && sync

ENTRYPOINT ["/opt/conda/bin/halfpipe"]
