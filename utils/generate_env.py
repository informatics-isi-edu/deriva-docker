#!/usr/bin/env python3
"""Generate a DERIVA environment configuration file for use with docker compose.

Replaces utils/generate-env.sh with a maintainable Python implementation.
The generated .env file format is identical to the shell script output so
existing deployments require no changes.

Usage::

    python3 utils/generate_env.py --env test --hostname localhost
    python3 utils/generate_env.py --env prod --hostname myhost.org --email ops@example.org
    python3 utils/generate_env.py --env all --hostname myhost.org --email ops@example.org
    python3 utils/generate_env.py --env prod --enable-mcp-aws --hostname myhost.org --email ops@example.org

Requirements: Python 3.10+, stdlib only.
"""

from __future__ import annotations

import argparse
import datetime
import os
import secrets
import string
import sys
from dataclasses import dataclass, field
from pathlib import Path


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

VALID_ENVS = ("test", "dev", "staging", "prod", "all")

# Each deploy environment gets a fixed third octet for its Docker subnet,
# keeping subnets non-overlapping when multiple envs run on the same host.
_THIRD_OCTET: dict[str, int] = {
    "prod": 0,
    "staging": 1,
    "dev": 2,
    "test": 3,
}

# Env file sections: (heading, ordered list of var names).
# Variables listed here are emitted in this order; unlisted vars are not emitted.
_ENV_SECTIONS: list[tuple[str, list[str]]] = [
    ("Compose", [
        "COMPOSE_PROFILES",
        "COMPOSE_FILE",
        "COMPOSE_PROJECT_NAME",
    ]),
    ("General", [
        "DEPLOY_ENV",
        "CONTAINER_HOSTNAME",
        "CONTAINER_HOSTNAME_INTERNAL",
        "LETSENCRYPT_EMAIL",
        "LETSENCRYPT_CERTDIR",
        "LETSENCRYPT_CA_SERVER",
        "STACK_ENV_FILE",
    ]),
    ("Networking", [
        "HTTP_PORT",
        "HTTPS_PORT",
        "SUBNET",
        "GATEWAY",
        "RSYSLOG_IP",
        "RPROXY_IP",
    ]),
    ("SSL Certificates", [
        "CERT_FILENAME",
        "KEY_FILENAME",
        "CA_FILENAME",
        "CERT_DIR",
    ]),
    ("Auth", [
        "CREDENZA_DEFAULT_REALM",
        "CREDENZA_DB_BACKEND",
        "CREDENZA_DB_USER",
        "CREDENZA_DB_HOST",
        "CREDENZA_DB_PORT",
        "CREDENZA_DEBUG",
        "CREDENZA_ISOLATION_ENABLED",
        "KEYCLOAK_IP",
        "KEYCLOAK_BASE_URL",
    ]),
    ("Database", [
        "POSTGRES_HOST",
        "POSTGRES_USER",
    ]),
    ("Monitoring", [
        "GRAFANA_USERNAME",
        "GRAFANA_PASSWORD",
    ]),
    ("DERIVA", [
        "CREATE_TEST_DB",
        "ERMREST_ADMIN_GROUP",
        "HATRAC_ADMIN_GROUP",
        "AUTHN_SESSION_HOST",
        "AUTHN_SESSION_HOST_VERIFY",
    ]),
    ("MCP", [
        "DERIVA_MCP_SSL_VERIFY",
        "DERIVA_MCP_HOSTNAME_MAP",
    ]),
    ("Chatbot", [
        "DERIVA_CHATBOT_LLM_API_KEY",
    ]),
    ("AWS CloudWatch Logs (only active when COMPOSE_FILE includes docker-compose-mcp-aws.yml)", [
        "AWS_REGION",
        "AWS_LOG_GROUP",
    ]),
    ("Secrets", [
        "SECRETS_DIR",
    ]),
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def random_token(length: int = 16) -> str:
    """Return a random alphanumeric string of the given length.

    Uses secrets.choice over a fixed alphabet to match the shell script's
    LC_ALL=C tr -dc a-zA-Z0-9 </dev/urandom | head -c<length> output.
    Minimum length is 8.
    """
    if length < 8:
        raise ValueError(f"Minimum token length is 8, got {length}")
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def jupyterhub_crypt_key() -> str:
    """Return a URL-safe base64 key suitable for JUPYTERHUB_CRYPT_KEY.

    Matches: openssl rand -base64 32 | tr '+/' '-_' | tr -d '\\n'
    """
    import base64
    raw = secrets.token_bytes(32)
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def safe_hostname(hostname: str) -> str:
    """Replace dots and hyphens with underscores for use in file/project names."""
    return hostname.replace(".", "_").replace("-", "_")


def internal_hostname(hostname: str, org_hostname: str) -> str:
    """Return the internal Docker network hostname.

    For localhost deployments this is always 'deriva'. For all others it is
    the first label of the public hostname (e.g. 'myhost' from 'myhost.org').
    """
    if org_hostname == "localhost":
        return "deriva"
    return hostname.split(".")[0]


# ---------------------------------------------------------------------------
# Core config dataclass
# ---------------------------------------------------------------------------

@dataclass
class DeployConfig:
    """All resolved values for a single environment's .env file."""

    # The non-secret env vars emitted to the .env file, in insertion order.
    vars: dict[str, str] = field(default_factory=dict)

    # Secret vars written to individual .txt files under secrets_dir.
    # Key: lowercase filename stem (e.g. "postgres_password").
    # Value: the secret string.
    secrets: dict[str, str] = field(default_factory=dict)

    # Path to write the .env file.
    env_file: Path = field(default=Path())

    # Directory to write per-secret .txt files.
    secrets_dir: Path = field(default=Path())


# ---------------------------------------------------------------------------
# Config builder
# ---------------------------------------------------------------------------

def build_config(args: argparse.Namespace, env: str) -> DeployConfig:
    """Resolve all values for a single deploy environment."""

    cfg = DeployConfig()

    # -- Hostnames -----------------------------------------------------------

    org_hostname = args.hostname or "localhost"
    hostname = org_hostname
    if args.decorate_hostname and org_hostname != "localhost":
        hostname = f"{env}-{org_hostname}"

    safe = safe_hostname(hostname)
    internal = internal_hostname(hostname, org_hostname)
    is_localhost = org_hostname == "localhost"

    # -- Networking ----------------------------------------------------------

    octet       = _THIRD_OCTET[env]
    subnet      = f"172.28.{octet}.0/24"
    gateway     = f"172.28.{octet}.1"
    rsyslog_ip  = f"172.28.{octet}.100"
    keycloak_ip = f"172.28.{octet}.200"
    rproxy_ip   = f"172.28.{octet}.250"

    # -- Secrets (defaults; overridden for prod/staging/dev below) -----------

    postgres_password           = "postgres"
    postgres_ermrest_password   = "ermrest"
    postgres_hatrac_password    = "hatrac"
    postgres_webauthn_password  = "webauthn"
    postgres_deriva_password    = "deriva"
    credenza_db_password        = "credenza"
    credenza_encryption_key     = random_token(24)
    grafana_password            = "deriva-admin"
    jupyterhub_key              = jupyterhub_crypt_key()
    keycloak_client_secret      = random_token(32)
    mcp_client_secret           = random_token(32)
    credenza_redis_commander_password = ""

    # -- Feature flags (may be mutated by env-type logic below) --------------

    enable_keycloak           = args.enable_keycloak
    enable_jupyter            = args.enable_jupyter
    enable_mcp                = args.enable_mcp
    enable_chatbot            = args.enable_chatbot
    enable_credenza_redis     = args.enable_credenza_redis
    enable_credenza_isolation = args.enable_credenza_isolation

    # -- Profiles (set semantics -- no string concatenation bugs) ------------

    profiles: set[str] = {
        "deriva-base",
        "deriva-monitoring-base",
        "deriva-monitoring-rproxy",
    }

    # -- Cert / Let's Encrypt defaults ---------------------------------------
    # Cert file vars are only populated for test mode (self-signed certs).
    # For prod/staging/dev, Let's Encrypt handles TLS so these stay empty
    # unless explicitly passed on the command line.

    default_cert_dir      = "deriva-dev-localhost"
    cert_dir              = args.cert_dir or ""
    cert_filename         = args.cert_filename or ""
    key_filename          = args.key_filename  or ""
    ca_filename           = args.ca_filename   or ""
    letsencrypt_email     = args.email or "isrd-support@isi.edu"
    # Expand home dir at generation time -- systemd EnvironmentFile and Docker
    # Compose do not re-expand shell variables embedded in env file values.
    letsencrypt_certdir   = (
        f"{os.path.expanduser('~')}/.deriva-docker/certs/{hostname}/letsencrypt"
    )

    # -- Auth / DB defaults --------------------------------------------------

    credenza_default_realm      = "keycloak"
    keycloak_base_url           = "http://keycloak:8080/auth/realms/deriva"
    # Default: localhost -- DERIVA services in the Apache container call authn
    # via loopback. Only overridden to the internal Docker hostname when
    # Credenza isolation is enabled (separate container, not co-located).
    authn_session_host          = "localhost"
    authn_session_host_verify   = "true"
    create_test_db              = "false"

    # -- Env-type specific logic ---------------------------------------------

    if env in ("prod", "staging", "dev"):
        # Randomise all secrets for non-test environments.
        postgres_password           = random_token()
        postgres_ermrest_password   = random_token()
        postgres_hatrac_password    = random_token()
        postgres_webauthn_password  = random_token()
        postgres_deriva_password    = random_token()
        credenza_db_password        = random_token()
        grafana_password            = random_token()

        profiles.add(env)  # "prod", "staging", or "dev"
        profiles.add("deriva-web-rproxy-letsencrypt")

        if enable_credenza_redis:
            profiles.add("credenza-redis-backend")
            if enable_credenza_isolation:
                profiles.add("credenza-redis-test")

        if enable_credenza_isolation:
            profiles.add(
                "credenza-redis" if enable_credenza_redis else "credenza-postgres"
            )

    if env == "test":
        # test environment forces on all core services.
        enable_keycloak = True
        enable_jupyter  = True
        enable_mcp      = True

        # cert filenames default to cert_dir-based names in test mode.
        cert_dir      = args.cert_dir      or default_cert_dir
        cert_filename = args.cert_filename or f"{cert_dir}.crt"
        key_filename  = args.key_filename  or f"{cert_dir}.key"
        ca_filename   = args.ca_filename   or "deriva-dev-ca.crt"
        create_test_db = "true"

        if enable_credenza_redis:
            profiles |= {
                "deriva-web-rproxy",
                "credenza-redis-backend",
                "credenza-redis-commander",
                "test",
            }
            if enable_credenza_isolation:
                profiles.add("credenza-redis-test")
            credenza_redis_commander_password = "credenza-admin"
        else:
            profiles |= {"deriva-web-rproxy", "test"}
            if enable_credenza_isolation:
                profiles.add("credenza-postgres-test")

    # -- Feature flag -> profile mapping -------------------------------------

    if enable_keycloak:
        profiles.add("deriva-auth-keycloak")
    if args.enable_groups:
        profiles.add("deriva-groups")
    if args.enable_ddns:
        profiles.add("ddns-update")
    if enable_mcp:
        profiles.add("deriva-mcp")
    if enable_chatbot:
        profiles.add("deriva-chatbot")
    if enable_jupyter:
        if not enable_keycloak:
            _warn("Jupyter requires Keycloak -- Jupyter will not be enabled.")
        else:
            profiles.add("jupyter")

    # -- AWS MCP override ----------------------------------------------------

    compose_files = ["docker-compose.yml"]

    if args.enable_mcp_aws:
        profiles.add("deriva-mcp")
        profiles.add("deriva-chatbot")
        enable_mcp = True
        profiles.discard("deriva-monitoring-base")
        profiles.discard("deriva-monitoring-rproxy")
        # MCP-only stack has no Apache web container; use Traefik-only letsencrypt profile.
        if "deriva-web-rproxy-letsencrypt" in profiles:
            profiles.discard("deriva-web-rproxy-letsencrypt")
            profiles.add("rproxy-letsencrypt")
        compose_files.append("docker-compose-mcp-aws.yml")
        # MCP-only stack has no web/postgres container; use Redis for Credenza session storage.
        # Credenza must also run as an isolated container (no Apache co-location in MCP stack).
        enable_credenza_redis = True
        enable_credenza_isolation = True
        # Default log group to a hostname-scoped path unless the operator overrode it explicitly.
        if args.aws_log_group == "/deriva/chatbot":
            args.aws_log_group = f"/aws/ec2/instance/{hostname}/chatbot"

    # -- Credenza DB backend -------------------------------------------------

    if enable_credenza_redis:
        credenza_db_backend = "redis"
        credenza_db_host    = "credenza-redis"
        credenza_db_port    = "6379/0"
    else:
        credenza_db_backend = "postgresql"
        credenza_db_host    = "deriva-postgres"
        credenza_db_port    = "5432"

    if enable_credenza_isolation:
        authn_session_host        = internal
        authn_session_host_verify = "false"

    # -- Hostname remapping for localhost ------------------------------------

    if is_localhost:
        deriva_mcp_hostname_map = f'{{"{hostname}":"{internal}"}}'
        deriva_mcp_ssl_verify   = "false"
    else:
        deriva_mcp_hostname_map = "{}"
        deriva_mcp_ssl_verify   = "true"

    # -- Paths ---------------------------------------------------------------

    output_dir  = Path(args.output_dir).expanduser()
    env_file    = output_dir / f"{safe}.env"
    secrets_dir = output_dir / "secrets" / safe / env

    # -- Assemble vars dict (order matches original shell script output) ------

    cfg.vars = {
        "COMPOSE_PROFILES": ",".join(sorted(profiles)),  # sorted for stable output
        "COMPOSE_FILE":     ":".join(compose_files),
        "COMPOSE_PROJECT_NAME": f"deriva-{safe}",

        "DEPLOY_ENV":                 env,
        "CONTAINER_HOSTNAME":         hostname,
        "CONTAINER_HOSTNAME_INTERNAL": internal,
        "LETSENCRYPT_EMAIL":           letsencrypt_email,
        "LETSENCRYPT_CERTDIR":         letsencrypt_certdir,
        "LETSENCRYPT_CA_SERVER":       args.letsencrypt_ca_server,
        "STACK_ENV_FILE":              str(env_file),

        "HTTP_PORT":   "80",
        "HTTPS_PORT":  "443",
        "SUBNET":      subnet,
        "GATEWAY":     gateway,
        "RSYSLOG_IP":  rsyslog_ip,
        "RPROXY_IP":   rproxy_ip,

        "CERT_FILENAME": cert_filename,
        "KEY_FILENAME":  key_filename,
        "CA_FILENAME":   ca_filename,
        "CERT_DIR":      cert_dir,

        "CREDENZA_DEFAULT_REALM":       credenza_default_realm,
        "CREDENZA_DB_BACKEND":          credenza_db_backend,
        "CREDENZA_DB_USER":             "credenza",
        "CREDENZA_DB_HOST":             credenza_db_host,
        "CREDENZA_DB_PORT":             credenza_db_port,
        "CREDENZA_DEBUG":               "false",
        "CREDENZA_ISOLATION_ENABLED":   str(enable_credenza_isolation).lower(),
        "KEYCLOAK_IP":                  keycloak_ip,
        "KEYCLOAK_BASE_URL":            keycloak_base_url,

        "POSTGRES_HOST":                "deriva-postgres",
        "POSTGRES_USER":                "postgres",

        "GRAFANA_USERNAME":             "deriva-admin",
        "GRAFANA_PASSWORD":             grafana_password,

        "CREATE_TEST_DB":               create_test_db,
        "ERMREST_ADMIN_GROUP":          args.ermrest_admin_group or "admin",
        "HATRAC_ADMIN_GROUP":           args.hatrac_admin_group  or "admin",
        "AUTHN_SESSION_HOST":           authn_session_host,
        "AUTHN_SESSION_HOST_VERIFY":    authn_session_host_verify,

        "DERIVA_MCP_SSL_VERIFY":        deriva_mcp_ssl_verify,
        "DERIVA_MCP_HOSTNAME_MAP":      deriva_mcp_hostname_map,

        "DERIVA_CHATBOT_LLM_API_KEY":   args.llm_api_key or "",

        "AWS_REGION":                   args.aws_region,
        "AWS_LOG_GROUP":                args.aws_log_group,

        "SECRETS_DIR":                  secrets_dir.as_posix(),
    }

    # -- Assemble secrets dict -----------------------------------------------

    cfg.secrets = {
        "postgres_password":                postgres_password,
        "postgres_ermrest_password":        postgres_ermrest_password,
        "postgres_hatrac_password":         postgres_hatrac_password,
        "postgres_webauthn_password":       postgres_webauthn_password,
        "postgres_deriva_password":         postgres_deriva_password,
        "credenza_db_password":             credenza_db_password,
        "credenza_encryption_key":          credenza_encryption_key,
        "grafana_password":                 grafana_password,
        "jupyterhub_crypt_key":             jupyterhub_key,
        "keycloak_deriva_client_secret":    keycloak_client_secret,
    }

    if env == "test" and enable_credenza_redis:
        cfg.secrets["credenza_redis_commander_password"] = credenza_redis_commander_password

    if enable_mcp:
        cfg.secrets["mcp_client_secret"] = mcp_client_secret

    cfg.env_file    = env_file
    cfg.secrets_dir = secrets_dir
    return cfg


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def render_env_file(cfg: DeployConfig) -> str:
    """Render the .env file contents as a string."""
    timestamp = datetime.datetime.now().strftime("%c")
    lines = [f"# Auto-generated {timestamp}", ""]

    for heading, keys in _ENV_SECTIONS:
        lines.append(f"# {heading}")
        for key in keys:
            value = cfg.vars.get(key, "")
            lines.append(f"{key}={value}")
        lines.append("")

    return "\n".join(lines)


def write_env_file(cfg: DeployConfig) -> None:
    cfg.env_file.parent.mkdir(parents=True, exist_ok=True)
    cfg.env_file.write_text(render_env_file(cfg), encoding="utf-8")
    _ok(f"Environment file '{cfg.env_file}' has been created.")


_SYSTEM_ENV_DIR  = Path("/etc/deriva-docker")
_SYSTEM_ENV_LINK = _SYSTEM_ENV_DIR / "deriva-stack.env"


def install_symlink(cfg: DeployConfig) -> None:
    """Symlink the generated env file into /etc/deriva-docker/deriva-stack.env.

    Attempts the operation directly; on PermissionError prints the equivalent
    sudo commands for the operator to run manually.
    """
    target = cfg.env_file.resolve()
    try:
        _SYSTEM_ENV_DIR.mkdir(parents=True, exist_ok=True)
        if _SYSTEM_ENV_LINK.exists() or _SYSTEM_ENV_LINK.is_symlink():
            _warn(f"Replacing existing file/symlink at '{_SYSTEM_ENV_LINK}'.")
            _SYSTEM_ENV_LINK.unlink()
        _SYSTEM_ENV_LINK.symlink_to(target)
        _ok(f"Installed symlink: {_SYSTEM_ENV_LINK} -> {target}")
    except PermissionError:
        print(f"  Permission denied. Run as root or execute manually:")
        print(f"    sudo mkdir -p {_SYSTEM_ENV_DIR}")
        print(f"    sudo ln -sf {target} {_SYSTEM_ENV_LINK}")


def write_secret_files(cfg: DeployConfig) -> None:
    """Write each secret to its own .txt file under secrets_dir."""
    cfg.secrets_dir.mkdir(parents=True, exist_ok=True)
    for name, value in cfg.secrets.items():
        if not value:
            _warn(f"Skipping empty secret: {name}")
            continue
        dest = cfg.secrets_dir / f"{name}.txt"
        dest.write_text(value, encoding="utf-8")
        _ok(f"Wrote ${name.upper()} to {dest}")


# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

def _ok(msg: str) -> None:
    print(f"[ok]   {msg}")

def _warn(msg: str) -> None:
    print(f"[warn] {msg}")

def _err(msg: str) -> None:
    print(f"[err]  {msg}", file=sys.stderr)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="generate_env.py",
        description="Generate a DERIVA environment configuration file for use with docker compose.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s -e test -h localhost
  %(prog)s -e all --hostname test.at.derivacloud.net
  %(prog)s --env dev --hostname myhost.local --email user@example.com
  %(prog)s --env prod --hostname myhost.org --email ops@example.org --enable-mcp-aws
""",
    )

    p.add_argument("--env", "-e",
        dest="env_type", default="test", choices=VALID_ENVS, metavar="ENV",
        help="Environment type: test | dev | staging | prod | all (default: test)")
    p.add_argument("--output-dir", "-o",
        default="~/.deriva-docker/env",
        help="Output directory for generated env file (default: ~/.deriva-docker/env)")
    p.add_argument("--hostname",
        default="", metavar="NAME",
        help="Public hostname (default: localhost)")
    p.add_argument("--decorate-hostname", "-d",
        action="store_true",
        help="Prepend the environment name to the hostname (e.g. dev-myhost). "
             "Automatic when using -e all, except for localhost.")

    g = p.add_argument_group("features")
    g.add_argument("--enable-credenza-isolation", "-c", action="store_true",
        help="Create a separate isolated container for Credenza")
    g.add_argument("--enable-credenza-redis", "-r", action="store_true",
        help="Enable Redis backend for Credenza")
    g.add_argument("--enable-keycloak", "-k", action="store_true",
        help="Enable Keycloak IDP container")
    g.add_argument("--enable-groups", "-g", action="store_true",
        help="Enable Deriva Groups containers")
    g.add_argument("--enable-jupyter", "-j", action="store_true",
        help="Enable Jupyter containers (requires --enable-keycloak)")
    g.add_argument("--enable-ddns", action="store_true",
        help="Enable DDNS refresh")
    g.add_argument("--enable-mcp", "-m", action="store_true",
        help="Enable the DERIVA MCP server (deriva-mcp-core)")
    g.add_argument("--enable-chatbot", "-b", action="store_true",
        help="Enable the DERIVA Chatbot UI (deriva-mcp-ui)")
    g.add_argument("--llm-api-key", default="", metavar="KEY",
        help="LLM API key (required when --enable-chatbot is set)")

    aws = p.add_argument_group("AWS")
    aws.add_argument("--enable-mcp-aws", action="store_true",
        help="Enable AWS overrides for the lean MCP stack (CloudWatch logging, restart "
             "policies). Activates docker-compose-mcp-aws.yml and disables the local "
             "monitoring stack. Implies --enable-mcp and --enable-chatbot.")
    aws.add_argument("--aws-region", default="us-west-2", metavar="REGION",
        help="AWS region for CloudWatch Logs (default: us-west-2)")
    aws.add_argument("--aws-log-group", default="/deriva/chatbot", metavar="GROUP",
        help="CloudWatch log group name (default: /deriva/chatbot)")

    tls = p.add_argument_group("TLS / Let's Encrypt")
    tls.add_argument("--email", default="", metavar="EMAIL",
        help="Let's Encrypt email (required for dev, staging, prod)")
    tls.add_argument("--letsencrypt-staging", dest="letsencrypt_ca_server",
        action="store_const",
        const="https://acme-staging-v02.api.letsencrypt.org/directory",
        default="",
        help="Use the Let's Encrypt staging endpoint (issues untrusted certs; for testing only)")
    tls.add_argument("--cert-filename", default="", metavar="FILE")
    tls.add_argument("--key-filename",  default="", metavar="FILE")
    tls.add_argument("--ca-filename",   default="", metavar="FILE")
    tls.add_argument("--cert-dir",      default="", metavar="DIR",
        help="Certificate base directory")

    adv = p.add_argument_group("advanced")
    adv.add_argument("--ermrest-admin-group", default="", metavar="GROUP")
    adv.add_argument("--hatrac-admin-group",  default="", metavar="GROUP")
    adv.add_argument("--dry-run", "-n", action="store_true",
                     help="Print the generated env file(s) to stdout; do not write any files.")
    adv.add_argument("--install", "-i", action="store_true",
                     help="Symlink the generated env file to /etc/deriva-docker/deriva-stack.env. "
                          "Attempts directly; prints sudo commands on permission error. "
                          "Ignored with --env all.")

    return p


def validate(args: argparse.Namespace) -> bool:
    """Run pre-flight checks. Returns False and prints errors if invalid."""
    ok = True

    if args.env_type in ("dev", "staging", "prod") and not args.email:
        _err(f"--email is required for environment: {args.env_type}")
        ok = False

    if (args.enable_chatbot or args.enable_mcp_aws) and not args.llm_api_key:
        _warn("--enable-chatbot is set but --llm-api-key was not provided. "
              "Set DERIVA_CHATBOT_LLM_API_KEY in the generated env file before "
              "starting the chatbot.")

    return ok


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    if not validate(args):
        sys.exit(1)

    envs = ["test", "dev", "staging", "prod"] if args.env_type == "all" else [args.env_type]
    if args.env_type == "all":
        args.decorate_hostname = True

    for env in envs:
        cfg = build_config(args, env)
        if args.dry_run:
            print(render_env_file(cfg))
        else:
            write_env_file(cfg)
            write_secret_files(cfg)
            if args.install:
                if args.env_type == "all":
                    _warn("--install is not supported with --env all; skipping symlink.")
                else:
                    install_symlink(cfg)
            print()


if __name__ == "__main__":
    main()
