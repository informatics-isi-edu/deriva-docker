import os
import shlex
from oauthenticator.generic import GenericOAuthenticator
from dockerspawner import DockerSpawner
from escapism import escape

c = get_config() # noqa
# c.JupyterHub.log_level = "DEBUG"

# ------------------ Core Hub ------------------
# Hub binds internally; Traefik routes external traffic
c.JupyterHub.ip = "0.0.0.0"
c.JupyterHub.port = 8000
c.JupyterHub.base_url = os.environ.get("JUPYTERHUB_BASE_URL", "/jupyterhub/")
public_url = "https://" + os.environ.get("CONTAINER_HOSTNAME", "localhost")

# Use the Hub container's DNS name and the Hub's *internal* port (default 8081)
c.JupyterHub.hub_ip = "0.0.0.0"                   # bind inside the Hub container
c.JupyterHub.hub_port = 8081
c.JupyterHub.hub_connect_url = f"http://jupyterhub:{c.JupyterHub.hub_port}{c.JupyterHub.base_url}"

# Persist Hub state
DATA_DIR = "/data"
os.makedirs(DATA_DIR, exist_ok=True)
c.JupyterHub.db_url = f"sqlite:///{os.path.join(DATA_DIR, 'jupyterhub.sqlite')}"
# Use Docker secret if present
secret_file = "/run/secrets/jh_cookie_secret"
if os.path.exists(secret_file) and os.path.getsize(secret_file) > 0:
    c.JupyterHub.cookie_secret_file = secret_file
else:
    c.JupyterHub.cookie_secret_file = os.path.join(DATA_DIR, "jupyterhub_cookie_secret")


c.JupyterHub.shutdown_on_logout = True
c.JupyterHub.cleanup_servers = True
c.JupyterHub.concurrent_spawn_limit = 10
c.JupyterHub.active_server_limit = 0

c.ServerApp.default_kernel_name = "deriva-dev-uv"

# ------------------ Auth: Keycloak OIDC ------------------
c.JupyterHub.authenticator_class = GenericOAuthenticator

# --- Client + endpoints ---
c.GenericOAuthenticator.client_id = "deriva-client"
c.GenericOAuthenticator.client_secret = open("/run/secrets/keycloak_deriva_client_secret").read().strip()
c.GenericOAuthenticator.oauth_callback_url = f"{public_url}{c.JupyterHub.base_url}oauth_callback"
c.GenericOAuthenticator.authorize_url = os.environ["OIDC_AUTHORIZE_URL"]
c.GenericOAuthenticator.token_url = os.environ["OIDC_TOKEN_URL"]
c.GenericOAuthenticator.userdata_url = os.environ["OIDC_USERINFO_URL"]
c.GenericOAuthenticator.scope = shlex.split(os.environ.get("OIDC_SCOPE", "openid email profile offline_access"))

# --- Userinfo call behavior (replaces userdata_method) ---
# Defaults are fine for Keycloak (Bearer token in Authorization header)
c.GenericOAuthenticator.userdata_params = {}                # GET params if you ever need them
c.GenericOAuthenticator.userdata_token_method = "header"    # or "url" for access_token=query

# --- Username & groups ---
c.GenericOAuthenticator.username_claim = os.environ.get("OIDC_USERNAME_KEY", "preferred_username")

c.GenericOAuthenticator.manage_groups = True
# Keycloak sends short group names via Group Membership mapper -> "groups"
c.GenericOAuthenticator.auth_state_groups_key = "oauth_user.groups"

# Optional: restrict/login + auto-admin by group
_admin_groups = {u.strip() for u in os.environ.get("JUPYTERHUB_ADMIN_GROUPS", "").split(",") if u.strip()}
_allowed_groups = {u.strip() for u in os.environ.get("JUPYTERHUB_ALLOWED_GROUPS", "").split(",") if u.strip()}
if _admin_groups:
    c.GenericOAuthenticator.admin_groups = _admin_groups
if _allowed_groups:
    c.GenericOAuthenticator.allowed_groups = _allowed_groups

c.Authenticator.enable_auth_state = True                 # store tokens/refresh_token in DB
c.Authenticator.auth_refresh_age = 300                  # recheck/refresh at most every 5 min
c.OAuthenticator.refresh_pre_spawn = True               # refresh before (re)spawning user server
c.OAuthenticator.scope = ["openid", "profile", "email", "offline_access"]

c.GenericOAuthenticator.refresh_pre_spawn = True
# Tell JupyterHub which key(s) to use for auth_state encryption
keyfile = "/run/secrets/jupyterhub_crypt_key"
with open(keyfile) as f:
    key = f.read().strip()
c.CryptKeeper.keys = [key]


# ------------------ Spawner: Docker ------------------

c.JupyterHub.spawner_class = DockerSpawner
c.DockerSpawner.name_template = "jupyter-{username}"

c.DockerSpawner.image = os.environ.get("SINGLEUSER_IMAGE", "isrddev/deriva-jupyter-singleuser:latest")
c.DockerSpawner.use_docker_client_env = True
#c.DockerSpawner.pull_policy = "Never"

# Persist the home dir so notebooks, kernels, and venvs survive restarts
c.DockerSpawner.notebook_dir = "/home/jovyan"

# Per-user named volumes
c.DockerSpawner.volumes = {
    "jupyterhub-user-{username}": "/home/jovyan"
}

# Ensure single-user containers join the same docker network as the hub
c.DockerSpawner.network_name = os.environ.get("COMPOSE_PROJECT_NAME", "deriva") + "_internal_network"
c.DockerSpawner.use_internal_ip = True

c.DockerSpawner.environment = {
    "JUPYTERHUB_BASE_URL": os.environ.get("JUPYTERHUB_BASE_URL", "/jupyterhub/"),
    "UV_CACHE_DIR": "/home/jovyan/.cache/uv",
    "SERVERAPP_SHUTDOWN_NO_ACTIVITY_TIMEOUT": "2100"  # 35 min
}

# cleanup
c.DockerSpawner.remove = True                # delete container once stopped
c.DockerSpawner.extra_create_kwargs = {"stop_timeout": 30}

# Users land in JupyterLab
c.Spawner.default_url = "/lab"
c.Spawner.start_timeout = 60
c.Spawner.http_timeout = 60
