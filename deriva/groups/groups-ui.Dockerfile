# Multi-stage build for React + nginx
FROM node:24-slim AS builder

RUN apt-get update && \
    apt-get install -y \
    git \
    curl \
    ca-certificates \
    --no-install-recommends && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /

# Accept build argument to control source fetch
ARG GIT_FETCH=0
ENV GIT_FETCH=${GIT_FETCH}

# Always create code path
RUN mkdir -p /deriva-groups-ui

# Copy whatever source is available from context (fails if src/deriva-groups-ui missing entirely)
COPY src/deriva-groups-ui ./deriva-groups-ui

# Clone if forced or local source is missing
RUN if [ "$GIT_FETCH" = "1" ] || [ ! -f "./deriva-groups-ui/package.json" ]; then \
      echo "Cloning deriva-groups-ui from GitHub..."; \
      rm -rf ./deriva-groups-ui && \
      git clone https://github.com/informatics-isi-edu/deriva-groups-ui.git ./deriva-groups-ui; \
    else \
      echo "Using local deriva-groups-ui directory from build context"; \
    fi

WORKDIR /deriva-groups-ui

# Accept Vite environment variables
ARG VITE_BASE_URL
ARG VITE_BACKEND_URL
ARG VITE_API_BASE_PATH
ARG VITE_UI_BASE_PATH

ENV VITE_BASE_URL=$VITE_BASE_URL
ENV VITE_BACKEND_URL=$VITE_BACKEND_URL
ENV VITE_API_BASE_PATH=$VITE_API_BASE_PATH
ENV VITE_UI_BASE_PATH=$VITE_UI_BASE_PATH

# Install dependencies and build the UI
RUN yarn config set network-timeout 300000 -g && yarn install --frozen-lockfile && yarn build

# Final stage with nginx
FROM nginx:alpine

# Copy built UI and nginx config
COPY --from=builder /deriva-groups-ui/dist /usr/share/nginx/html
COPY --from=builder /deriva-groups-ui/config/nginx.conf /etc/nginx/nginx.conf

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
