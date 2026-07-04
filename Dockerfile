# =============================================================================
# CCIP NFT Bridge - CLI Container
# =============================================================================
FROM node:18-alpine

# Set the working directory
WORKDIR /usr/src/app

# Install a couple of light utilities useful for debugging inside the container.
RUN apk add --no-cache bash curl jq

# Copy package.json and package-lock.json first so npm install is cached
# separately from the rest of the source (faster rebuilds).
COPY package*.json ./

RUN npm install

# Copy the rest of the application code.
COPY . .

# Make sure the data/logs directories exist even on a fresh clone.
RUN mkdir -p /usr/src/app/data /usr/src/app/logs

# Keep the container running so commands can be executed via `docker exec`.
CMD ["tail", "-f", "/dev/null"]
