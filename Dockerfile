# Base image with common dependencies
FROM node:18-slim as base
RUN mkdir -p /usr/src/app
WORKDIR /usr/src/app
EXPOSE 3000

# Development environment
FROM base as dev
COPY package.json package-lock.json ./
RUN npm install
COPY index.js ./
CMD ["npm", "run", "dev"]

# UAT environment
FROM base as uat
COPY package.json package-lock.json ./
RUN npm install
COPY index.js ./
CMD ["npm", "run", "uat"]

# Production environment
FROM base as prod
COPY package.json package-lock.json ./
RUN npm install
COPY index.js ./
CMD ["npm", "run", "prod"]
