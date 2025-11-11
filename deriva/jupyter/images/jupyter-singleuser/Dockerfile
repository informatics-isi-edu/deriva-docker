FROM python:3.12-slim

ENV DEBIAN_FRONTEND=noninteractive \
    NB_USER=jovyan NB_UID=1000 NB_GID=100 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    UV_LINK_MODE=copy \
    SHELL=/bin/bash \
    TERM=xterm-256color

# minimal OS deps
COPY packages.apt /tmp/packages.apt
RUN apt-get update && \
    xargs -a /tmp/packages.apt apt-get install -y --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# COPY deriva-dev CA cert
COPY --from=certs deriva-dev-ca.crt /usr/local/share/ca-certificates/deriva-dev-ca.crt
RUN update-ca-certificates

# COPY default server config
RUN mkdir -p /usr/local/etc/jupyter
COPY jupyter_server_config.py /usr/local/etc/jupyter/jupyter_server_config.py

# create non-root user
RUN useradd -m -s /bin/bash -u "${NB_UID}" -g "${NB_GID}" "${NB_USER}" || \
    useradd -m -s /bin/bash -u "${NB_UID}" "${NB_USER}"

# install uv for NB_USER
USER ${NB_USER}
WORKDIR /home/${NB_USER}
RUN curl -Ls https://astral.sh/uv/install.sh | sh
ENV PATH="/home/${NB_USER}/.local/bin:${PATH}"
RUN printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"' >> "/home/${NB_USER}/.bash_profile"

# create venv inside home and install from requirements (use user uv + --python)
COPY requirements.txt /tmp/requirements.txt
ENV APP_VENV="/home/${NB_USER}/venvs/deriva-dev"
RUN mkdir -p "$HOME/venvs" \
 && uv venv "$APP_VENV" \
 && uv pip install -U \
      --python "$APP_VENV/bin/python" \
      --no-cache-dir --no-compile \
      -r /tmp/requirements.txt \
 && rm -rf ~/.cache/uv ~/.cache/pip

# make it default for shells & kernels
ENV VIRTUAL_ENV="$APP_VENV"
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"
RUN printf '%s\n' \
  '[ -f "$VIRTUAL_ENV/bin/activate" ] && . "$VIRTUAL_ENV/bin/activate" >/dev/null 2>&1' \
  >> "/home/${NB_USER}/.bash_profile"

# register kernelspec
RUN "${APP_VENV}/bin/python" \
    -m ipykernel install \
    --name deriva-dev-uv \
    --display-name "Python (deriva-dev via uv)" \
    --user

ENTRYPOINT ["/usr/bin/tini","--"]
CMD ["jupyterhub-singleuser","--ip=0.0.0.0"]
