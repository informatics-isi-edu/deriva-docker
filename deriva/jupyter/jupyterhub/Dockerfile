FROM jupyterhub/jupyterhub:latest

# Install oauthenticator
RUN pip install oauthenticator dockerspawner

# Copy JupyterHub configuration file
COPY jupyterhub_config.py /srv/jupyterhub/jupyterhub_config.py