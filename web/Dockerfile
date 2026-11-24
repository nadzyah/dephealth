# The browser application, in two shapes.
#
#   dev         the Vite development server, with the source bind mounted
#   production  the built files behind nginx
#
# The build arguments are read by Vite at build time and compiled into the
# bundle, so a production image is built for one API address. Nothing secret
# belongs in them: everything a browser receives is public.

FROM node:26-alpine AS deps

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

FROM deps AS dev

EXPOSE 5173
# Every interface, since nothing outside the container can reach a loopback
# address here
CMD ["npm", "run", "dev", "--", "--host", "0.0.0.0"]

FROM deps AS build

ARG VITE_API_BASE_URL=http://localhost:8080
ARG VITE_DEMO=false
ARG VITE_BASE=/

ENV VITE_API_BASE_URL=$VITE_API_BASE_URL
ENV VITE_DEMO=$VITE_DEMO
ENV VITE_BASE=$VITE_BASE

COPY . .
RUN npm run build

FROM nginx:1.31-alpine AS production

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 80

HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
    CMD ["wget", "--quiet", "--spider", "http://127.0.0.1/"]
